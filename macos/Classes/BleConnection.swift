import CoreBluetooth
import FlutterMacOS
import Foundation

protocol BleConnectionDelegate: AnyObject {
  func onDeviceDisconnected(device: BleConnection)
  func getCentralManager() -> CBCentralManager?
  func reconnect(device: BleConnection, result: @escaping FlutterResult)
  func emitLog(type: String, message: String)
}

class BleConnection: NSObject, CBPeripheralDelegate {
  private static let methodChannelName = "foundation_ble/bluetooth"
  private static let bleReadChannelName = "foundation_ble/ble/read"
  private static let bleWriteChannelName = "foundation_ble/ble/write"
  private static let bleConnectionStreamName =
    "foundation_ble/bluetooth/connection/stream"

  let deviceId: String

  private weak var delegate: BleConnectionDelegate?

  private let methodChannel: FlutterMethodChannel
  private let bleReadChannel: FlutterBasicMessageChannel
  private let bleWriteChannel: FlutterBasicMessageChannel
  private let connectionEventChannel: FlutterEventChannel

  fileprivate var connectionEventSink: FlutterEventSink?
  fileprivate var needsToResendConnectionState: [String: Any]?

  private(set) var connectedPeripheral: CBPeripheral?
  private var lastKnownPeripheralName: String?
  private(set) var isCleanedUp = false

  var peripheralId: String {
    deviceId
  }

  var peripheralName: String? {
    connectedPeripheral?.name ?? lastKnownPeripheralName
  }

  var isBonded: Bool {
    false
  }

  var currentPeripheral: CBPeripheral? {
    connectedPeripheral
  }

  init(
    deviceId: String,
    binaryMessenger: FlutterBinaryMessenger,
    delegate: BleConnectionDelegate
  ) {
    self.deviceId = deviceId
    self.delegate = delegate

    methodChannel = FlutterMethodChannel(
      name: "\(Self.methodChannelName)/\(deviceId)",
      binaryMessenger: binaryMessenger
    )

    bleReadChannel = FlutterBasicMessageChannel(
      name: "\(Self.bleReadChannelName)/\(deviceId)",
      binaryMessenger: binaryMessenger,
      codec: FlutterBinaryCodec.sharedInstance()
    )

    bleWriteChannel = FlutterBasicMessageChannel(
      name: "\(Self.bleWriteChannelName)/\(deviceId)",
      binaryMessenger: binaryMessenger,
      codec: FlutterBinaryCodec.sharedInstance()
    )

    connectionEventChannel = FlutterEventChannel(
      name: "\(Self.bleConnectionStreamName)/\(deviceId)",
      binaryMessenger: binaryMessenger
    )

    super.init()
    setupChannelHandlers()
  }

  func isReady() -> Bool {
    fatalError("Subclasses must override isReady()")
  }

  func isConnected() -> Bool {
    fatalError("Subclasses must override isConnected()")
  }

  func hasActiveOrPendingConnection(for peripheral: CBPeripheral) -> Bool {
    fatalError("Subclasses must override hasActiveOrPendingConnection(for:)")
  }

  func connect(peripheral: CBPeripheral) {
    fatalError("Subclasses must override connect(peripheral:)")
  }

  func disconnectTransport(result: @escaping FlutterResult) {
    fatalError("Subclasses must override disconnectTransport(result:)")
  }

  func handleBinaryWrite(data: Data) async -> Data {
    fatalError("Subclasses must override handleBinaryWrite(data:)")
  }

  func bond(result: @escaping FlutterResult) {
    result(false)
  }

  func cleanupTransport() {
  }

  func onDidConnect(peripheral: CBPeripheral) {
  }

  func onDidFailToConnect(peripheral: CBPeripheral, error: Error?) {
  }

  func onDidDisconnect(peripheral: CBPeripheral, error: Error?) {
  }

  func updateKnownPeripheral(_ peripheral: CBPeripheral?) {
    connectedPeripheral = peripheral
    if let name = peripheral?.name, !name.isEmpty {
      lastKnownPeripheralName = name
    }
  }

  func updateKnownPeripheralName(_ name: String?) {
    guard let name, !name.isEmpty else {
      return
    }
    lastKnownPeripheralName = name
  }

  func clearKnownPeripheralName() {
    lastKnownPeripheralName = nil
  }

  func clearConnectionState(resetPeripheralName: Bool = false) {
    connectedPeripheral = nil
    if resetPeripheralName {
      lastKnownPeripheralName = nil
    }
  }

  func currentPeripheralMatches(_ peripheral: CBPeripheral) -> Bool {
    connectedPeripheral?.identifier == peripheral.identifier
  }

