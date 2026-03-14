import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/pressure_mode.dart';
import '../models/stroke.dart';
import '../models/tile_key.dart';
import '../services/drawing_service.dart' show MutationInfo, MutationType;
import '../utils/spatial_grid.dart';
import 'tile_cache.dart';
import '../utils/perf_metrics.dart';
import 'stroke_rendering.dart' as rendering;

/// Layer 2 painter: all committed (finalized) strokes — tiled rendering.
///
/// Renders on a transparent layer — no background fill. Composites over
/// [BackgroundPainter] via Flutter's layer tree.
///
/// Instead of a single full-page raster cache, renders per-tile images
/// (512×512 world units) and caches them in a [TileCache] with LRU eviction.
/// Only tiles visible in the current viewport are rendered/blitted.
///
/// This painter lives **outside** the Flutter [Transform] widget — it handles
/// its own world→screen mapping via [viewportRect] and [zoom].
class CommittedStrokesPainter extends CustomPainter {
  CommittedStrokesPainter({
    required this.committedStrokes,
    required this.erasedStrokeIds,
    required this.strokeVersion,
    required this.pressureMode,
    required this.grainIntensity,
    required this.pressureExponent,
    required this.replayArcLength,
    required this.tiltStrength,
    required this.tileCache,
    required this.spatialGrid,
    required this.devicePixelRatio,
    required this.viewportRect,
    required this.zoom,
    required this.lastMutationInfo,
  });

  /// All committed strokes for the current page.
  final List<Stroke> committedStrokes;

  /// Set of stroke IDs erased via tombstones (cached in DrawingService).
  final Set<String> erasedStrokeIds;

  /// Monotonic version counter — changes only on committed stroke mutations.
  final int strokeVersion;

  /// How stylus pressure affects pencil rendering.
  final PressureMode pressureMode;

  /// Grain texture intensity for pencil tool (0.0–1.0).
  final double grainIntensity;

  /// Power-curve exponent for pencil pressure mapping.
  final double pressureExponent;

  /// Arc length for replay/committed stroke rendering.
  final double replayArcLength;

  /// Tilt effect strength (0.0 = off, 1.0 = full tilt shading).
  final double tiltStrength;

  /// Per-tile raster cache shared across paints. Owned by CanvasWidget.
  final TileCache tileCache;

  /// Spatial grid for finding strokes per tile.
  final SpatialGrid? spatialGrid;

  /// Device pixel ratio for high-DPI rasterization.
  final double devicePixelRatio;

  /// World-space rectangle currently visible on screen.
  final Rect viewportRect;

  /// Current zoom factor.
  final double zoom;

  /// Describes the most recent mutation for cache update path selection.
  final MutationInfo lastMutationInfo;

  @override
  void paint(Canvas canvas, Size size) {
    final perf = PerfMetrics.instance;
    final sw = Stopwatch()..start();

    // Safety net: if strokeVersion changed, ensure stale tiles are purged.
    // Fine-grained invalidateRect() handles per-mutation cases, but bulk
    // events (loadStrokes, backfillSpines) may leave stale empty tiles.
    if (tileCache.version != strokeVersion) {
      tileCache.clear();
      // Sync tile cache version to stroke version
      while (tileCache.version < strokeVersion) {
        tileCache.bumpVersion();
      }
    }

    final tileSize = TileCache.tileWorldSize;
    final pixelSize = TileCache.tilePixelSize(zoom, devicePixelRatio);

    // Compute visible tile range from viewport
    final colMin = (viewportRect.left / tileSize).floor();
    final colMax = (viewportRect.right / tileSize).floor();
    final rowMin = (viewportRect.top / tileSize).floor();
    final rowMax = (viewportRect.bottom / tileSize).floor();

    int tilesRendered = 0;
    int tilesHit = 0;

    for (int r = rowMin; r <= rowMax; r++) {
      for (int c = colMin; c <= colMax; c++) {
        final key = TileKey(c, r);
        final tileWorld = key.worldRect(tileSize);

        // Try exact cache hit (version + resolution match)
        var img = tileCache.get(key, pixelSize);
        if (img != null) {
          tilesHit++;
        } else {
          // Render fresh tile
          img = _renderTile(key, tileWorld, pixelSize);
          tileCache.put(key, img, pixelSize);
          tilesRendered++;
        }

        // Blit tile to screen position
        final screenRect = Rect.fromLTWH(
          (tileWorld.left - viewportRect.left) * zoom,
          (tileWorld.top - viewportRect.top) * zoom,
          tileSize * zoom,
          tileSize * zoom,
        );

        canvas.drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          screenRect,
          Paint()..filterQuality = FilterQuality.low,
        );
      }
    }

