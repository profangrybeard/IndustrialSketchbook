import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/pressure_mode.dart';
import '../models/stroke.dart';
import '../services/drawing_service.dart' show MutationInfo, MutationType;
import 'stroke_raster_cache.dart';
import 'stroke_rendering.dart' as rendering;

/// Layer 2 painter: all committed (finalized) strokes (Phase 2.8).
///
/// Renders on a transparent layer — no background fill. Composites over
/// [BackgroundPainter] via Flutter's layer tree.
///
/// Uses [strokeVersion] for cache invalidation: during active drawing
/// (pointer move), the version doesn't change, so [shouldRepaint] returns
/// `false` and Flutter reuses the cached GPU texture.
///
/// Additionally maintains a [StrokeRasterCache] for incremental updates:
/// on pen-up (single stroke append), only the new stroke is rendered on top
/// of the cached image instead of re-rendering all N strokes.
class CommittedStrokesPainter extends CustomPainter {
  CommittedStrokesPainter({
    required this.committedStrokes,
    required this.erasedStrokeIds,
    required this.strokeVersion,
    required this.pressureMode,
    required this.grainIntensity,
    required this.pressureExponent,
    required this.rasterCache,
    required this.devicePixelRatio,
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

  /// Shared raster cache owned by CanvasWidget. Survives across rebuilds.
  final StrokeRasterCache rasterCache;

  /// Device pixel ratio for high-DPI rasterization.
  final double devicePixelRatio;

  /// Describes the most recent mutation for cache update path selection.
  final MutationInfo lastMutationInfo;

  @override
  void paint(Canvas canvas, Size size) {
    final paramHash =
        Object.hash(pressureMode, grainIntensity, pressureExponent);

    // 1. Cache hit — version, size, and params all match. Just blit.
    if (rasterCache.isValid(strokeVersion, size, paramHash)) {
      _drawCachedImage(canvas, size);
      return;
    }

    // 2. Incremental update — cache is exactly 1 version behind and the
    //    last mutation was a simple pen-up append. Draw old image + new stroke.
    if (lastMutationInfo.type == MutationType.append &&
        lastMutationInfo.appendedStroke != null &&
        rasterCache.canIncrement(strokeVersion, size, paramHash)) {
      _incrementCache(canvas, size, paramHash);
      return;
    }

    // 3. Dirty-region update — clear and re-render only the affected area.
    if (lastMutationInfo.type == MutationType.dirtyRegion &&
        lastMutationInfo.dirtyRect != null &&
        !lastMutationInfo.dirtyRect!.isEmpty &&
        rasterCache.canDirtyRebuild(strokeVersion, size, paramHash)) {
      _dirtyRegionRebuild(canvas, size, paramHash);
      return;
    }

    // 4. Full rebuild — clear, load, or first render.
    _fullRebuildCache(canvas, size, paramHash);
  }

  /// Blit the cached raster image to the canvas.
  void _drawCachedImage(Canvas canvas, Size size) {
    final image = rasterCache.image!;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
          0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint(),
    );
  }

  /// Incrementally update the cache: composite old image + new stroke.
  void _incrementCache(Canvas canvas, Size size, int paramHash) {
    final dpr = devicePixelRatio;
    final recorder = ui.PictureRecorder();
    final recCanvas = Canvas(recorder);
    recCanvas.scale(dpr, dpr);

    // Draw existing cached image
    final oldImage = rasterCache.image!;
    recCanvas.drawImageRect(
      oldImage,
      Rect.fromLTWH(
          0, 0, oldImage.width.toDouble(), oldImage.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint(),
    );

    // Render only the newly appended stroke
    final stroke = lastMutationInfo.appendedStroke!;
    if (!stroke.isTombstone) {
      rendering.renderStroke(
        recCanvas,
        stroke,
        pressureMode: pressureMode,
        grainIntensity: grainIntensity,
        pressureExponent: pressureExponent,
      );
    }

    final picture = recorder.endRecording();
    final newImage = picture.toImageSync(
        (size.width * dpr).ceil(), (size.height * dpr).ceil());
    picture.dispose();
    rasterCache.update(newImage, strokeVersion, size, paramHash);

    _drawCachedImage(canvas, size);
  }

  /// Dirty-region cache update: clear and re-render only the affected area.
  ///
  /// Used for undo/redo/erase where only a localized area changes.
  /// Cost: O(K) where K = strokes overlapping the dirty rect, vs O(N) for
  /// full rebuild.
  void _dirtyRegionRebuild(Canvas canvas, Size size, int paramHash) {
    final dpr = devicePixelRatio;
    final dirtyRect = lastMutationInfo.dirtyRect!;
    final recorder = ui.PictureRecorder();
    final recCanvas = Canvas(recorder);
    recCanvas.scale(dpr, dpr);

    // Draw existing cached image as base
    final oldImage = rasterCache.image!;
    recCanvas.drawImageRect(
      oldImage,
      Rect.fromLTWH(
          0, 0, oldImage.width.toDouble(), oldImage.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint(),
    );

    // Clear the dirty rect to transparent
    recCanvas.drawRect(
      dirtyRect,
      Paint()..blendMode = BlendMode.clear,
    );

    // Clip to dirty rect and re-render only overlapping strokes.
    // Clipping prevents alpha doubling for semi-transparent strokes
    // that cross the dirty region boundary.
    recCanvas.save();
    recCanvas.clipRect(dirtyRect);
    for (final stroke in committedStrokes) {
      if (stroke.isTombstone) continue;
      if (erasedStrokeIds.contains(stroke.id)) continue;
      if (!stroke.boundingRect.overlaps(dirtyRect)) continue;
      rendering.renderStroke(
        recCanvas,
        stroke,
        pressureMode: pressureMode,
        grainIntensity: grainIntensity,
        pressureExponent: pressureExponent,
      );
    }
    recCanvas.restore();

    final picture = recorder.endRecording();
    final newImage = picture.toImageSync(
        (size.width * dpr).ceil(), (size.height * dpr).ceil());
    picture.dispose();
    rasterCache.update(newImage, strokeVersion, size, paramHash);

    _drawCachedImage(canvas, size);
  }

  /// Full cache rebuild: re-render all visible strokes.
  void _fullRebuildCache(Canvas canvas, Size size, int paramHash) {
    final dpr = devicePixelRatio;
    final recorder = ui.PictureRecorder();
    final recCanvas = Canvas(recorder);
    recCanvas.scale(dpr, dpr);

    for (final stroke in committedStrokes) {
      if (stroke.isTombstone) continue;
      if (erasedStrokeIds.contains(stroke.id)) continue;
      rendering.renderStroke(
        recCanvas,
        stroke,
        pressureMode: pressureMode,
        grainIntensity: grainIntensity,
        pressureExponent: pressureExponent,
      );
    }

    final picture = recorder.endRecording();
    final newImage = picture.toImageSync(
        (size.width * dpr).ceil(), (size.height * dpr).ceil());
    picture.dispose();
    rasterCache.update(newImage, strokeVersion, size, paramHash);

    _drawCachedImage(canvas, size);
  }

  @override
  bool shouldRepaint(covariant CommittedStrokesPainter oldDelegate) {
    return strokeVersion != oldDelegate.strokeVersion ||
        pressureMode != oldDelegate.pressureMode ||
        grainIntensity != oldDelegate.grainIntensity ||
        pressureExponent != oldDelegate.pressureExponent;
  }
}
