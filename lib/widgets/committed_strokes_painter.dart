import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

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
/// **Progressive rendering**: renders at most a few tiles per frame to avoid
/// blocking the UI thread. Cache misses beyond the frame budget are deferred
/// to subsequent frames via [continuationNotifier]. Old-resolution tiles
/// (from [TileCache.getAny]) are stretched as placeholders until the new
/// version renders.
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
    ValueNotifier<int>? continuationNotifier,
  })  : _continuationNotifier = continuationNotifier,
        super(repaint: continuationNotifier);

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

  /// Optional notifier for triggering continuation paints.
  /// When non-null, enables progressive rendering: tiles beyond the frame
  /// budget are deferred and this notifier is bumped to schedule the next
  /// paint frame. When null, all tiles render synchronously (legacy behavior).
  final ValueNotifier<int>? _continuationNotifier;

  /// Time budget in microseconds for tile rendering per frame.
  /// Always renders at least one tile to ensure progress, then checks budget.
  /// At ~30ms/tile, this typically yields 1 tile per frame.
  static const int _frameBudgetUs = 8000; // 8ms

  @override
  void paint(Canvas canvas, Size size) {
    final perf = PerfMetrics.instance;
    perf.resetTileStats();
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

    perf.tileVisibleCount = (colMax - colMin + 1) * (rowMax - rowMin + 1);
    final blitPaint = Paint()..filterQuality = FilterQuality.low;

    // Progressive upgrade strategy (Google Maps style):
    // - Tiles with NO cached version: render synchronously (never blank)
    // - Tiles with old-resolution version: show stretched, upgrade with budget
    // This guarantees every tile shows SOMETHING on every frame.
    int tilesDeferred = 0;
    int upgradesThisFrame = 0;

    for (int r = rowMin; r <= rowMax; r++) {
      for (int c = colMin; c <= colMax; c++) {
        final key = TileKey(c, r);
        final tileWorld = key.worldRect(tileSize);

        final screenRect = Rect.fromLTWH(
          (tileWorld.left - viewportRect.left) * zoom,
          (tileWorld.top - viewportRect.top) * zoom,
          tileSize * zoom,
          tileSize * zoom,
        );

        // 1) Exact cache hit (version + resolution match) — blit immediately
        var img = tileCache.get(key, pixelSize);
        if (img != null) {
          final blitSw = Stopwatch()..start();
          canvas.drawImageRect(
            img,
            Rect.fromLTWH(
                0, 0, img.width.toDouble(), img.height.toDouble()),
            screenRect,
            blitPaint,
          );
          blitSw.stop();
          perf.tileBlitUs += blitSw.elapsedMicroseconds;
          continue;
        }

        // 2) Cache miss — check for old-resolution fallback (e.g., post-zoom)
        final fallback = (_continuationNotifier != null)
            ? tileCache.getAny(key)
            : null;

        if (fallback != null) {
          // Has old-resolution tile. Upgrade with frame budget:
          // always upgrade at least 1 per frame (guaranteed progress),
          // then check budget for additional upgrades.
          if (upgradesThisFrame == 0 ||
              sw.elapsedMicroseconds <= _frameBudgetUs) {
            // Within budget — render at new resolution
            upgradesThisFrame++;
            final tileSw = Stopwatch()..start();
            img = _renderTile(key, tileWorld, pixelSize);
            tileSw.stop();
            tileCache.put(key, img, pixelSize);
            final tileUs = tileSw.elapsedMicroseconds;
            perf.tileRenderTotalUs += tileUs;
            if (tileUs > perf.tileRenderMaxUs) perf.tileRenderMaxUs = tileUs;
            perf.tileRenderCount++;

            canvas.drawImageRect(
              img,
              Rect.fromLTWH(
                  0, 0, img.width.toDouble(), img.height.toDouble()),
              screenRect,
              blitPaint,
            );
          } else {
            // Over budget — show stretched old-resolution placeholder
            canvas.drawImageRect(
              fallback,
              Rect.fromLTWH(0, 0, fallback.width.toDouble(),
                  fallback.height.toDouble()),
              screenRect,
              blitPaint,
            );
            tilesDeferred++;
          }
        } else {
          // 3) No fallback — render synchronously (never show blank tiles)
          final tileSw = Stopwatch()..start();
          img = _renderTile(key, tileWorld, pixelSize);
          tileSw.stop();
          tileCache.put(key, img, pixelSize);
          final tileUs = tileSw.elapsedMicroseconds;
          perf.tileRenderTotalUs += tileUs;
          if (tileUs > perf.tileRenderMaxUs) perf.tileRenderMaxUs = tileUs;
          perf.tileRenderCount++;

          canvas.drawImageRect(
            img,
            Rect.fromLTWH(
                0, 0, img.width.toDouble(), img.height.toDouble()),
            screenRect,
            blitPaint,
          );
        }
      }
    }

    // Schedule continuation frame for deferred upgrades
    if (tilesDeferred > 0 && _continuationNotifier != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _continuationNotifier!.value++;
      });
    }

    sw.stop();
    final totalUs = sw.elapsedMicroseconds;
    perf.recordCommittedPaint(totalUs);
    perf.committedPaintType = tilesDeferred > 0
        ? '${perf.tileRenderCount}r/${perf.tileCacheHits}h/${tilesDeferred}d/${perf.tileVisibleCount}v'
        : '${perf.tileRenderCount}r/${perf.tileCacheHits}h/${perf.tileVisibleCount}v';

    // Post-pinch detection: record the first paint after pinch end
    if (perf.pinchEndPending) {
      perf.postPinchPaintUs = totalUs;
      perf.postPinchTilesRendered = perf.tileRenderCount;
      perf.pinchEndPending = false;
    }

    // Log when tiles were freshly rendered or deferred (not all cache hits)
    if (perf.tileRenderCount > 0 || tilesDeferred > 0) {
      debugPrint('[CommittedPainter] ${perf.committedPaintType} '
          '${committedStrokes.length}str v=$strokeVersion '
          'render=${perf.tileRenderTotalUs}µs(max ${perf.tileRenderMaxUs}µs) '
          'blit=${perf.tileBlitUs}µs total=${totalUs}µs '
          'miss:absent=${perf.tileMissAbsent}/ver=${perf.tileMissVersion}/res=${perf.tileMissResolution}');
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

    // Zoom-adaptive arc length: at higher zoom, use finer subdivisions
    // so curves stay smooth. At zoom 1x, use replayArcLength (1.5).
    // At zoom 3x, use replayArcLength/3 (0.5). Clamped to avoid
    // excessive subdivision at extreme zoom.
    final effectiveArcLength = zoom > 1.0
        ? math.max(replayArcLength / zoom, 0.3)
        : replayArcLength;

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
        targetArcLength: effectiveArcLength,
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
