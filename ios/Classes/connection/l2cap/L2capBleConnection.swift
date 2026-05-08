import AccessorySetupKit
import CoreBluetooth
import Flutter
import Foundation

final class L2capBleConnection: BleConnection, StreamDelegate, @unchecked Sendable {
    private static let readBufferSize = Int(UInt16.max)
    private static let outputSpaceWaitIntervalMs = 1
    private static let outputSpaceTimeoutSeconds: CFTimeInterval = 5
    private static let writeProgressLogIntervalBytes = 256 * 1024
    private static let writeProgressLogIntervalSeconds: CFTimeInterval = 1
    private static let notableOutputSpaceWaitThresholdSeconds: CFTimeInterval = 0.020
    private static let longOutputSpaceWaitLogThresholdSeconds: CFTimeInterval = 0.150
    private let psm: CBL2CAPPSM
    private let stateQueue = DispatchQueue(label: "com.foundation.ble.ios.l2cap.state")
    private let readQueue = DispatchQueue(label: "com.foundation.ble.ios.l2cap.read")
    private let writeQueue = DispatchQueue(label: "com.foundation.ble.ios.l2cap.write")

    private let outputSpaceSemaphore = DispatchSemaphore(value: 0)

    private var l2capChannel: CBL2CAPChannel?
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var isOpeningChannel = false
    private var readLoopGeneration: UInt64 = 0
    private var suppressDisconnectEvent = false

    private struct WriteDiagnostics {
        let reason: String
        let totalBytes: Int
        let startedAt: CFAbsoluteTime
        var lastProgressLogAt: CFAbsoluteTime
        var bytesAtLastProgressLog: Int
        var nextProgressByteCount: Int
        var waitCount = 0
        var notableWaitCount = 0
        var longWaitCount = 0
        var totalWaitSeconds: CFTimeInterval = 0
        var maxWaitSeconds: CFTimeInterval = 0
        var writeCallCount = 0
        var zeroWriteCount = 0
        var minWriteSize = Int.max
        var maxWriteSize = 0

        init(reason: String, totalBytes: Int, startedAt: CFAbsoluteTime) {
            self.reason = reason
            self.totalBytes = totalBytes
            self.startedAt = startedAt
            lastProgressLogAt = startedAt
            bytesAtLastProgressLog = 0
            nextProgressByteCount = min(totalBytes, L2capBleConnection.writeProgressLogIntervalBytes)
        }

        mutating func recordWait(duration: CFTimeInterval) {
            waitCount += 1
            totalWaitSeconds += duration
            maxWaitSeconds = max(maxWaitSeconds, duration)
            if duration >= L2capBleConnection.notableOutputSpaceWaitThresholdSeconds {
                notableWaitCount += 1
            }
            if duration >= L2capBleConnection.longOutputSpaceWaitLogThresholdSeconds {
                longWaitCount += 1
            }
        }

        mutating func recordWrite(bytes: Int) {
            writeCallCount += 1
            minWriteSize = min(minWriteSize, bytes)
            maxWriteSize = max(maxWriteSize, bytes)
        }

        mutating func recordZeroWrite() {
            zeroWriteCount += 1
        }

    }

    init(
        deviceId: String,
        binaryMessenger: FlutterBinaryMessenger,
        delegate: BleConnectionDelegate,
        accessorySession: ASAccessorySession?,
        psm: CBL2CAPPSM,
        logCallback: ((String) -> Void)? = nil
    ) {
        self.psm = psm
        super.init(
            deviceId: deviceId,
            binaryMessenger: binaryMessenger,
            delegate: delegate,
            accessorySession: accessorySession,
            logCallback: logCallback
        )
    }

    override func isReady() -> Bool {
        isConnected()
    }

    override func isConnected() -> Bool {
        guard currentPeripheral?.state == .connected else {
            return false
        }

        return stateQueue.sync {
            l2capChannel != nil && inputStream != nil && outputStream != nil
        }
    }

