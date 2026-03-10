/// Sync engine state for UI (Phase 3.2).
sealed class SyncState {
  const SyncState();
}

/// No sync in progress.
class SyncIdle extends SyncState {
  const SyncIdle();
}

/// Uploading unsynced strokes to Drive.
class SyncPushing extends SyncState {
  const SyncPushing({this.phase = '', this.pushed = 0, this.total = 0});
  final String phase;
  final int pushed;
  final int total;
}

/// Downloading journals from other devices.
class SyncPulling extends SyncState {
  const SyncPulling({
    this.phase = '',
    this.journalsDone = 0,
    this.journalsTotal = 0,
    this.imported = 0,
  });
  final String phase;
  final int journalsDone;
  final int journalsTotal;
  final int imported;
}

/// Sync completed successfully.
class SyncSuccess extends SyncState {
  const SyncSuccess(this.syncedAt);
  final DateTime syncedAt;
}

/// Sync failed with an error.
class SyncError extends SyncState {
  const SyncError(this.message);
  final String message;
}
