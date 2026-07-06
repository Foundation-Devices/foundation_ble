import 'dart:async';

import 'ble_connection.dart';
import 'ble_exceptions.dart';
import 'ble_platform.dart';
import 'method_channel/method_channel_ble_platform.dart';
import 'models/ble_device_info.dart';
import 'models/ble_log_event.dart';
import 'models/ble_scan_event.dart';
import 'models/ble_status.dart';
import 'models/ios_accessory_setup.dart';

class FoundationBle {
  FoundationBle({
    BlePlatform? platform,
    this.setupTimeout = const Duration(seconds: 10),
  }) : platform = platform ?? MethodChannelBlePlatform() {
    _ownedPlatforms.add(this.platform);
  }

  final BlePlatform platform;
  final Duration setupTimeout;

  final List<BlePlatform> _ownedPlatforms = <BlePlatform>[];

  final Map<String, BleConnection> _deviceConnections =
      <String, BleConnection>{};
  final StreamController<List<BleConnection>> _deviceConnectionsController =
      StreamController<List<BleConnection>>.broadcast();

  Stream<List<BleConnection>> get deviceConnectionsStream =>
      _deviceConnectionsController.stream;

  List<BleConnection> get deviceConnections =>
      _deviceConnections.values.toList(growable: false);

  List<String> get activeDeviceIds =>
      _deviceConnections.keys.toList(growable: false);

  Stream<BleScanEvent> get scanEvents => platform.scanEvents;

  Stream<BleLogEvent> get logEvents => platform.logEvents;

  BleConnection getDeviceConnection(String deviceId) {
    final existingConnection = _deviceConnections[deviceId];
    if (existingConnection != null) {
      return existingConnection;
    }

    final connection = platform.createConnection(deviceId);
    _deviceConnections[deviceId] = connection;
    _notifyDeviceConnectionsChanged();
    return connection;
  }

  Future<BleConnection> _createDeviceConnection(String deviceId) async {
    final existingConnection = _deviceConnections.remove(deviceId);
    if (existingConnection != null) {
      await existingConnection.dispose();
    }

    final connection = platform.createConnection(deviceId);
    _deviceConnections[deviceId] = connection;
    _notifyDeviceConnectionsChanged();
    return connection;
  }

  bool hasDeviceConnection(String deviceId) {
    return _deviceConnections.containsKey(deviceId);
  }

  void removeDeviceConnection(String deviceId) {
    final connection = _deviceConnections.remove(deviceId);
    if (connection != null) {
      unawaited(connection.dispose());
    }
    _notifyDeviceConnectionsChanged();
  }

  Future<String> getDeviceName() => platform.getDeviceName();

  Future<bool> requestBlePermissions() => platform.requestBlePermissions();

  Future<bool?> hasPermission() {
    final android = platform is AndroidBlePlatformCapability
        ? platform as AndroidBlePlatformCapability
        : null;
    return android?.hasPermission() ?? Future.value(null);
  }

  Future<bool> getBleAdapterState() => platform.getBleAdapterState();

  Future<bool?> requestEnableBle() {
    final android = platform is AndroidBlePlatformCapability
        ? platform as AndroidBlePlatformCapability
        : null;
    return android?.requestEnableBle() ?? Future.value(null);
  }

  Future<List<BleDeviceInfo>> getKnownDevices() => platform.getKnownDevices();

  Future<bool> startScan({
    String? deviceId,
    String? macId,
    String? serviceUuid,
  }) => platform.startScan(
    deviceId: deviceId,
    macId: macId,
    serviceUuid: serviceUuid,
  );

  Future<bool> stopScan() => platform.stopScan();

  Future<void> prepareDevice(String deviceId) =>
      platform.prepareDevice(deviceId);

  Future<void> reconnect(String deviceId) async {
    getDeviceConnection(deviceId);
    await platform.reconnect(deviceId);
  }

  Future<void> disconnect(String deviceId) async {
    await _deviceConnections[deviceId]?.disconnect();
  }

  Future<bool> removeDevice(String deviceId) async {
    final removed = await platform.removeDevice(deviceId);

    if (removed) {
      removeDeviceConnection(deviceId);
    }
    return removed;
  }

  Future<BleConnection> connect(String deviceId) async {
    final resolvedDeviceId = _requireDeviceId(
      deviceId,
      message: 'Device ID is required when connecting to a BLE device',
    );

    return switch (platform.target) {
      BleTarget.ios => _connectIos(deviceId: resolvedDeviceId),
      BleTarget.macos => _connectMacos(deviceId: resolvedDeviceId),
      BleTarget.android => _connectAndroid(deviceId: resolvedDeviceId),
    };
  }

  Future<BleDeviceInfo> setupDevice({
    required List<IosAccessoryPickerItem> iosPickerItems,
  }) async {
    return switch (platform.target) {
      BleTarget.ios => _setupIosDevice(iosPickerItems: iosPickerItems),
      BleTarget.macos || BleTarget.android => throw UnsupportedError(
        'Accessory setup discovery is only available on iOS',
      ),
    };
  }

