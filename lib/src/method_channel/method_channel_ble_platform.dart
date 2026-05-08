import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:foundation_ble/foundation_ble.dart';

import 'ble_channel_configuration.dart';
import 'method_channel_ble_connection.dart';

abstract class MethodChannelBlePlatform extends BlePlatform {
  MethodChannelBlePlatform._();

  factory MethodChannelBlePlatform({
    BleTarget? target,
    BinaryMessenger? binaryMessenger,
    BleTransport transport = const BleTransport.gatt(),
    BleChannelConfiguration configuration = const BleChannelConfiguration(),
  }) {
    transport.validate();

    final resolvedTarget = target ?? _detectTarget();
    return switch (resolvedTarget) {
      BleTarget.android => _AndroidMethodChannelBlePlatform(
        binaryMessenger: binaryMessenger,
        transport: transport,
        configuration: configuration,
      ),
      BleTarget.ios => _IosMethodChannelBlePlatform(
        binaryMessenger: binaryMessenger,
        transport: transport,
        configuration: configuration,
      ),
      BleTarget.macos => _MacosMethodChannelBlePlatform(
        binaryMessenger: binaryMessenger,
        transport: transport,
        configuration: configuration,
      ),
    };
  }

  static BleTarget _detectTarget() {
    if (kIsWeb) {
      throw UnsupportedError(
        'foundation_ble only supports Android, iOS, and macOS',
      );
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => BleTarget.android,
      TargetPlatform.iOS => BleTarget.ios,
      TargetPlatform.macOS => BleTarget.macos,
      _ => throw UnsupportedError(
        'foundation_ble only supports Android, iOS, and macOS',
      ),
    };
  }
}

Map<String, Object?>? _buildScanArguments({
  String? deviceId,
  String? macId,
  String? serviceUuid,
}) {
  final normalizedDeviceId = deviceId?.trim();
  final normalizedMacId = macId?.trim();
  final normalizedServiceUuid = serviceUuid?.trim();

  final hasDeviceId =
      normalizedDeviceId != null && normalizedDeviceId.isNotEmpty;
  final hasMacId = normalizedMacId != null && normalizedMacId.isNotEmpty;
  final hasServiceUuid =
      normalizedServiceUuid != null && normalizedServiceUuid.isNotEmpty;
  final lowercaseDeviceId = normalizedDeviceId?.toLowerCase();
  final lowercaseMacId = normalizedMacId?.toLowerCase();

  if (hasDeviceId && hasMacId && lowercaseDeviceId != lowercaseMacId) {
    throw ArgumentError.value(
      macId,
      'macId',
      'macId and deviceId must match when both are provided',
    );
  }

  final resolvedMacId = hasMacId ? normalizedMacId : normalizedDeviceId;
  if (resolvedMacId == null && !hasServiceUuid) {
    return null;
  }

  return <String, Object?>{
    if (resolvedMacId case final String resolvedMacId)
      'deviceId': resolvedMacId,
    if (resolvedMacId case final String resolvedMacId) 'macId': resolvedMacId,
    if (normalizedServiceUuid case final String normalizedServiceUuid)
      'uuid': normalizedServiceUuid,
    if (normalizedServiceUuid case final String normalizedServiceUuid)
      'serviceUuid': normalizedServiceUuid,
  };
}

void _logAccessorySetupDebug(String message) {
  assert(() {
    debugPrint('[FoundationBle:AccessorySetup][Flutter] $message');
    return true;
  }());
}

String _formatAccessorySetupDebugValue(Object? value) {
  if (value == null) {
    return 'null';
  }

  if (value is Uint8List) {
    return _formatAccessorySetupDebugBytes(value);
  }

  if (value is List) {
    return '[${value.map(_formatAccessorySetupDebugValue).join(', ')}]';
  }

  if (value is Map) {
    return '{${value.entries.map((entry) => '${entry.key}: ${_formatAccessorySetupDebugValue(entry.value)}').join(', ')}}';
  }

  return value.toString();
}

String _formatAccessorySetupDebugBytes(Uint8List bytes) {
  const maxLoggedBytes = 32;
  final limit = bytes.lengthInBytes < maxLoggedBytes
      ? bytes.lengthInBytes
      : maxLoggedBytes;
  final buffer = StringBuffer('0x');
  for (var index = 0; index < limit; index += 1) {
    buffer.write(bytes[index].toRadixString(16).padLeft(2, '0').toUpperCase());
  }
  if (bytes.lengthInBytes > maxLoggedBytes) {
    buffer.write('... (${bytes.lengthInBytes} bytes)');
  }
  return buffer.toString();
}