    override func hasActiveOrPendingConnection(for peripheral: CBPeripheral) -> Bool {
        guard let currentPeripheral,
            currentPeripheral.identifier == peripheral.identifier
        else {
            return false
        }

        return currentPeripheral.state == .connecting || currentPeripheral.state == .connected || stateQueue.sync { isOpeningChannel || l2capChannel != nil }
    }

    override func connect(peripheral: CBPeripheral) {
        log(
            "connect requested peripheral=\(peripheral.identifier.uuidString) state=\(peripheral.state.rawValue)"
        )

        if hasActiveOrPendingConnection(for: peripheral) {
            log("connect ignored because a connection is already active or pending")
            return
        }

        if let currentPeripheral,
            currentPeripheral.identifier != peripheral.identifier
        {
            closeChannel(
                cancelPeripheral: true,
                clearPeripheral: true,
                suppressNextDisconnectEvent: true
            )
        }

        if peripheral.state == .connecting {
            log("adopting already-connecting peripheral and waiting for central didConnect callback")
            updateKnownPeripheral(peripheral)
            peripheral.delegate = self
            return
        }

        if peripheral.state == .connected {
            log("peripheral already connected, opening L2CAP directly")
            onDidConnect(peripheral: peripheral)
            return
        }

        sendConnectionEvent(type: "connection_attempt")

        log("resetting streams before starting a fresh central connect")
        resetStreams(clearPeripheral: false)
        updateKnownPeripheral(peripheral)
        peripheral.delegate = self
        log("calling CBCentralManager.connect for peripheral=\(peripheral.identifier.uuidString)")
        centralManager()?.connect(peripheral, options: connectOptions())
    }

    override func disconnectTransport(result: @escaping FlutterResult) {
        let wasConnected = currentPeripheral != nil || isConnected()
        log("disconnect requested wasConnected=\(wasConnected)")
        closeChannel(
            cancelPeripheral: true,
            clearPeripheral: false,
            suppressNextDisconnectEvent: false
        )
        result(["disconnecting": wasConnected])
    }

    override func handleBinaryWrite(data: Data) async -> Data {
        let success = await withCheckedContinuation { continuation in
            writeQueue.async { [weak self] in
                continuation.resume(
                    returning: self?.writeSynchronously(data, reason: "application") ?? false
                )
            }
        }

        return success ? Data([1]) : Data()
    }

    override func cleanupTransport() {
        closeChannel(
            cancelPeripheral: true,
            clearPeripheral: true,
            suppressNextDisconnectEvent: true
        )
    }

    override func onDidConnect(peripheral: CBPeripheral) {
        log(
            "didConnect peripheral=\(peripheral.identifier.uuidString) state=\(peripheral.state.rawValue)"
        )

        if currentPeripheralMatches(peripheral) && stateQueue.sync(execute: { isOpeningChannel || l2capChannel != nil }) {
            log("didConnect ignored because channel is already opening/open")
            return
        }

        updateKnownPeripheral(peripheral)
        peripheral.delegate = self
        log("didConnect resetting any previous L2CAP streams before opening a new channel")
        resetStreams(clearPeripheral: false)

        stateQueue.sync {
            isOpeningChannel = true
        }
        log("opening L2CAP channel psm=0x\(String(psm, radix: 16))")
        peripheral.openL2CAPChannel(psm)
    }

    override func onDidFailToConnect(peripheral: CBPeripheral, error: Error?) {
        guard currentPeripheralMatches(peripheral) else {
            return
        }

        log("didFailToConnect error=\(error?.localizedDescription ?? "nil")")
        closeChannel(
            cancelPeripheral: false,
            clearPeripheral: true,
            suppressNextDisconnectEvent: true
        )
        onConnectionError(error?.localizedDescription ?? "Failed to connect to device")
    }

