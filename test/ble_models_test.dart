import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:foundation_ble/foundation_ble.dart';

void main() {
  group('BLE models', () {
    test('DeviceStatus parses connection event payloads', () {
      final status = DeviceStatus.fromMap(<String, Object?>{
        'type': 'device_connected',
        'connected': true,
        'ready': true,
        'peripheralId': 'abc',
        'peripheralName': 'Prime',
        'bonded': true,
      });

      expect(status.type, BluetoothConnectionEventType.deviceConnected);
      expect(status.connected, isTrue);
      expect(status.readyForWrite, isTrue);
      expect(status.peripheralId, 'abc');
      expect(status.peripheralName, 'Prime');
      expect(status.bonded, isTrue);
    });

    test('BleDeviceInfo falls back to shared device keys', () {
      final info = BleDeviceInfo.fromMap(<String, dynamic>{
        'deviceId': 'abc',
        'name': 'Prime',
        'bonded': true,
        'isConnected': true,
      });

      expect(info.peripheralId, 'abc');
      expect(info.peripheralName, 'Prime');
      expect(info.isConnected, isTrue);
      expect(info.bondState, isTrue);
      expect(info.state, 2);
    });

    test('BleScanEvent parses scan event payloads', () {
      final event = BleScanEvent.fromMap(<String, Object?>{
        'type': 'device_found',
        'deviceId': 'abc',
        'deviceName': 'Prime',
      });

      expect(event.type, BluetoothConnectionEventType.deviceFound);
      expect(event.deviceId, 'abc');
      expect(event.deviceName, 'Prime');
    });

    test('BleLogEvent parses typed and legacy payloads', () {
      final trace = BleLogEvent.fromPayload(<String, Object?>{
        'type': 'TRACE',
        'message': 'connectGatt issued',
      });
      final debug = BleLogEvent.fromPayload(<String, Object?>{
        'type': 'DEBUG',
        'message': 'Bluetooth adapter is disabled',
      });
      final legacy = BleLogEvent.fromPayload('legacy log line');

      expect(trace.type, BleLogType.trace);
      expect(trace.message, 'connectGatt issued');
      expect(debug.type, BleLogType.debug);
      expect(debug.message, 'Bluetooth adapter is disabled');
      expect(legacy.type, BleLogType.debug);
      expect(legacy.message, 'legacy log line');
    });

    test('IosAccessoryPickerItem serializes descriptor fields', () {
      final item = IosAccessoryPickerItem(
        id: 'prime-orange',
        name: 'Prime Orange',
        imageAsset: 'assets/prime_orange.png',
        descriptor: IosAccessoryDiscoveryDescriptor(
          bluetoothCompanyIdentifier: 1234,
          bluetoothManufacturerData: Uint8List.fromList(<int>[0x01, 0x02]),
          bluetoothManufacturerDataMask: Uint8List.fromList(<int>[0xFF, 0x00]),
          bluetoothNameCompareOptions: const <IosBluetoothNameCompareOption>{
            IosBluetoothNameCompareOption.caseInsensitive,
            IosBluetoothNameCompareOption.anchored,
          },
          bluetoothNameSubstring: 'Prime',
          bluetoothRange: IosAccessoryDiscoveryRange.immediate,
          bluetoothServiceData: Uint8List.fromList(<int>[0xA0, 0xB0]),
          bluetoothServiceDataMask: Uint8List.fromList(<int>[0xFF, 0xF0]),
          bluetoothServiceUuid: '6E400001-B5A3-F393-E0A9-E50E24DCCA9E',
        ),
      );

      final map = item.toMap();
      final descriptor = Map<String, Object?>.from(map['descriptor']! as Map);

      expect(map['id'], 'prime-orange');
      expect(map['name'], 'Prime Orange');
      expect(map['imageAsset'], 'assets/prime_orange.png');
      expect(descriptor['bluetoothCompanyIdentifier'], 1234);
      expect(
        descriptor['bluetoothManufacturerData'],
        Uint8List.fromList(<int>[0x01, 0x02]),
      );
      expect(
        descriptor['bluetoothManufacturerDataMask'],
        Uint8List.fromList(<int>[0xFF, 0x00]),
      );
      expect(descriptor['bluetoothNameCompareOptions'], <String>[
        'anchored',
        'caseInsensitive',
      ]);
      expect(descriptor['bluetoothNameSubstring'], 'Prime');
      expect(descriptor['bluetoothRange'], 'immediate');
      expect(
        descriptor['bluetoothServiceData'],
        Uint8List.fromList(<int>[0xA0, 0xB0]),
      );
      expect(
        descriptor['bluetoothServiceDataMask'],
        Uint8List.fromList(<int>[0xFF, 0xF0]),
      );
      expect(
        descriptor['bluetoothServiceUuid'],
        '6E400001-B5A3-F393-E0A9-E50E24DCCA9E',
      );
    });

    test('IosAccessorySetupResult parses method channel payloads', () {
      final result = IosAccessorySetupResult.fromMap(<String, Object?>{
        'deviceId': 'abc',
        'pickerItemId': 'prime-orange',
      });

      expect(result.deviceId, 'abc');
      expect(result.pickerItemId, 'prime-orange');
    });
  });
}
