import 'dart:typed_data';

import 'ble_transport.dart';
import 'models/ble_status.dart';

abstract interface class BleConnection {
  String get deviceId;

  BleTransport get transport;

  DeviceStatus get lastDeviceStatus;

  Stream<Uint8List> get readStream;

  Stream<DeviceStatus> get deviceStatusStream;

  Stream<DeviceStatus> get connectionEvents;

  Future<DeviceStatus> getCurrentDeviceStatus();

  Future<bool> isConnected();

  Future<bool> write(Uint8List data);

  Future<int?> readRssi();

  Future<void> disconnect();

  Future<String?> getConnectedPeripheralId();

  Future<bool> reconnect();

  Future<void> dispose();
}

//android only features should go into this interface.
abstract interface class AndroidBleConnectionCapability {
  Future<bool> bond();

  Future<bool> requestPhy2();
}
