import CoreBluetooth
import FlutterMacOS
import Foundation

final class GattBleConnection: BleConnection {
  private static let blePacketSize = 244
  private static let bluetoothSIGBaseSuffix = "-0000-1000-8000-00805f9b34fb"

  private let primeUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")

  private var writeCharacteristic: CBCharacteristic?
  private var readCharacteristic: CBCharacteristic?
  private var bleWriteQueue: BleWriteQueue?
  private var deviceReady = false
  private var isServiceDiscoveryInProgress = false
  private var pendingCharacteristicDiscoveries = 0

  override func isReady() -> Bool {
    isConnected() && deviceReady && writeCharacteristic != nil
  }

  override func isConnected() -> Bool {
    currentPeripheral?.state == .connected
  }

  override func hasActiveOrPendingConnection(for peripheral: CBPeripheral) -> Bool {
    guard let currentPeripheral,
          currentPeripheral.identifier == peripheral.identifier
    else {
      return false
    }

    return currentPeripheral.state == .connecting ||
      currentPeripheral.state == .connected ||
      isServiceDiscoveryInProgress ||
      deviceReady
  }

  override func connect(peripheral: CBPeripheral) {
    if hasActiveOrPendingConnection(for: peripheral) {
      return
    }

    if let currentPeripheral,
       currentPeripheral.identifier != peripheral.identifier
    {
      centralManager()?.cancelPeripheralConnection(currentPeripheral)
      resetConnectionState()
    }

    if peripheral.state == .connecting {
      updateKnownPeripheral(peripheral)
      peripheral.delegate = self
      return
    }

    if peripheral.state == .connected {
      onDidConnect(peripheral: peripheral)
      return
    }

    sendConnectionEvent(type: "connection_attempt")

    updateKnownPeripheral(peripheral)
    peripheral.delegate = self
    pendingCharacteristicDiscoveries = 0
    isServiceDiscoveryInProgress = false
    centralManager()?.connect(peripheral)
  }

  override func disconnectTransport(result: @escaping FlutterResult) {
    guard let peripheral = currentPeripheral else {
      result(["disconnecting": false, "message": "No device connected"])
      return
    }

    bleWriteQueue?.cancel()
    bleWriteQueue = nil
    centralManager()?.cancelPeripheralConnection(peripheral)
    result(["disconnecting": true])
  }

  override func handleBinaryWrite(data: Data) async -> Data {
    guard let peripheral = currentPeripheral,
          peripheral.state == .connected,
          deviceReady,
          let writeCharacteristic
    else {
      return Data()
    }

    if bleWriteQueue == nil {
      bleWriteQueue = BleWriteQueue(
        peripheral: peripheral,
        characteristic: writeCharacteristic
      )
    }

    if data.count <= Self.blePacketSize {
      let success = await bleWriteQueue?.enqueue(data: data) ?? false
      return success ? Data([1]) : Data()
    }

    for chunk in data.chunked(into: Self.blePacketSize) {
      let success = await bleWriteQueue?.enqueue(data: chunk) ?? false
      if !success {
        return Data()
      }
    }

    return Data([1])
  }

  override func cleanupTransport() {
    if let peripheral = currentPeripheral {
      bleWriteQueue?.cancel()
      centralManager()?.cancelPeripheralConnection(peripheral)
    }
    resetConnectionState()
  }

  override func onDidConnect(peripheral: CBPeripheral) {
    if currentPeripheralMatches(peripheral) &&
      (deviceReady || isServiceDiscoveryInProgress)
    {
      return
    }

    updateKnownPeripheral(peripheral)
    peripheral.delegate = self
    writeCharacteristic = nil
    readCharacteristic = nil
    bleWriteQueue?.cancel()
    bleWriteQueue = nil
    deviceReady = false
    pendingCharacteristicDiscoveries = 0
    isServiceDiscoveryInProgress = true

    peripheral.discoverServices(nil)
    sendConnectionEvent(type: "device_connected")
  }

  override func onDidFailToConnect(peripheral: CBPeripheral, error: Error?) {
    guard currentPeripheralMatches(peripheral) else {
      return
    }

    resetConnectionState(for: peripheral)
    onConnectionError(error?.localizedDescription ?? "Failed to connect to device")
  }

