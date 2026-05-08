import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:foundation_ble/foundation_ble.dart';
import 'package:foundation_ble/src/platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FoundationBle', () {
    test('connect rejects invalid l2cap psm values', () {
      expect(
        () => FoundationBle().connect(
          'device-a',
          transport: const BleTransport.l2cap(psm: 0),
        ),
        throwsArgumentError,
      );
    });

    test('connect rejects l2cap transport with a custom platform', () {
      expect(
        () => FoundationBle(
          platform: _FakeAndroidPlatform(),
        ).connect('device-a', transport: const BleTransport.l2cap(psm: 123)),
        throwsA(isA<BleTransportException>()),
      );
    });

    test('requestBlePermissions delegates to the platform', () async {
      final platform = _FakeMacosPlatform();
      final ble = FoundationBle(platform: platform);

      final granted = await ble.requestBlePermissions();

      expect(granted, isTrue);
      expect(platform.permissionRequestCount, 1);

      await ble.dispose();
      expect(platform.disposeCount, 1);
    });

    test('startScan forwards optional mac and UUID filters', () async {
      final platform = _FakeAndroidPlatform();
      final ble = FoundationBle(platform: platform);

      final started = await ble.startScan(
        macId: 'AA:BB:CC:DD:EE:FF',
        serviceUuid: '12345678-1234-1234-1234-1234567890AB',
      );

      expect(started, isTrue);
      expect(platform.lastScanArguments, <String, String?>{
        'deviceId': null,
        'macId': 'AA:BB:CC:DD:EE:FF',
        'serviceUuid': '12345678-1234-1234-1234-1234567890AB',
      });

      await ble.dispose();
    });

    test('reuses and resets device connections', () async {
      final platform = _FakeMacosPlatform();
      final ble = FoundationBle(platform: platform);

      final first = ble.getDeviceConnection('device-a');
      final second = ble.getDeviceConnection('device-a');
      final third = ble.getDeviceConnection('device-a', reset: true);

      expect(identical(first, second), isTrue);
      expect(identical(first, third), isFalse);
      expect((first as _FakeBleConnection).disposed, isTrue);

      await ble.dispose();
    });

    test(
      'removeDevice disposes the cached connection when removal succeeds',
      () async {
        final platform = _FakeMacosPlatform();
        final ble = FoundationBle(platform: platform);

        final connection =
            ble.getDeviceConnection('device-a') as _FakeBleConnection;
        final removed = await ble.removeDevice('device-a');

        expect(removed, isTrue);
        expect(connection.disposed, isTrue);
        expect(ble.hasDeviceConnection('device-a'), isFalse);

        await ble.dispose();
      },
    );

    test('setupDevice uses iOS accessory setup as discovery', () async {
      final platform = _FakeIosPlatform(
        accessorySetupResult: const IosAccessorySetupResult(
          deviceId: 'ios-device',
          pickerItemId: 'prime-orange',
        ),
        knownDevices: const <BleDeviceInfo>[
          BleDeviceInfo(
            peripheralId: 'ios-device',
            peripheralName: 'Prime Orange',
            isConnected: false,
            state: 0,
            bondState: true,
          ),
        ],
      );

      final ble = FoundationBle(platform: platform);

      const pickerItems = <IosAccessoryPickerItem>[
        IosAccessoryPickerItem(
          id: 'prime-orange',
          name: 'Prime Orange',
          descriptor: IosAccessoryDiscoveryDescriptor(
            bluetoothNameSubstring: 'Prime',
            bluetoothServiceUuid: '6E400001-B5A3-F393-E0A9-E50E24DCCA9E',
          ),
        ),
      ];
      final result = await ble.setupDevice(iosPickerItems: pickerItems);

      expect(result.peripheralId, 'ios-device');
      expect(result.peripheralName, 'Prime Orange');
      expect(result.isConnected, isFalse);
      expect(ble.hasDeviceConnection('ios-device'), isFalse);
      expect(platform.lastAccessoryPickerItems, pickerItems);

      await ble.dispose();
    });

    test('setupDevice throws when iOS accessory setup is cancelled', () async {
      final platform = _FakeIosPlatform(accessorySetupResult: null);
      final ble = FoundationBle(
        platform: platform,
        setupTimeout: const Duration(milliseconds: 50),
      );

      const pickerItems = <IosAccessoryPickerItem>[
        IosAccessoryPickerItem(
          id: 'prime-orange',
          name: 'Prime Orange',
          descriptor: IosAccessoryDiscoveryDescriptor(
            bluetoothNameSubstring: 'Prime',
            bluetoothServiceUuid: '6E400001-B5A3-F393-E0A9-E50E24DCCA9E',
          ),
        ),
      ];

      await expectLater(
        ble.setupDevice(iosPickerItems: pickerItems),
        throwsA(
          isA<BleSetupTimeoutException>().having(
            (BleSetupTimeoutException error) => error.message,
            'message',
            'Accessory setup cancelled',
          ),
        ),
      );
    });

    test('setupDevice requires non-empty iOS picker items', () async {
      final platform = _FakeIosPlatform();
      final ble = FoundationBle(platform: platform);

      await expectLater(
        ble.setupDevice(iosPickerItems: const <IosAccessoryPickerItem>[]),
        throwsArgumentError,
      );
    });

    test('connect prepares and reconnects on macOS', () async {
      final platform = _FakeMacosPlatform();
      final connection = platform.connectionFor('mac-device');
      platform.onReconnect = (String deviceId) {
        Future<void>.delayed(Duration.zero, () {
          connection.emitStatus(
            const DeviceStatus(
              type: BluetoothConnectionEventType.deviceConnected,
              connected: true,
              ready: true,
              peripheralId: 'mac-device',
            ),
          );
        });
      };

      final ble = FoundationBle(
        platform: platform,
        setupTimeout: const Duration(milliseconds: 50),
      );

      final result = await ble.connect('mac-device');

      expect(result, same(connection));
      expect(platform.preparedDeviceIds, <String>['mac-device']);
      expect(platform.reconnectedDeviceIds, <String>['mac-device']);

      await ble.dispose();
    });

    test('connect waits for iOS ready state before returning', () async {
      final platform = _FakeIosPlatform();
      final connection = platform.connectionFor('ios-device');
      platform.onReconnect = (_) {
        Future<void>.delayed(Duration.zero, () {
          connection.emitStatus(
            const DeviceStatus(
              type: BluetoothConnectionEventType.deviceConnected,
              connected: true,
              ready: false,
              peripheralId: 'ios-device',
            ),
          );
        });
      };

      final ble = FoundationBle(
        platform: platform,
        setupTimeout: const Duration(milliseconds: 50),
      );

      var completed = false;
      final future = ble.connect('ios-device')
        ..then((_) {
          completed = true;
        });

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(completed, isFalse);

      connection.emitStatus(
        const DeviceStatus(
          type: BluetoothConnectionEventType.deviceConnected,
          connected: true,
          ready: true,
          peripheralId: 'ios-device',
        ),
      );

      final result = await future;

      expect(result, same(connection));
      expect(platform.preparedDeviceIds, <String>['ios-device']);
      expect(platform.reconnectedDeviceIds, <String>['ios-device']);

      await ble.dispose();
    });

    test('connect surfaces macOS setup timeout', () async {
      final platform = _FakeMacosPlatform();
      final ble = FoundationBle(
        platform: platform,
        setupTimeout: const Duration(milliseconds: 10),
      );

      await expectLater(
        ble.connect('mac-device'),
        throwsA(
          isA<BleSetupTimeoutException>().having(
            (BleSetupTimeoutException error) => error.message,
            'message',
            'Device connection timed out',
          ),
        ),
      );
    });

    test('connect reconnects on Android without pairing or bonding', () async {
      final platform = _FakeAndroidPlatform();
      final connection = platform.connectionFor('android-device');
      connection.onStatusRequested = () {
        Future<void>.delayed(Duration.zero, () {
          connection.emitStatus(
            const DeviceStatus(
              type: BluetoothConnectionEventType.deviceConnected,
              connected: true,
              ready: true,
              peripheralId: 'android-device',
            ),
          );
        });
      };

      final ble = FoundationBle(
        platform: platform,
        setupTimeout: const Duration(milliseconds: 50),
      );

      final result = await ble.connect('android-device');

      expect(result, same(connection));
      expect(platform.pairedDeviceIds, isEmpty);
      expect((connection as _FakeAndroidBleConnection).bondCalls, 0);

      await ble.dispose();
    });

    test('connect surfaces Android connection timeout', () async {
      final platform = _FakeAndroidPlatform();
      final ble = FoundationBle(
        platform: platform,
        setupTimeout: const Duration(milliseconds: 10),
      );

      await expectLater(
        ble.connect('android-device'),
        throwsA(
          isA<BleSetupTimeoutException>().having(
            (BleSetupTimeoutException error) => error.message,
            'message',
            'Device connection timed out',
          ),
        ),
      );
    });
  });
}

