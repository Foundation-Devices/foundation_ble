import AppKit
import CoreBluetooth
import FlutterMacOS
import Foundation

class BluetoothChannel: NSObject, CBCentralManagerDelegate, BleConnectionDelegate {
  private struct ScanRequest {
    let filterDeviceId: String?
    let serviceUUID: CBUUID?

    var scanServices: [CBUUID]? {
      guard let serviceUUID else {
        return nil
      }
      return [serviceUUID]
    }
  }

  private struct TrackedBleConnection {
    let connection: BleConnection
  }

  private let methodChannelName = "foundation_ble/bluetooth"
  private let bleScanStreamName = "foundation_ble/bluetooth/scan/stream"
  private let bleLogStreamName = "foundation_ble/bluetooth/log/stream"
  private let primeUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
  private let scanTimeoutSeconds: TimeInterval = 15

  private let binaryMessenger: FlutterBinaryMessenger
  private let bleQueue = DispatchQueue(label: "xyz.foundation.ble.macos", qos: .userInteractive)

  private var centralManager: CBCentralManager?
  private var permissionProbeManager: CBCentralManager?
  private var methodChannel: FlutterMethodChannel?
  private var scanEventSink: FlutterEventSink?
  private var logEventSink: FlutterEventSink?
  private var pendingPermissionResult: FlutterResult?
  private var pendingScanResult: FlutterResult?
  private var pendingScanRequest: ScanRequest?
  private var permissionTimeoutWorkItem: DispatchWorkItem?
  private var scanTimeoutWorkItem: DispatchWorkItem?

  private var devices: [String: TrackedBleConnection] = [:]
  private var knownPeripherals: [String: CBPeripheral] = [:]
  private var knownPeripheralNames: [String: String] = [:]
  private var activeScanRequest: ScanRequest?
  private var isScanning = false
  private var isShuttingDown = false
  private var isPermissionProbeActive = false

