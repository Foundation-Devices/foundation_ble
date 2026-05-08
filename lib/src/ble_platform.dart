import 'ble_connection.dart';
import 'method_channel/method_channel_ble_platform.dart';
import 'models/ble_device_info.dart';
import 'models/ble_scan_event.dart';
import 'models/ios_accessory_setup.dart';
import 'platform_interface.dart';

enum BleTarget { android, ios, macos }

abstract class BlePlatform extends PlatformInterface {
  BlePlatform() : super(token: _token);

  static final Object _token = Object();
  static BlePlatform? _instance;

  static BlePlatform get instance => _instance ??= MethodChannelBlePlatform();

  static set instance(BlePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  BleTarget get target;

  Stream<BleScanEvent> get scanEvents;

  Stream<String> get logEvents;

  Future<String> getDeviceName();

  Future<bool> requestBlePermissions();

  Future<bool> getBleAdapterState();

  Future<List<BleDeviceInfo>> getKnownDevices();

  Future<bool> startScan({
    String? deviceId,
    String? macId,
    String? serviceUuid,
  });

  Future<bool> stopScan();

  Future<void> prepareDevice(String deviceId);

  Future<void> reconnect(String deviceId);

  Future<bool> removeDevice(String deviceId);

  BleConnection createConnection(String deviceId);

  Future<void> dispose();
}

abstract interface class IosAccessorySetupCapability {
  Future<IosAccessorySetupResult?> showAccessorySetup({
    required List<IosAccessoryPickerItem> items,
  });
}

abstract interface class AndroidBlePlatformCapability {
  Future<void> pair(String deviceId);

  Future<int> getApiLevel();

  Future<bool?> requestEnableBle();
}