    override func onDidDisconnect(peripheral: CBPeripheral, error: Error?) {
        guard currentPeripheralMatches(peripheral) else {
            return
        }

        let shouldSuppress = stateQueue.sync {
            let value = suppressDisconnectEvent
            suppressDisconnectEvent = false
            return value
        }

        log(
            "didDisconnect error=\(error?.localizedDescription ?? "nil") suppress=\(shouldSuppress)"
        )
        resetStreams(clearPeripheral: true)

        if shouldSuppress {
            return
        }

        onDeviceDisconnected(error: error?.localizedDescription)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didOpen channel: CBL2CAPChannel?,
        error: Error?
    ) {
        guard currentPeripheralMatches(peripheral) else {
            log(
                "didOpen ignored because peripheral no longer matches current connection peripheral=\(peripheral.identifier.uuidString)"
            )
            return
        }

        if let error {
            log("didOpen failed error=\(error.localizedDescription)")
            failActiveChannel(message: "Failed to open L2CAP channel: \(error.localizedDescription)")
            return
        }

        guard let channel else {
            log("didOpen failed because channel is nil")
            failActiveChannel(message: "Failed to open L2CAP channel")
            return
        }

        guard let inputStream = channel.inputStream,
            let outputStream = channel.outputStream
        else {
            log("didOpen failed because channel streams are unavailable")
            failActiveChannel(message: "L2CAP channel streams are unavailable")
            return
        }

        log(
            "didOpen succeeded psm=0x\(String(channel.psm, radix: 16)) inputStatus=\(describe(inputStream.streamStatus)) outputStatus=\(describe(outputStream.streamStatus))"
        )
        log("configuring L2CAP streams on main run loop")
        configureStreams(inputStream: inputStream, outputStream: outputStream)

        log(
            "streams opened inputStatus=\(describe(inputStream.streamStatus)) outputStatus=\(describe(outputStream.streamStatus))"
        )

        let generation = stateQueue.sync { () -> UInt64 in
            l2capChannel = channel
            self.inputStream = inputStream
            self.outputStream = outputStream
            isOpeningChannel = false
            readLoopGeneration &+= 1
            suppressDisconnectEvent = false
            return readLoopGeneration
        }

        log("starting read loop generation=\(generation)")
        startReadLoop(inputStream: inputStream, generation: generation)
        sendConnectionEvent(type: "device_connected")
    }

    private func writeSynchronously(_ data: Data, reason: String) -> Bool {
        guard let outputStream = stateQueue.sync(execute: { self.outputStream }),
            isConnected()
        else {
            log("write aborted because no connected output stream is available")
            return false
        }

        if data.isEmpty {
            return true
        }

        let byteCount = data.count
        var totalWritten = 0
        var stallStartedAt: CFAbsoluteTime?
        var diagnostics = WriteDiagnostics(
            reason: reason,
            totalBytes: byteCount,
            startedAt: CFAbsoluteTimeGetCurrent()
        )

        log(
            "write started reason=\(reason) bytes=\(byteCount) outputStatus=\(describe(outputStream.streamStatus)) hasSpace=\(outputStream.hasSpaceAvailable)"
        )

        return data.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }

            while totalWritten < byteCount {
                if !outputStream.hasSpaceAvailable {
                    if !waitForOutputSpace(
                        outputStream,
                        stallStartedAt: &stallStartedAt,
                        diagnostics: &diagnostics,
                        totalWritten: totalWritten
                    ) {
                        let message =
                            outputStream.streamError?.localizedDescription
                            ?? "L2CAP write timed out waiting for output space"
                        log(
                            "write stalled outputStatus=\(describe(outputStream.streamStatus)) error=\(message)"
                        )
                        logWriteSummary(
                            diagnostics,
                            totalWritten: totalWritten,
                            outcome: "failed_wait",
                            outputStatus: outputStream.streamStatus
                        )
                        failActiveChannel(message: message)
                        return false
                    }
                    continue
                }

                let written = outputStream.write(
                    baseAddress.advanced(by: totalWritten),
                    maxLength: byteCount - totalWritten
                )

                if written > 0 {
                    totalWritten += written
                    stallStartedAt = nil
                    diagnostics.recordWrite(bytes: written)
                    maybeLogWriteProgress(
                        diagnostics: &diagnostics,
                        totalWritten: totalWritten
                    )
                    continue
                }

                if written == 0,
                    {
                        diagnostics.recordZeroWrite()
                        return waitForOutputSpace(
                            outputStream,
                            stallStartedAt: &stallStartedAt,
                            diagnostics: &diagnostics,
                            totalWritten: totalWritten
                        )
                    }()
                {
                    continue
                }

                let message = outputStream.streamError?.localizedDescription ?? "L2CAP write failed"
                log(
                    "write failed written=\(written) outputStatus=\(describe(outputStream.streamStatus)) error=\(message)"
                )
                logWriteSummary(
                    diagnostics,
                    totalWritten: totalWritten,
                    outcome: "failed_write",
                    outputStatus: outputStream.streamStatus
                )
                failActiveChannel(message: message)
                return false
            }

