import CoreBluetooth
import FlutterMacOS
import Foundation

final class L2capBleConnection: BleConnection, StreamDelegate, @unchecked Sendable {
  private static let readBufferSize = Int(UInt16.max)
  private static let outputSpaceWaitIntervalMs = 5
  private let psm: CBL2CAPPSM
  private let stateQueue = DispatchQueue(label: "com.foundation.ble.macos.l2cap.state")
  private let readQueue = DispatchQueue(label: "com.foundation.ble.macos.l2cap.read")
  private let writeQueue = DispatchQueue(label: "com.foundation.ble.macos.l2cap.write")

  private let outputSpaceSemaphore = DispatchSemaphore(value: 0)

  private var l2capChannel: CBL2CAPChannel?
  private var inputStream: InputStream?
  private var outputStream: OutputStream?
  private var isOpeningChannel = false
  private var readLoopGeneration: UInt64 = 0
  private var suppressDisconnectEvent = false

  init(
    deviceId: String,
    binaryMessenger: FlutterBinaryMessenger,
    delegate: BleConnectionDelegate,
    psm: CBL2CAPPSM
  ) {
    self.psm = psm
    super.init(
      deviceId: deviceId,
      binaryMessenger: binaryMessenger,
      delegate: delegate
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

    return currentPeripheral.state == .connecting ||
      currentPeripheral.state == .connected ||
      stateQueue.sync { isOpeningChannel || l2capChannel != nil }
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
      log("adopting already-connecting peripheral")
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

    resetStreams(clearPeripheral: false)
    updateKnownPeripheral(peripheral)
    peripheral.delegate = self
    centralManager()?.connect(peripheral)
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
        continuation.resume(returning: self?.writeSynchronously(data) ?? false)
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

    if currentPeripheralMatches(peripheral) &&
      stateQueue.sync(execute: { isOpeningChannel || l2capChannel != nil })
    {
      log("didConnect ignored because channel is already opening/open")
      return
    }

    updateKnownPeripheral(peripheral)
    peripheral.delegate = self
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

  private func writeSynchronously(_ data: Data) -> Bool {
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

    return data.withUnsafeBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        return false
      }

      while totalWritten < byteCount {
        if !outputStream.hasSpaceAvailable {
          if !waitForOutputSpace(outputStream, stallStartedAt: &stallStartedAt) {
            let message = outputStream.streamError?.localizedDescription
              ?? "L2CAP write timed out waiting for output space"
            log(
              "write stalled outputStatus=\(describe(outputStream.streamStatus)) error=\(message)"
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
          continue
        }

        if written == 0,
           waitForOutputSpace(outputStream, stallStartedAt: &stallStartedAt)
        {
          continue
        }

        let message = outputStream.streamError?.localizedDescription ?? "L2CAP write failed"
        log(
          "write failed written=\(written) outputStatus=\(describe(outputStream.streamStatus)) error=\(message)"
        )
        failActiveChannel(message: message)
        return false
      }

      return true
    }
  }

  private func waitForOutputSpace(
    _ outputStream: OutputStream,
    stallStartedAt: inout CFAbsoluteTime?
  ) -> Bool {
    if outputStream.hasSpaceAvailable {
      stallStartedAt = nil
      return true
    }

    if stallStartedAt == nil {
      stallStartedAt = CFAbsoluteTimeGetCurrent()
    }

    while isConnected() {
      let result = outputSpaceSemaphore.wait(
        timeout: .now() + .milliseconds(Self.outputSpaceWaitIntervalMs)
      )
      if outputStream.hasSpaceAvailable {
        stallStartedAt = nil
        return true
      }

      if result == .timedOut,
         let stallStartedAt,
         CFAbsoluteTimeGetCurrent() - stallStartedAt >= 5
      {
        return false
      }

      if outputStream.streamError != nil {
        return false
      }
    }

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

    outputSpaceSemaphore.signal()
    teardownStreams(inputStream: streams.0, outputStream: streams.1)

    if clearPeripheral {
      clearConnectionState()
    }
  }

  private func configureStreams(inputStream: InputStream, outputStream: OutputStream) {
    let configure = {
      inputStream.delegate = self
      outputStream.delegate = self
      inputStream.schedule(in: .main, forMode: .common)
      outputStream.schedule(in: .main, forMode: .common)
      inputStream.open()
      outputStream.open()
    }

    if Thread.isMainThread {
      configure()
    } else {
      DispatchQueue.main.sync(execute: configure)
    }
  }

  private func teardownStreams(inputStream: InputStream?, outputStream: OutputStream?) {
    let teardown = {
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

  private func log(_ message: String) {
    NSLog("[FoundationBle:L2CAP][%@] %@", deviceId, message)
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
