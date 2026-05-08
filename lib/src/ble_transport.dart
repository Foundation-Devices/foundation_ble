class BleTransport {
  const BleTransport.gatt() : mode = BleTransportMode.gatt, psm = null;

  const BleTransport.l2cap({required this.psm}) : mode = BleTransportMode.l2cap;

  final BleTransportMode mode;
  final int? psm;

  bool get isGatt => mode == BleTransportMode.gatt;

  bool get isL2cap => mode == BleTransportMode.l2cap;

  void validate() {
    if (!isL2cap) {
      return;
    }

    final resolvedPsm = psm;
    if (resolvedPsm == null || resolvedPsm <= 0 || resolvedPsm > 0xFFFF) {
      throw ArgumentError.value(
        psm,
        'psm',
        'L2CAP PSM must be between 1 and 65535',
      );
    }
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{'mode': mode.name, if (psm != null) 'psm': psm};
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is BleTransport &&
            runtimeType == other.runtimeType &&
            mode == other.mode &&
            psm == other.psm;
  }

  @override
  int get hashCode => Object.hash(mode, psm);

  @override
  String toString() => 'BleTransport(mode: $mode, psm: $psm)';
}

enum BleTransportMode { gatt, l2cap }