  override func onDidDisconnect(peripheral: CBPeripheral, error: Error?) {
    guard currentPeripheralMatches(peripheral) else {
      return
    }

    resetConnectionState(for: peripheral)
    onDeviceDisconnected(error: error?.localizedDescription)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard currentPeripheralMatches(peripheral) else {
      return
    }

    if let error {
      failConnection(
        peripheral: peripheral,
        message: "Service discovery failed: \(error.localizedDescription)"
      )
      return
    }

    if deviceReady {
      return
    }

    guard let services = peripheral.services, !services.isEmpty else {
      failConnection(
        peripheral: peripheral,
        message: "No GATT services discovered"
      )
      return
    }

    pendingCharacteristicDiscoveries = services.count
    for service in services {
      peripheral.discoverCharacteristics(nil, for: service)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard currentPeripheralMatches(peripheral) else {
      return
    }

    if let error {
      failConnection(
        peripheral: peripheral,
        message: "Characteristic discovery failed: \(error.localizedDescription)"
      )
      return
    }

    if deviceReady {
      return
    }

    pendingCharacteristicDiscoveries = max(0, pendingCharacteristicDiscoveries - 1)
    if pendingCharacteristicDiscoveries > 0 {
      return
    }

    finalizeCharacteristicDiscovery(for: peripheral)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard currentPeripheralMatches(peripheral) else {
      return
    }

    guard error == nil, let data = characteristic.value else {
      return
    }
    sendBinaryData(data)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard currentPeripheralMatches(peripheral) else {
      return
    }

    guard characteristic.uuid == writeCharacteristic?.uuid else {
      return
    }

    bleWriteQueue?.notifyWriteCompleted(error: error)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    guard currentPeripheralMatches(peripheral) else {
      return
    }
    bleWriteQueue?.notifyReady()
  }

  private func resetConnectionState(for peripheral: CBPeripheral? = nil) {
    if let peripheral, !currentPeripheralMatches(peripheral) {
      return
    }

    bleWriteQueue?.cancel()
    bleWriteQueue = nil
    writeCharacteristic = nil
    readCharacteristic = nil
    deviceReady = false
    isServiceDiscoveryInProgress = false
    pendingCharacteristicDiscoveries = 0
    clearConnectionState()
  }

  private func failConnection(peripheral: CBPeripheral, message: String) {
    resetConnectionState(for: peripheral)

    if peripheral.state == .connected || peripheral.state == .connecting {
      centralManager()?.cancelPeripheralConnection(peripheral)
    }

    onConnectionError(message)
  }

  private func finalizeCharacteristicDiscovery(for peripheral: CBPeripheral) {
    let services = peripheral.services ?? []
    guard let selection = resolveCharacteristicSelection(from: services) else {
      failConnection(
        peripheral: peripheral,
        message: "No writable GATT characteristic found"
      )
      return
    }

    bleWriteQueue?.cancel()
    bleWriteQueue = BleWriteQueue(
      peripheral: peripheral,
      characteristic: selection.writeCharacteristic
    )
    writeCharacteristic = selection.writeCharacteristic
    readCharacteristic = selection.readCharacteristic
    deviceReady = true
    isServiceDiscoveryInProgress = false

    configureReadCharacteristic(
      peripheral,
      characteristic: selection.readCharacteristic
    )
    sendConnectionEvent(type: "device_connected")
  }

  private struct CharacteristicSelection {
    let serviceUUID: CBUUID
    let writeCharacteristic: CBCharacteristic
    let readCharacteristic: CBCharacteristic?
  }

  private func resolveCharacteristicSelection(
    from services: [CBService]
  ) -> CharacteristicSelection? {
    let serviceMatches = services.compactMap { service -> CharacteristicSelection? in
      guard let characteristics = service.characteristics,
            let writeCharacteristic = selectWriteCharacteristic(from: characteristics)
      else {
        return nil
      }

      return CharacteristicSelection(
        serviceUUID: service.uuid,
        writeCharacteristic: writeCharacteristic,
        readCharacteristic: selectReadCharacteristic(from: characteristics)
      )
    }

    if let bestServiceMatch = serviceMatches.max(by: { scoreSelection($0) < scoreSelection($1) }) {
      return bestServiceMatch
    }

    let allCharacteristics = services.flatMap { $0.characteristics ?? [] }
    guard let writeCharacteristic = allCharacteristics
      .filter(isWritableCharacteristic(_:))
      .max(by: { scoreWriteCharacteristic($0) < scoreWriteCharacteristic($1) })
    else {
      return nil
    }

    let readCharacteristic = allCharacteristics
      .filter(isReadableCharacteristic(_:))
      .max(by: { scoreReadCharacteristic($0) < scoreReadCharacteristic($1) })

    return CharacteristicSelection(
      serviceUUID: writeCharacteristic.service?.uuid ?? primeUUID,
      writeCharacteristic: writeCharacteristic,
      readCharacteristic: readCharacteristic
    )
  }

  private func selectWriteCharacteristic(
    from characteristics: [CBCharacteristic]
  ) -> CBCharacteristic? {
    characteristics
      .filter(isWritableCharacteristic(_:))
      .max(by: { scoreWriteCharacteristic($0) < scoreWriteCharacteristic($1) })
  }

  private func selectReadCharacteristic(
    from characteristics: [CBCharacteristic]
  ) -> CBCharacteristic? {
    characteristics
      .filter(isReadableCharacteristic(_:))
      .max(by: { scoreReadCharacteristic($0) < scoreReadCharacteristic($1) })
  }

  private func scoreSelection(_ selection: CharacteristicSelection) -> Int {
    var score = 0
    if isCustomServiceUUID(selection.serviceUUID) {
      score += 100
    }
    score += scoreWriteCharacteristic(selection.writeCharacteristic) * 10
    if let readCharacteristic = selection.readCharacteristic {
      score += 20
      score += scoreReadCharacteristic(readCharacteristic) * 10
    }
    return score
  }

  private func isWritableCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
    characteristic.properties.contains(.write) ||
      characteristic.properties.contains(.writeWithoutResponse)
  }

