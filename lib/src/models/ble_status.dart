import 'dart:core';

enum BluetoothConnectionEventType {
  deviceConnected,
  deviceDisconnected,
  deviceFound,
  scanStarted,
  scanStopped,
  scanError,
  connectionAttempt,
  connectionError,
  bondBonding,
  bondBonded,
  bondRemoved,
}

class ConnectedDeviceInfo {
  const ConnectedDeviceInfo({
    required this.deviceId,
    required this.name,
    required this.bonded,
  });

  factory ConnectedDeviceInfo.fromMap(Map<dynamic, dynamic> map) {
    final deviceId = (map['deviceId'] ?? map['peripheralId'])?.toString() ?? '';
    final name =
        (map['name'] ?? map['peripheralName'])?.toString() ?? 'Unknown';
    final bonded = (map['bonded'] ?? map['bondState']) == true;

    return ConnectedDeviceInfo(deviceId: deviceId, name: name, bonded: bonded);
  }

  final String deviceId;
  final String name;
  final bool bonded;

  @override
  String toString() {
    return 'ConnectedDeviceInfo(deviceId: $deviceId, name: $name, bonded: $bonded)';
  }
}

class DeviceStatus {
  const DeviceStatus({
    this.type,
    required this.connected,
    this.ready = false,
    this.peripheralId,
    this.peripheralName,
    this.error,
    this.bonded = false,
  });

  factory DeviceStatus.fromMap(Map<dynamic, dynamic> map) {
    return DeviceStatus(
      type: _parseEventType(map['type']),
      connected: map['connected'] == true,
      ready: map['ready'] == true,
      peripheralId: map['peripheralId']?.toString(),
      peripheralName: map['peripheralName']?.toString(),
      error: map['error']?.toString(),
      bonded: map['bonded'] == true,
    );
  }

  final BluetoothConnectionEventType? type;
  final bool connected;
  final bool ready;
  final bool bonded;
  final String? peripheralId;
  final String? peripheralName;
  final String? error;

  bool get readyForWrite => connected && ready;

  bool get isConnectionEvent {
    return type == BluetoothConnectionEventType.deviceConnected ||
        type == BluetoothConnectionEventType.deviceDisconnected ||
        type == BluetoothConnectionEventType.connectionAttempt ||
        type == BluetoothConnectionEventType.connectionError;
  }

  bool get hasError => error != null;

  static BluetoothConnectionEventType? _parseEventType(dynamic typeValue) {
    switch (typeValue?.toString()) {
      case 'device_connected':
        return BluetoothConnectionEventType.deviceConnected;
      case 'device_disconnected':
        return BluetoothConnectionEventType.deviceDisconnected;
      case 'device_found':
        return BluetoothConnectionEventType.deviceFound;
      case 'scan_started':
        return BluetoothConnectionEventType.scanStarted;
      case 'scan_stopped':
        return BluetoothConnectionEventType.scanStopped;
      case 'scan_error':
        return BluetoothConnectionEventType.scanError;
      case 'connection_attempt':
        return BluetoothConnectionEventType.connectionAttempt;
      case 'connection_error':
        return BluetoothConnectionEventType.connectionError;
      case 'bond_bonding':
        return BluetoothConnectionEventType.bondBonding;
      case 'bond_bonded':
        return BluetoothConnectionEventType.bondBonded;
      case 'bond_removed':
        return BluetoothConnectionEventType.bondRemoved;
      default:
        return null;
    }
  }

  @override
  String toString() {
    return 'DeviceStatus(type: $type, connected: $connected, ready: $ready, peripheralId: $peripheralId, peripheralName: $peripheralName, bonded: $bonded, error: $error)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is DeviceStatus &&
            runtimeType == other.runtimeType &&
            type == other.type &&
            connected == other.connected &&
            ready == other.ready &&
            bonded == other.bonded &&
            peripheralId == other.peripheralId &&
            peripheralName == other.peripheralName &&
            error == other.error;
  }

  @override
  int get hashCode {
    return Object.hash(
      type,
      connected,
      ready,
      bonded,
      peripheralId,
      peripheralName,
      error,
    );
  }
}