  Future<void> dispose() async {
    final connections = _deviceConnections.values.toList(growable: false);
    for (final connection in connections) {
      await connection.dispose();
    }
    _deviceConnections.clear();
    _notifyDeviceConnectionsChanged();
    await _deviceConnectionsController.close();
    for (final ownedPlatform in _ownedPlatforms.reversed) {
      await ownedPlatform.dispose();
    }
  }

  Future<BleDeviceInfo> _setupIosDevice({
    required List<IosAccessoryPickerItem> iosPickerItems,
  }) async {
    final accessorySetup = platform is IosAccessorySetupCapability
        ? platform as IosAccessorySetupCapability
        : null;
    if (accessorySetup == null) {
      throw UnsupportedError(
        'iOS accessory setup is unavailable for this platform implementation',
      );
    }

    if (iosPickerItems.isEmpty) {
      throw ArgumentError.value(
        iosPickerItems,
        'iosPickerItems',
        'must not be empty',
      );
    }

    final setupResult = await accessorySetup.showAccessorySetup(
      items: iosPickerItems,
    );
    final resolvedDeviceId = setupResult?.deviceId;
    if (resolvedDeviceId == null || resolvedDeviceId.isEmpty) {
      throw const BleSetupTimeoutException('Accessory setup cancelled');
    }

    final knownDevices = await getKnownDevices();
    for (final device in knownDevices) {
      if (device.peripheralId == resolvedDeviceId) {
        return device;
      }
    }

    return BleDeviceInfo(
      peripheralId: resolvedDeviceId,
      peripheralName: '',
      isConnected: false,
      state: 0,
      bondState: true,
    );
  }

  Future<BleConnection> _connectIos({required String deviceId}) async {
    final connection = await _createDeviceConnection(deviceId);
    await platform.prepareDevice(deviceId);

    final currentStatus = await connection.getCurrentDeviceStatus();
    if (currentStatus.readyForWrite) {
      return connection;
    }

    if (!currentStatus.connected) {
      await platform.reconnect(deviceId);
    }

    final deviceStatus = await _waitForStatus(
      stream: connection.deviceStatusStream,
      accepts: (DeviceStatus event) =>
          event.readyForWrite || (event.hasError && !event.connected),
      initialStatus: currentStatus,
      fallbackStatus: connection.getCurrentDeviceStatus,
    );

    if (deviceStatus.hasError) {
      throw BleConnectionException(
        deviceStatus.error ?? 'Device connection failed',
      );
    }

    if (deviceStatus.readyForWrite) {
      return connection;
    }

    throw const BleSetupTimeoutException('Device connection timed out');
  }

  Future<BleConnection> _connectMacos({required String deviceId}) async {
    final connection = await _createDeviceConnection(deviceId);
    await platform.prepareDevice(deviceId);

    final currentStatus = await connection.getCurrentDeviceStatus();
    if (currentStatus.readyForWrite) {
      return connection;
    }

    await platform.reconnect(deviceId);

    final deviceStatus = await _waitForStatus(
      stream: connection.deviceStatusStream,
      accepts: (DeviceStatus event) =>
          event.readyForWrite || (event.hasError && !event.connected),
      initialStatus: currentStatus,
      fallbackStatus: connection.getCurrentDeviceStatus,
    );

    if (deviceStatus.hasError) {
      throw BleConnectionException(
        deviceStatus.error ?? 'Device connection failed',
      );
    }

    if (deviceStatus.readyForWrite) {
      return connection;
    }

    throw const BleSetupTimeoutException('Device connection timed out');
  }

  Future<BleConnection> _connectAndroid({required String deviceId}) async {
    final connection = await _createDeviceConnection(deviceId);

    final currentStatus = await connection.getCurrentDeviceStatus();
    if (currentStatus.readyForWrite) {
      return connection;
    }

    await platform.reconnect(deviceId);

    final deviceStatus = await _waitForStatus(
      stream: connection.deviceStatusStream,
      accepts: (DeviceStatus event) =>
          event.readyForWrite || (event.hasError && !event.connected),
      initialStatus: currentStatus,
      fallbackStatus: connection.getCurrentDeviceStatus,
    );

    if (deviceStatus.hasError) {
      throw BleConnectionException(
        deviceStatus.error ?? 'Device connection failed',
      );
    }

    if (deviceStatus.readyForWrite) {
      return connection;
    }

    throw const BleSetupTimeoutException('Device connection timed out');
  }

  Future<DeviceStatus> _waitForStatus({
    required Stream<DeviceStatus> stream,
    required bool Function(DeviceStatus status) accepts,
    required Future<DeviceStatus> Function() fallbackStatus,
    DeviceStatus? initialStatus,
  }) async {
    if (initialStatus != null && accepts(initialStatus)) {
      return initialStatus;
    }

    return stream
        .firstWhere(accepts)
        .timeout(setupTimeout, onTimeout: fallbackStatus);
  }

  String _requireDeviceId(String? deviceId, {required String message}) {
    if (deviceId == null || deviceId.isEmpty) {
      throw ArgumentError(message);
    }
    return deviceId;
  }

  void _notifyDeviceConnectionsChanged() {
    if (!_deviceConnectionsController.isClosed) {
      _deviceConnectionsController.add(deviceConnections);
    }
  }
}
