import 'package:sheet_clone/services/app_auth.dart';

class AuthExtras {
  /// Пытается войти в Supabase (создаст пользователя, если его нет).
  static Future<void> tryBackendSignInIfConfigured() async {
    await AppAuth.ensureSignedIn();
  }
}