abstract class _FakeBlePlatformBase extends BlePlatform
    with MockPlatformInterfaceMixin {
  _FakeBlePlatformBase(
    this.target, {
    this.knownDevices = const <BleDeviceInfo>[],
  });

  @override
  final BleTarget target;
  final List<BleDeviceInfo> knownDevices;

  final StreamController<BleScanEvent> _scanEventsController =
      StreamController<BleScanEvent>.broadcast();
  final Map<String, _FakeBleConnection> connections =
      <String, _FakeBleConnection>{};

  final List<String> preparedDeviceIds = <String>[];
  final List<String> reconnectedDeviceIds = <String>[];
  final List<String> removedDeviceIds = <String>[];
  Map<String, String?>? lastScanArguments;
  int permissionRequestCount = 0;
  int disposeCount = 0;

  void Function(String deviceId)? onReconnect;

  @override
  Stream<BleScanEvent> get scanEvents => _scanEventsController.stream;

  @override
  Stream<String> get logEvents => const Stream<String>.empty();

  @override
  Future<String> getDeviceName() async => 'Host Device';

  @override
  Future<bool> requestBlePermissions() async {
    permissionRequestCount += 1;
    return true;
  }

  @override
  Future<bool> getBleAdapterState() async => true;

  @override
  Future<List<BleDeviceInfo>> getKnownDevices() async => knownDevices;

  @override
  Future<bool> startScan({
    String? deviceId,
    String? macId,
    String? serviceUuid,
  }) async {
    lastScanArguments = <String, String?>{
      'deviceId': deviceId,
      'macId': macId,
      'serviceUuid': serviceUuid,
    };
    return true;
  }

  @override
  Future<bool> stopScan() async => true;

  @override
  Future<void> prepareDevice(String deviceId) async {
    preparedDeviceIds.add(deviceId);
  }

  @override
  Future<void> reconnect(String deviceId) async {
    reconnectedDeviceIds.add(deviceId);
    onReconnect?.call(deviceId);
  }

  @override
  Future<bool> removeDevice(String deviceId) async {
    removedDeviceIds.add(deviceId);
    return true;
  }

  @override
  BleConnection createConnection(String deviceId) {
    return connections.remove(deviceId) ?? newConnection(deviceId);
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
    await _scanEventsController.close();
  }

  _FakeBleConnection connectionFor(String deviceId) {
    return connections.putIfAbsent(deviceId, () => newConnection(deviceId));
  }

  _FakeBleConnection newConnection(String deviceId);
}

