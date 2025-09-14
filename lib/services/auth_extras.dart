import 'package:flutter/foundation.dart';

/// NO-AUTH режим: ничего не делаем, чтобы не было ошибки
/// `AuthApiException(invalid_credentials)`.
class AuthExtras {
  static Future<void> tryBackendSignInIfConfigured() async {
    debugPrint('AuthExtras: NO-AUTH mode – skipping signInWithPassword');
  }
}
