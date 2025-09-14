import 'package:flutter/foundation.dart';

/// NO-AUTH заглушка: в проекте отключён вход в Supabase,
/// но код ожидает наличие AuthService.currentUser.
/// Возвращаем null и гасим попытки авто-логина.
class AuthService {
  /// Всегда null в no-auth режиме.
  static dynamic get currentUser => null;

  static Future<void> tryBackendSignInIfConfigured() async {
    debugPrint('AuthService: NO-AUTH mode – skipping signInWithPassword');
  }
}
