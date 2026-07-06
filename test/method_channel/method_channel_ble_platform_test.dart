import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foundation_ble/foundation_ble.dart';
import 'package:foundation_ble/src/method_channel/method_channel_ble_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodCodec = StandardMethodCodec();
  final binding = TestDefaultBinaryMessengerBinding.instance;
  final messenger = binding.defaultBinaryMessenger;
  final methodChannel = MethodChannel(
    'foundation_ble/bluetooth',
    methodCodec,
    messenger,
  );

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      methodChannel,
      null,
    );
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'foundation_ble/bluetooth/scan/stream',
      null,
    );
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'foundation_ble/bluetooth/log/stream',
      null,
    );
  });

  test(
    'android adapter uses the root channel',
    () async {
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
        MethodCall call,
      ) async {
        calls.add(call);
        switch (call.method) {
          case 'getConnectedDevices':
            return <Map<String, Object?>>[
              <String, Object?>{
                'peripheralId': 'device-a',
                'peripheralName': 'Prime',
                'isConnected': true,
                'state': 2,
                'bondState': true,
              },
            ];
          case 'pair':
            return null;
          case 'removeDevice':
            return true;
          case 'apiLevel':
            return 34;
          case 'hasPermission':
            return true;
          case 'requestBlePermissions':
            return true;
        }
        return null;
      });

      final platform = MethodChannelBlePlatform(
        target: BleTarget.android,
        binaryMessenger: messenger,
      );

      final granted = await platform.requestBlePermissions();
      final knownDevices = await platform.getKnownDevices();
      final androidPlatform = platform as AndroidBlePlatformCapability;
      final hasPermission = await androidPlatform.hasPermission();
      await androidPlatform.pair('device-a');
      final apiLevel = await androidPlatform.getApiLevel();
      final removed = await platform.removeDevice('device-a');
      await platform.dispose();

      expect(granted, isTrue);
      expect(hasPermission, isTrue);
      expect(knownDevices, hasLength(1));
      expect(knownDevices.single.peripheralId, 'device-a');
      expect(apiLevel, 34);
      expect(removed, isTrue);
      expect(calls.map((call) => call.method), <String>[
        'requestBlePermissions',
        'getConnectedDevices',
        'hasPermission',
        'pair',
        'apiLevel',
        'removeDevice',
      ]);

      final pairArguments = Map<String, Object?>.from(
        calls[3].arguments as Map,
      );
      expect(pairArguments['deviceId'], 'device-a');
    },
  );

  test('android startScan forwards mac and UUID filters', () async {
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
      MethodCall call,
    ) async {
      calls.add(call);
      if (call.method == 'startScan') {
        return <String, Object?>{'scanning': true};
      }
      return null;
    });

    final platform = MethodChannelBlePlatform(
      target: BleTarget.android,
      binaryMessenger: messenger,
    );

    final started = await platform.startScan(
      macId: 'AA:BB:CC:DD:EE:FF',
      serviceUuid: '12345678-1234-1234-1234-1234567890AB',
    );
    await platform.dispose();

    expect(started, isTrue);
    expect(calls, hasLength(1));

    final arguments = Map<String, Object?>.from(calls.single.arguments as Map);
    expect(arguments['deviceId'], 'AA:BB:CC:DD:EE:FF');
    expect(arguments['macId'], 'AA:BB:CC:DD:EE:FF');
    expect(arguments['uuid'], '12345678-1234-1234-1234-1234567890AB');
    expect(arguments['serviceUuid'], '12345678-1234-1234-1234-1234567890AB');
  });

  test('ios adapter exposes accessory setup capability', () async {
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
      MethodCall call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'requestBlePermissions':
          return true;
        case 'getAccessories':
          return <Map<String, Object?>>[
            <String, Object?>{
              'peripheralId': 'ios-device',
              'peripheralName': 'Prime iOS',
              'isConnected': false,
              'state': 0,
              'bondState': false,
            },
          ];
        case 'showAccessorySetup':
          return <String, Object?>{
            'deviceId': 'ios-device',
            'pickerItemId': 'prime-orange',
          };
      }
      return null;
    });

    final platform = MethodChannelBlePlatform(
      target: BleTarget.ios,
      binaryMessenger: messenger,
    );
    final granted = await platform.requestBlePermissions();
    final knownDevices = await platform.getKnownDevices();
    final iosCapability = platform as IosAccessorySetupCapability;
    final setupResult = await iosCapability.showAccessorySetup(
      items: const <IosAccessoryPickerItem>[
        IosAccessoryPickerItem(
          id: 'prime-orange',
          name: 'Prime Orange',
          imageAsset: 'assets/prime_orange.png',
          descriptor: IosAccessoryDiscoveryDescriptor(
            bluetoothNameSubstring: 'Prime',
            bluetoothServiceUuid: '6E400001-B5A3-F393-E0A9-E50E24DCCA9E',
            bluetoothRange: IosAccessoryDiscoveryRange.immediate,
          ),
        ),
      ],
    );

    expect(granted, isTrue);
    expect(knownDevices.single.peripheralId, 'ios-device');
    expect(setupResult?.deviceId, 'ios-device');
    expect(setupResult?.pickerItemId, 'prime-orange');
    expect(calls.first.method, 'requestBlePermissions');
    expect(calls[1].method, 'getAccessories');
    expect(calls.last.method, 'showAccessorySetup');

    final arguments = Map<String, Object?>.from(calls.last.arguments as Map);
    final items = List<Object?>.from(arguments['items']! as List);
    final item = Map<String, Object?>.from(items.single! as Map);
    final descriptor = Map<String, Object?>.from(item['descriptor']! as Map);

    expect(item['id'], 'prime-orange');
    expect(item['name'], 'Prime Orange');
    expect(item['imageAsset'], 'assets/prime_orange.png');
    expect(descriptor['bluetoothNameSubstring'], 'Prime');
    expect(
      descriptor['bluetoothServiceUuid'],
      '6E400001-B5A3-F393-E0A9-E50E24DCCA9E',
    );
    expect(descriptor['bluetoothRange'], 'immediate');
  });

  test(
    'ios accessory setup rejects empty picker items before native call',
    () async {
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
        MethodCall call,
      ) async {
        calls.add(call);
        return null;
      });

      final platform = MethodChannelBlePlatform(
        target: BleTarget.ios,
        binaryMessenger: messenger,
      );
      final iosCapability = platform as IosAccessorySetupCapability;

      await expectLater(
        iosCapability.showAccessorySetup(
          items: const <IosAccessoryPickerItem>[],
        ),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    },
  );

  test('scanEvents parses event payloads from the event channel', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      methodChannel,
      (MethodCall call) async => null,
    );
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'foundation_ble/bluetooth/scan/stream',
      (ByteData? message) async {
        final call = methodCodec.decodeMethodCall(message);
        if (call.method == 'listen') {
          Future<void>.delayed(Duration.zero, () {
            messenger.handlePlatformMessage(
              'foundation_ble/bluetooth/scan/stream',
              methodCodec.encodeSuccessEnvelope(<String, Object?>{
                'type': 'device_found',
                'deviceId': 'scan-device',
                'deviceName': 'Prime Scan',
              }),
              (_) {},
            );
          });
        }
        return methodCodec.encodeSuccessEnvelope(null);
      },
    );

    final platform = MethodChannelBlePlatform(
      target: BleTarget.macos,
      binaryMessenger: messenger,
    );

    final event = await platform.scanEvents.first;

    expect(event.type, BluetoothConnectionEventType.deviceFound);
    expect(event.deviceId, 'scan-device');
    expect(event.deviceName, 'Prime Scan');
  });

  test('logEvents parses typed payloads from the event channel', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      methodChannel,
      (MethodCall call) async => null,
    );
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'foundation_ble/bluetooth/log/stream',
      (ByteData? message) async {
        final call = methodCodec.decodeMethodCall(message);
        if (call.method == 'listen') {
          Future<void>.delayed(Duration.zero, () {
            messenger.handlePlatformMessage(
              'foundation_ble/bluetooth/log/stream',
              methodCodec.encodeSuccessEnvelope(<String, Object?>{
                'type': 'TRACE',
                'message': 'connectGatt issued',
              }),
              (_) {},
            );
          });
        }
        return methodCodec.encodeSuccessEnvelope(null);
      },
    );

    final platform = MethodChannelBlePlatform(
      target: BleTarget.android,
      binaryMessenger: messenger,
    );

    final event = await platform.logEvents.first;

    expect(event.type, BleLogType.trace);
    expect(event.message, 'connectGatt issued');
  });

  test(
    'macos adapter requests BLE permissions through the method channel',
    () async {
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
        MethodCall call,
      ) async {
        calls.add(call);
        switch (call.method) {
          case 'requestBlePermissions':
            return true;
        }
        return null;
      });

      final platform = MethodChannelBlePlatform(
        target: BleTarget.macos,
        binaryMessenger: messenger,
      );

      final granted = await platform.requestBlePermissions();

      expect(granted, isTrue);
      expect(calls.map((call) => call.method), <String>[
        'requestBlePermissions',
      ]);
    },
  );
}
