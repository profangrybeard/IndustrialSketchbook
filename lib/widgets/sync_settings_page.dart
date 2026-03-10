import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_state.dart';
import '../providers/auth_provider.dart';

/// Settings page for Google Sign-In and sync controls (Phase 3.1).
///
/// Accessed via the cloud icon in the floating palette. Shows:
/// - Google Sign-In button (when signed out)
/// - User card with avatar, email, sign-out (when signed in)
/// - Sync controls (Sync Now button, last sync time) — Phase 3.2
class SyncSettingsPage extends ConsumerWidget {
  const SyncSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        title: const Text('Sync Settings'),
        backgroundColor: const Color(0xFF2A2A2A),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Auth section
            _buildAuthSection(context, ref, authState),
            const SizedBox(height: 32),

            // Sync section (placeholder for Phase 3.2)
            if (authState is AuthSignedIn) ...[
              const Text(
                'Sync',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 12),
              _buildSyncPlaceholder(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAuthSection(
      BuildContext context, WidgetRef ref, AuthState state) {
    return switch (state) {
      AuthSignedOut() => _buildSignInButton(ref),
      AuthSigningIn() => const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: CircularProgressIndicator(),
          ),
        ),
      AuthSignedIn(:final email, :final displayName, :final photoUrl) =>
        _buildUserCard(ref, email, displayName, photoUrl),
      AuthError(:final message) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSignInButton(ref),
            const SizedBox(height: 8),
            Text(
              'Error: $message',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ],
        ),
    };
  }

  Widget _buildSignInButton(WidgetRef ref) {
    return Center(
      child: ElevatedButton.icon(
        onPressed: () => ref.read(authServiceProvider).signIn(),
        icon: const Icon(Icons.login),
        label: const Text('Sign in with Google'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF4285F4),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }

  Widget _buildUserCard(
      WidgetRef ref, String email, String displayName, String? photoUrl) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          // Avatar
          CircleAvatar(
            radius: 24,
            backgroundImage:
                photoUrl != null ? NetworkImage(photoUrl) : null,
            backgroundColor: const Color(0xFF4285F4),
            child: photoUrl == null
                ? Text(
                    displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold),
                  )
                : null,
          ),
          const SizedBox(width: 16),
          // Name and email
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  email,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ),
          // Sign out button
          IconButton(
            onPressed: () => ref.read(authServiceProvider).signOut(),
            icon: const Icon(Icons.logout, color: Colors.white54),
            tooltip: 'Sign out',
          ),
        ],
      ),
    );
  }

  Widget _buildSyncPlaceholder() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        children: [
          Icon(Icons.cloud_outlined, color: Colors.white38),
          SizedBox(width: 12),
          Text(
            'Sync controls coming in Phase 3.2',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
