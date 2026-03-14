import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/pressure_mode.dart';
import '../models/stroke.dart';
import '../utils/perf_metrics.dart';
import 'stroke_rendering.dart' as rendering;

/// Layer 3 painter: in-flight stroke + eraser cursor (Phase 2.8).
///
/// Renders on a transparent layer — no background fill. Composites over
/// [CommittedStrokesPainter] via Flutter's layer tree.
///
/// Always repaints ([shouldRepaint] returns `true`), but per-frame cost is
/// O(inflight points only) — typically 1–10 points, not thousands.
class ActiveStrokePainter extends CustomPainter {
  ActiveStrokePainter({
    this.inflightStroke,
    this.eraserCursorPosition,
    this.eraserRadius = 20.0,
    this.showEraserCursor = false,
    required this.pressureMode,
    required this.grainIntensity,
    required this.pressureExponent,
    this.tiltStrength = 0.0,
    this.liveArcLength = 0.5,
    required this.suppressSinglePoint,
  });

  /// The stroke currently being drawn (pen is down), or null.
  final Stroke? inflightStroke;

  /// Current eraser cursor position (null when eraser is not active).
  final Offset? eraserCursorPosition;

  /// Eraser hit radius in logical pixels.
  final double eraserRadius;

  /// Whether to draw the dashed eraser cursor circle.
  final bool showEraserCursor;

  /// How stylus pressure affects pencil rendering.
  final PressureMode pressureMode;

  /// Grain texture intensity for pencil tool (0.0–1.0).
  final double grainIntensity;

  /// Power-curve exponent for pencil pressure mapping.
  final double pressureExponent;

  /// Tilt effect strength (0.0 = off, 1.0 = full tilt shading).
  final double tiltStrength;

  /// Arc length for live drawing fidelity.
  final double liveArcLength;

  /// When true, skip rendering inflight strokes with only 1 point.
  ///
  /// This eliminates the "dot" artifact at stroke starts. The 8ms delay
  /// until the second point arrives (one frame at 120Hz) is imperceptible.
  /// When stroke stitching provides a bridge point, the inflight stroke
  /// starts with 2 points and this flag has no effect.
  final bool suppressSinglePoint;

  @override
  void paint(Canvas canvas, Size size) {
    final perf = PerfMetrics.instance;
    perf.markFrameStart();

    final inflight = inflightStroke;
    if (inflight != null) {
      perf.inflightPointCount = inflight.points.length;

      // Skip single-point rendering to avoid dot artifact
      if (!(suppressSinglePoint && inflight.points.length == 1)) {
        final sw = Stopwatch()..start();
        rendering.renderStroke(
          canvas,
          inflight,
          pressureMode: pressureMode,
          grainIntensity: grainIntensity,
          pressureExponent: pressureExponent,
          tiltStrength: tiltStrength,
          targetArcLength: liveArcLength,
        );
        sw.stop();
        perf.recordActiveStrokePaint(sw.elapsedMicroseconds);
        perf.inflightSpinePointCount = perf.lastStrokeSpinePoints;
        perf.inflightSaveLayerCount = perf.lastStrokeChunkCount + 1;
      }
    }

    if (showEraserCursor && eraserCursorPosition != null) {
      _drawEraserCursor(canvas);
    }
  }

  /// Draw a dashed circle at the eraser cursor position.
  void _drawEraserCursor(Canvas canvas) {
    final cursorPos = eraserCursorPosition;
    if (cursorPos == null) return;

    final paint = Paint()
      ..color = const Color(0x66888888)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..isAntiAlias = true;

    const segments = 16;
    const gapFraction = 0.3;
    const arcPerSegment = (2 * math.pi) / segments;
    const drawArc = arcPerSegment * (1 - gapFraction);

    final rect = Rect.fromCircle(center: cursorPos, radius: eraserRadius);
    for (int i = 0; i < segments; i++) {
      final startAngle = i * arcPerSegment;
      canvas.drawArc(rect, startAngle, drawArc, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant ActiveStrokePainter oldDelegate) {
    // Always repaint during drawing — but now only draws 1 stroke.
    return true;
  }
}
