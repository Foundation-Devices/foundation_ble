import 'dart:async';

import 'ble_connection.dart';
import 'ble_exceptions.dart';
import 'ble_platform.dart';
import 'ble_transport.dart';
import 'method_channel/method_channel_ble_platform.dart';
import 'models/ble_device_info.dart';
import 'models/ble_scan_event.dart';
import 'models/ble_status.dart';
import 'models/ios_accessory_setup.dart';

class FoundationBle {
  FoundationBle({
    BlePlatform? platform,
    this.setupTimeout = const Duration(seconds: 10),
  }) : _hasCustomPlatform = platform != null,
       platform = platform ?? MethodChannelBlePlatform() {
    _ownedPlatforms.add(this.platform);
    if (!_hasCustomPlatform) {
      _transportPlatforms[const BleTransport.gatt()] = this.platform;
    }
  }

  final BlePlatform platform;
  final Duration setupTimeout;
  final bool _hasCustomPlatform;

  final List<BlePlatform> _ownedPlatforms = <BlePlatform>[];
  final Map<BleTransport, BlePlatform> _transportPlatforms =
      <BleTransport, BlePlatform>{};

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

  Stream<String> get logEvents => platform.logEvents;

  BleConnection getDeviceConnection(
    String deviceId, {
    BleTransport transport = const BleTransport.gatt(),
    bool reset = false,
  }) {
    final selectedPlatform = _platformForTransport(transport);
    final existingConnection = _deviceConnections[deviceId];
    if (!reset &&
        existingConnection != null &&
        existingConnection.transport == transport) {
      return existingConnection;
    }

    if (existingConnection != null) {
      _deviceConnections.remove(deviceId);
      unawaited(existingConnection.dispose());
    }

    final connection = selectedPlatform.createConnection(deviceId);
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

  Future<bool> getBleAdapterState() => platform.getBleAdapterState();

  Future<bool?> requestEnableBle() {
    final android = platform is AndroidBlePlatformCapability
        ? platform as AndroidBlePlatformCapability
        : null;
    return android?.requestEnableBle() ?? Future.value(null);
  }

  Future<List<BleDeviceInfo>> getKnownDevices() async {
    if (_ownedPlatforms.length == 1) {
      return platform.getKnownDevices();
    }

    final devicesById = <String, BleDeviceInfo>{};
    final deviceLists = await Future.wait(
      _ownedPlatforms.map((ownedPlatform) => ownedPlatform.getKnownDevices()),
    );

    for (final deviceList in deviceLists) {
      for (final device in deviceList) {
        devicesById[device.peripheralId] = device;
      }
    }

    return devicesById.values.toList(growable: false);
  }

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

  Future<void> prepareDevice(
    String deviceId, {
    BleTransport transport = const BleTransport.gatt(),
  }) => _platformForTransport(transport).prepareDevice(deviceId);

  Future<void> reconnect(
    String deviceId, {
    BleTransport transport = const BleTransport.gatt(),
  }) async {
    getDeviceConnection(deviceId, transport: transport);
    await _platformForTransport(transport).reconnect(deviceId);
  }

  Future<void> disconnect(String deviceId) async {
    await _deviceConnections[deviceId]?.disconnect();
  }

  Future<bool> removeDevice(String deviceId) async {
    var removed = false;
    for (final ownedPlatform in _ownedPlatforms) {
      removed = await ownedPlatform.removeDevice(deviceId) || removed;
    }

    if (removed) {
      removeDeviceConnection(deviceId);
    }
    return removed;
  }

  Future<BleConnection> connect(
    String deviceId, {
    BleTransport transport = const BleTransport.gatt(),
    bool reset = false,
  }) async {
    final resolvedDeviceId = _requireDeviceId(
      deviceId,
      message: 'Device ID is required when connecting to a BLE device',
    );

    return switch (platform.target) {
      BleTarget.ios => _connectIos(
        deviceId: resolvedDeviceId,
        transport: transport,
        reset: reset,
      ),
      BleTarget.macos => _connectMacos(
        deviceId: resolvedDeviceId,
        transport: transport,
        reset: reset,
      ),
      BleTarget.android => _connectAndroid(
        deviceId: resolvedDeviceId,
        transport: transport,
        reset: reset,
      ),
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

  Future<BleConnection> _connectIos({
    required String deviceId,
    required BleTransport transport,
    bool reset = false,
  }) async {
    final selectedPlatform = _platformForTransport(transport);
    await selectedPlatform.prepareDevice(deviceId);

    final connection = getDeviceConnection(
      deviceId,
      transport: transport,
      reset: reset,
    );
    final currentStatus = await connection.getCurrentDeviceStatus();
    if (currentStatus.readyForWrite) {
      return connection;
    }

    if (!currentStatus.connected) {
      await selectedPlatform.reconnect(deviceId);
    }

    final deviceStatus = await _waitForStatus(
      stream: connection.connectionEvents,
      accepts: (DeviceStatus event) =>
          event.readyForWrite || (event.hasError && !event.connected),
      initialStatus: currentStatus,
      fallbackStatus: connection.getCurrentDeviceStatus,
    );

    if (deviceStatus.hasError) {
      throw BleTransportException(
        deviceStatus.error ?? 'Device connection failed',
      );
    }

    if (deviceStatus.readyForWrite) {
      return connection;
    }

    throw const BleSetupTimeoutException('Device connection timed out');
  }

  Future<BleConnection> _connectMacos({
    required String deviceId,
    required BleTransport transport,
    bool reset = false,
  }) async {
    final selectedPlatform = _platformForTransport(transport);
    await selectedPlatform.prepareDevice(deviceId);

    final connection = getDeviceConnection(
      deviceId,
      transport: transport,
      reset: reset,
    );
    final currentStatus = await connection.getCurrentDeviceStatus();
    if (currentStatus.readyForWrite) {
      return connection;
    }

    await selectedPlatform.reconnect(deviceId);

    final deviceStatus = await _waitForStatus(
      stream: connection.deviceStatusStream,
      accepts: (DeviceStatus event) =>
          event.readyForWrite || (event.hasError && !event.connected),
      initialStatus: currentStatus,
      fallbackStatus: connection.getCurrentDeviceStatus,
    );

    if (deviceStatus.hasError) {
      throw BleTransportException(
        deviceStatus.error ?? 'Device connection failed',
      );
    }

    if (deviceStatus.connected) {
      return connection;
    }

    throw const BleSetupTimeoutException('Device connection timed out');
  }

  Future<BleConnection> _connectAndroid({
    required String deviceId,
    required BleTransport transport,
    bool reset = false,
  }) async {
    final selectedPlatform = _platformForTransport(transport);

    if (selectedPlatform is AndroidBlePlatformCapability) {
      await (selectedPlatform as AndroidBlePlatformCapability).pair(deviceId);
    }

    await selectedPlatform.reconnect(deviceId);

    final connection = getDeviceConnection(
      deviceId,
      transport: transport,
      reset: reset,
    );

    final currentStatus = await connection.getCurrentDeviceStatus();
    final deviceStatus = await _waitForStatus(
      stream: connection.connectionEvents,
      accepts: (DeviceStatus event) =>
          event.readyForWrite || (event.hasError && !event.connected),
      initialStatus: currentStatus,
      fallbackStatus: connection.getCurrentDeviceStatus,
    );

    if (deviceStatus.hasError) {
      throw BleTransportException(
        deviceStatus.error ?? 'Device connection failed',
      );
    }

    if (deviceStatus.readyForWrite) {
      if (connection is AndroidBleConnectionCapability) {
        await (connection as AndroidBleConnectionCapability).bond();
      }
      return connection;
    }

    throw const BleSetupTimeoutException('Pairing timed out');
  }

  BlePlatform _platformForTransport(BleTransport transport) {
    transport.validate();

    if (_hasCustomPlatform) {
      if (transport.isL2cap) {
        throw const BleTransportException(
          'Per-connection transport selection requires the default native platform implementation',
        );
      }
      return platform;
    }

    return _transportPlatforms.putIfAbsent(transport, () {
      final scopedPlatform = MethodChannelBlePlatform(
        target: platform.target,
        transport: transport,
      );
      _ownedPlatforms.add(scopedPlatform);
      return scopedPlatform;
    });
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
