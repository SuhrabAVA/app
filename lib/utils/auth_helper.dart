/// Helper class to store information about the currently logged in user.
///
/// This class exposes static fields that are set during the login
/// process. Other parts of the application can read these values to
/// determine the current user identifier, display name and whether
/// they are the technical leader.
class AuthHelper {
  /// Unique identifier of the currently logged‑in user. For regular
  /// employees this corresponds to their Firebase key. For the
  /// technical leader we use the special identifier `tech_leader`.
  static String? currentUserId;

  /// Human‑readable name of the current user (for example,
  /// "Иванов Иван Иванович"). This is displayed in the chat and other
  /// modules where user names are shown.
  static String? currentUserName;

  /// Indicates whether the current user is the technical leader. This
  /// flag can be used to enable or disable certain features in the UI.
  static bool isTechLeader = false;

  /// Sets the current user as the technical leader. Call this after
  /// successful login for the TL account.
  static void setTechLeader({required String name}) {
    currentUserId = 'tech_leader';
    currentUserName = name;
    isTechLeader = true;
  }

  /// Sets the current user as a regular employee. Pass both the
  /// unique employee identifier and the display name.
  static void setEmployee({required String id, required String name}) {
    currentUserId = id;
    currentUserName = name;
    isTechLeader = false;
  }

  /// Resets the stored user information. This can be used when
  /// signing out.
  static void clear() {
    currentUserId = null;
    currentUserName = null;
    isTechLeader = false;
  }
}