abstract class PlatformInterface {
  PlatformInterface({required Object token}) : _token = token;

  final Object _token;

  static void verifyToken(PlatformInterface instance, Object token) {
    if (instance is MockPlatformInterfaceMixin) {
      return;
    }

    if (!identical(instance._token, token)) {
      throw AssertionError(
        'Platform interfaces must not be implemented with `implements`.',
      );
    }
  }
}

mixin MockPlatformInterfaceMixin on PlatformInterface {}
