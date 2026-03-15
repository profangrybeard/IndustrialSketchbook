import 'dart:collection';
import 'dart:ui' as ui;

import '../models/tile_key.dart';
import '../utils/perf_metrics.dart';

/// Per-tile raster cache with LRU eviction for tiled rendering.
///
/// Each tile is a [tileWorldSize] × [tileWorldSize] world-unit square rendered
/// to a GPU image at a resolution determined by the current zoom and DPR.
/// The cache holds up to [maxTiles] images and evicts the least-recently-used
/// entries when full.
///
/// Uses [LinkedHashMap] for O(1) LRU operations (insertion-order iteration,
/// O(1) remove + re-insert to move to end).
class TileCache {
  TileCache({this.maxTiles = 64});

  /// Maximum number of cached tile images before LRU eviction kicks in.
  final int maxTiles;

  /// World-space size of each tile (logical pixels).
  static const double tileWorldSize = 512.0;

  /// Baseline maximum physical pixel dimension per tile.
  /// At high zoom only a few tiles are visible, so we can afford higher
  /// resolution per tile. [tilePixelSize] dynamically raises the cap
  /// based on visible tile count to prevent blurriness while staying
  /// within a total GPU memory budget.
  static const int baseMaxTilePixels = 2048;

  /// Absolute ceiling — never exceed this regardless of visible tile count.
  /// 4096×4096×4 = 64MB per tile. With 2-3 visible tiles at deep zoom,
  /// total GPU ≈ 128-192MB. Safe on modern mobile GPUs.
  static const int absoluteMaxTilePixels = 4096;

  /// Maximum pixel-size delta to accept a cached tile as a hit.
  /// Prevents re-render on micro-zoom changes (e.g. zoom 1.000 → 1.001).
  static const int resolutionTolerance = 2;

  /// Cached tile entries keyed by their grid position.
  /// Insertion order = LRU order (most recently accessed at the end).
  final _tiles = LinkedHashMap<TileKey, TileEntry>();

  /// Global version counter. Tiles with a lower version are stale.
  int _version = 0;

  /// Current cache version.
  int get version => _version;

  /// Number of cached tiles.
  int get tileCount => _tiles.length;

  /// Bump the global version (on stroke commit/erase/undo/redo).
  void bumpVersion() => _version++;

  /// Re-stamp all surviving tiles with the current version.
  ///
  /// Call after [invalidateRect] + [bumpVersion] when only the invalidated
  /// tiles need re-rendering. Surviving tiles are marked valid at the new
  /// version, avoiding unnecessary re-renders.
  void revalidateRemaining() {
    for (final entry in _tiles.values) {
      entry.version = _version;
    }
  }

  /// Get a cached tile image if it exists and matches the current version
  /// and resolution (within [resolutionTolerance]). Returns null if stale
  /// or missing. Records miss reasons on [PerfMetrics] for profiling.
  ui.Image? get(TileKey key, int pixelSize) {
    final perf = PerfMetrics.instance;
    final entry = _tiles[key];
    if (entry == null) {
      perf.tileMissAbsent++;
      perf.tileCacheMisses++;
      return null;
    }
    if (entry.version != _version) {
      perf.tileMissVersion++;
      perf.tileCacheMisses++;
      return null;
    }
    if ((entry.pixelSize - pixelSize).abs() > resolutionTolerance) {
      perf.tileMissResolution++;
      perf.tileCacheMisses++;
      return null;
    }
    // Cache hit — move to end of LRU (O(1) with LinkedHashMap)
    _tiles.remove(key);
    _tiles[key] = entry;
    perf.tileCacheHits++;
    return entry.image;
  }

  /// Get a cached tile image regardless of version/resolution (for stretch
  /// display during zoom). Returns null only if the tile was never cached.
  ui.Image? getAny(TileKey key) {
    final entry = _tiles[key];
    if (entry == null) return null;
    // Move to end of LRU
    _tiles.remove(key);
    _tiles[key] = entry;
    return entry.image;
  }

  /// Store a rendered tile image.
  void put(TileKey key, ui.Image image, int pixelSize) {
    // Dispose old image if replacing
    _tiles[key]?.image.dispose();
    _tiles.remove(key);
    _tiles[key] = TileEntry(image, _version, pixelSize);
    _evict();
  }

  /// Mark tiles overlapping [worldRect] as stale by removing them.
  void invalidateRect(ui.Rect worldRect) {
    final colMin = (worldRect.left / tileWorldSize).floor();
    final colMax = (worldRect.right / tileWorldSize).floor();
    final rowMin = (worldRect.top / tileWorldSize).floor();
    final rowMax = (worldRect.bottom / tileWorldSize).floor();

    for (int r = rowMin; r <= rowMax; r++) {
      for (int c = colMin; c <= colMax; c++) {
        final key = TileKey(c, r);
        final entry = _tiles.remove(key);
        if (entry != null) {
          entry.image.dispose();
        }
      }
    }
  }

  /// Clear all cached tiles (page switch).
  void clear() {
    for (final entry in _tiles.values) {
      entry.image.dispose();
    }
    _tiles.clear();
    _version = 0;
  }

  /// Dispose all images.
  void dispose() {
    clear();
  }

  /// Compute the physical pixel size for a tile at the given zoom + DPR.
  ///
  /// Dynamically caps resolution based on zoom level:
  /// - At zoom ≤ 1x: cap at [baseMaxTilePixels] (2048) — many tiles visible.
  /// - At higher zoom: fewer tiles visible, so raise cap up to
  ///   [absoluteMaxTilePixels] (4096) for sharper rendering.
  ///
  /// The budget logic: at zoom 1x ~6 tiles visible → 2048 cap.
  /// At zoom 3x ~2 tiles visible → ~3500 cap. At zoom 5x → 4096 cap.
  /// Total GPU stays roughly constant (~64-128MB across all visible tiles).
  static int tilePixelSize(double zoom, double dpr) {
    // Scale cap linearly from base to absolute as zoom increases.
    // At zoom 1x: base. At zoom 4x+: absolute ceiling.
    final zoomFactor = ((zoom - 1.0) / 3.0).clamp(0.0, 1.0);
    final cap = baseMaxTilePixels +
        ((absoluteMaxTilePixels - baseMaxTilePixels) * zoomFactor).round();
    return (tileWorldSize * zoom * dpr).ceil().clamp(1, cap);
  }

  /// Evict least-recently-used tiles beyond [maxTiles].
  void _evict() {
    while (_tiles.length > maxTiles) {
      // First key in LinkedHashMap = least recently used
      final oldest = _tiles.keys.first;
      final entry = _tiles.remove(oldest);
      entry?.image.dispose();
    }
  }
}

/// A cached tile entry: the rasterized image plus metadata.
class TileEntry {
  ui.Image image;
  int version;
  final int pixelSize;

  TileEntry(this.image, this.version, this.pixelSize);
}
