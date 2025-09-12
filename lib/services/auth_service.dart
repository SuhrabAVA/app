import 'package:supabase_flutter/supabase_flutter.dart';

class AuthService {
  static final _auth = Supabase.instance.client.auth;

  static Future<void> signIn(String email, String password) async {
    await _auth.signInWithPassword(email: email, password: password);
  }

  static Future<void> signOut() async {
    await _auth.signOut();
  }

  static Stream<AuthState> authChanges() => _auth.onAuthStateChange;

  static bool get isLoggedIn => _auth.currentSession != null;
  static User? get currentUser => _auth.currentUser;
}
