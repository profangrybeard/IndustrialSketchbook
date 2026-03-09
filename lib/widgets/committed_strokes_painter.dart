import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/pressure_mode.dart';
import '../models/stroke.dart';
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
    required this.lastMutationWasAppend,
    this.lastAppendedStroke,
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

  /// Whether the last version bump was a simple pen-up append.
  final bool lastMutationWasAppend;

  /// The stroke appended in the last pen-up (if [lastMutationWasAppend]).
  final Stroke? lastAppendedStroke;

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
    if (rasterCache.canIncrement(strokeVersion, size, paramHash) &&
        lastMutationWasAppend &&
        lastAppendedStroke != null) {
      _incrementCache(canvas, size, paramHash);
      return;
    }

    // 3. Full rebuild — undo, erase, clear, load, or first render.
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
    final stroke = lastAppendedStroke!;
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
