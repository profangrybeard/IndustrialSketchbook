import 'dart:ui';

/// OCR Pipeline (TDD §4.2).
///
/// Runs in a Dart Isolate. Fire-and-forget.
/// Uses ML Kit Digital Ink Recognition (vector mode — no rasterize step).
///
/// ## Checkpoint Events (when pipeline is triggered)
///
/// | Trigger                          | Priority |
/// |----------------------------------|----------|
/// | Pen-up + 900ms idle              | Primary  |
/// | Page navigation                  | High     |
/// | App backgrounded (onPause)       | High     |
/// | Every 50 strokes (safety net)    | Medium   |
/// | Undo / redo action               | Low      |
///
/// ## Pipeline Flow
///
/// ```
/// DirtySnapshot → OcrIsolate → ML Kit recognize()
///   → Map bounding boxes to canvas coords
///   → Build OCRSnapshot
///   → Write to SQLite
///   → Upsert into search_index (FTS5)
/// ```
class OcrService {
  // TODO Phase 5: Isolate setup with SendPort/ReceivePort
  // TODO Phase 5: DirtyRegion tracking and flush
  // TODO Phase 5: 900ms debounce timer
  // TODO Phase 5: ML Kit Digital Ink Recognition integration
  // TODO Phase 5: FTS5 search index upsert

  /// Whether the OCR pipeline is active.
  bool get isActive => false; // Stub — Phase 5

  /// Trigger OCR processing for a dirty region.
  ///
  /// Fire-and-forget: returns immediately. Results are written
  /// to SQLite and optionally notified via callback.
  Future<void> processDirtyRegion({
    required String pageId,
    required Rect dirtyBounds,
    required List<String> strokeIds,
  }) async {
    // TODO Phase 5: Send DirtySnapshot to OcrIsolate via SendPort
  }

  /// Flush any pending dirty regions immediately.
  ///
  /// Called on page navigation and app backgrounding.
  Future<void> flush() async {
    // TODO Phase 5: Immediate flush without debounce wait
  }

  /// Dispose of the isolate and clean up resources.
  Future<void> dispose() async {
    // TODO Phase 5: Kill isolate, close ports
  }
}
