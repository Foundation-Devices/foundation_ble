import AccessorySetupKit
import CoreBluetooth
import Flutter
import Foundation
import UIKit

class BluetoothChannel: NSObject, CBCentralManagerDelegate, BleConnectionDelegate {
    typealias AssetKeyResolver = (_ asset: String, _ package: String?) -> String

    private struct PickerConfigurationError: LocalizedError {
        let code: String
        let message: String

        var errorDescription: String? { message }
    }

    private struct PickerDisplayConfiguration {
        let id: String?
        let name: String
        let displayItem: ASPickerDisplayItem
        let descriptor: ASDiscoveryDescriptor
        let bluetoothCompanyIdentifier: UInt16?
        let bluetoothNameSubstring: String?
        let bluetoothServiceUUID: String?
    }

    private struct TrackedBleConnection {
        let connection: BleConnection
    }

    private let methodChannelName = "foundation_ble/bluetooth"
    private let bleScanStreamName = "foundation_ble/bluetooth/scan/stream"
    private let bleLogStreamName = "foundation_ble/bluetooth/log/stream"

    private let assetKeyResolver: AssetKeyResolver
    private let binaryMessenger: FlutterBinaryMessenger
    private let bleQueue = DispatchQueue(label: "xyz.foundation.ble", qos: .userInteractive)

    private var centralManager: CBCentralManager?
    private var methodChannel: FlutterMethodChannel?
    private var scanEventSink: FlutterEventSink?
    private var logEventSink: FlutterEventSink?
    private var setupResult: FlutterResult?
    private var session: ASAccessorySession?
    private var accessorySetupSessionError: PickerConfigurationError?

    private var devices: [String: TrackedBleConnection] = [:]
    private var pairedAccessories: [UUID: ASAccessory] = [:]
    private var knownPeripherals: [String: CBPeripheral] = [:]
    private var knownPeripheralNames: [String: String] = [:]
    private var activePickerItems: [PickerDisplayConfiguration] = []

    private let restoreIdentifier: String
    private var needsServiceRediscovery = false
    private var restoredPeripheralId: String?
    private var reconnectionTimer: Timer?
    private var reconnectionAttempts = 0
    private var isShuttingDown = false