abstract base class _MethodChannelBlePlatformBase
    extends MethodChannelBlePlatform {
  _MethodChannelBlePlatformBase({
    required this.target,
    BinaryMessenger? binaryMessenger,
    BleChannelConfiguration configuration = const BleChannelConfiguration(),
  }) : _binaryMessenger = binaryMessenger,
       _configuration = configuration,
       _methodChannel = MethodChannel(
         configuration.bluetoothMethodChannelName,
         const StandardMethodCodec(),
         binaryMessenger,
       ),
       _scanEventChannel = EventChannel(
         configuration.bluetoothScanStreamName,
         const StandardMethodCodec(),
         binaryMessenger,
       ),
       _logEventChannel = EventChannel(
         configuration.bluetoothLogStreamName,
         const StandardMethodCodec(),
         binaryMessenger,
       ),
       super._() {
    _scanEvents = _scanEventChannel.receiveBroadcastStream().map((
      dynamic event,
    ) {
      if (event is Map<dynamic, dynamic>) {
        return BleScanEvent.fromMap(event);
      }
      return const BleScanEvent();
    }).asBroadcastStream();

    _logEvents = _logEventChannel
        .receiveBroadcastStream()
        .map((dynamic event) => event?.toString() ?? '')
        .asBroadcastStream();
  }

  final BinaryMessenger? _binaryMessenger;
  final BleChannelConfiguration _configuration;
  final MethodChannel _methodChannel;
  final EventChannel _scanEventChannel;
  final EventChannel _logEventChannel;

  late final Stream<BleScanEvent> _scanEvents;
  late final Stream<String> _logEvents;

  @override
  final BleTarget target;

  @override
  Stream<BleScanEvent> get scanEvents => _scanEvents;

  @override
  Stream<String> get logEvents => _logEvents;

  @override
  Future<String> getDeviceName() async {
    final name = await _invokeMethod<String>('deviceName');
    return name ?? 'Unknown';
  }

  @override
  Future<bool> requestBlePermissions() async {
    return (await _invokeMethod<bool>('requestBlePermissions')) ?? false;
  }

  @override
  Future<bool> getBleAdapterState() async {
    return await _invokeMethod<bool>('getBleAdapterState') ?? false;
  }

  @override
  Future<List<BleDeviceInfo>> getKnownDevices() async {
    final methodName = switch (target) {
      BleTarget.android => 'getConnectedDevices',
      BleTarget.ios || BleTarget.macos => 'getAccessories',
    };

    try {
      final result = await _invokeMethod<List<dynamic>>(methodName);
      if (result == null) {
        return const <BleDeviceInfo>[];
      }

      return result
          .map(
            (dynamic item) =>
                BleDeviceInfo.fromMap(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false);
    } catch (_) {
      return const <BleDeviceInfo>[];
    }
  }

  @override
  Future<bool> startScan({
    String? deviceId,
    String? macId,
    String? serviceUuid,
  }) async {
    final arguments = _buildScanArguments(
      deviceId: deviceId,
      macId: macId,
      serviceUuid: serviceUuid,
    );

    try {
      final result = await _invokeMethod<Map<dynamic, dynamic>>(
        'startScan',
        arguments,
      );
      return result?['scanning'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> stopScan() async {
    try {
      final result = await _invokeMethod<Map<dynamic, dynamic>>('stopScan');
      return result?['scanning'] == false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> prepareDevice(String deviceId) async {
    await _invokeMethod<void>('prepareDevice', <String, Object?>{
      'deviceId': deviceId,
    });
  }

  @override
  Future<void> reconnect(String deviceId) async {
    await _invokeMethod<void>('reconnect', <String, Object?>{
      'deviceId': deviceId,
    });
  }

  @override
  Future<bool> removeDevice(String deviceId) async {
    try {
      final result = await _invokeMethod<bool>(
        'removeDevice',
        <String, Object?>{'deviceId': deviceId},
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  BleConnection createConnection(String deviceId) {
    return MethodChannelBleConnection(
      deviceId: deviceId,
      transport: const BleTransport.gatt(),
      binaryMessenger: _binaryMessenger,
      configuration: _configuration,
    );
  }

  @override
  Future<void> dispose() async {}

  @protected
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) {
    return _invokeMethod<T>(method, arguments);
  }

  @protected
  BinaryMessenger? get binaryMessenger => _binaryMessenger;

  @protected
  BleChannelConfiguration get configuration => _configuration;

  Future<T?> _invokeMethod<T>(String method, [Object? arguments]) {
    return _methodChannel.invokeMethod<T>(method, arguments);
  }
}

final class _AndroidMethodChannelBlePlatform
    extends _MethodChannelBlePlatformBase
    implements AndroidBlePlatformCapability {
  _AndroidMethodChannelBlePlatform({
    required this.transport,
    super.binaryMessenger,
    super.configuration = const BleChannelConfiguration(),
  }) : super(target: BleTarget.android);

  final BleTransport transport;

  @override
  Future<List<BleDeviceInfo>> getKnownDevices() async {
    return _runWithFallback<List<BleDeviceInfo>>(() async {
      final result = await _invokeTransportAwareMethod<List<dynamic>>(
        'getConnectedDevices',
        _transportArguments(),
      );
      if (result == null) {
        return const <BleDeviceInfo>[];
      }

      return result
          .map(
            (dynamic item) =>
                BleDeviceInfo.fromMap(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false);
    }, const <BleDeviceInfo>[]);
  }

  @override
  Future<bool> startScan({
    String? deviceId,
    String? macId,
    String? serviceUuid,
  }) async {
    final arguments = _buildScanArguments(
      deviceId: deviceId,
      macId: macId,
      serviceUuid: serviceUuid,
    );

    return _runWithFallback<bool>(() async {
      final result = await _invokeTransportAwareMethod<Map<dynamic, dynamic>>(
        'startScan',
        _transportArguments(arguments),
      );
      return result?['scanning'] == true;
    }, false);
  }

  @override
  Future<void> prepareDevice(String deviceId) async {
    await _invokeTransportAwareMethod<void>(
      'prepareDevice',
      _transportArguments(<String, Object?>{'deviceId': deviceId}),
    );
  }

  @override
  Future<void> reconnect(String deviceId) async {
    await _invokeTransportAwareMethod<void>(
      'reconnect',
      _transportArguments(<String, Object?>{'deviceId': deviceId}),
    );
  }

  @override
  BleConnection createConnection(String deviceId) {
    return AndroidMethodChannelBleConnection(
      deviceId: deviceId,
      transport: transport,
      binaryMessenger: binaryMessenger,
      configuration: configuration,
    );
  }

  @override
  Future<int> getApiLevel() async {
    return await invokeMethod<int>('apiLevel') ?? 0;
  }

  @override
  Future<bool?> requestEnableBle() async {
    return invokeMethod<bool>('enableBluetooth');
  }

  @override
  Future<void> pair(String deviceId) async {
    await _invokeTransportAwareMethod<void>(
      'pair',
      _transportArguments(<String, Object?>{'deviceId': deviceId}),
    );
  }

  Future<T> _runWithFallback<T>(Future<T> Function() action, T fallback) async {
    try {
      return await action();
    } on BleTransportException {
      rethrow;
    } catch (_) {
      return fallback;
    }
  }

  Map<String, Object?> _transportArguments([Map<String, Object?>? arguments]) {
    return <String, Object?>{
      if (arguments != null) ...arguments,
      'transport': transport.toMap(),
    };
  }

  Future<T?> _invokeTransportAwareMethod<T>(
    String method, [
    Object? arguments,
  ]) async {
    try {
      return await invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      if (error.code == 'INVALID_TRANSPORT' ||
          error.code == 'TRANSPORT_UNSUPPORTED') {
        throw BleTransportException(
          error.message ?? 'Failed to use ${transport.mode.name} transport',
        );
      }
      rethrow;
    }
  }
}

final class _IosMethodChannelBlePlatform extends _MethodChannelBlePlatformBase
    implements IosAccessorySetupCapability {
  _IosMethodChannelBlePlatform({
    required this.transport,
    super.binaryMessenger,
    super.configuration = const BleChannelConfiguration(),
  }) : super(target: BleTarget.ios);

  final BleTransport transport;

  @override
  Future<List<BleDeviceInfo>> getKnownDevices() async {
    return _runWithFallback<List<BleDeviceInfo>>(() async {
      final result = await _invokeTransportAwareMethod<List<dynamic>>(
        'getAccessories',
        _transportArguments(),
      );
      if (result == null) {
        return const <BleDeviceInfo>[];
      }

      return result
          .map(
            (dynamic item) =>
                BleDeviceInfo.fromMap(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false);
    }, const <BleDeviceInfo>[]);
  }

  @override
  Future<bool> startScan({
    String? deviceId,
    String? macId,
    String? serviceUuid,
  }) async {
    final arguments = _buildScanArguments(
      deviceId: deviceId,
      macId: macId,
      serviceUuid: serviceUuid,
    );

    return _runWithFallback<bool>(() async {
      final result = await _invokeTransportAwareMethod<Map<dynamic, dynamic>>(
        'startScan',
        _transportArguments(arguments),
      );
      return result?['scanning'] == true;
    }, false);
  }

  @override
  Future<void> prepareDevice(String deviceId) async {
    await _invokeTransportAwareMethod<void>(
      'prepareDevice',
      _transportArguments(<String, Object?>{'deviceId': deviceId}),
    );
  }

  @override
  Future<void> reconnect(String deviceId) async {
    await _invokeTransportAwareMethod<void>(
      'reconnect',
      _transportArguments(<String, Object?>{'deviceId': deviceId}),
    );
  }

  @override
  BleConnection createConnection(String deviceId) {
    return MethodChannelBleConnection(
      deviceId: deviceId,
      transport: transport,
      binaryMessenger: binaryMessenger,
      configuration: configuration,
    );
  }

  @override
  Future<IosAccessorySetupResult?> showAccessorySetup({
    required List<IosAccessoryPickerItem> items,
  }) async {
    if (items.isEmpty) {
      throw ArgumentError.value(items, 'items', 'must not be empty');
    }

    final arguments = <String, Object?>{
      'items': items.map((item) => item.toMap()).toList(growable: false),
    };

    _logAccessorySetupDebug(
      'showAccessorySetup request=${_formatAccessorySetupDebugValue(arguments)}',
    );

    final result = await invokeMethod<Object?>('showAccessorySetup', arguments);

    _logAccessorySetupDebug(
      'showAccessorySetup result=${_formatAccessorySetupDebugValue(result)}',
    );

    if (result == null) {
      return null;
    }
    if (result is String) {
      return result.isEmpty ? null : IosAccessorySetupResult(deviceId: result);
    }
    if (result is Map<dynamic, dynamic>) {
      return IosAccessorySetupResult.fromMap(Map<String, dynamic>.from(result));
    }

    throw ArgumentError.value(
      result,
      'result',
      'Unexpected iOS accessory setup result payload',
    );
  }

  Future<T> _runWithFallback<T>(Future<T> Function() action, T fallback) async {
    try {
      return await action();
    } catch (_) {
      return fallback;
    }
  }

  Map<String, Object?> _transportArguments([Map<String, Object?>? arguments]) {
    return <String, Object?>{
      if (arguments != null) ...arguments,
      'transport': transport.toMap(),
    };
  }

  Future<T?> _invokeTransportAwareMethod<T>(
    String method, [
    Object? arguments,
  ]) async {
    return invokeMethod<T>(method, arguments);
  }
}

final class _MacosMethodChannelBlePlatform
    extends _MethodChannelBlePlatformBase {
  _MacosMethodChannelBlePlatform({
    required this.transport,
    super.binaryMessenger,
    super.configuration = const BleChannelConfiguration(),
  }) : super(target: BleTarget.macos);

  final BleTransport transport;

  @override
  Future<List<BleDeviceInfo>> getKnownDevices() async {
    return _runWithFallback<List<BleDeviceInfo>>(() async {
      final result = await _invokeTransportAwareMethod<List<dynamic>>(
        'getAccessories',
        _transportArguments(),
      );
      if (result == null) {
        return const <BleDeviceInfo>[];
      }

      return result
          .map(
            (dynamic item) =>
                BleDeviceInfo.fromMap(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false);
    }, const <BleDeviceInfo>[]);
  }

  @override
  Future<bool> startScan({
    String? deviceId,
    String? macId,
    String? serviceUuid,
  }) async {
    final arguments = _buildScanArguments(
      deviceId: deviceId,
      macId: macId,
      serviceUuid: serviceUuid,
    );

    return _runWithFallback<bool>(() async {
      final result = await _invokeTransportAwareMethod<Map<dynamic, dynamic>>(
        'startScan',
        _transportArguments(arguments),
      );
      return result?['scanning'] == true;
    }, false);
  }

  @override
  Future<void> prepareDevice(String deviceId) async {
    await _invokeTransportAwareMethod<void>(
      'prepareDevice',
      _transportArguments(<String, Object?>{'deviceId': deviceId}),
    );
  }

  @override
  Future<void> reconnect(String deviceId) async {
    await _invokeTransportAwareMethod<void>(
      'reconnect',
      _transportArguments(<String, Object?>{'deviceId': deviceId}),
    );
  }

  @override
  BleConnection createConnection(String deviceId) {
    return MethodChannelBleConnection(
      deviceId: deviceId,
      transport: transport,
      binaryMessenger: binaryMessenger,
      configuration: configuration,
    );
  }

  Future<T> _runWithFallback<T>(Future<T> Function() action, T fallback) async {
    try {
      return await action();
    } on BleTransportException {
      rethrow;
    } catch (_) {
      return fallback;
    }
  }

  Map<String, Object?> _transportArguments([Map<String, Object?>? arguments]) {
    return <String, Object?>{
      if (arguments != null) ...arguments,
      'transport': transport.toMap(),
    };
  }

  Future<T?> _invokeTransportAwareMethod<T>(
    String method, [
    Object? arguments,
  ]) async {
    try {
      return await invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      if (error.code == 'INVALID_TRANSPORT' ||
          error.code == 'TRANSPORT_UNSUPPORTED') {
        throw BleTransportException(
          error.message ?? 'Failed to use ${transport.mode.name} transport',
        );
      }
      rethrow;
    }
  }
}