    sw.stop();
    perf.committedPaintUs = sw.elapsedMicroseconds;
    perf.committedPaintType =
        tilesRendered > 0 ? 'tile:$tilesRendered/$tilesHit' : 'hit';

    // Debug: log first paint after strokes load to diagnose disappearing
    // strokes. Only logs when tiles were freshly rendered (not cache hits).
    if (tilesRendered > 0) {
      debugPrint('[CommittedPainter] paint: ${tilesRendered + tilesHit} tiles '
          '(${tilesRendered} rendered, $tilesHit cached), '
          '${committedStrokes.length} strokes, '
          'version=$strokeVersion, '
          'viewport=$viewportRect, zoom=$zoom, '
          'pixelSize=$pixelSize, '
          'spatialGrid=${spatialGrid != null ? "yes(${spatialGrid!.strokeCount})" : "null"}, '
          '${sw.elapsedMicroseconds}µs');
    }
  }

  /// Render a single tile to an image at the given pixel resolution.
  ui.Image _renderTile(TileKey key, Rect tileWorld, int pixelSize) {
    final recorder = ui.PictureRecorder();
    final recCanvas = Canvas(recorder);

    // Scale from world coords to pixel coords
    final scale = pixelSize / TileCache.tileWorldSize;
    recCanvas.scale(scale, scale);

    // Translate so tile's top-left is at canvas origin
    recCanvas.translate(-tileWorld.left, -tileWorld.top);

    // Find strokes that overlap this tile
    Set<String> candidateIds;
    if (spatialGrid != null) {
      candidateIds = spatialGrid!.queryRect(tileWorld);
    } else {
      // Fallback: all visible strokes (expensive)
      candidateIds = {
        for (final s in committedStrokes)
          if (!s.isTombstone &&
              !erasedStrokeIds.contains(s.id) &&
              s.points.isNotEmpty &&
              s.boundingRect.overlaps(tileWorld))
            s.id,
      };
    }

    // Debug: log spatial grid mismatches on first render
    if (candidateIds.isEmpty && committedStrokes.isNotEmpty && spatialGrid != null) {
      // Double-check with linear scan to detect spatial grid bug
      final linearIds = {
        for (final s in committedStrokes)
          if (!s.isTombstone &&
              !erasedStrokeIds.contains(s.id) &&
              s.points.isNotEmpty &&
              s.boundingRect.overlaps(tileWorld))
            s.id,
      };
      if (linearIds.isNotEmpty) {
        debugPrint('[CommittedPainter] SPATIAL GRID BUG: tile $key '
            'tileWorld=$tileWorld — grid returned 0, linear scan found '
            '${linearIds.length} strokes. Example: '
            '${committedStrokes.firstWhere((s) => linearIds.contains(s.id)).boundingRect}');
        // Use the linear scan results as fallback
        candidateIds = linearIds;
      }
    }

    // Clip to tile bounds to prevent bleeding into adjacent tiles
    recCanvas.save();
    recCanvas.clipRect(tileWorld);

    int strokesRendered = 0;
    for (final stroke in committedStrokes) {
      if (!candidateIds.contains(stroke.id)) continue;
      if (stroke.isTombstone) continue;
      if (erasedStrokeIds.contains(stroke.id)) continue;
      strokesRendered++;

      rendering.renderStroke(
        recCanvas,
        stroke,
        pressureMode: pressureMode,
        grainIntensity: grainIntensity,
        pressureExponent: pressureExponent,
        tiltStrength: tiltStrength,
        targetArcLength: replayArcLength,
      );
    }

    recCanvas.restore();

    final picture = recorder.endRecording();
    final image = picture.toImageSync(pixelSize, pixelSize);
    picture.dispose();
    return image;
  }

  @override
  bool shouldRepaint(covariant CommittedStrokesPainter oldDelegate) {
    return strokeVersion != oldDelegate.strokeVersion ||
        viewportRect != oldDelegate.viewportRect ||
        zoom != oldDelegate.zoom ||
        pressureMode != oldDelegate.pressureMode ||
        grainIntensity != oldDelegate.grainIntensity ||
        pressureExponent != oldDelegate.pressureExponent ||
        replayArcLength != oldDelegate.replayArcLength ||
        tiltStrength != oldDelegate.tiltStrength;
  }
}
