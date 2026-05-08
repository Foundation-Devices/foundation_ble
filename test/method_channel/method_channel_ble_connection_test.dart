import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foundation_ble/src/method_channel/method_channel_ble_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodCodec = StandardMethodCodec();
  const binaryCodec = BinaryCodec();
  final binding = TestDefaultBinaryMessengerBinding.instance;
  final messenger = binding.defaultBinaryMessenger;
  final rootMethodChannel = MethodChannel(
    'foundation_ble/bluetooth',
    methodCodec,
    messenger,
  );
  final methodChannel = MethodChannel(
    'foundation_ble/bluetooth/device-a',
    methodCodec,
    messenger,
  );
  final writeChannel = BasicMessageChannel<ByteData>(
    'foundation_ble/ble/write/device-a',
    binaryCodec,
    binaryMessenger: messenger,
  );

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      rootMethodChannel,
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      methodChannel,
      null,
    );
    binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
      writeChannel,
      null,
    );
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'foundation_ble/bluetooth/connection/stream/device-a',
      null,
    );
  });

  test(
    'does not activate status event channel until stream is listened to',
    () async {
      var listenCalls = 0;
      binding.defaultBinaryMessenger.setMockMessageHandler(
        'foundation_ble/bluetooth/connection/stream/device-a',
        (ByteData? message) async {
          final call = methodCodec.decodeMethodCall(message);
          if (call.method == 'listen') {
            listenCalls += 1;
          }
          return methodCodec.encodeSuccessEnvelope(null);
        },
      );

      final connection = MethodChannelBleConnection(
        deviceId: 'device-a',
        binaryMessenger: messenger,
      );

      await Future<void>.delayed(Duration.zero);
      expect(listenCalls, 0);

      final subscription = connection.deviceStatusStream.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(listenCalls, 1);

      await subscription.cancel();
      await connection.dispose();
    },
  );

  test(
    'connection adapter maps methods, read/write, and status streams',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        rootMethodChannel,
        (MethodCall call) async {
          switch (call.method) {
            case 'removeDevice':
              return true;
          }
          return null;
        },
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(methodChannel, (
        MethodCall call,
      ) async {
        switch (call.method) {
          case 'getCurrentDeviceStatus':
            return <String, Object?>{
              'type': 'device_connected',
              'connected': true,
              'ready': true,
              'bonded': true,
              'peripheralId': 'device-a',
            };
          case 'reconnect':
            return <String, Object?>{'reconnecting': true};
          case 'getConnectedPeripheralId':
            return 'device-a';
          case 'bond':
            return true;
        }
        return null;
      });
      binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
        writeChannel,
        (ByteData? message) async {
          final result = ByteData(1);
          result.setUint8(0, 1);
          return result;
        },
      );
      binding.defaultBinaryMessenger.setMockMessageHandler(
        'foundation_ble/bluetooth/connection/stream/device-a',
        (ByteData? message) async {
          final call = methodCodec.decodeMethodCall(message);
          if (call.method == 'listen') {
            Future<void>.delayed(Duration.zero, () {
              messenger.handlePlatformMessage(
                'foundation_ble/bluetooth/connection/stream/device-a',
                methodCodec.encodeSuccessEnvelope(<String, Object?>{
                  'type': 'device_connected',
                  'connected': true,
                  'ready': true,
                  'bonded': true,
                  'peripheralId': 'device-a',
                }),
                (_) {},
              );
            });
          }
          return methodCodec.encodeSuccessEnvelope(null);
        },
      );

      final connection = AndroidMethodChannelBleConnection(
        deviceId: 'device-a',
        binaryMessenger: messenger,
      );

      final statusFuture = connection.connectionEvents.first;
      final status = await connection.getCurrentDeviceStatus();
      final writeResult = await connection.write(
        Uint8List.fromList(<int>[1, 2, 3]),
      );
      final reconnectResult = await connection.reconnect();
      final peripheralId = await connection.getConnectedPeripheralId();
      final bondResult = await connection.bond();
      final streamedStatus = await statusFuture;

      expect(status.connected, isTrue);
      expect(connection.lastDeviceStatus.connected, isTrue);
      expect(writeResult, isTrue);
      expect(reconnectResult, isTrue);
      expect(peripheralId, 'device-a');
      expect(bondResult, isTrue);
      expect(streamedStatus.readyForWrite, isTrue);

      await connection.dispose();
    },
  );
}
