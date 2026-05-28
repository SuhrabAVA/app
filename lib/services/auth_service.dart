import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sheet_clone/services/app_auth.dart';

class AuthService {
  /// Текущий пользователь Supabase (null, если не вошли).
  static User? get currentUser => Supabase.instance.client.auth.currentUser;

  /// Для совместимости со старым кодом.
  static Future<void> tryBackendSignInIfConfigured() =>
      AppAuth.ensureSignedIn();
}
