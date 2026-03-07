/// Sync Pipeline (TDD §4.3).
///
/// Background worker. Offline-first.
/// Uses Supabase REST API with exponential backoff.
///
/// ## Pipeline Flow
///
/// ```
/// Any mutation → SyncEvent written to sync_queue [status: pending]
///   → SyncQueue.enqueue() → if online: schedule immediate flush
///
/// SyncQueue.flush():
///   → SELECT pending events ORDER BY timestamp ASC
///   → For each: POST to Supabase
///     → On success: status = "synced"
///     → On failure: retry_count++, exponential backoff
///       → After 5 failures: status = "failed", alert user
/// ```
///
/// ## Conflict Resolution (TDD §4.3.1)
///
/// | Event Type           | Strategy                              |
/// |----------------------|---------------------------------------|
/// | strokeAdded          | Idempotent (UUID dedup)               |
/// | strokeTombstoned     | Idempotent (no-op if already erased)  |
/// | pageMetadataUpdated  | Last timestamp wins                   |
/// | chapterReordered     | Last timestamp wins                   |
/// | imageTagged          | Merge tag arrays, deduplicate         |
/// | pageBranched         | Accept both (branching is additive)   |
class SyncService {
  // TODO Phase 11: Supabase project setup and connection
  // TODO Phase 11: SyncQueue worker with flush loop
  // TODO Phase 11: Online/offline detection
  // TODO Phase 11: Exponential backoff retry (max 5)
  // TODO Phase 11: Conflict resolution per TDD §4.3.1
  // TODO Phase 11: Reconnect handler for offline periods

  /// Whether the device is currently online.
  bool get isOnline => false; // Stub — Phase 11

  /// Enqueue a sync event for a committed stroke.
  Future<void> enqueueStrokeAdded(String strokeId) async {
    // TODO Phase 11: Write SyncEvent to sync_queue table
  }

  /// Flush all pending sync events to the cloud.
  Future<void> flush() async {
    // TODO Phase 11: Process pending queue
  }

  /// Dispose of resources.
  Future<void> dispose() async {
    // TODO Phase 11: Cancel timers, close connections
  }
}
