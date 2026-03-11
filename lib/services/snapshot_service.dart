import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'database_service.dart';

/// Manages raster snapshots of pages for instant page-switch display.
///
/// Two-tier cache:
/// - **Tier 1**: In-memory LRU cache of PNG blobs (zero I/O latency)
/// - **Tier 2**: SQLite `page_snapshots` table (survives app restart)
///
/// On page switch, the snapshot is loaded from cache/DB, decoded to
/// a [ui.Image], and displayed immediately while strokes load in the
/// background. When the stroke rebuild completes, the canvas crossfades
/// from the snapshot to the live rendering.
class SnapshotService {
  SnapshotService(this._db);

  final DatabaseService _db;

  // ---------------------------------------------------------------------------
  // In-memory LRU cache
  // ---------------------------------------------------------------------------

  /// Max cached PNG blobs in memory.
  static const int maxEntries = 5;

  /// Page-ID → PNG blob.
  final Map<String, Uint8List> _cache = {};

  /// Access-order tracking. MRU at the end.
  final List<String> _accessOrder = [];

  /// Number of cached entries (for testing).
  int get cacheSize => _cache.length;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Capture a snapshot from a raster cache [ui.Image].
  ///
  /// PNG-encodes the image, stores in memory cache, and persists to DB.
  /// The DB write is fire-and-forget — it won't block the UI thread.
  ///
  /// [strokeVersion] is stored for cache-validity checks on reload.
  Future<void> captureSnapshot({
    required String pageId,
    required ui.Image image,
    required int strokeVersion,
  }) async {
    try {
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final pngBlob = byteData.buffer.asUint8List();

      // Store in memory cache
      _cache[pageId] = pngBlob;
      _promote(pageId);
      _evictIfNeeded();

      // Persist to DB (fire-and-forget)
      _db
          .savePageSnapshot(
            pageId: pageId,
            pngBlob: pngBlob,
            strokeVersion: strokeVersion,
            width: image.width,
            height: image.height,
          )
          .catchError((e) =>
              debugPrint('SnapshotService: DB persist failed: $e'));
    } catch (e) {
      debugPrint('SnapshotService: capture failed: $e');
    }
  }

  /// Load a snapshot and decode it to a displayable [ui.Image].
  ///
  /// Checks in-memory cache first, then falls back to DB. Returns null
  /// if no snapshot exists for [pageId].
  Future<ui.Image?> getSnapshot(String pageId) async {
    try {
      // Tier 1: in-memory cache
      var blob = _cache[pageId];
      if (blob != null) {
        _promote(pageId);
      } else {
        // Tier 2: DB fallback
        blob = await _db.getPageSnapshot(pageId);
        if (blob == null) return null;

        // Promote to memory cache
        _cache[pageId] = blob;
        _promote(pageId);
        _evictIfNeeded();
      }

      // Decode PNG → ui.Image
      final codec = await ui.instantiateImageCodec(blob);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (e) {
      debugPrint('SnapshotService: getSnapshot failed: $e');
      return null;
    }
  }

  /// Check if a snapshot exists in memory cache (no I/O).
  bool hasCachedSnapshot(String pageId) => _cache.containsKey(pageId);

  /// Remove a page's snapshot from both cache and DB.
  void invalidate(String pageId) {
    _cache.remove(pageId);
    _accessOrder.remove(pageId);
    _db.deletePageSnapshot(pageId).catchError(
        (e) => debugPrint('SnapshotService: delete failed: $e'));
  }

  /// Clear all in-memory cached snapshots (DB remains).
  void clearMemoryCache() {
    _cache.clear();
    _accessOrder.clear();
  }

  // ---------------------------------------------------------------------------
  // LRU helpers
  // ---------------------------------------------------------------------------

  void _promote(String pageId) {
    _accessOrder.remove(pageId);
    _accessOrder.add(pageId);
  }

  void _evictIfNeeded() {
    while (_cache.length > maxEntries) {
      if (_accessOrder.isEmpty) break;
      final lruPageId = _accessOrder.removeAt(0);
      _cache.remove(lruPageId);
    }
  }
}
