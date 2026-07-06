enum BleLogType {
  trace,
  debug;

  String get wireName {
    return switch (this) {
      BleLogType.trace => 'TRACE',
      BleLogType.debug => 'DEBUG',
    };
  }
}

class BleLogEvent {
  const BleLogEvent({required this.type, required this.message});

  factory BleLogEvent.fromPayload(dynamic payload) {
    if (payload is Map<dynamic, dynamic>) {
      return BleLogEvent(
        type: _parseType(payload['type']),
        message: (payload['message'] ?? payload['log'])?.toString() ?? '',
      );
    }

    return BleLogEvent(
      type: BleLogType.debug,
      message: payload?.toString() ?? '',
    );
  }

  final BleLogType type;
  final String message;

  static BleLogType _parseType(dynamic typeValue) {
    return switch (typeValue?.toString().toUpperCase()) {
      'TRACE' => BleLogType.trace,
      'DEBUG' => BleLogType.debug,
      _ => BleLogType.debug,
    };
  }

  @override
  String toString() {
    return 'BleLogEvent(type: ${type.wireName}, message: $message)';
  }
}
