import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../models/auth_state.dart';

/// Google Sign-In service for Drive sync (Phase 3.1).
///
/// Manages the Google Sign-In lifecycle and exposes [AuthState] via
/// [ChangeNotifier]. Requests `drive.appdata` scope for appDataFolder access.
class AuthService extends ChangeNotifier {
  AuthService();

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['https://www.googleapis.com/auth/drive.appdata'],
  );

  AuthState _state = const AuthSignedOut();
  AuthState get state => _state;

  /// Whether the user is currently signed in.
  bool get isSignedIn => _state is AuthSignedIn;

  /// The currently signed-in account (null if signed out).
  GoogleSignInAccount? get currentAccount => _googleSignIn.currentUser;

  /// Attempt silent sign-in (cached credentials). Called on app launch.
  Future<void> silentSignIn() async {
    try {
      final account = await _googleSignIn.signInSilently();
      if (account != null) {
        _state = AuthSignedIn(
          email: account.email,
          displayName: account.displayName ?? account.email,
          photoUrl: account.photoUrl,
        );
        notifyListeners();
      }
    } catch (e) {
      // Silent sign-in failed — stay signed out, no error shown
      debugPrint('Silent sign-in failed: $e');
    }
  }

  /// Interactive sign-in (shows Google account picker).
  Future<void> signIn() async {
    _state = const AuthSigningIn();
    notifyListeners();

    try {
      final account = await _googleSignIn.signIn();
      if (account != null) {
        _state = AuthSignedIn(
          email: account.email,
          displayName: account.displayName ?? account.email,
          photoUrl: account.photoUrl,
        );
      } else {
        // User cancelled the sign-in
        _state = const AuthSignedOut();
      }
    } catch (e) {
      _state = AuthError(e.toString());
    }
    notifyListeners();
  }

  /// Sign out and clear cached credentials.
  Future<void> signOut() async {
    await _googleSignIn.signOut();
    _state = const AuthSignedOut();
    notifyListeners();
  }

  /// Get auth headers for Google API calls.
  /// Returns null if not signed in.
  Future<Map<String, String>?> get authHeaders async {
    final account = _googleSignIn.currentUser;
    if (account == null) return null;
    return await account.authHeaders;
  }
}