            logWriteSummary(
                diagnostics,
                totalWritten: totalWritten,
                outcome: "completed",
                outputStatus: outputStream.streamStatus
            )
            return true
        }
    }

    private func waitForOutputSpace(
        _ outputStream: OutputStream,
        stallStartedAt: inout CFAbsoluteTime?,
        diagnostics: inout WriteDiagnostics,
        totalWritten: Int
    ) -> Bool {
        if outputStream.hasSpaceAvailable {
            stallStartedAt = nil
            return true
        }

        if outputStream.streamError != nil {
            return false
        }

        if stallStartedAt == nil {
            stallStartedAt = CFAbsoluteTimeGetCurrent()
        }

        let timeoutAt = stallStartedAt! + Self.outputSpaceTimeoutSeconds
        let waitStartedAt = CFAbsoluteTimeGetCurrent()

        while isConnected() {
            let result = outputSpaceSemaphore.wait(
                timeout: .now() + .milliseconds(Self.outputSpaceWaitIntervalMs)
            )

            if outputStream.hasSpaceAvailable {
                let waitDuration = CFAbsoluteTimeGetCurrent() - waitStartedAt
                diagnostics.recordWait(duration: waitDuration)
                maybeLogNotableWait(
                    diagnostics: diagnostics,
                    waitDuration: waitDuration,
                    totalWritten: totalWritten
                )
                stallStartedAt = nil
                return true
            }

            if outputStream.streamError != nil {
                let waitDuration = CFAbsoluteTimeGetCurrent() - waitStartedAt
                diagnostics.recordWait(duration: waitDuration)
                maybeLogNotableWait(
                    diagnostics: diagnostics,
                    waitDuration: waitDuration,
                    totalWritten: totalWritten
                )
                return false
            }

            if result == .timedOut,
                CFAbsoluteTimeGetCurrent() >= timeoutAt
            {
                let waitDuration = CFAbsoluteTimeGetCurrent() - waitStartedAt
                diagnostics.recordWait(duration: waitDuration)
                maybeLogNotableWait(
                    diagnostics: diagnostics,
                    waitDuration: waitDuration,
                    totalWritten: totalWritten
                )
                return false
            }
        }

        let waitDuration = CFAbsoluteTimeGetCurrent() - waitStartedAt
        diagnostics.recordWait(duration: waitDuration)
        maybeLogNotableWait(
            diagnostics: diagnostics,
            waitDuration: waitDuration,
            totalWritten: totalWritten
        )
        return false
    }

    private func startReadLoop(inputStream: InputStream, generation: UInt64) {
        log(
            "read loop armed generation=\(generation) inputStatus=\(describe(inputStream.streamStatus))"
        )

        if inputStream.hasBytesAvailable {
            drainInputStream(inputStream: inputStream, generation: generation)
        }
    }

    private func drainInputStream(inputStream: InputStream, generation: UInt64) {
        readQueue.async { [weak self] in
            guard let self else {
                return
            }
            guard self.isCurrentReadLoop(inputStream: inputStream, generation: generation) else {
                self.log("read loop skipped because generation changed")
                return
            }

            // Apple L2CAP streams can deliver up to 65535-byte packets, so keep the
            // read buffer large enough to avoid unnecessary read iterations.
            var buffer = [UInt8](repeating: 0, count: Self.readBufferSize)

            while inputStream.hasBytesAvailable {
                let readCount = inputStream.read(&buffer, maxLength: buffer.count)

                if readCount > 0 {
                    self.sendBinaryData(Data(buffer.prefix(readCount)))
                    continue
                }

                if readCount < 0 {
                    let message = inputStream.streamError?.localizedDescription ?? "L2CAP read failed"
                    self.log(
                        "read loop failed count=\(readCount) inputStatus=\(self.describe(inputStream.streamStatus)) error=\(message)"
                    )
                    self.handleReadLoopTermination(error: message, generation: generation)
                    return
                }

                if inputStream.streamStatus == .atEnd {
                    self.log(
                        "read loop reached EOF inputStatus=\(self.describe(inputStream.streamStatus)) error=\(inputStream.streamError?.localizedDescription ?? "nil")"
                    )
                    self.handleReadLoopTermination(error: nil, generation: generation)
                    return
                }

                self.log(
                    "read loop yielded no bytes; waiting for next stream event inputStatus=\(self.describe(inputStream.streamStatus))"
                )
                return
            }
        }
    }

    private func handleReadLoopTermination(error: String?, generation: UInt64) {
        let isCurrentGeneration = stateQueue.sync { readLoopGeneration == generation }
        guard isCurrentGeneration else {
            log("read loop termination ignored for stale generation=\(generation)")
            return
        }

        log("read loop terminating error=\(error ?? "nil") generation=\(generation)")
        if let error {
            failActiveChannel(message: error)
            return
        }

        closeChannel(
            cancelPeripheral: true,
            clearPeripheral: false,
            suppressNextDisconnectEvent: false
        )
    }

    private func failActiveChannel(message: String) {
        log("failActiveChannel message=\(message)")
        closeChannel(
            cancelPeripheral: true,
            clearPeripheral: false,
            suppressNextDisconnectEvent: true
        )
        onConnectionError(message)
    }

    private func closeChannel(
        cancelPeripheral: Bool,
        clearPeripheral: Bool,
        suppressNextDisconnectEvent: Bool
    ) {
        let peripheral = currentPeripheral

        log(
            "closeChannel cancelPeripheral=\(cancelPeripheral) clearPeripheral=\(clearPeripheral) suppressNextDisconnectEvent=\(suppressNextDisconnectEvent) peripheralState=\(peripheral?.state.rawValue ?? -1) inputStatus=\(currentInputStreamStatus()) outputStatus=\(currentOutputStreamStatus())"
        )

        stateQueue.sync {
            if suppressNextDisconnectEvent {
                suppressDisconnectEvent = true
            }
            readLoopGeneration &+= 1
        }

        resetStreams(clearPeripheral: clearPeripheral)

        guard cancelPeripheral,
            let peripheral,
            peripheral.state == .connected || peripheral.state == .connecting
        else {
            return
        }

        centralManager()?.cancelPeripheralConnection(peripheral)
    }

    private func resetStreams(clearPeripheral: Bool) {
        let streams = stateQueue.sync { () -> (InputStream?, OutputStream?) in
            let streams = (self.inputStream, self.outputStream)
            l2capChannel = nil
            self.inputStream = nil
            outputStream = nil
            isOpeningChannel = false
            return streams
        }

        log(
            "resetStreams clearPeripheral=\(clearPeripheral) inputStatus=\(describe(streams.0?.streamStatus)) outputStatus=\(describe(streams.1?.streamStatus))"
        )

        teardownStreams(inputStream: streams.0, outputStream: streams.1)

        if clearPeripheral {
            clearConnectionState()
        }
    }

    private func configureStreams(inputStream: InputStream, outputStream: OutputStream) {
        let configure = {
            self.log(
                "configureStreams on main run loop inputStatus=\(self.describe(inputStream.streamStatus)) outputStatus=\(self.describe(outputStream.streamStatus))"
            )
            inputStream.delegate = self
            outputStream.delegate = self
            inputStream.schedule(in: .main, forMode: .common)
            outputStream.schedule(in: .main, forMode: .common)
            inputStream.open()
            outputStream.open()
            self.log(
                "configureStreams completed inputStatus=\(self.describe(inputStream.streamStatus)) outputStatus=\(self.describe(outputStream.streamStatus))"
            )
        }

        if Thread.isMainThread {
            configure()
        } else {
            DispatchQueue.main.sync(execute: configure)
        }
    }

    private func teardownStreams(inputStream: InputStream?, outputStream: OutputStream?) {
        let teardown = {
            self.log(
                "teardownStreams on main run loop inputStatus=\(self.describe(inputStream?.streamStatus)) outputStatus=\(self.describe(outputStream?.streamStatus))"
            )
            inputStream?.delegate = nil
            outputStream?.delegate = nil
            inputStream?.remove(from: .main, forMode: .common)
            outputStream?.remove(from: .main, forMode: .common)
            inputStream?.close()
            outputStream?.close()
        }

        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.sync(execute: teardown)
        }
    }

    private func isCurrentReadLoop(inputStream: InputStream, generation: UInt64) -> Bool {
        stateQueue.sync {
            self.inputStream === inputStream && readLoopGeneration == generation
        }
    }

    private func isCurrentConnection(generation: UInt64) -> Bool {
        guard currentPeripheral?.state == .connected else {
            return false
        }

        return stateQueue.sync {
            readLoopGeneration == generation && l2capChannel != nil && outputStream != nil
        }
    }

    private func currentInputStreamStatus() -> String {
        stateQueue.sync {
            describe(inputStream?.streamStatus)
        }
    }

    private func currentOutputStreamStatus() -> String {
        stateQueue.sync {
            describe(outputStream?.streamStatus)
        }
    }

    private func maybeLogWriteProgress(
        diagnostics: inout WriteDiagnostics,
        totalWritten: Int
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let shouldLog =
            totalWritten >= diagnostics.totalBytes ||
            totalWritten >= diagnostics.nextProgressByteCount ||
            now - diagnostics.lastProgressLogAt >= Self.writeProgressLogIntervalSeconds

        guard shouldLog else {
            return
        }

        let elapsed = max(now - diagnostics.startedAt, 0.001)
        let intervalElapsed = max(now - diagnostics.lastProgressLogAt, 0.001)
        let intervalBytes = totalWritten - diagnostics.bytesAtLastProgressLog
        let overallKBps = Double(totalWritten) / elapsed / 1024
        let recentKBps = Double(intervalBytes) / intervalElapsed / 1024
        let averageWriteSize =
            diagnostics.writeCallCount > 0
            ? Double(totalWritten) / Double(diagnostics.writeCallCount)
            : 0

        log(
            "write progress reason=\(diagnostics.reason) written=\(totalWritten)/\(diagnostics.totalBytes) elapsedMs=\(formatMs(elapsed)) overallKBps=\(formatRate(overallKBps)) recentKBps=\(formatRate(recentKBps)) waits=\(diagnostics.waitCount) notableWaits=\(diagnostics.notableWaitCount) totalWaitMs=\(formatMs(diagnostics.totalWaitSeconds)) maxWaitMs=\(formatMs(diagnostics.maxWaitSeconds)) writeCalls=\(diagnostics.writeCallCount) avgWriteSize=\(formatBytes(averageWriteSize))"
        )

        diagnostics.lastProgressLogAt = now
        diagnostics.bytesAtLastProgressLog = totalWritten
        diagnostics.nextProgressByteCount = min(
            diagnostics.totalBytes,
            totalWritten + Self.writeProgressLogIntervalBytes
        )
    }

    private func maybeLogNotableWait(
        diagnostics: WriteDiagnostics,
        waitDuration: CFTimeInterval,
        totalWritten: Int
    ) {
        guard waitDuration >= Self.longOutputSpaceWaitLogThresholdSeconds else {
            return
        }

        log(
            "write wait reason=\(diagnostics.reason) waitMs=\(formatMs(waitDuration)) written=\(totalWritten)/\(diagnostics.totalBytes) waits=\(diagnostics.waitCount) outputStatus=\(currentOutputStreamStatus())"
        )
    }

    private func logWriteSummary(
        _ diagnostics: WriteDiagnostics,
        totalWritten: Int,
        outcome: String,
        outputStatus: Stream.Status
    ) {
        let elapsed = max(CFAbsoluteTimeGetCurrent() - diagnostics.startedAt, 0.001)
        let overallKBps = Double(totalWritten) / elapsed / 1024
        let minWriteSize = diagnostics.minWriteSize == Int.max ? 0 : diagnostics.minWriteSize
        let averageWriteSize =
            diagnostics.writeCallCount > 0
            ? Double(totalWritten) / Double(diagnostics.writeCallCount)
            : 0

        log(
            "write summary reason=\(diagnostics.reason) outcome=\(outcome) written=\(totalWritten)/\(diagnostics.totalBytes) elapsedMs=\(formatMs(elapsed)) overallKBps=\(formatRate(overallKBps)) waits=\(diagnostics.waitCount) notableWaits=\(diagnostics.notableWaitCount) longWaits=\(diagnostics.longWaitCount) totalWaitMs=\(formatMs(diagnostics.totalWaitSeconds)) maxWaitMs=\(formatMs(diagnostics.maxWaitSeconds)) writeCalls=\(diagnostics.writeCallCount) zeroWrites=\(diagnostics.zeroWriteCount) minWriteSize=\(minWriteSize) maxWriteSize=\(diagnostics.maxWriteSize) avgWriteSize=\(formatBytes(averageWriteSize)) outputStatus=\(describe(outputStatus))"
        )
    }

    private func formatMs(_ seconds: CFTimeInterval) -> String {
        String(format: "%.1f", seconds * 1000)
    }

    private func formatRate(_ kilobytesPerSecond: Double) -> String {
        String(format: "%.1f", kilobytesPerSecond)
    }

    private func formatBytes(_ byteCount: Double) -> String {
        String(format: "%.1f", byteCount)
    }

    private func describe(_ status: Stream.Status?) -> String {
        guard let status else {
            return "nil"
        }

        switch status {
        case .notOpen:
            return "notOpen"
        case .opening:
            return "opening"
        case .open:
            return "open"
        case .reading:
            return "reading"
        case .writing:
            return "writing"
        case .atEnd:
            return "atEnd"
        case .closed:
            return "closed"
        case .error:
            return "error"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    override func log(_ message: String) {
        NSLog("[FoundationBle:L2CAP][%@] %@", deviceId, message)
        super.log(message)
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if let inputStream = aStream as? InputStream {
            let generation = stateQueue.sync { () -> UInt64? in
                guard self.inputStream === inputStream else {
                    return nil
                }
                return readLoopGeneration
            }
            guard let generation else {
                return
            }

            if eventCode.contains(.hasBytesAvailable) {
                drainInputStream(inputStream: inputStream, generation: generation)
            }

            if eventCode.contains(.errorOccurred) {
                let message = inputStream.streamError?.localizedDescription ?? "L2CAP read failed"
                log(
                    "input stream error inputStatus=\(describe(inputStream.streamStatus)) error=\(message)"
                )
                handleReadLoopTermination(error: message, generation: generation)
                return
            }

            if eventCode.contains(.endEncountered) {
                log(
                    "input stream ended inputStatus=\(describe(inputStream.streamStatus)) error=\(inputStream.streamError?.localizedDescription ?? "nil")"
                )
                handleReadLoopTermination(error: nil, generation: generation)
            }
            return
        }

        guard let outputStream = aStream as? OutputStream else {
            return
        }

        let isCurrentOutputStream = stateQueue.sync {
            self.outputStream === outputStream
        }
        guard isCurrentOutputStream else {
            return
        }

        if eventCode.contains(.hasSpaceAvailable) ||
            eventCode.contains(.errorOccurred) ||
            eventCode.contains(.endEncountered)
        {
            outputSpaceSemaphore.signal()
        }
    }
}
