import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_state.dart';
import '../services/auth_service.dart';

/// Singleton AuthService provider.
///
/// Manages Google Sign-In state. Attempt silent sign-in by calling
/// `ref.read(authServiceProvider).silentSignIn()` on app launch.
final authServiceProvider = ChangeNotifierProvider<AuthService>((ref) {
  return AuthService();
});

/// Derived provider: whether the user is signed in.
final isSignedInProvider = Provider<bool>((ref) {
  return ref.watch(authServiceProvider).isSignedIn;
});

/// Derived provider: current auth state.
final authStateProvider = Provider<AuthState>((ref) {
  return ref.watch(authServiceProvider).state;
});
