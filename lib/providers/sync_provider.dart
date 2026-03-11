import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/sync_state.dart';
import '../services/drive_service.dart';
import '../services/sync_service.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

/// Singleton SyncEngine provider (Phase 3.2).
///
/// Depends on auth, database, and device ID. Creates a [DriveService]
/// internally and wires it to the [SyncEngine].
final syncEngineProvider = ChangeNotifierProvider<SyncEngine>((ref) {
  final authService = ref.watch(authServiceProvider);
  final db = ref.watch(databaseServiceProvider).value;
  final deviceId = ref.watch(deviceIdProvider).value;

  // Guard: both DB and deviceId must be ready
  if (db == null || deviceId == null) {
    // Return a placeholder engine that will be replaced once deps resolve.
    // This shouldn't happen in practice since AppShell waits for DB.
    return SyncEngine(
      DriveService(authService),
      db ?? (throw StateError('DB not ready')),
      deviceId ?? 'unknown',
    );
  }

  final drive = DriveService(authService);
  final engine = SyncEngine(drive, db, deviceId);
  engine.initialize(); // Load last sync time (fire-and-forget)
  return engine;
});

/// Derived provider: current sync state for UI.
final syncStateProvider = Provider<SyncState>((ref) {
  return ref.watch(syncEngineProvider).state;
});
