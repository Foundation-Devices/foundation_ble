class BleDeviceInfo {
  const BleDeviceInfo({
    required this.peripheralId,
    required this.peripheralName,
    required this.isConnected,
    required this.state,
    this.bondState = false,
  });

  factory BleDeviceInfo.fromMap(Map<String, dynamic> map) {
    final isConnected = map['isConnected'] as bool? ?? false;

    return BleDeviceInfo(
      peripheralId: (map['peripheralId'] ?? map['deviceId']) as String? ?? '',
      peripheralName: (map['peripheralName'] ?? map['name']) as String? ?? '',
      isConnected: isConnected,
      state: map['state'] as int? ?? (isConnected ? 2 : 0),
      bondState: (map['bondState'] ?? map['bonded']) == true,
    );
  }

  final String peripheralId;
  final String peripheralName;
  final bool isConnected;
  final int state;
  final bool bondState;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'peripheralId': peripheralId,
      'peripheralName': peripheralName,
      'isConnected': isConnected,
      'state': state,
      'bondState': bondState,
    };
  }

  @override
  String toString() {
    return 'BleDeviceInfo(peripheralId: $peripheralId, peripheralName: $peripheralName, isConnected: $isConnected, state: $state, bondState: $bondState)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is BleDeviceInfo &&
            runtimeType == other.runtimeType &&
            peripheralId == other.peripheralId &&
            peripheralName == other.peripheralName &&
            isConnected == other.isConnected &&
            state == other.state &&
            bondState == other.bondState;
  }

  @override
  int get hashCode {
    return Object.hash(
      peripheralId,
      peripheralName,
      isConnected,
      state,
      bondState,
    );
  }
}
