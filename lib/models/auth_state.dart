/// Authentication state for Google Sign-In (Phase 3.1).
sealed class AuthState {
  const AuthState();
}

/// User is not signed in.
class AuthSignedOut extends AuthState {
  const AuthSignedOut();
}

/// Sign-in is in progress.
class AuthSigningIn extends AuthState {
  const AuthSigningIn();
}

/// User is signed in with Google.
class AuthSignedIn extends AuthState {
  const AuthSignedIn({
    required this.email,
    required this.displayName,
    this.photoUrl,
  });

  final String email;
  final String displayName;
  final String? photoUrl;
}

/// An error occurred during authentication.
class AuthError extends AuthState {
  const AuthError(this.message);
  final String message;
}
