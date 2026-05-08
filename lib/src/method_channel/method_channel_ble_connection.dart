import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:foundation_ble/foundation_ble.dart';

import 'ble_channel_configuration.dart';

class MethodChannelBleConnection implements BleConnection {
  MethodChannelBleConnection({
    required this.deviceId,
    BinaryMessenger? binaryMessenger,
    BleChannelConfiguration configuration = const BleChannelConfiguration(),
  }) : _methodChannel = MethodChannel(
         '${configuration.bleChannelRoot}/$deviceId',
         const StandardMethodCodec(),
         binaryMessenger,
       ),
       _bleReadChannel = BasicMessageChannel<ByteData>(
         '${configuration.bleReadChannelRoot}/$deviceId',
         const BinaryCodec(),
         binaryMessenger: binaryMessenger,
       ),
       _bleWriteChannel = BasicMessageChannel<ByteData>(
         '${configuration.bleWriteChannelRoot}/$deviceId',
         const BinaryCodec(),
         binaryMessenger: binaryMessenger,
       ),
       _connectionEventChannel = EventChannel(
         '${configuration.bleConnectionStreamRoot}/$deviceId',
         const StandardMethodCodec(),
         binaryMessenger,
       ) {
    _deviceStatusController = StreamController<DeviceStatus>.broadcast(
      onListen: _startDeviceStatusSubscription,
    );
    _initChannels();
  }

  final MethodChannel _methodChannel;
  final BasicMessageChannel<ByteData> _bleReadChannel;
  final BasicMessageChannel<ByteData> _bleWriteChannel;
  final EventChannel _connectionEventChannel;

  @override
  final String deviceId;

  final StreamController<Uint8List> _readController =
      StreamController<Uint8List>.broadcast();
  late final StreamController<DeviceStatus> _deviceStatusController;

  StreamSubscription<dynamic>? _deviceStatusSubscription;

  @override
  DeviceStatus lastDeviceStatus = const DeviceStatus(connected: false);

  bool _isDisposed = false;

  @override
  Stream<Uint8List> get readStream => _readController.stream;

  @override
  Stream<DeviceStatus> get deviceStatusStream => _deviceStatusController.stream;

  @override
  Stream<DeviceStatus> get connectionEvents =>
      deviceStatusStream.where((status) => status.isConnectionEvent);

  void _initChannels() {
    _bleReadChannel.setMessageHandler((ByteData? message) async {
      if (message != null && !_readController.isClosed) {
        _readController.add(message.buffer.asUint8List());
      }
      return ByteData(0);
    });
  }

  void _startDeviceStatusSubscription() {
    if (_deviceStatusSubscription != null || _isDisposed) {
      return;
    }

    _deviceStatusSubscription = _connectionEventChannel
        .receiveBroadcastStream()
        .listen((dynamic event) {
          final status = event is Map<dynamic, dynamic>
              ? DeviceStatus.fromMap(event)
              : const DeviceStatus(connected: false);
          lastDeviceStatus = status;
          if (!_deviceStatusController.isClosed) {
            _deviceStatusController.add(status);
          }
        });
  }

  @override
  Future<DeviceStatus> getCurrentDeviceStatus() async {
    try {
      final result = await _invokeMethod<Map<dynamic, dynamic>>(
        'getCurrentDeviceStatus',
      );
      if (result == null) {
        return const DeviceStatus(connected: false);
      }

      final status = DeviceStatus.fromMap(result);
      lastDeviceStatus = status;
      return status;
    } catch (_) {
      return const DeviceStatus(connected: false);
    }
  }

  @override
  Future<bool> isConnected() async {
    try {
      return await _invokeMethod<bool>('isConnected') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> write(Uint8List data) async {
    if (_isDisposed) {
      return false;
    }

    try {
      final result = await _bleWriteChannel.send(ByteData.sublistView(data));
      if (result == null || result.lengthInBytes == 0) {
        return false;
      }
      return result.getUint8(0) == 1;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int?> readRssi() async {
    try {
      return await _invokeMethod<int>('readRssi');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _invokeMethod<void>('disconnect');
    } catch (_) {
      // Best-effort disconnect.
    }
  }

  @override
  Future<String?> getConnectedPeripheralId() async {
    try {
      return await _invokeMethod<String>('getConnectedPeripheralId');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> reconnect() async {
    try {
      final result = await _invokeMethod<dynamic>('reconnect');
      return result == true ||
          (result is Map<dynamic, dynamic> && result['reconnecting'] == true);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;

    try {
      await _invokeMethod<void>('dispose');
    } catch (_) {}
    await _deviceStatusSubscription?.cancel();
    _bleReadChannel.setMessageHandler(null);
    await _readController.close();
    await _deviceStatusController.close();
  }

  @protected
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) {
    return _invokeMethod<T>(method, arguments);
  }

  Future<T?> _invokeMethod<T>(String method, [Object? arguments]) {
    return _methodChannel.invokeMethod<T>(method, arguments);
  }
}

class AndroidMethodChannelBleConnection extends MethodChannelBleConnection
    implements AndroidBleConnectionCapability {
  AndroidMethodChannelBleConnection({
    required super.deviceId,
    super.binaryMessenger,
    super.configuration,
  });

  @override
  Future<bool> bond() async {
    try {
      return await invokeMethod<bool>('bond') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestPhy2() async {
    try {
      return await invokeMethod<bool>('requestPhy2') ?? false;
    } catch (_) {
      return false;
    }
  }
}