  init(binaryMessenger: FlutterBinaryMessenger) {
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

    methodChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "internal", message: "self deallocated", details: nil))
        return
      }

      switch call.method {
      case "deviceName":
        result(self.hostDeviceName())
      case "requestBlePermissions":
        self.requestBlePermissions(result: result)
      case "enableBluetooth":
        self.ensureBluetoothManager()
        result(self.centralManager?.state == .poweredOn)
      case "pair":
        self.pair(call: call, result: result)
      case "getAccessories":
        self.getAccessories(call: call, result: result)
      case "getConnectedDevices":
        self.getConnectedDevices(call: call, result: result)
      case "prepareDevice":
        self.prepareDevice(call: call, result: result)
      case "reconnect":
        self.reconnect(call: call, result: result)
      case "removeDevice":
        self.removeDevice(call: call, result: result)
      case "startScan":
        self.startScan(call: call, result: result)
      case "stopScan":
        self.stopScan(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func onDeviceDisconnected(device: BleConnection) {
  }

  func emitLog(type: String, message: String) {
    sendLog(type: type, message: message)
  }

  func getCentralManager() -> CBCentralManager? {
    centralManager
  }

  func reconnect(device: BleConnection, result: @escaping FlutterResult) {
    reconnect(deviceId: device.deviceId, result: result)
  }

  private func hostDeviceName() -> String {
    Host.current().localizedName ?? ProcessInfo.processInfo.hostName
  }

  private func ensureBluetoothManager() {
    if centralManager == nil {
      centralManager = CBCentralManager(delegate: self, queue: bleQueue)
    }
  }

  private func requestBlePermissions(result: @escaping FlutterResult) {
    switch CBCentralManager.authorization {
    case .allowedAlways:
      ensureBluetoothManager()
      result(true)
    case .denied, .restricted:
      result(false)
    case .notDetermined:
      guard pendingPermissionResult == nil else {
        result(
          FlutterError(
            code: "PERMISSION_REQUEST_IN_PROGRESS",
            message: "Bluetooth permission request already in progress",
            details: nil
          )
        )
        return
      }

      pendingPermissionResult = result
      schedulePermissionRequestTimeout()
      startPermissionProbeManagerIfNeeded()
    @unknown default:
      result(false)
    }
  }

  private func schedulePermissionRequestTimeout() {
    permissionTimeoutWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      self?.finishPermissionRequestIfNeeded(force: true)
    }
    permissionTimeoutWorkItem = workItem
    bleQueue.asyncAfter(deadline: .now() + 10, execute: workItem)
  }

  private func cancelPermissionRequestTimeout() {
    permissionTimeoutWorkItem?.cancel()
    permissionTimeoutWorkItem = nil
  }

  private func startPermissionProbeManagerIfNeeded() {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }

      if let permissionProbeManager = self.permissionProbeManager {
        self.handlePermissionProbeState(for: permissionProbeManager)
        return
      }

      self.permissionProbeManager = CBCentralManager(delegate: self, queue: nil)
    }
  }

  private func handlePermissionProbeState(for central: CBCentralManager) {
    guard pendingPermissionResult != nil else {
      return
    }

    switch CBCentralManager.authorization {
    case .allowedAlways, .denied, .restricted:
      finishPermissionRequestIfNeeded(force: false)
    case .notDetermined:
      switch central.state {
      case .poweredOn:
        startPermissionProbe(with: central)
      case .poweredOff, .unsupported, .unauthorized:
        finishPermissionRequestIfNeeded(force: true)
      case .unknown, .resetting:
        break
      @unknown default:
        finishPermissionRequestIfNeeded(force: true)
      }
    @unknown default:
      finishPermissionRequestIfNeeded(force: true)
    }
  }

  private func startPermissionProbe(with central: CBCentralManager) {
    guard !isPermissionProbeActive else {
      return
    }

    isPermissionProbeActive = true
    central.scanForPeripherals(withServices: nil, options: nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.isPermissionProbeActive else {
        return
      }

      central.stopScan()
      self.isPermissionProbeActive = false
    }
  }

  private func stopPermissionProbeManager() {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }

      if let permissionProbeManager = self.permissionProbeManager, permissionProbeManager.isScanning {
        permissionProbeManager.stopScan()
      }
      self.permissionProbeManager?.delegate = nil
      self.permissionProbeManager = nil
      self.isPermissionProbeActive = false
    }
  }

  private func finishPermissionRequestIfNeeded(force: Bool) {
    guard let pendingPermissionResult else {
      return
    }

    let granted: Bool
    switch CBCentralManager.authorization {
    case .allowedAlways:
      granted = true
    case .denied, .restricted:
      granted = false
    case .notDetermined:
      guard force else {
        return
      }
      granted = false
    @unknown default:
      granted = false
    }

    cancelPermissionRequestTimeout()
    self.pendingPermissionResult = nil
    stopPermissionProbeManager()
    pendingPermissionResult(granted)
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
      delegate: self
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

    _ = getOrCreateDevice(deviceId: deviceId)
    _ = resolvePeripheral(deviceId: deviceId)
    result(true)
  }

  private func pair(call: FlutterMethodCall, result: @escaping FlutterResult) {
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

    _ = getOrCreateDevice(deviceId: deviceId)
    _ = beginScan(
      with: central,
      request: ScanRequest(filterDeviceId: deviceId, serviceUUID: nil)
    )
    result(["scanning": true])
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

    let bleConnection = getOrCreateDevice(deviceId: deviceId)

    guard let peripheral = resolvePeripheral(deviceId: deviceId) else {
      _ = beginScan(
        with: central,
        request: ScanRequest(filterDeviceId: deviceId, serviceUUID: nil)
      )
      result(["reconnecting": true])
      return
    }

    bleConnection.updateKnownPeripheralName(peripheral.name)
    if bleConnection.hasActiveOrPendingConnection(for: peripheral) {
      result(["reconnecting": true])
      return
    }

    bleConnection.connect(peripheral: peripheral)
    result(["reconnecting": true])
  }

  private func getConnectedDevices(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let connectedDevices = buildKnownDeviceEntries().filter { entry in
      entry["isConnected"] as? Bool == true
    }
    result(connectedDevices)
  }

  private func getAccessories(call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(buildKnownDeviceEntries())
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

    let removedPeripheral = knownPeripherals.removeValue(forKey: deviceId)
    let removedName = knownPeripheralNames.removeValue(forKey: deviceId)
    let removedDevice = devices.removeValue(forKey: deviceId)
    removedDevice?.connection.cleanup()
    result(removedPeripheral != nil || removedName != nil || removedDevice != nil)
  }

  private func startScan(call: FlutterMethodCall, result: @escaping FlutterResult) {
    ensureBluetoothManager()

    guard let central = centralManager else {
      result(["scanning": false])
      return
    }

    if let permissionProbeManager, permissionProbeManager.isScanning {
      permissionProbeManager.stopScan()
      isPermissionProbeActive = false
    }

    let scanRequest: ScanRequest
    do {
      scanRequest = try resolveScanRequest(arguments: call.arguments as? [String: Any])
    } catch let error as NSError {
      result(
        FlutterError(
          code: error.domain,
          message: error.localizedDescription,
          details: nil
        )
      )
      return
    }

    switch central.state {
    case .poweredOn:
      startScan(with: central, request: scanRequest, result: result)
    case .unknown, .resetting:
      pendingScanResult = result
      pendingScanRequest = scanRequest
    case .poweredOff, .unsupported, .unauthorized:
      sendScanEvent(type: "scan_error", deviceName: currentScanErrorDetails(state: central.state))
      result(["scanning": false])
    @unknown default:
      sendScanEvent(type: "scan_error", deviceName: currentScanErrorDetails(state: central.state))
      result(["scanning": false])
    }
  }

  private func startScan(
    with central: CBCentralManager,
    request: ScanRequest,
    result: @escaping FlutterResult
  ) {
    _ = beginScan(with: central, request: request)
    result(["scanning": true])
  }

  private func completePendingScanIfNeeded(with central: CBCentralManager) {
    guard let pendingScanResult else {
      return
    }

    switch central.state {
    case .poweredOn:
      let result = pendingScanResult
      let request = pendingScanRequest ?? ScanRequest(filterDeviceId: nil, serviceUUID: nil)
      clearPendingScan()
      startScan(with: central, request: request, result: result)
    case .unknown, .resetting:
      return
    case .poweredOff, .unsupported, .unauthorized:
      let result = pendingScanResult
      clearPendingScan()
      sendScanEvent(type: "scan_error", deviceName: currentScanErrorDetails(state: central.state))
      result(["scanning": false])
    @unknown default:
      let result = pendingScanResult
      clearPendingScan()
      sendScanEvent(type: "scan_error", deviceName: currentScanErrorDetails(state: central.state))
      result(["scanning": false])
    }
  }

  private func clearPendingScan() {
    pendingScanResult = nil
    pendingScanRequest = nil
  }

  private func stopScan(result: @escaping FlutterResult) {
    stopScanInternal(sendEvent: true)
    result(["scanning": false])
  }

  private func resolvePeripheral(deviceId: String) -> CBPeripheral? {
    if let knownPeripheral = knownPeripherals[deviceId] {
      return knownPeripheral
    }

    guard let uuid = UUID(uuidString: deviceId), let central = centralManager else {
      return nil
    }

    let cachedPeripherals = central.retrievePeripherals(withIdentifiers: [uuid])
    if let peripheral = cachedPeripherals.first {
      knownPeripherals[deviceId] = peripheral
      if let peripheralName = peripheral.name, !peripheralName.isEmpty {
        knownPeripheralNames[deviceId] = peripheralName
      }
      return peripheral
    }

    let connectedPeripherals = central.retrieveConnectedPeripherals(withServices: [primeUUID])
    if let peripheral = connectedPeripherals.first(where: { $0.identifier == uuid }) {
      knownPeripherals[deviceId] = peripheral
      if let peripheralName = peripheral.name, !peripheralName.isEmpty {
        knownPeripheralNames[deviceId] = peripheralName
      }
      return peripheral
    }

    return nil
  }

  func cleanup() {
    isShuttingDown = true
    stopScanInternal(sendEvent: false)
    stopPermissionProbeManager()
    cancelPermissionRequestTimeout()

    for (_, trackedDevice) in devices {
      trackedDevice.connection.cleanup()
    }

    devices.removeAll()
    knownPeripherals.removeAll()
    knownPeripheralNames.removeAll()
    scanEventSink = nil
    logEventSink = nil
    pendingPermissionResult = nil
    clearPendingScan()
    methodChannel?.setMethodCallHandler(nil)
    methodChannel = nil
    centralManager?.delegate = nil
    centralManager = nil
    isScanning = false
    isPermissionProbeActive = false
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if permissionProbeManager === central {
      handlePermissionProbeState(for: central)
      return
    }

    if central.state != .poweredOn && isScanning {
      stopScanInternal(sendEvent: false)
      sendScanEvent(type: "scan_error", deviceName: currentScanErrorDetails(state: central.state))
    }

    if central.state == .poweredOff {
      for (_, trackedDevice) in devices where trackedDevice.connection.isConnected() {
        trackedDevice.connection.sendConnectionEvent(
          type: nil,
          error: "Bluetooth powered off"
        )
      }
    }

    completePendingScanIfNeeded(with: central)
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    if permissionProbeManager === central && isPermissionProbeActive {
      central.stopScan()
      isPermissionProbeActive = false
      finishPermissionRequestIfNeeded(force: false)
      return
    }

    let deviceId = peripheral.identifier.uuidString
    let deviceName = advertisementLocalName(from: advertisementData) ?? peripheral.name
    let activeScanRequest = activeScanRequest
    let targetDeviceId = activeScanRequest?.filterDeviceId
    let targetServiceUUID = activeScanRequest?.serviceUUID
    let isTargetedMatch = targetDeviceId != nil && matchesIdentifier(deviceId, targetDeviceId)
    let matchesServiceUUID =
      targetServiceUUID != nil && advertisedServiceUUIDs(from: advertisementData).contains {
        $0 == targetServiceUUID
      }

    if !shouldIncludeScanResult(
      targetDeviceId: targetDeviceId,
      targetServiceUUID: targetServiceUUID,
      isTargetedMatch: isTargetedMatch,
      matchesServiceUUID: matchesServiceUUID
    ) {
      return
    }

    knownPeripherals[deviceId] = peripheral
    if let deviceName, !deviceName.isEmpty {
      knownPeripheralNames[deviceId] = deviceName
      devices[deviceId]?.connection.updateKnownPeripheralName(deviceName)
    }

    sendScanEvent(type: "device_found", deviceId: deviceId, deviceName: deviceName)

    if isTargetedMatch && (targetServiceUUID == nil || matchesServiceUUID) {
      stopScanInternal(sendEvent: true)
      connectToDevice(peripheral)
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    let deviceId = peripheral.identifier.uuidString
    knownPeripherals[deviceId] = peripheral
    if let deviceName = peripheral.name, !deviceName.isEmpty {
      knownPeripheralNames[deviceId] = deviceName
    }
    devices[deviceId]?.connection.onDidConnect(peripheral: peripheral)
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    let deviceId = peripheral.identifier.uuidString
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
    devices[deviceId]?.connection.onDidDisconnect(peripheral: peripheral, error: error)
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

  private func logBle(_ message: String) {
    NSLog("[FoundationBle:macOS] %@", message)
    sendLog(type: "DEBUG", message: message)
  }

  private func sendLog(type: String, message: String) {
    let send = { [weak self] in
      self?.logEventSink?([
        "type": type,
        "message": message,
      ])
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
    ensureBluetoothManager()

    var orderedDeviceIds: [String] = []
    var deviceEntries: [String: (peripheral: CBPeripheral?, connection: BleConnection?)] = [:]

    func upsert(deviceId: String, peripheral: CBPeripheral?, connection: BleConnection?) {
      if deviceEntries[deviceId] == nil {
        orderedDeviceIds.append(deviceId)
        deviceEntries[deviceId] = (peripheral, connection)
        return
      }

      let existing = deviceEntries[deviceId]
      deviceEntries[deviceId] = (
        peripheral ?? existing?.peripheral,
        connection ?? existing?.connection
      )
    }

    if let central = centralManager, central.state == .poweredOn {
      let connectedPeripherals = central.retrieveConnectedPeripherals(withServices: [primeUUID])
      for peripheral in connectedPeripherals {
        let deviceId = peripheral.identifier.uuidString
        knownPeripherals[deviceId] = peripheral
        if let peripheralName = peripheral.name, !peripheralName.isEmpty {
          knownPeripheralNames[deviceId] = peripheralName
        }
        upsert(
          deviceId: deviceId,
          peripheral: peripheral,
          connection: devices[deviceId]?.connection
        )
      }
    }

    for (deviceId, peripheral) in knownPeripherals {
      upsert(
        deviceId: deviceId,
        peripheral: peripheral,
        connection: devices[deviceId]?.connection
      )
    }

    for (deviceId, trackedDevice) in devices {
      upsert(
        deviceId: deviceId,
        peripheral: trackedDevice.connection.currentPeripheral ?? knownPeripherals[deviceId],
        connection: trackedDevice.connection
      )
    }

    return orderedDeviceIds.map { deviceId in
      let entry = deviceEntries[deviceId]
      let peripheral = entry?.peripheral
      let connection = entry?.connection
      let isConnected = connection?.isConnected() == true || peripheral?.state == .connected
      let peripheralName =
        connection?.peripheralName ??
        peripheral.map { displayName(for: $0, deviceId: deviceId) } ??
        knownPeripheralNames[deviceId] ??
        "Unknown"
      let state =
        connection?.currentPeripheral?.state.rawValue ??
        peripheral?.state.rawValue ??
        CBPeripheralState.disconnected.rawValue

      return [
        "deviceId": deviceId,
        "name": peripheralName,
        "bonded": false,
        "peripheralId": deviceId,
        "peripheralName": peripheralName,
        "isConnected": isConnected,
        "state": state,
        "bondState": false,
      ]
    }
  }

  private func resolveScanRequest(arguments: [String: Any]?) throws -> ScanRequest {
    let requestedMacId = (arguments?["macId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let legacyDeviceId =
      (arguments?["deviceId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    if let requestedMacId, !requestedMacId.isEmpty,
       let legacyDeviceId, !legacyDeviceId.isEmpty,
       !matchesIdentifier(requestedMacId, legacyDeviceId)
    {
      throw NSError(
        domain: "INVALID_SCAN_FILTER",
        code: 0,
        userInfo: [
          NSLocalizedDescriptionKey:
            "macId and deviceId must match when both are provided"
        ]
      )
    }

    let filterDeviceId =
      requestedMacId?.isEmpty == false ? requestedMacId :
      (legacyDeviceId?.isEmpty == false ? legacyDeviceId : nil)

    let rawServiceUUID =
      (arguments?["uuid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ??
      (arguments?["serviceUuid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    let serviceUUID: CBUUID?
    if let rawServiceUUID, !rawServiceUUID.isEmpty {
      guard UUID(uuidString: rawServiceUUID) != nil else {
        throw NSError(
          domain: "INVALID_SCAN_FILTER",
          code: 0,
          userInfo: [
            NSLocalizedDescriptionKey: "Invalid service UUID: \(rawServiceUUID)"
          ]
        )
      }
      serviceUUID = CBUUID(string: rawServiceUUID)
    } else {
      serviceUUID = nil
    }

    return ScanRequest(filterDeviceId: filterDeviceId, serviceUUID: serviceUUID)
  }

  private func beginScan(with central: CBCentralManager, request: ScanRequest) -> Bool {
    activeScanRequest = request

    if central.isScanning {
      central.stopScan()
    }

    scheduleScanTimeout()
    central.scanForPeripherals(
      withServices: request.scanServices,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    )
    isScanning = true
    sendScanEvent(type: "scan_started")
    return true
  }

  private func scheduleScanTimeout() {
    scanTimeoutWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      self?.stopScanInternal(sendEvent: true)
    }
    scanTimeoutWorkItem = workItem
    bleQueue.asyncAfter(deadline: .now() + scanTimeoutSeconds, execute: workItem)
  }

  private func stopScanInternal(sendEvent: Bool) {
    scanTimeoutWorkItem?.cancel()
    scanTimeoutWorkItem = nil

    centralManager?.stopScan()
    activeScanRequest = nil
    isScanning = false

    if sendEvent {
      sendScanEvent(type: "scan_stopped")
    }
  }

  private func connectToDevice(_ peripheral: CBPeripheral) {
    let deviceId = peripheral.identifier.uuidString
    knownPeripherals[deviceId] = peripheral
    if let deviceName = peripheral.name, !deviceName.isEmpty {
      knownPeripheralNames[deviceId] = deviceName
    }
    let connection = getOrCreateDevice(deviceId: deviceId)
    connection.updateKnownPeripheralName(peripheral.name)
    connection.connect(peripheral: peripheral)
  }

  private func shouldIncludeScanResult(
    targetDeviceId: String?,
    targetServiceUUID: CBUUID?,
    isTargetedMatch: Bool,
    matchesServiceUUID: Bool
  ) -> Bool {
    if targetDeviceId == nil && targetServiceUUID == nil {
      return true
    }

    if targetDeviceId != nil && !isTargetedMatch {
      return false
    }

    if targetServiceUUID != nil && !matchesServiceUUID {
      return false
    }

    return true
  }



  private func matchesIdentifier(_ lhs: String, _ rhs: String?) -> Bool {
    guard let rhs else {
      return false
    }
    return lhs.caseInsensitiveCompare(rhs) == .orderedSame
  }

  private func advertisedServiceUUIDs(from advertisementData: [String: Any]) -> [CBUUID] {
    let advertisedServices =
      (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
    let overflowServices =
      (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
    let solicitedServices =
      (advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID]) ?? []
    return advertisedServices + overflowServices + solicitedServices
  }

  private func advertisementLocalName(from advertisementData: [String: Any]) -> String? {
    advertisementData[CBAdvertisementDataLocalNameKey] as? String
  }

  private func displayName(for peripheral: CBPeripheral, deviceId: String) -> String {
    peripheral.name ?? knownPeripheralNames[deviceId] ?? "Unknown"
  }

  private func currentScanErrorDetails(state: CBManagerState? = nil) -> String {
    switch CBCentralManager.authorization {
    case .denied, .restricted:
      return """
        macOS Bluetooth access is denied. Use Request Access to retry or check \
        System Settings > Privacy & Security > Bluetooth.
        """
    case .allowedAlways, .notDetermined:
      break
    @unknown default:
      break
    }

    switch state ?? centralManager?.state ?? .unknown {
    case .poweredOff:
      return "macOS Bluetooth is powered off. Turn Bluetooth on and try scanning again."
    case .unsupported:
      return "This Mac does not support Bluetooth Low Energy."
    case .unauthorized:
      return """
        macOS Bluetooth access is unavailable. Use Request Access to retry or \
        check System Settings > Privacy & Security > Bluetooth.
        """
    case .resetting, .unknown:
      return "macOS Bluetooth is still initializing. Wait a moment and try scanning again."
    case .poweredOn:
      return "macOS reported Bluetooth as available, but scanning still failed. Try again."
    @unknown default:
      return "macOS Bluetooth is unavailable right now. Try again in a moment."
    }
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
}
