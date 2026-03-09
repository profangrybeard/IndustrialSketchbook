import 'stroke_raster_cache.dart';

/// LRU pool of [StrokeRasterCache] instances keyed by page ID.
///
/// Retains the raster caches of recently visited pages so that switching
/// back to a previously-viewed page can skip the full O(N) stroke rebuild.
/// When the pool exceeds [maxEntries], the least-recently-used entry is
/// evicted and its GPU image disposed.
class RasterCachePool {
  RasterCachePool({this.maxEntries = 3});

  /// Maximum number of page caches retained simultaneously.
  final int maxEntries;

  /// Page-ID → cache mapping.
  final Map<String, StrokeRasterCache> _entries = {};

  /// Access-order tracking. Most-recently-used page ID is at the end.
  final List<String> _accessOrder = [];

  /// Number of cached entries.
  int get size => _entries.length;

  /// Get or create a cache entry for [pageId], promoting it to MRU.
  ///
  /// If [pageId] already exists in the pool, returns the existing
  /// [StrokeRasterCache] and moves it to the most-recently-used position.
  /// Otherwise creates a fresh cache, adds it to the pool, and evicts
  /// the LRU entry if the pool exceeds [maxEntries].
  StrokeRasterCache getOrCreate(String pageId) {
    final existing = _entries[pageId];
    if (existing != null) {
      _promote(pageId);
      return existing;
    }

    // Create new entry
    final cache = StrokeRasterCache();
    _entries[pageId] = cache;
    _accessOrder.add(pageId);

    // Evict LRU if over capacity
    while (_entries.length > maxEntries) {
      _evictLru();
    }

    return cache;
  }

  /// Look up a cache entry without promoting it in access order.
  ///
  /// Returns `null` if [pageId] is not in the pool.
  StrokeRasterCache? peek(String pageId) => _entries[pageId];

  /// Remove and dispose a specific page's cache (e.g. on page delete).
  void remove(String pageId) {
    final cache = _entries.remove(pageId);
    if (cache != null) {
      cache.dispose();
      _accessOrder.remove(pageId);
    }
  }

  /// Dispose all cached entries and clear the pool.
  void dispose() {
    for (final cache in _entries.values) {
      cache.dispose();
    }
    _entries.clear();
    _accessOrder.clear();
  }

  /// Move [pageId] to the most-recently-used position (end of list).
  void _promote(String pageId) {
    _accessOrder.remove(pageId);
    _accessOrder.add(pageId);
  }

  /// Evict the least-recently-used entry (front of access order).
  void _evictLru() {
    if (_accessOrder.isEmpty) return;
    final lruPageId = _accessOrder.removeAt(0);
    final cache = _entries.remove(lruPageId);
    cache?.dispose();
  }
}