  func sendConnectionEvent(
    type: String? = nil,
    error: String? = nil
  ) {
    let connectionData = currentEventPayload(type: type, error: error)

    guard let sink = connectionEventSink else {
      needsToResendConnectionState = connectionData
      return
    }

    let send = { sink(connectionData) }
    if Thread.isMainThread {
      send()
    } else {
      DispatchQueue.main.async {
        send()
      }
    }
  }

  func sendBinaryData(_ data: Data) {
    let send = { [weak self] in
      self?.bleReadChannel.sendMessage(data) { _ in }
    }

    if Thread.isMainThread {
      send()
    } else {
      DispatchQueue.main.async {
        send()
      }
    }
  }

  func onConnectionError(_ message: String) {
    sendConnectionEvent(type: "connection_error", error: message)
  }

  func log(_ message: String) {
    delegate?.emitLog(type: "TRACE", message: message)
  }

  func onDeviceDisconnected(error: String? = nil) {
    sendConnectionEvent(type: "device_disconnected", error: error)
    delegate?.onDeviceDisconnected(device: self)
  }

  func cleanup() {
    if isCleanedUp {
      return
    }
    isCleanedUp = true

    cleanupTransport()

    let clearHandlers = {
      self.methodChannel.setMethodCallHandler(nil)
      self.bleWriteChannel.setMessageHandler(nil)
    }

    if Thread.isMainThread {
      clearHandlers()
    } else {
      DispatchQueue.main.async(execute: clearHandlers)
    }

    clearConnectionState()
    connectionEventSink = nil
    needsToResendConnectionState = nil
  }

  func centralManager() -> CBCentralManager? {
    delegate?.getCentralManager()
  }

  private func setupChannelHandlers() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.setupChannelHandlers()
      }
      return
    }

    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "DEALLOCATED", message: "BleConnection deallocated", details: nil))
        return
      }
      self.handleMethodCall(call: call, result: result)
    }

    connectionEventChannel.setStreamHandler(ConnectionStreamHandler(bleConnection: self))

    bleWriteChannel.setMessageHandler { [weak self] message, reply in
      guard let self, let data = message as? Data else {
        reply(Data())
        return
      }

      Task { [weak self] in
        guard let self else {
          DispatchQueue.main.async { reply(Data()) }
          return
        }

        let replyStatus = await self.handleBinaryWrite(data: data)
        DispatchQueue.main.async {
          reply(replyStatus)
        }
      }
    }
  }

  private func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "bond":
      bond(result: result)
    case "getCurrentDeviceStatus":
      getCurrentDeviceStatus(result: result)
    case "dispose":
      if isConnected() {
        disconnectTransport(result: { _ in })
      }
      cleanup()
      result(nil)
    case "disconnect":
      disconnectTransport(result: result)
    case "getConnectedPeripheralId":
      result(peripheralId)
    case "isConnected":
      result(isConnected())
    case "reconnect":
      reconnect(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func getCurrentDeviceStatus(result: @escaping FlutterResult) {
    sendConnectionEvent()
    result(currentResultPayload(type: nil, error: nil))
  }

  private func reconnect(result: @escaping FlutterResult) {
    guard delegate != nil else {
      result(
        FlutterError(
          code: "NO_CENTRAL",
          message: "Central manager not available",
          details: nil
        )
      )
      return
    }

    delegate?.reconnect(device: self, result: result)
  }

  private func currentResultPayload(
    type: String?,
    error: String?
  ) -> [String: Any?] {
    [
      "type": type as Any,
      "connected": isConnected(),
      "ready": isReady(),
      "peripheralId": deviceId,
      "peripheralName": peripheralName ?? "Unknown Device",
      "bonded": isBonded,
      "timestamp": Date().timeIntervalSince1970 * 1000,
      "error": error,
    ]
  }

  private func currentEventPayload(
    type: String?,
    error: String?
  ) -> [String: Any] {
    [
      "type": type as Any,
      "connected": isConnected(),
      "ready": isReady(),
      "peripheralId": deviceId,
      "peripheralName": peripheralName ?? "Unknown Device",
      "bonded": isBonded,
      "timestamp": Date().timeIntervalSince1970 * 1000,
      "error": error ?? NSNull(),
    ]
  }
}

private final class ConnectionStreamHandler: NSObject, FlutterStreamHandler {
  weak var bleConnection: BleConnection?

  init(bleConnection: BleConnection) {
    self.bleConnection = bleConnection
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    bleConnection?.connectionEventSink = events

    if let pendingState = bleConnection?.needsToResendConnectionState {
      events(pendingState)
      bleConnection?.needsToResendConnectionState = nil
    }

    if bleConnection?.currentPeripheral != nil || bleConnection?.isConnected() == true {
      bleConnection?.sendConnectionEvent(
        type: bleConnection?.isConnected() == true
          ? "device_connected" : "device_disconnected"
      )
    }

    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    bleConnection?.connectionEventSink = nil
    return nil
  }
}
