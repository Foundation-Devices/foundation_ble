import 'ble_status.dart';

class BleScanEvent {
  const BleScanEvent({this.type, this.deviceId, this.deviceName});

  factory BleScanEvent.fromMap(Map<dynamic, dynamic> map) {
    return BleScanEvent(
      type: DeviceStatus.fromMap(<dynamic, dynamic>{'type': map['type']}).type,
      deviceId: map['deviceId']?.toString(),
      deviceName: map['deviceName']?.toString(),
    );
  }

  final BluetoothConnectionEventType? type;
  final String? deviceId;
  final String? deviceName;

  @override
  String toString() {
    return 'BleScanEvent(type: $type, deviceId: $deviceId, deviceName: $deviceName)';
  }
}