  private func isReadableCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
    characteristic.properties.contains(.read) ||
      characteristic.properties.contains(.notify) ||
      characteristic.properties.contains(.indicate)
  }

  private func scoreWriteCharacteristic(_ characteristic: CBCharacteristic) -> Int {
    if characteristic.properties.contains(.writeWithoutResponse) {
      return 3
    }
    if characteristic.properties.contains(.write) {
      return 2
    }
    return 0
  }

  private func scoreReadCharacteristic(_ characteristic: CBCharacteristic) -> Int {
    if characteristic.properties.contains(.notify) {
      return 3
    }
    if characteristic.properties.contains(.indicate) {
      return 2
    }
    if characteristic.properties.contains(.read) {
      return 1
    }
    return 0
  }

  private func isCustomServiceUUID(_ uuid: CBUUID) -> Bool {
    !canonicalUUIDString(for: uuid).hasSuffix(Self.bluetoothSIGBaseSuffix)
  }

  private func canonicalUUIDString(for uuid: CBUUID) -> String {
    let bytes = [UInt8](uuid.data)
    switch bytes.count {
    case 2:
      let short = bytes.map { String(format: "%02x", $0) }.joined()
      return "0000\(short)-0000-1000-8000-00805f9b34fb"
    case 4:
      let short = bytes.map { String(format: "%02x", $0) }.joined()
      return "\(short)-0000-1000-8000-00805f9b34fb"
    default:
      return uuid.uuidString.lowercased()
    }
  }

  private func configureReadCharacteristic(
    _ peripheral: CBPeripheral,
    characteristic: CBCharacteristic?
  ) {
    guard let characteristic else {
      return
    }

    if characteristic.properties.contains(.read) {
      peripheral.readValue(for: characteristic)
    }

    if characteristic.properties.contains(.notify) ||
      characteristic.properties.contains(.indicate)
    {
      peripheral.setNotifyValue(true, for: characteristic)
    }
  }
}

private extension Data {
  func chunked(into chunkSize: Int) -> [Data] {
    guard !isEmpty else {
      return []
    }

    var index = startIndex
    var chunks: [Data] = []
    while index < endIndex {
      let nextIndex = self.index(index, offsetBy: chunkSize, limitedBy: endIndex) ?? endIndex
      chunks.append(self[index..<nextIndex])
      index = nextIndex
    }
    return chunks
  }
}
