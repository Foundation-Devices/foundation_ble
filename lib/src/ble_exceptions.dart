class BleSetupTimeoutException implements Exception {
  const BleSetupTimeoutException(this.message);

  final String message;

  @override
  String toString() => 'BleSetupTimeoutException: $message';
}

class BleTransportException implements Exception {
  const BleTransportException(this.message);

  final String message;

  @override
  String toString() => 'BleTransportException: $message';
}
