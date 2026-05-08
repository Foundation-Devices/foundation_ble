class BleSetupTimeoutException implements Exception {
  const BleSetupTimeoutException(this.message);

  final String message;

  @override
  String toString() => 'BleSetupTimeoutException: $message';
}

class BleConnectionException implements Exception {
  const BleConnectionException(this.message);

  final String message;

  @override
  String toString() => 'BleConnectionException: $message';
}
