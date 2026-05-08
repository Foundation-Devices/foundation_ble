class BleChannelConfiguration {
  const BleChannelConfiguration({
    this.sessionBootstrapChannelName = 'foundation_ble/bootstrap',
    this.bluetoothMethodChannelName = 'foundation_ble/bluetooth',
    this.bluetoothScanStreamName = 'foundation_ble/bluetooth/scan/stream',
    this.bluetoothLogStreamName = 'foundation_ble/bluetooth/log/stream',
    this.bleChannelRoot = 'foundation_ble/bluetooth',
    this.bleReadChannelRoot = 'foundation_ble/ble/read',
    this.bleWriteChannelRoot = 'foundation_ble/ble/write',
    this.bleConnectionStreamRoot = 'foundation_ble/bluetooth/connection/stream',
  });

  final String sessionBootstrapChannelName;
  final String bluetoothMethodChannelName;
  final String bluetoothScanStreamName;
  final String bluetoothLogStreamName;
  final String bleChannelRoot;
  final String bleReadChannelRoot;
  final String bleWriteChannelRoot;
  final String bleConnectionStreamRoot;

  BleChannelConfiguration scopedToSession(String sessionId) {
    final sessionRoot = 'foundation_ble/session/$sessionId';
    return BleChannelConfiguration(
      sessionBootstrapChannelName: sessionBootstrapChannelName,
      bluetoothMethodChannelName: '$sessionRoot/bluetooth',
      bluetoothScanStreamName: '$sessionRoot/bluetooth/scan/stream',
      bluetoothLogStreamName: '$sessionRoot/bluetooth/log/stream',
      bleChannelRoot: '$sessionRoot/bluetooth',
      bleReadChannelRoot: '$sessionRoot/ble/read',
      bleWriteChannelRoot: '$sessionRoot/ble/write',
      bleConnectionStreamRoot: '$sessionRoot/bluetooth/connection/stream',
    );
  }
}