final class _FakeIosPlatform extends _FakeBlePlatformBase
    implements IosAccessorySetupCapability {
  _FakeIosPlatform({
    this.accessorySetupResult,
    List<BleDeviceInfo> knownDevices = const <BleDeviceInfo>[],
  }) : super(BleTarget.ios, knownDevices: knownDevices);

  final IosAccessorySetupResult? accessorySetupResult;
  List<IosAccessoryPickerItem>? lastAccessoryPickerItems;

  @override
  Future<IosAccessorySetupResult?> showAccessorySetup({
    required List<IosAccessoryPickerItem> items,
  }) async {
    lastAccessoryPickerItems = items;
    return accessorySetupResult;
  }

  @override
  _FakeBleConnection newConnection(String deviceId) =>
      _FakeBleConnection(deviceId);
}

final class _FakeMacosPlatform extends _FakeBlePlatformBase {
  _FakeMacosPlatform() : super(BleTarget.macos);

  @override
  _FakeBleConnection newConnection(String deviceId) =>
      _FakeBleConnection(deviceId);
}

final class _FakeAndroidPlatform extends _FakeBlePlatformBase
    implements AndroidBlePlatformCapability {
  _FakeAndroidPlatform() : super(BleTarget.android);

  final List<String> pairedDeviceIds = <String>[];

  @override
  Future<int> getApiLevel() async => 34;

  @override
  Future<bool?> requestEnableBle() async => true;

  @override
  Future<void> pair(String deviceId) async {
    pairedDeviceIds.add(deviceId);
  }

  @override
  _FakeAndroidBleConnection newConnection(String deviceId) {
    return _FakeAndroidBleConnection(deviceId);
  }
}

class _FakeBleConnection implements BleConnection {
  _FakeBleConnection(this.deviceId);

  @override
  final String deviceId;

  @override
  final BleTransport transport = const BleTransport.gatt();

  final StreamController<Uint8List> _readController =
      StreamController<Uint8List>.broadcast();
  final StreamController<DeviceStatus> _statusController =
      StreamController<DeviceStatus>.broadcast();

  bool disposed = false;
  void Function()? onStatusRequested;

  @override
  DeviceStatus lastDeviceStatus = const DeviceStatus(connected: false);

  void emitStatus(DeviceStatus status) {
    lastDeviceStatus = status;
    _statusController.add(status);
  }

  @override
  Stream<Uint8List> get readStream => _readController.stream;

  @override
  Stream<DeviceStatus> get deviceStatusStream => _statusController.stream;

  @override
  Stream<DeviceStatus> get connectionEvents =>
      deviceStatusStream.where((status) => status.isConnectionEvent);

  @override
  Future<DeviceStatus> getCurrentDeviceStatus() async {
    onStatusRequested?.call();
    return lastDeviceStatus;
  }

  @override
  Future<bool> isConnected() async => lastDeviceStatus.connected;

  @override
  Future<bool> write(Uint8List data) async => true;

  @override
  Future<int?> readRssi() async => null;

  @override
  Future<void> disconnect() async {}

  @override
  Future<String?> getConnectedPeripheralId() async => deviceId;

  @override
  Future<bool> reconnect() async => true;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _readController.close();
    await _statusController.close();
  }
}

final class _FakeAndroidBleConnection extends _FakeBleConnection
    implements AndroidBleConnectionCapability {
  _FakeAndroidBleConnection(super.deviceId);

  int bondCalls = 0;

  @override
  Future<bool> bond() async {
    bondCalls += 1;
    return true;
  }

  @override
  Future<bool> requestPhy2() async => true;
}
