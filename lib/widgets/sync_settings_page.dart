import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_state.dart';
import '../models/sync_state.dart';
import '../providers/auth_provider.dart';
import '../providers/sync_provider.dart';

/// Settings page for Google Sign-In and sync controls (Phase 3.1 + 3.2).
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
            _buildAuthSection(context, ref, authState),
            const SizedBox(height: 32),
            if (authState is AuthSignedIn) ...[
              const Text(
                'SYNC',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 12),
              _buildSyncSection(ref),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAuthSection(BuildContext context, WidgetRef ref, AuthState state) {
    return switch (state) {
      AuthSignedOut() => _buildSignInButton(ref),
      AuthSigningIn() => const Center(
          child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
      AuthSignedIn(:final email, :final displayName, :final photoUrl) =>
        _buildUserCard(ref, email, displayName, photoUrl),
      AuthError(:final message) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSignInButton(ref),
            const SizedBox(height: 8),
            Text('Error: $message',
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ]),
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Widget _buildUserCard(WidgetRef ref, String email, String displayName, String? photoUrl) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        CircleAvatar(
          radius: 24,
          backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
          backgroundColor: const Color(0xFF4285F4),
          child: photoUrl == null
              ? Text(displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold))
              : null,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(displayName, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(email, style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ]),
        ),
        IconButton(
          onPressed: () => ref.read(authServiceProvider).signOut(),
          icon: const Icon(Icons.logout, color: Colors.white54),
          tooltip: 'Sign out',
        ),
      ]),
    );
  }

  Widget _buildSyncSection(WidgetRef ref) {
    final syncState = ref.watch(syncStateProvider);
    final isBusy = syncState is SyncPushing || syncState is SyncPulling;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _buildSyncIcon(syncState),
          const SizedBox(width: 12),
          Expanded(child: _buildSyncStatusText(syncState)),
        ]),
        if (isBusy) ...[
          const SizedBox(height: 10),
          _buildProgressBar(syncState),
        ],
        if (syncState is SyncSuccess) ...[
          () {
            final summary = ref.watch(syncEngineProvider).lastSyncSummary;
            if (summary.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(summary,
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
            );
          }(),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: isBusy ? null : () => ref.read(syncEngineProvider).syncNow(),
            icon: isBusy
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))
                : const Icon(Icons.sync),
            label: Text(syncState is SyncPushing ? 'Uploading...'
                : syncState is SyncPulling ? 'Downloading...' : 'Sync Now'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4285F4),
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFF3A3A3A),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildProgressBar(SyncState state) {
    double? progress;
    if (state is SyncPushing && state.total > 0) {
      progress = state.pushed / state.total;
    } else if (state is SyncPulling && state.journalsTotal > 0) {
      progress = state.journalsDone / state.journalsTotal;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: progress,
        backgroundColor: const Color(0xFF3A3A3A),
        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF4285F4)),
        minHeight: 4,
      ),
    );
  }

  Widget _buildSyncIcon(SyncState state) {
    return switch (state) {
      SyncIdle() => const Icon(Icons.cloud_outlined, color: Colors.white38, size: 28),
      SyncPushing() => const Icon(Icons.cloud_upload, color: Color(0xFF4285F4), size: 28),
      SyncPulling() => const Icon(Icons.cloud_download, color: Color(0xFF4285F4), size: 28),
      SyncSuccess() => const Icon(Icons.cloud_done, color: Color(0xFF4CAF50), size: 28),
      SyncError() => const Icon(Icons.cloud_off, color: Colors.redAccent, size: 28),
    };
  }

  Widget _buildSyncStatusText(SyncState state) {
    return switch (state) {
      SyncIdle() => const Text('Not synced yet', style: TextStyle(color: Colors.white38, fontSize: 14)),
      SyncPushing(:final phase, :final pushed, :final total) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(phase.isNotEmpty ? phase : 'Uploading...',
              style: const TextStyle(color: Color(0xFF4285F4), fontSize: 14)),
          if (total > 0) Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('$pushed / $total strokes',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ),
        ],
      ),
      SyncPulling(:final phase, :final journalsDone, :final journalsTotal, :final imported) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(phase.isNotEmpty ? phase : 'Downloading...',
              style: const TextStyle(color: Color(0xFF4285F4), fontSize: 14)),
          if (journalsTotal > 0) Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('Journal $journalsDone / $journalsTotal • $imported imported',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ),
        ],
      ),
      SyncSuccess(:final syncedAt) => Text('Last synced: ${_formatTimeAgo(syncedAt)}',
          style: const TextStyle(color: Color(0xFF4CAF50), fontSize: 14)),
      SyncError(:final message) => Text('Error: $message',
          style: const TextStyle(color: Colors.redAccent, fontSize: 14), maxLines: 2, overflow: TextOverflow.ellipsis),
    };
  }

  String _formatTimeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    final d = diff.inDays;
    return '$d day${d > 1 ? "s" : ""} ago';
  }
}
