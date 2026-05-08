import Flutter
import UIKit

public class FoundationBlePlugin: NSObject, FlutterPlugin {
  private static var shared: FoundationBlePlugin?

  private let bluetoothChannel: BluetoothChannel
  private var terminateObserver: NSObjectProtocol?

  init(
    binaryMessenger: FlutterBinaryMessenger,
    assetKeyResolver: @escaping (_ asset: String, _ package: String?) -> String
  ) {
    bluetoothChannel = BluetoothChannel(
      binaryMessenger: binaryMessenger,
      assetKeyResolver: assetKeyResolver
    )
    super.init()

    terminateObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willTerminateNotification,
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
    let instance = FoundationBlePlugin(
      binaryMessenger: registrar.messenger(),
      assetKeyResolver: { asset, package in
        if let package, !package.isEmpty {
          return registrar.lookupKey(forAsset: asset, fromPackage: package)
        }
        return registrar.lookupKey(forAsset: asset)
      }
    )
    shared = instance
  }
}
