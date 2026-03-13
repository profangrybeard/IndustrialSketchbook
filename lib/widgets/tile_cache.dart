import 'dart:ui' as ui;

import '../models/tile_key.dart';

/// Per-tile raster cache with LRU eviction for tiled rendering.
///
/// Each tile is a [tileWorldSize] × [tileWorldSize] world-unit square rendered
/// to a GPU image at a resolution determined by the current zoom and DPR.
/// The cache holds up to [maxTiles] images and evicts the least-recently-used
/// entries when full.
class TileCache {
  TileCache({this.maxTiles = 64});

  /// Maximum number of cached tile images before LRU eviction kicks in.
  final int maxTiles;

  /// World-space size of each tile (logical pixels).
  static const double tileWorldSize = 512.0;

  /// Maximum physical pixel dimension per tile (prevents GPU memory blowout).
  static const int maxTilePixels = 2048;

  /// Cached tile entries keyed by their grid position.
  final Map<TileKey, TileEntry> _tiles = {};

  /// LRU ordering — most recently accessed at the end.
  final List<TileKey> _lruOrder = [];

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
  /// and resolution. Returns null if stale or missing.
  ui.Image? get(TileKey key, int pixelSize) {
    final entry = _tiles[key];
    if (entry == null) return null;
    if (entry.version != _version) return null;
    if (entry.pixelSize != pixelSize) return null;
    // Touch LRU
    _lruOrder.remove(key);
    _lruOrder.add(key);
    return entry.image;
  }

  /// Get a cached tile image regardless of version/resolution (for stretch
  /// display during zoom). Returns null only if the tile was never cached.
  ui.Image? getAny(TileKey key) {
    final entry = _tiles[key];
    if (entry == null) return null;
    _lruOrder.remove(key);
    _lruOrder.add(key);
    return entry.image;
  }

  /// Store a rendered tile image.
  void put(TileKey key, ui.Image image, int pixelSize) {
    // Dispose old image if replacing
    _tiles[key]?.image.dispose();
    _tiles[key] = TileEntry(image, _version, pixelSize);
    _lruOrder.remove(key);
    _lruOrder.add(key);
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
          _lruOrder.remove(key);
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
    _lruOrder.clear();
    _version = 0;
  }

  /// Dispose all images.
  void dispose() {
    clear();
  }

  /// Compute the physical pixel size for a tile at the given zoom + DPR.
  /// Capped at [maxTilePixels] to prevent GPU memory blowout at deep zoom.
  static int tilePixelSize(double zoom, double dpr) =>
      (tileWorldSize * zoom * dpr).ceil().clamp(1, maxTilePixels);

  /// Evict least-recently-used tiles beyond [maxTiles].
  void _evict() {
    while (_tiles.length > maxTiles && _lruOrder.isNotEmpty) {
      final oldest = _lruOrder.removeAt(0);
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
