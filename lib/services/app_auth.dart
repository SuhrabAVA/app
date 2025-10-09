// lib/services/app_auth.dart
import 'package:supabase_flutter/supabase_flutter.dart';

const _email = String.fromEnvironment('WAREHOUSE_EMAIL', defaultValue: '');
const _password =
    String.fromEnvironment('WAREHOUSE_PASSWORD', defaultValue: '');

class AppAuth {
  static final _sb = Supabase.instance.client;

  /// Гарантирует, что клиент Supabase залогинен как authenticated.
  static Future<void> ensureSignedIn() async {
    final session = _sb.auth.currentSession;
    if (session != null && session.user != null) return;

    if (_email.isEmpty || _password.isEmpty) {
      throw Exception(
        'Анонимный вход выключен. Укажи креды запуска через --dart-define=WAREHOUSE_EMAIL=... и --dart-define=WAREHOUSE_PASSWORD=...',
      );
    }

    try {
      await _sb.auth.signInWithPassword(email: _email, password: _password);
      return;
    } on AuthException catch (e) {
      // Если пользователя нет — создадим и войдём.
      final msg = (e.message ?? '').toLowerCase();
      if (msg.contains('invalid login') || msg.contains('user not found')) {
        await _sb.auth.signUp(email: _email, password: _password);
        await _sb.auth.signInWithPassword(email: _email, password: _password);
        return;
      }
      rethrow;
    }
  }
}
