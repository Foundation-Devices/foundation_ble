import AppKit
import FlutterMacOS
import Foundation

public class FoundationBlePlugin: NSObject, FlutterPlugin {
  private static var shared: FoundationBlePlugin?

  private let bluetoothChannel: BluetoothChannel
  private var terminateObserver: NSObjectProtocol?

  init(binaryMessenger: FlutterBinaryMessenger) {
    bluetoothChannel = BluetoothChannel(binaryMessenger: binaryMessenger)
    super.init()

    terminateObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.bluetoothChannel.cleanup()
    }
  }

  deinit {
    if let terminateObserver {
      NotificationCenter.default.removeObserver(terminateObserver)
    }
    bluetoothChannel.cleanup()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FoundationBlePlugin(binaryMessenger: registrar.messenger)
    shared = instance
  }
}