    init(
        binaryMessenger: FlutterBinaryMessenger,
        assetKeyResolver: @escaping AssetKeyResolver
    ) {
        let bundleId = Bundle.main.bundleIdentifier ?? "xyz.foundation"
        restoreIdentifier = "\(bundleId).ble.restore"
        self.assetKeyResolver = assetKeyResolver
        self.binaryMessenger = binaryMessenger
        super.init()

        FlutterEventChannel(name: bleScanStreamName, binaryMessenger: binaryMessenger)
            .setStreamHandler(ScanStreamHandler(bluetoothChannel: self))

        FlutterEventChannel(name: bleLogStreamName, binaryMessenger: binaryMessenger)
            .setStreamHandler(LogStreamHandler(bluetoothChannel: self))

        methodChannel = FlutterMethodChannel(
            name: methodChannelName,
            binaryMessenger: binaryMessenger
        )

        ensureBluetoothManager()

        methodChannel?.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterError(code: "internal", message: "self deallocated", details: nil))
                return
            }

            switch call.method {
            case "requestBlePermissions":
                result(true)
            case "getBleAdapterState":
                result(self.centralManager?.state == .poweredOn)
            case "enableBluetooth":
                self.enableBluetooth(result: result)
            case "showAccessorySetup":
                self.showAccessorySetup(call: call, result: result)
            case "deviceName":
                result(UIDevice.current.name)
            case "getAccessories":
                self.getAccessories(call: call, result: result)
            case "getConnectedDevices":
                self.getConnectedDevices(call: call, result: result)
            case "startScan":
                self.startScan(call: call, result: result)
            case "stopScan":
                self.stopScan(result: result)
            case "prepareDevice":
                self.prepareDevice(call: call, result: result)
            case "reconnect":
                self.reconnect(call: call, result: result)
            case "removeDevice":
                self.removeDevice(call: call, result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        ensureBluetoothManager()
        setupAccessorySession()
    }

    func onDeviceDisconnected(device: BleConnection) {
    }

    func getCentralManager() -> CBCentralManager? {
        centralManager
    }

    func reconnect(device: BleConnection, result: @escaping FlutterResult) {
        reconnect(
            deviceId: device.deviceId,
            result: result
        )
    }

    private func enableBluetooth(result: @escaping FlutterResult) {
        ensureBluetoothManager()
        result(centralManager?.state == .poweredOn)
    }

    private func ensureBluetoothManager() {
        if centralManager == nil {
            centralManager = CBCentralManager(
                delegate: self,
                queue: bleQueue,
                options: [
                    CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier
                ]
            )
        }
    }

    private func getOrCreateDevice(deviceId: String) -> BleConnection {
        if let existingDevice = devices[deviceId] {
            if !existingDevice.connection.isCleanedUp {
                return existingDevice.connection
            }

            existingDevice.connection.cleanup()
        }

        let device = GattBleConnection(
            deviceId: deviceId,
            binaryMessenger: binaryMessenger,
            delegate: self,
            accessorySession: session,
            logCallback: { [weak self] type, message in
                self?.emitLog(type: type, message: message)
            }
        )

        if let peripheralName = knownPeripheralNames[deviceId] {
            device.updateKnownPeripheralName(peripheralName)
        }

        devices[deviceId] = TrackedBleConnection(connection: device)
        return device
    }

    private func prepareDevice(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
            let deviceId = arguments["deviceId"] as? String,
            !deviceId.isEmpty
        else {
            result(
                FlutterError(
                    code: "INVALID_DEVICE_ID",
                    message: "Device ID is required",
                    details: nil
                )
            )
            return
        }

        ensureBluetoothManager()

        let bleConnection = getOrCreateDevice(deviceId: deviceId)
        if let peripheral = resolvePeripheral(deviceId: deviceId), let peripheralName = peripheral.name {
            bleConnection.updateKnownPeripheralName(peripheralName)
        }
        result(true)
    }

    private func reconnect(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
            let deviceId = arguments["deviceId"] as? String,
            !deviceId.isEmpty
        else {
            result(
                FlutterError(
                    code: "INVALID_DEVICE_ID",
                    message: "Device ID is required",
                    details: nil
                )
            )
            return
        }

        reconnect(deviceId: deviceId, result: result)
    }

    private func reconnect(
        deviceId: String,
        result: @escaping FlutterResult
    ) {
        guard ensureAccessorySetupSession(result: result) != nil else {
            return
        }

        ensureBluetoothManager()

        guard let central = centralManager, central.state == .poweredOn else {
            result(
                FlutterError(
                    code: "NO_CENTRAL",
                    message: "Central manager not available or not powered on",
                    details: nil
                )
            )
            return
        }

        guard let bluetoothId = UUID(uuidString: deviceId), isAccessoryAssociated(bluetoothId) else {
            removeTrackedDevice(deviceId: deviceId, disconnectError: "Accessory is no longer associated")

            result(
                FlutterError(
                    code: "ACCESSORY_NOT_ASSOCIATED",
                    message: "Accessory is not associated on iOS",
                    details: deviceId
                )
            )
            return
        }

        let bleConnection = getOrCreateDevice(deviceId: deviceId)

        if let accessory = accessory(for: deviceId) {
            bleConnection.updateKnownPeripheralName(accessory.displayName)
        }

        guard let peripheral = resolvePeripheral(deviceId: deviceId) else {
            result(
                FlutterError(
                    code: "DEVICE_NOT_FOUND",
                    message: "Device not found: \(deviceId)",
                    details: nil
                )
            )
            return
        }

        knownPeripherals[deviceId] = peripheral
        if let peripheralName = peripheral.name, !peripheralName.isEmpty {
            knownPeripheralNames[deviceId] = peripheralName
            bleConnection.updateKnownPeripheralName(peripheralName)
        }

        logBle(
            "reconnect deviceId=\(deviceId) peripheralState=\(peripheral.state.rawValue) tracked=\(devices[deviceId] != nil)"
        )

        if bleConnection.hasActiveOrPendingConnection(for: peripheral) {
            logBle("reconnect skipped because connection is already active or pending deviceId=\(deviceId)")
            result(["reconnecting": true])
            return
        }

        if peripheral.state == .connected {
            logBle("reconnect forwarding connected peripheral directly to connection deviceId=\(deviceId)")
            bleConnection.onDidConnect(peripheral: peripheral)
        } else {
            logBle("reconnect asking connection to connect deviceId=\(deviceId)")
            bleConnection.connect(peripheral: peripheral)
        }

        _ = central
        result(["reconnecting": true])
    }

    private func getConnectedDevices(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard ensureAccessorySetupSession(result: result) != nil else {
            return
        }

        let connectedDevices = buildKnownDeviceEntries().filter { entry in
            entry["isConnected"] as? Bool == true
        }
        result(connectedDevices)
    }

    private func getAccessories(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard ensureAccessorySetupSession(result: result) != nil else {
            return
        }

        result(buildKnownDeviceEntries())
    }

    private func startScan(call: FlutterMethodCall, result: @escaping FlutterResult) {
        result(["scanning": true])
    }

    private func stopScan(result: @escaping FlutterResult) {
        result(["scanning": false])
    }

    private func removeDevice(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
            let deviceId = arguments["deviceId"] as? String,
            !deviceId.isEmpty
        else {
            result(
                FlutterError(
                    code: "INVALID_DEVICE_ID",
                    message: "Device ID is required",
                    details: nil
                )
            )
            return
        }

        let accessory = accessory(for: deviceId)
        let hadKnownState =
            devices[deviceId] != nil || knownPeripherals[deviceId] != nil || knownPeripheralNames[deviceId] != nil || accessory != nil

        let finalizeRemoval = { [weak self] in
            guard let self else {
                return
            }

            if let peripheral = self.knownPeripherals[deviceId] ?? self.devices[deviceId]?.connection.currentPeripheral,
                let central = self.centralManager,
                peripheral.state == .connected || peripheral.state == .connecting
            {
                central.cancelPeripheralConnection(peripheral)
            }

            self.knownPeripherals.removeValue(forKey: deviceId)
            self.knownPeripheralNames.removeValue(forKey: deviceId)

            self.removeTrackedDevice(deviceId: deviceId, disconnectError: "Device removed")

            if let bluetoothId = UUID(uuidString: deviceId) {
                self.pairedAccessories.removeValue(forKey: bluetoothId)
            }
        }

        if let accessory, let session {
            session.removeAccessory(accessory) { [weak self] error in
                if let error {
                    result(
                        FlutterError(
                            code: "REMOVE_ACCESSORY_FAILED",
                            message: "Failed to remove accessory",
                            details: error.localizedDescription
                        )
                    )
                    return
                }

                finalizeRemoval()
                self?.emitAccessoryRemovedEvent(accessory: accessory)
                result(true)
            }
            return
        }

        finalizeRemoval()
        result(hadKnownState)
    }

    private func resolvePeripheral(deviceId: String, serviceUUID: CBUUID? = nil) -> CBPeripheral? {
        if let knownPeripheral = knownPeripherals[deviceId] {
            return knownPeripheral
        }

        guard let uuid = UUID(uuidString: deviceId), let central = centralManager else {
            return nil
        }

        let cachedPeripherals = central.retrievePeripherals(withIdentifiers: [uuid])
        if let peripheral = cachedPeripherals.first {
            cacheResolvedPeripheral(peripheral, deviceId: deviceId)
            return peripheral
        }

        if let serviceUUID {
            let connectedPeripherals = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
            if let peripheral = connectedPeripherals.first(where: { $0.identifier == uuid }) {
                cacheResolvedPeripheral(peripheral, deviceId: deviceId)
                return peripheral
            }
        }
        return nil
    }

    private func cacheResolvedPeripheral(_ peripheral: CBPeripheral, deviceId: String) {
        knownPeripherals[deviceId] = peripheral
        if let peripheralName = peripheral.name, !peripheralName.isEmpty {
            knownPeripheralNames[deviceId] = peripheralName
        }
    }

    func cleanup() {
        isShuttingDown = true
        stopReconnection()

        for (_, trackedDevice) in devices {
            trackedDevice.connection.cleanup()
        }

        devices.removeAll()
        knownPeripherals.removeAll()
        knownPeripheralNames.removeAll()
        pairedAccessories.removeAll()
        activePickerItems.removeAll()
        scanEventSink = nil
        setupResult = nil
        methodChannel?.setMethodCallHandler(nil)
        methodChannel = nil
        centralManager?.delegate = nil
        centralManager = nil
        session?.invalidate()
        session = nil
    }

    private func isAccessoryAssociated(_ bluetoothId: UUID) -> Bool {
        sessionAccessories.contains { $0.bluetoothIdentifier == bluetoothId }
    }

    private func accessory(for deviceId: String) -> ASAccessory? {
        guard let bluetoothId = UUID(uuidString: deviceId) else {
            return nil
        }

        return sessionAccessories.first(where: { $0.bluetoothIdentifier == bluetoothId }) ?? pairedAccessories[bluetoothId]
    }


    private func removeTrackedDevice(deviceId: String, disconnectError: String? = nil) {
        guard let trackedDevice = devices.removeValue(forKey: deviceId) else {
            return
        }

        let connection = trackedDevice.connection
        if connection.currentPeripheral != nil || connection.isConnected() {
            connection.onDeviceDisconnected(error: disconnectError)
        }

        connection.clearKnownPeripheralName()
        connection.cleanup()
    }

    private func attemptReconnection() {
        guard !pairedAccessories.isEmpty else {
            stopReconnection()
            return
        }

        let staleIds = pairedAccessories.keys.filter { !isAccessoryAssociated($0) }
        for bluetoothId in staleIds {
            pairedAccessories.removeValue(forKey: bluetoothId)
        }

        guard !pairedAccessories.isEmpty else {
            stopReconnection()
            return
        }

        guard let central = centralManager, central.state == .poweredOn else {
            scheduleReconnection()
            return
        }

        _ = central
        for (bluetoothId, _) in pairedAccessories {
            let deviceId = bluetoothId.uuidString
            guard let trackedDevice = devices[deviceId] else {
                continue
            }
            if trackedDevice.connection.isConnected() {
                continue
            }

            connectToAccessoryPeripheral(bluetoothId: bluetoothId)
        }
    }

    private func scheduleReconnection() {
        reconnectionAttempts += 1
        reconnectionTimer?.invalidate()
        let delay = min(pow(2.0, Double(reconnectionAttempts)), 30.0)
        DispatchQueue.main.async { [weak self] in
            self?.reconnectionTimer = Timer.scheduledTimer(
                withTimeInterval: delay,
                repeats: false
            ) { [weak self] _ in
                self?.attemptReconnection()
            }
        }
    }

    private func stopReconnection() {
        reconnectionTimer?.invalidate()
        reconnectionTimer = nil
        reconnectionAttempts = 0
    }

    private func setupAccessorySession() {
        guard session == nil, accessorySetupSessionError == nil else {
            return
        }

        if let configurationError = accessorySetupSessionConfigurationError() {
            accessorySetupSessionError = configurationError
            return
        }

        let session = ASAccessorySession()
        self.session = session
        session.activate(on: DispatchQueue.main, eventHandler: handleAccessoryEvent)
    }

    private func showAccessorySetup(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let session = ensureAccessorySetupSession(result: result) else {
            return
        }

        guard UIApplication.shared.applicationState == .active else {
            logAccessorySetup("showAccessorySetup skipped because applicationState is not active")
            result(nil)
            return
        }

        let arguments = call.arguments as? [String: Any] ?? [:]
        logAccessorySetup("showAccessorySetup request=\(accessorySetupDebugDescription(of: arguments))")

        let pickerItems: [PickerDisplayConfiguration]
        do {
            pickerItems = try buildPickerDisplayItems(arguments: arguments)
            logAccessorySetup(
                "parsed picker items=\(pickerItems.map { accessorySetupSummary(for: $0) }.joined(separator: "; "))"
            )
        } catch let error as PickerConfigurationError {
            logAccessorySetup("failed to build picker items code=\(error.code) message=\(error.message)")
            result(
                FlutterError(
                    code: error.code,
                    message: error.message,
                    details: nil
                )
            )
            return
        } catch {
            logAccessorySetup("failed to build picker items error=\(error.localizedDescription)")
            result(
                FlutterError(
                    code: "ACCESSORY_SETUP_INVALID_ARGUMENTS",
                    message: error.localizedDescription,
                    details: nil
                )
            )
            return
        }

        do {
            try validatePickerDisplayItemsAgainstAppConfiguration(pickerItems)
            logAccessorySetup("picker items passed Info.plist validation")
        } catch let error as PickerConfigurationError {
            logAccessorySetup("failed Info.plist validation code=\(error.code) message=\(error.message)")
            result(
                FlutterError(
                    code: error.code,
                    message: error.message,
                    details: nil
                )
            )
            return
        } catch {
            logAccessorySetup("failed Info.plist validation error=\(error.localizedDescription)")
            result(
                FlutterError(
                    code: "ACCESSORY_SETUP_INVALID_CONFIGURATION",
                    message: error.localizedDescription,
                    details: nil
                )
            )
            return
        }

        if setupResult != nil {
            logAccessorySetup("showAccessorySetup rejected because a picker is already showing")
            result(
                FlutterError(
                    code: "ACCESSORY_SETUP_ALREADY_ACTIVE",
                    message: "A picker is already showing",
                    details: nil
                )
            )
            return
        }

        activePickerItems = pickerItems
        setupResult = result
        logAccessorySetup(
            "presenting accessory picker with items=\(pickerItems.map { accessorySetupSummary(for: $0) }.joined(separator: "; "))"
        )

        Task { @MainActor in
            await presentAccessoryPicker(session: session, displayItems: pickerItems.map(\.displayItem))
        }
    }

    @MainActor
    private func presentAccessoryPicker(
        session: ASAccessorySession,
        displayItems: [ASPickerDisplayItem]
    ) async {
        logAccessorySetup("session.showPicker starting displayItemCount=\(displayItems.count)")
        do {
            try await session.showPicker(for: displayItems)
            logAccessorySetup("session.showPicker completed without throwing")
        } catch {
            logAccessorySetup("session.showPicker failed error=\(error.localizedDescription)")
            activePickerItems.removeAll()
            if let setupResult {
                setupResult(nil)
                self.setupResult = nil
            }
        }
    }

    private func handleAccessoryEvent(event: ASAccessoryEvent) {
        switch event.eventType {
        case .accessoryAdded, .accessoryChanged:
            guard let accessory = event.accessory else { return }
            logAccessorySetup(
                "event=\(String(describing: event.eventType)) accessory=\(accessorySetupSummary(for: accessory))"
            )
            initWithAccessory(accessory: accessory)
        case .activated:
            logAccessorySetup("event=activated existingAccessoryCount=\(sessionAccessories.count)")
            checkAndConnectToExistingAccessories()
        case .accessoryRemoved:
            if let accessory = event.accessory {
                logAccessorySetup("event=accessoryRemoved accessory=\(accessorySetupSummary(for: accessory))")
                handleAccessoryRemoved(accessory: accessory)
            }
        case .pickerDidDismiss:
            logAccessorySetup("event=pickerDidDismiss")
            activePickerItems.removeAll()
            if let setupResult {
                setupResult(nil)
                self.setupResult = nil
            }
        case .pickerSetupFailed:
            let errorDescription = event.error?.localizedDescription ?? "nil"
            if let accessory = event.accessory {
                logAccessorySetup(
                    "event=pickerSetupFailed error=\(errorDescription) accessory=\(accessorySetupSummary(for: accessory))"
                )
            } else {
                logAccessorySetup("event=pickerSetupFailed error=\(errorDescription)")
            }
        default:
            break
        }
    }

    private func initWithAccessory(accessory: ASAccessory) {
        if let bluetoothId = accessory.bluetoothIdentifier {
            pairedAccessories[bluetoothId] = accessory
            let deviceId = bluetoothId.uuidString
            knownPeripheralNames[deviceId] = accessory.displayName
            devices[deviceId]?.connection.updateKnownPeripheralName(accessory.displayName)
        }

        ensureBluetoothManager()

        if let bluetoothId = accessory.bluetoothIdentifier {
            sendScanEvent(
                type: "device_found",
                deviceId: bluetoothId.uuidString,
                deviceName: accessory.displayName
            )
        }

        if let setupResult {
            if let bluetoothId = accessory.bluetoothIdentifier {
                var payload: [String: Any] = ["deviceId": bluetoothId.uuidString]
                let pickerItemId = pickerItemId(for: accessory)
                logAccessorySetup(
                    "completing accessory setup deviceId=\(bluetoothId.uuidString) pickerItemId=\(pickerItemId ?? "nil") accessory=\(accessorySetupSummary(for: accessory))"
                )
                if let pickerItemId {
                    payload["pickerItemId"] = pickerItemId
                }
                setupResult(payload)
            } else {
                setupResult(nil)
            }
            self.setupResult = nil
            activePickerItems.removeAll()
        }
    }

    private func checkAndConnectToExistingAccessories() {
        ensureBluetoothManager()
        for accessory in sessionAccessories {
            guard let bluetoothId = accessory.bluetoothIdentifier else {
                continue
            }

            pairedAccessories[bluetoothId] = accessory
            let deviceId = bluetoothId.uuidString
            knownPeripheralNames[deviceId] = accessory.displayName
            devices[deviceId]?.connection.updateKnownPeripheralName(accessory.displayName)

            sendScanEvent(
                type: "device_found",
                deviceId: deviceId,
                deviceName: accessory.displayName
            )

            guard let trackedDevice = devices[deviceId],
                let central = centralManager,
                central.state == .poweredOn
            else {
                continue
            }

            connectToAccessoryPeripheral(bluetoothId: bluetoothId)
        }
    }

    private func handleAccessoryRemoved(accessory: ASAccessory) {
        emitAccessoryRemovedEvent(accessory: accessory)

        if let bluetoothId = accessory.bluetoothIdentifier {
            pairedAccessories.removeValue(forKey: bluetoothId)
            let deviceId = bluetoothId.uuidString
            knownPeripherals.removeValue(forKey: deviceId)
            knownPeripheralNames.removeValue(forKey: deviceId)
            removeTrackedDevice(deviceId: deviceId, disconnectError: "Accessory removed")
        }
    }

    private func emitAccessoryRemovedEvent(accessory: ASAccessory) {
        let peripheralId = accessory.bluetoothIdentifier?.uuidString ?? accessory.displayName
        sendScanEvent(
            type: "device_disconnected",
            deviceId: peripheralId,
            deviceName: accessory.displayName
        )
    }

    private func connectToAccessoryPeripheral(bluetoothId: UUID) {
        guard isAccessoryAssociated(bluetoothId),
            let central = centralManager,
            central.state == .poweredOn
        else {
            return
        }

        let deviceId = bluetoothId.uuidString
        guard let peripheral = resolvePeripheral(deviceId: deviceId) else {
            logBle("connectToAccessoryPeripheral peripheral cache miss deviceId=\(deviceId) — CB has not restored the peripheral reference yet, skipping")
            return
        }

        let bleConnection = getOrCreateDevice(deviceId: deviceId)
        if let accessory = pairedAccessories[bluetoothId] ?? sessionAccessories.first(where: { $0.bluetoothIdentifier == bluetoothId }) {
            bleConnection.updateKnownPeripheralName(accessory.displayName)
        }
        if let peripheralName = peripheral.name {
            bleConnection.updateKnownPeripheralName(peripheralName)
        }

        logBle(
            "connectToAccessoryPeripheral deviceId=\(deviceId) peripheralState=\(peripheral.state.rawValue)"
        )

        if bleConnection.hasActiveOrPendingConnection(for: peripheral) {
            logBle("connectToAccessoryPeripheral skipped because connection is already active or pending deviceId=\(deviceId)")
            return
        }

        cacheResolvedPeripheral(peripheral, deviceId: deviceId)
        if peripheral.state == .connected {
            logBle("connectToAccessoryPeripheral forwarding connected peripheral deviceId=\(deviceId)")
            bleConnection.onDidConnect(peripheral: peripheral)
        } else {
            logBle("connectToAccessoryPeripheral asking connection to connect deviceId=\(deviceId)")
            bleConnection.connect(peripheral: peripheral)
        }

        _ = central
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            handleBluetoothPoweredOn(central: central)
        case .poweredOff:
            handleBluetoothPoweredOff()
        default:
            break
        }
    }

    private func handleBluetoothPoweredOn(central: CBCentralManager) {
        var sessionPaired: [UUID: ASAccessory] = [:]
        for accessory in sessionAccessories {
            if let bluetoothId = accessory.bluetoothIdentifier {
                sessionPaired[bluetoothId] = accessory
                knownPeripheralNames[bluetoothId.uuidString] = accessory.displayName
            }
        }
        pairedAccessories = sessionPaired

        for (deviceId, _) in devices {
            guard let bluetoothId = UUID(uuidString: deviceId),
                pairedAccessories[bluetoothId] != nil
            else {
                continue
            }

            connectToAccessoryPeripheral(bluetoothId: bluetoothId)
        }

        if needsServiceRediscovery, let restoredPeripheralId {
            handleRestoredPeripheral(peripheralId: restoredPeripheralId, central: central)
        }
    }

    private func handleBluetoothPoweredOff() {
        for (_, trackedDevice) in devices where trackedDevice.connection.isConnected() {
            trackedDevice.connection.sendConnectionEvent(type: nil, error: "Bluetooth powered off")
        }
    }

    private func handleRestoredPeripheral(peripheralId: String, central: CBCentralManager) {
        guard let bluetoothId = UUID(uuidString: peripheralId),
            isAccessoryAssociated(bluetoothId)
        else {
            removeTrackedDevice(deviceId: peripheralId, disconnectError: "Accessory is no longer associated")
            needsServiceRediscovery = false
            restoredPeripheralId = nil
            return
        }

        let peripherals = central.retrievePeripherals(withIdentifiers: [bluetoothId])
        guard let peripheral = peripherals.first else {
            needsServiceRediscovery = false
            restoredPeripheralId = nil
            return
        }

        cacheResolvedPeripheral(peripheral, deviceId: peripheralId)
        let bleConnection = getOrCreateDevice(deviceId: peripheralId)
        if let accessory = accessory(for: peripheralId) {
            bleConnection.updateKnownPeripheralName(accessory.displayName)
        }

        if peripheral.state == .connected {
            bleConnection.onDidConnect(peripheral: peripheral)
        } else {
            bleConnection.connect(peripheral: peripheral)
        }

        needsServiceRediscovery = false
        restoredPeripheralId = nil
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                let deviceId = peripheral.identifier.uuidString
                knownPeripherals[deviceId] = peripheral
                if let peripheralName = peripheral.name, !peripheralName.isEmpty {
                    knownPeripheralNames[deviceId] = peripheralName
                }

                guard isAccessoryAssociated(peripheral.identifier),
                    let trackedDevice = devices[deviceId]
                else {
                    continue
                }

                if peripheral.state == .connected {
                    needsServiceRediscovery = true
                    restoredPeripheralId = deviceId
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let deviceId = peripheral.identifier.uuidString
        logBle("central didConnect deviceId=\(deviceId) state=\(peripheral.state.rawValue) tracked=\(devices[deviceId] != nil)")
        cacheResolvedPeripheral(peripheral, deviceId: deviceId)
        devices[deviceId]?.connection.onDidConnect(peripheral: peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let deviceId = peripheral.identifier.uuidString
        logBle(
            "central didFailToConnect deviceId=\(deviceId) state=\(peripheral.state.rawValue) tracked=\(devices[deviceId] != nil) error=\(error?.localizedDescription ?? "nil")"
        )
        cacheResolvedPeripheral(peripheral, deviceId: deviceId)
        devices[deviceId]?.connection.onDidFailToConnect(peripheral: peripheral, error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if isShuttingDown {
            return
        }

        let deviceId = peripheral.identifier.uuidString
        logBle(
            "central didDisconnect deviceId=\(deviceId) state=\(peripheral.state.rawValue) tracked=\(devices[deviceId] != nil) error=\(error?.localizedDescription ?? "nil")"
        )
        cacheResolvedPeripheral(peripheral, deviceId: deviceId)
        devices[deviceId]?.connection.onDidDisconnect(peripheral: peripheral, error: error)

        if isAccessoryAssociated(peripheral.identifier) {
            scheduleReconnection()
        }
    }

    private func sendScanEvent(type: String, deviceId: String? = nil, deviceName: String? = nil) {
        var payload: [String: Any] = ["type": type]
        if let deviceId {
            payload["deviceId"] = deviceId
        }
        if let deviceName {
            payload["deviceName"] = deviceName
        }

        let send = { [weak self] in
            self?.scanEventSink?(payload)
        }

        if Thread.isMainThread {
            send()
        } else {
            DispatchQueue.main.async {
                send()
            }
        }
    }

    private func buildKnownDeviceEntries() -> [[String: Any]] {
        var orderedDeviceIds: [String] = []
        var deviceEntries: [String: (accessory: ASAccessory?, peripheral: CBPeripheral?, connection: BleConnection?)] =
            [:]

        func upsert(
            deviceId: String,
            accessory: ASAccessory?,
            peripheral: CBPeripheral?,
            connection: BleConnection?
        ) {
            if deviceEntries[deviceId] == nil {
                orderedDeviceIds.append(deviceId)
                deviceEntries[deviceId] = (accessory, peripheral, connection)
                return
            }

            let existing = deviceEntries[deviceId]
            deviceEntries[deviceId] = (
                accessory ?? existing?.accessory,
                peripheral ?? existing?.peripheral,
                connection ?? existing?.connection
            )
        }

        for (bluetoothId, accessory) in pairedAccessories {
            let deviceId = bluetoothId.uuidString
            upsert(
                deviceId: deviceId,
                accessory: accessory,
                peripheral: knownPeripherals[deviceId],
                connection: devices[deviceId]?.connection
            )
        }

        for (deviceId, peripheral) in knownPeripherals {
            upsert(
                deviceId: deviceId,
                accessory: accessory(for: deviceId),
                peripheral: peripheral,
                connection: devices[deviceId]?.connection
            )
        }

        for (deviceId, trackedDevice) in devices {
            upsert(
                deviceId: deviceId,
                accessory: accessory(for: deviceId),
                peripheral: trackedDevice.connection.currentPeripheral ?? knownPeripherals[deviceId] ?? resolvePeripheral(deviceId: deviceId),
                connection: trackedDevice.connection
            )
        }

        return orderedDeviceIds.map { deviceId in
            let entry = deviceEntries[deviceId]
            let accessory = entry?.accessory
            let peripheral = entry?.peripheral
            let connection = entry?.connection
            let isConnected = connection?.isConnected() == true || peripheral?.state == .connected
            let peripheralName =
                connection?.peripheralName ?? accessory?.displayName ?? peripheral?.name ?? knownPeripheralNames[deviceId] ?? "Unknown"
            let state =
                connection?.currentPeripheral?.state.rawValue ?? peripheral?.state.rawValue
                ?? (isConnected
                    ? CBPeripheralState.connected.rawValue
                    : CBPeripheralState.disconnected.rawValue)
            let bonded = accessory != nil || connection?.isBonded == true

            return [
                "deviceId": deviceId,
                "name": peripheralName,
                "bonded": bonded,
                "peripheralId": deviceId,
                "peripheralName": peripheralName,
                "isConnected": isConnected,
                "state": state,
                "bondState": bonded,
            ]
        }
    }


    private func matchesIdentifier(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs else {
            return false
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func buildPickerDisplayItems(arguments: [String: Any]) throws
        -> [PickerDisplayConfiguration]
    {
        guard let rawItems = arguments["items"] else {
            throw PickerConfigurationError(
                code: "ACCESSORY_SETUP_INVALID_ITEMS",
                message: "items must be a non-empty array"
            )
        }

        guard let items = rawItems as? [Any], !items.isEmpty else {
            throw PickerConfigurationError(
                code: "ACCESSORY_SETUP_INVALID_ITEMS",
                message: "items must be a non-empty array"
            )
        }

        return try items.enumerated().map { index, rawItem in
            guard let item = rawItem as? [String: Any] else {
                throw PickerConfigurationError(
                    code: "ACCESSORY_SETUP_INVALID_ITEM",
                    message: "items[\(index)] must be a map"
                )
            }
            return try buildPickerDisplayItem(item: item, index: index)
        }
    }

    //makes sure IOS
    private func validatePickerDisplayItemsAgainstAppConfiguration(
        _ pickerItems: [PickerDisplayConfiguration]
    ) throws {
        let infoDictionary = Bundle.main.infoDictionary ?? [:]

        let supportedTechnologies = accessorySetupSupportedTechnologies(in: infoDictionary)
        guard
            supportedTechnologies.contains(where: {
                $0.caseInsensitiveCompare("Bluetooth") == .orderedSame
            })
        else {
            throw PickerConfigurationError(
                code: "ACCESSORY_SETUP_MISSING_INFO_PLIST_SUPPORT",
                message: "Info.plist must include NSAccessorySetupSupports or NSAccessorySetupKitSupports with Bluetooth before showing the iOS accessory picker."
            )
        }

        let declaredBluetoothNames = infoDictionaryStringArrayValue(
            forKey: "NSAccessorySetupBluetoothNames",
            in: infoDictionary
        )
        let declaredBluetoothServices = Set(
            infoDictionaryStringArrayValue(
                forKey: "NSAccessorySetupBluetoothServices",
                in: infoDictionary
            ).map { CBUUID(string: $0).uuidString }
        )
        let declaredBluetoothCompanyIdentifiers = infoDictionaryStringArrayValue(
            forKey: "NSAccessorySetupBluetoothCompanyIdentifiers",
            in: infoDictionary
        )

        logAccessorySetup(
            "validating picker items supportedTechnologies=\(supportedTechnologies) declaredNames=\(declaredBluetoothNames) declaredServices=\(declaredBluetoothServices.sorted()) declaredCompanyIds=\(declaredBluetoothCompanyIdentifiers)"
        )

        for (index, pickerItem) in pickerItems.enumerated() {
            if let bluetoothNameSubstring = pickerItem.bluetoothNameSubstring,
                !declaredBluetoothNames.contains(where: {
                    bluetoothNameMatchesDeclaredEntry(
                        bluetoothNameSubstring,
                        declaredEntry: $0
                    )
                })
            {
                throw PickerConfigurationError(
                    code: "ACCESSORY_SETUP_UNDECLARED_BLUETOOTH_NAME",
                    message: "items[\(index)].descriptor.bluetoothNameSubstring must be declared in Info.plist under NSAccessorySetupBluetoothNames."
                )
            }

            if let bluetoothServiceUUID = pickerItem.bluetoothServiceUUID {
                let normalizedService = CBUUID(string: bluetoothServiceUUID).uuidString
                guard declaredBluetoothServices.contains(normalizedService) else {
                    throw PickerConfigurationError(
                        code: "ACCESSORY_SETUP_UNDECLARED_BLUETOOTH_SERVICE",
                        message: "items[\(index)].descriptor.bluetoothServiceUuid must be declared in Info.plist under NSAccessorySetupBluetoothServices."
                    )
                }
            }

            if let bluetoothCompanyIdentifier = pickerItem.bluetoothCompanyIdentifier {
                guard
                    declaredBluetoothCompanyIdentifiers.contains(where: {
                        bluetoothCompanyIdentifierMatchesDeclaredEntry(
                            bluetoothCompanyIdentifier,
                            declaredEntry: $0
                        )
                    })
                else {
                    throw PickerConfigurationError(
                        code: "ACCESSORY_SETUP_UNDECLARED_BLUETOOTH_COMPANY_ID",
                        message: "items[\(index)].descriptor.bluetoothCompanyIdentifier must be declared in Info.plist under NSAccessorySetupBluetoothCompanyIdentifiers."
                    )
                }
            }
        }

        logAccessorySetup("validated \(pickerItems.count) picker item(s) against Info.plist")
    }

    private func buildPickerDisplayItem(item: [String: Any], index: Int) throws
        -> PickerDisplayConfiguration
    {
        guard let id = item["id"] as? String, !id.isEmpty else {
            throw PickerConfigurationError(
                code: "ACCESSORY_SETUP_INVALID_ITEM_ID",
                message: "items[\(index)].id must be a non-empty string"
            )
        }

        guard let name = item["name"] as? String, !name.isEmpty else {
            throw PickerConfigurationError(
                code: "ACCESSORY_SETUP_INVALID_ITEM_NAME",
                message: "items[\(index)].name must be a non-empty string"
            )
        }

        guard let descriptorArguments = item["descriptor"] as? [String: Any] else {
            throw PickerConfigurationError(
                code: "ACCESSORY_SETUP_INVALID_DESCRIPTOR",
                message: "items[\(index)].descriptor must be a map"
            )
        }

        let descriptor = try buildDiscoveryDescriptor(
            arguments: descriptorArguments,
            index: index
        )
        let image = try resolvePickerImage(
            asset: item["imageAsset"] as? String,
            package: item["imagePackage"] as? String,
            index: index
        )
        let displayItem = ASPickerDisplayItem(
            name: name,
            productImage: image,
            descriptor: descriptor
        )

        return PickerDisplayConfiguration(
            id: id,
            name: name,
            displayItem: displayItem,
            descriptor: descriptor,
            bluetoothCompanyIdentifier: intValue(
                from: descriptorArguments["bluetoothCompanyIdentifier"]
            ).flatMap { value in
                guard (0...0xFFFF).contains(value) else {
                    return nil
                }
                return UInt16(value)
            },
            bluetoothNameSubstring: descriptorArguments["bluetoothNameSubstring"] as? String,
            bluetoothServiceUUID: descriptorArguments["bluetoothServiceUuid"] as? String
        )
    }

    private func buildDiscoveryDescriptor(arguments: [String: Any], index: Int) throws
        -> ASDiscoveryDescriptor
    {
        let descriptor = ASDiscoveryDescriptor()
        descriptor.supportedOptions = [.bluetoothPairingLE]
        var hasBluetoothFilter = false

        if let bluetoothCompanyIdentifier = intValue(from: arguments["bluetoothCompanyIdentifier"]) {
            guard (0...0xFFFF).contains(bluetoothCompanyIdentifier) else {
                throw PickerConfigurationError(
                    code: "ACCESSORY_SETUP_INVALID_COMPANY_ID",
                    message: "items[\(index)].descriptor.bluetoothCompanyIdentifier must be between 0 and 65535"
                )
            }
            descriptor.bluetoothCompanyIdentifier =
                ASBluetoothCompanyIdentifier(rawValue: UInt16(bluetoothCompanyIdentifier))
            hasBluetoothFilter = true
        }

        if let bluetoothManufacturerData = typedData(from: arguments["bluetoothManufacturerData"]) {
            descriptor.bluetoothManufacturerDataBlob = bluetoothManufacturerData
            hasBluetoothFilter = true
        }

        if let bluetoothManufacturerDataMask = typedData(
            from: arguments["bluetoothManufacturerDataMask"]
        ) {
            guard descriptor.bluetoothManufacturerDataBlob != nil else {
                throw PickerConfigurationError(
                    code: "ACCESSORY_SETUP_INVALID_MANUFACTURER_MASK",
                    message: "items[\(index)].descriptor.bluetoothManufacturerDataMask requires bluetoothManufacturerData"
                )
            }
            guard descriptor.bluetoothManufacturerDataBlob?.count == bluetoothManufacturerDataMask.count
            else {
                throw PickerConfigurationError(
                    code: "ACCESSORY_SETUP_INVALID_MANUFACTURER_MASK",
                    message: "items[\(index)].descriptor.bluetoothManufacturerData and bluetoothManufacturerDataMask must have the same length"
                )
            }
            descriptor.bluetoothManufacturerDataMask = bluetoothManufacturerDataMask
        }

        if let bluetoothNameSubstring = arguments["bluetoothNameSubstring"] as? String {
            guard !bluetoothNameSubstring.isEmpty else {
                throw PickerConfigurationError(
                    code: "ACCESSORY_SETUP_INVALID_NAME_SUBSTRING",
                    message: "items[\(index)].descriptor.bluetoothNameSubstring must not be empty"
                )
            }
            descriptor.bluetoothNameSubstring = bluetoothNameSubstring
            hasBluetoothFilter = true
        }

        let bluetoothNameCompareOptions = try parseBluetoothNameCompareOptions(
            value: arguments["bluetoothNameCompareOptions"],
            index: index
        )
        if !bluetoothNameCompareOptions.isEmpty {
            guard descriptor.bluetoothNameSubstring != nil else {
                throw PickerConfigurationError(
                    code: "ACCESSORY_SETUP_INVALID_NAME_COMPARE_OPTIONS",
                    message: "items[\(index)].descriptor.bluetoothNameCompareOptions requires bluetoothNameSubstring"
                )
            }
            guard #available(iOS 18.2, *) else {
                throw PickerConfigurationError(
                    code: "ACCESSORY_SETUP_UNSUPPORTED_NAME_COMPARE_OPTIONS",
                    message: "bluetoothNameCompareOptions requires iOS 18.2 or newer"
                )
            }
            descriptor.bluetoothNameSubstringCompareOptions = bluetoothNameCompareOptions
        }

        descriptor.bluetoothRange = try parseBluetoothRange(
            value: arguments["bluetoothRange"],
            index: index
        )

        if let bluetoothServiceData = typedData(from: arguments["bluetoothServiceData"]) {
            descriptor.bluetoothServiceDataBlob = bluetoothServiceData
            hasBluetoothFilter = true
        }

        if let bluetoothServiceDataMask = typedData(from: arguments["bluetoothServiceDataMask"]) {
            guard descriptor.bluetoothServiceDataBlob != nil else {
                throw PickerConfigurationError(
                    code: "ACCESSORY_SETUP_INVALID_SERVICE_MASK",
                    message: "items[\(index)].descriptor.bluetoothServiceDataMask requires bluetoothServiceData"
                )
            }
            guard descriptor.bluetoothServiceDataBlob?.count == bluetoothServiceDataMask.count else {
                throw PickerConfigurationError(
                    code: "ACCESSORY_SETUP_INVALID_SERVICE_MASK",
                    message: "items[\(index)].descriptor.bluetoothServiceData and bluetoothServiceDataMask must have the same length"
                )
            }
            descriptor.bluetoothServiceDataMask = bluetoothServiceDataMask
        }

        if let bluetoothServiceUUID = arguments["bluetoothServiceUuid"] as? String {
            guard !bluetoothServiceUUID.isEmpty else {
                throw PickerConfigurationError(
                    code: "ACCESSORY_SETUP_INVALID_SERVICE_UUID",
                    message: "items[\(index)].descriptor.bluetoothServiceUuid must not be empty"
                )
            }
            descriptor.bluetoothServiceUUID = CBUUID(string: bluetoothServiceUUID)
            hasBluetoothFilter = true
        }

        guard hasBluetoothFilter else {
            throw PickerConfigurationError(
                code: "ACCESSORY_SETUP_MISSING_FILTERS",
                message: "items[\(index)].descriptor must include at least one Bluetooth discovery filter"
            )
        }

        return descriptor
    }

    private func resolvePickerImage(asset: String?, package: String?, index: Int) throws -> UIImage {
        guard let asset, !asset.isEmpty else {
            return UIImage()
        }

        let resolvedPackage = package?.isEmpty == true ? nil : package
        let assetKey = assetKeyResolver(asset, resolvedPackage)
        guard let imagePath = Bundle.main.path(forResource: assetKey, ofType: nil),
            let image = UIImage(contentsOfFile: imagePath)
        else {
            throw PickerConfigurationError(
                code: "ACCESSORY_SETUP_INVALID_IMAGE_ASSET",
                message: "Failed to load items[\(index)].imageAsset: \(asset)"
            )
        }

        return image
    }

    private func typedData(from value: Any?) -> Data? {
        if let typedData = value as? FlutterStandardTypedData {
            return typedData.data
        }
        if let data = value as? Data {
            return data
        }
        return nil
    }

    private func intValue(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }

    private func parseBluetoothRange(value: Any?, index: Int) throws -> ASDiscoveryDescriptor.Range {
        guard let rawValue = value as? String else {
            return ASDiscoveryDescriptor.Range.default
        }

        switch rawValue {
        case "default":
            return ASDiscoveryDescriptor.Range.default
        case "immediate":
            return ASDiscoveryDescriptor.Range.immediate
        default:
            throw PickerConfigurationError(
                code: "ACCESSORY_SETUP_INVALID_RANGE",
                message: "items[\(index)].descriptor.bluetoothRange must be one of: default, immediate"
            )
        }
    }

    private func parseBluetoothNameCompareOptions(value: Any?, index: Int) throws
        -> NSString.CompareOptions
    {
        guard let rawValues = value as? [Any] else {
            return []
        }

        var options: NSString.CompareOptions = []
        for rawValue in rawValues {
            guard let option = rawValue as? String else {
                throw PickerConfigurationError(
                    code: "ACCESSORY_SETUP_INVALID_NAME_COMPARE_OPTIONS",
                    message: "items[\(index)].descriptor.bluetoothNameCompareOptions must be an array of strings"
                )
            }

            switch option {
            case "caseInsensitive":
                options.insert(.caseInsensitive)
            case "literal":
                options.insert(.literal)
            case "backwards":
                options.insert(.backwards)
            case "anchored":
                options.insert(.anchored)
            case "numeric":
                options.insert(.numeric)
            case "diacriticInsensitive":
                options.insert(.diacriticInsensitive)
            case "widthInsensitive":
                options.insert(.widthInsensitive)
            case "forcedOrdering":
                options.insert(.forcedOrdering)
            case "regularExpression":
                options.insert(.regularExpression)
            default:
                throw PickerConfigurationError(
                    code: "ACCESSORY_SETUP_INVALID_NAME_COMPARE_OPTION",
                    message: "items[\(index)].descriptor.bluetoothNameCompareOptions contains unsupported value: \(option)"
                )
            }
        }

        return options
    }

    private func infoDictionaryStringArrayValue(
        forKey key: String,
        in infoDictionary: [String: Any]
    ) -> [String] {
        guard let values = infoDictionary[key] as? [Any] else {
            return []
        }

        return values.compactMap { value in
            if let stringValue = value as? String {
                return stringValue
            }
            return nil
        }
    }

    private func bluetoothNameMatchesDeclaredEntry(
        _ bluetoothNameSubstring: String,
        declaredEntry: String
    ) -> Bool {
        let normalizedSubstring = bluetoothNameSubstring.lowercased()
        let normalizedDeclaredEntry = declaredEntry.lowercased()
        return normalizedDeclaredEntry.contains(normalizedSubstring) || normalizedSubstring.contains(normalizedDeclaredEntry)
    }

    private func bluetoothCompanyIdentifierMatchesDeclaredEntry(
        _ bluetoothCompanyIdentifier: UInt16,
        declaredEntry: String
    ) -> Bool {
        let trimmedValue = declaredEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return false
        }

        if let decimalValue = UInt16(trimmedValue, radix: 10),
            decimalValue == bluetoothCompanyIdentifier
        {
            return true
        }

        let normalizedValue =
            trimmedValue.lowercased().hasPrefix("0x")
            ? String(trimmedValue.dropFirst(2))
            : trimmedValue
        guard let hexValue = UInt16(normalizedValue, radix: 16) else {
            return false
        }
        return hexValue == bluetoothCompanyIdentifier
    }

    private func pickerItemId(for accessory: ASAccessory) -> String? {
        return activePickerItems.first(where: { configuration in
            discoveryDescriptorsMatch(configuration.descriptor, accessory.descriptor)
        })?.id
    }

    private func logAccessorySetup(_ message: String) {
        #if DEBUG
        NSLog("[FoundationBle:AccessorySetup] %@", message)
        #endif
    }

    private func accessorySetupSummary(for configuration: PickerDisplayConfiguration) -> String {
        accessorySetupSummary(
            id: configuration.id,
            name: configuration.name,
            bluetoothIdentifier: nil,
            bluetoothCompanyIdentifier: configuration.bluetoothCompanyIdentifier,
            descriptor: configuration.descriptor
        )
    }

    private func accessorySetupSummary(for accessory: ASAccessory) -> String {
        accessorySetupSummary(
            id: nil,
            name: accessory.displayName,
            bluetoothIdentifier: accessory.bluetoothIdentifier?.uuidString,
            bluetoothCompanyIdentifier: nil,
            descriptor: accessory.descriptor
        )
    }

    private func accessorySetupSummary(
        id: String?,
        name: String,
        bluetoothIdentifier: String?,
        bluetoothCompanyIdentifier: UInt16?,
        descriptor: ASDiscoveryDescriptor
    ) -> String {
        var parts: [String] = []

        if let id {
            parts.append("id=\(id)")
        }
        if let bluetoothIdentifier {
            parts.append("bluetoothId=\(bluetoothIdentifier)")
        }

        parts.append("name=\(name)")

        if let companyIdentifier = bluetoothCompanyIdentifier {
            parts.append(String(format: "companyId=0x%04X", companyIdentifier))
        }
        if let nameSubstring = descriptor.bluetoothNameSubstring {
            parts.append("nameSubstring=\(nameSubstring)")
        }

        parts.append("range=\(accessorySetupRangeDescription(descriptor.bluetoothRange))")

        if let serviceUUID = descriptor.bluetoothServiceUUID?.uuidString {
            parts.append("serviceUuid=\(serviceUUID)")
        }
        if let manufacturerData = descriptor.bluetoothManufacturerDataBlob {
            parts.append("manufacturerData=\(accessorySetupDataDescription(manufacturerData))")
        }
        if let manufacturerDataMask = descriptor.bluetoothManufacturerDataMask {
            parts.append("manufacturerMask=\(accessorySetupDataDescription(manufacturerDataMask))")
        }
        if let serviceData = descriptor.bluetoothServiceDataBlob {
            parts.append("serviceData=\(accessorySetupDataDescription(serviceData))")
        }
        if let serviceDataMask = descriptor.bluetoothServiceDataMask {
            parts.append("serviceMask=\(accessorySetupDataDescription(serviceDataMask))")
        }

        if #available(iOS 18.2, *), !descriptor.bluetoothNameSubstringCompareOptions.isEmpty {
            parts.append("nameCompareOptionsRaw=\(descriptor.bluetoothNameSubstringCompareOptions.rawValue)")
        }

        return parts.joined(separator: " ")
    }

    private func accessorySetupRangeDescription(_ range: ASDiscoveryDescriptor.Range) -> String {
        switch range {
        case .default:
            return "default"
        case .immediate:
            return "immediate"
        @unknown default:
            return String(describing: range)
        }
    }

    private func accessorySetupDataDescription(_ data: Data) -> String {
        let maxLoggedBytes = 32
        let prefix = data.prefix(maxLoggedBytes).map { String(format: "%02X", $0) }.joined()
        if data.count > maxLoggedBytes {
            return "0x\(prefix)... (\(data.count) bytes)"
        }
        return "0x\(prefix)"
    }

    private func accessorySetupDebugDescription(of value: Any?) -> String {
        switch value {
        case nil:
            return "nil"
        case let dictionary as [String: Any]:
            let entries = dictionary.keys.sorted().map { key in
                let valueDescription = accessorySetupDebugDescription(of: dictionary[key])
                return "\(key): \(valueDescription)"
            }
            return "{\(entries.joined(separator: ", "))}"
        case let array as [Any]:
            return "[\(array.map { accessorySetupDebugDescription(of: $0) }.joined(separator: ", "))]"
        case let typedData as FlutterStandardTypedData:
            return accessorySetupDataDescription(typedData.data)
        case let data as Data:
            return accessorySetupDataDescription(data)
        default:
            return String(describing: value)
        }
    }

    private var sessionAccessories: [ASAccessory] {
        session?.accessories ?? []
    }

    private func ensureAccessorySetupSession(result: @escaping FlutterResult) -> ASAccessorySession? {
        if let session {
            return session
        }

        setupAccessorySession()

        if let session {
            return session
        }

        let configurationError =
            accessorySetupSessionError
            ?? PickerConfigurationError(
                code: "ACCESSORY_SETUP_SESSION_UNAVAILABLE",
                message: "Unable to initialize AccessorySetupKit. Check your app Info.plist configuration."
            )
        result(
            FlutterError(
                code: configurationError.code,
                message: configurationError.message,
                details: nil
            )
        )
        return nil
    }

    private func accessorySetupSessionConfigurationError() -> PickerConfigurationError? {
        let infoDictionary = Bundle.main.infoDictionary ?? [:]
        let legacySupportedTechnologies = infoDictionaryStringArrayValue(
            forKey: "NSAccessorySetupKitSupports",
            in: infoDictionary
        )
        guard
            legacySupportedTechnologies.contains(where: {
                $0.caseInsensitiveCompare("Bluetooth") == .orderedSame || $0.caseInsensitiveCompare("WiFi") == .orderedSame
            })
        else {
            return PickerConfigurationError(
                code: "ACCESSORY_SETUP_MISSING_INFO_PLIST_SUPPORT",
                message: "Info.plist must include NSAccessorySetupKitSupports with Bluetooth or WiFi before initializing AccessorySetupKit. For compatibility, mirror the same values under NSAccessorySetupSupports as well."
            )
        }

        return nil
    }

    private func accessorySetupSupportedTechnologies(in infoDictionary: [String: Any]) -> [String] {
        infoDictionaryStringArrayValue(forKey: "NSAccessorySetupSupports", in: infoDictionary) + infoDictionaryStringArrayValue(forKey: "NSAccessorySetupKitSupports", in: infoDictionary)
    }

    private func discoveryDescriptorsMatch(
        _ lhs: ASDiscoveryDescriptor,
        _ rhs: ASDiscoveryDescriptor
    ) -> Bool {
        guard lhs.bluetoothCompanyIdentifier == rhs.bluetoothCompanyIdentifier,
            lhs.bluetoothManufacturerDataBlob == rhs.bluetoothManufacturerDataBlob,
            lhs.bluetoothManufacturerDataMask == rhs.bluetoothManufacturerDataMask,
            lhs.bluetoothNameSubstring == rhs.bluetoothNameSubstring,
            lhs.bluetoothRange == rhs.bluetoothRange,
            lhs.bluetoothServiceDataBlob == rhs.bluetoothServiceDataBlob,
            lhs.bluetoothServiceDataMask == rhs.bluetoothServiceDataMask,
            lhs.bluetoothServiceUUID == rhs.bluetoothServiceUUID
        else {
            return false
        }

        if #available(iOS 18.2, *) {
            return lhs.bluetoothNameSubstringCompareOptions == rhs.bluetoothNameSubstringCompareOptions
        }

        return true
    }

    private class ScanStreamHandler: NSObject, FlutterStreamHandler {
        weak var bluetoothChannel: BluetoothChannel?

        init(bluetoothChannel: BluetoothChannel) {
            self.bluetoothChannel = bluetoothChannel
        }

        func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
            -> FlutterError?
        {
            bluetoothChannel?.scanEventSink = events
            return nil
        }

        func onCancel(withArguments arguments: Any?) -> FlutterError? {
            bluetoothChannel?.scanEventSink = nil
            return nil
        }
    }

    private class LogStreamHandler: NSObject, FlutterStreamHandler {
        weak var bluetoothChannel: BluetoothChannel?

        init(bluetoothChannel: BluetoothChannel) {
            self.bluetoothChannel = bluetoothChannel
        }

        func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
            -> FlutterError?
        {
            bluetoothChannel?.logEventSink = events
            return nil
        }

        func onCancel(withArguments arguments: Any?) -> FlutterError? {
            bluetoothChannel?.logEventSink = nil
            return nil
        }
    }

    private func logBle(_ message: String) {
        NSLog("[FoundationBle:iOS] %@", message)
        sendLog(type: "DEBUG", message: message)
    }

    func emitLog(type: String, message: String) {
        sendLog(type: type, message: message)
    }

    private func sendLog(type: String, message: String) {
        let payload = [
            "type": type,
            "message": message,
        ]
        let send = { [weak self] in
            self?.logEventSink?(payload)
        }

        if Thread.isMainThread {
            send()
        } else {
            DispatchQueue.main.async {
                send()
            }
        }
    }
}
