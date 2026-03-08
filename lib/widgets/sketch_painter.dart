import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/grid_style.dart';
import '../models/pressure_mode.dart';
import '../models/stroke.dart';
import '../models/stroke_point.dart';
import '../models/tool_type.dart';
import 'stroke_rendering.dart' as rendering;

/// Legacy single-layer painter (Phase 2.6).
///
/// **Superseded in Phase 2.8** by the three-layer architecture:
/// - [BackgroundPainter] — paper + grid
/// - [CommittedStrokesPainter] — committed strokes
/// - [ActiveStrokePainter] — inflight stroke + eraser cursor
///
/// Retained for backward compatibility with existing tests that reference
/// the static helper methods ([pencilPressure], [tiltWidthMultiplier], etc.).
/// These statics now forward to the shared functions in `stroke_rendering.dart`.
class SketchPainter extends CustomPainter {
  SketchPainter({
    required this.committedStrokes,
    this.inflightStroke,
    this.gridSpacing = 25.0,
    this.gridStyle = GridStyle.dots,
    this.paperColor = defaultPaperColor,
    this.erasedStrokeIds = const {},
    this.pressureMode = PressureMode.width,
    this.grainIntensity = 0.25,
    this.pressureExponent = 1.8,
    this.eraserCursorPosition,
    this.eraserRadius = 20.0,
    this.showEraserCursor = false,
  });

  /// Default paper background color.
  static const defaultPaperColor = Color(0xFFF5F5F0); // warm white / light cream

  /// Compute a grid overlay color that auto-contrasts against the background.
  ///
  /// Light backgrounds get noticeably darker grid marks; dark backgrounds get
  /// lighter ones. Returns a fully opaque color — no alpha tricks that become
  /// invisible at small radii.
  ///
  /// The contrast factor is intentionally strong (0.35 toward mid-gray) so
  /// that 1–2px dots remain clearly visible on all paper colors.
  static Color gridColorForBackground(Color bg) {
    return rendering.gridColorForBackground(bg);
  }

  /// All finalized strokes for the current page.
  final List<Stroke> committedStrokes;

  /// The stroke currently being drawn (pen is down), or null.
  final Stroke? inflightStroke;

  /// Grid spacing in logical pixels.
  final double gridSpacing;

  /// Which grid style to draw (dots, lines, or none).
  final GridStyle gridStyle;

  /// Paper background color. Configurable by the user.
  final Color paperColor;

  /// Set of stroke IDs that have been erased via tombstone strokes.
  /// These strokes are skipped during rendering.
  final Set<String> erasedStrokeIds;

  /// How stylus pressure affects pencil rendering.
  final PressureMode pressureMode;

  /// Grain texture intensity for pencil tool (0.0–1.0).
  /// Controlled by the active PencilLead preset.
  final double grainIntensity;

  /// Power-curve exponent for pencil pressure mapping.
  /// Controlled by the active [PressureCurve] preset.
  /// Default 1.8 matches Phase 2.6 "natural" behavior.
  final double pressureExponent;

  /// Current eraser cursor position (null when eraser is not active).
  final Offset? eraserCursorPosition;

  /// Eraser hit radius in logical pixels.
  final double eraserRadius;

  /// Whether to draw the dashed eraser cursor circle.
  final bool showEraserCursor;

  @override
  void paint(Canvas canvas, Size size) {
    // Draw paper background + grid overlay
    _drawBackground(canvas, size);

    // Draw committed strokes (skip tombstones and erased strokes)
    for (final stroke in committedStrokes) {
      if (stroke.isTombstone) continue;
      if (erasedStrokeIds.contains(stroke.id)) continue;
      _drawStroke(canvas, stroke);
    }

    // Draw in-flight stroke on top
    final inflight = inflightStroke;
    if (inflight != null) {
      _drawStroke(canvas, inflight);
    }

    // Draw eraser cursor overlay (on top of everything)
    if (showEraserCursor && eraserCursorPosition != null) {
      _drawEraserCursor(canvas);
    }
  }

  /// Draw a dashed circle at the eraser cursor position.
  ///
  /// Uses 16 arc segments with 30% gaps — subtle enough to not distract
  /// while drawing, visible enough to show the eraser's hit area.
  void _drawEraserCursor(Canvas canvas) {
    final cursorPos = eraserCursorPosition;
    if (cursorPos == null) return;

    final paint = Paint()
      ..color = const Color(0x66888888) // semi-transparent gray
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..isAntiAlias = true;

    // Dashed circle: 16 arc segments with 30% gap between each
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

  /// Draw the paper background and optional grid overlay.
  ///
  /// Always paints the paper background color regardless of system theme.
  /// Then draws the selected grid style (dots, lines, or nothing).
  void _drawBackground(Canvas canvas, Size size) {
    // Paper background — always the chosen color regardless of theme
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = paperColor
        ..style = PaintingStyle.fill,
    );

    // No overlay if grid is disabled or spacing is invalid
    if (gridStyle == GridStyle.none || gridSpacing <= 0) return;

    switch (gridStyle) {
      case GridStyle.dots:
        _drawDots(canvas, size);
      case GridStyle.lines:
        _drawLines(canvas, size);
      case GridStyle.none:
        break; // already handled above
    }
  }

  /// Draw evenly spaced dots at grid intersections.
  void _drawDots(Canvas canvas, Size size) {
    final dotPaint = Paint()
      ..color = gridColorForBackground(paperColor)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    // 1.2px radius — small enough to stay subtle, large enough to see
    const dotRadius = 1.2;

    for (double x = gridSpacing; x < size.width; x += gridSpacing) {
      for (double y = gridSpacing; y < size.height; y += gridSpacing) {
        canvas.drawCircle(Offset(x, y), dotRadius, dotPaint);
      }
    }
  }

  /// Draw full ruled grid lines at regular intervals.
  void _drawLines(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = gridColorForBackground(paperColor)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..isAntiAlias = true;

    // Vertical lines
    for (double x = gridSpacing; x < size.width; x += gridSpacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
    }

    // Horizontal lines
    for (double y = gridSpacing; y < size.height; y += gridSpacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }
  }

  // ---------------------------------------------------------------------------
  // Pencil realism helpers (Phase 2.6)
  // ---------------------------------------------------------------------------

  /// Non-linear pressure curve for pencil — light touches stay very light,
  /// heavy pressure gives bold marks. Gives the "resistance" feel of graphite.
  ///
  /// The [exponent] controls curve shape:
  /// - 1.0 = linear (no curve)
  /// - 1.4 = light resistance
  /// - 1.8 = natural graphite feel (default, Phase 2.6 behavior)
  /// - 2.5 = heavy resistance
  static double pencilPressure(double rawPressure, {double exponent = 1.8}) {
    return rendering.pencilPressure(rawPressure, exponent: exponent);
  }

  /// Tilt-based width multiplier — tilting the stylus sideways widens the
  /// stroke (simulating flat-shading with side of pencil lead).
  ///
  /// At 0° tilt (upright): multiplier = 1.0 (normal line).
  /// At ±60° tilt (flat): multiplier = 3.0 (wide shading stroke).
  static double tiltWidthMultiplier(double tiltX) {
    return rendering.tiltWidthMultiplier(tiltX);
  }

  /// Tilt-based opacity fade — flat pencil produces lighter marks.
  static double tiltOpacityFade(double tiltX) {
    return rendering.tiltOpacityFade(tiltX);
  }

  /// Position-based deterministic grain texture.
  ///
  /// Returns a value in [1 - intensity, 1.0] that creates subtle per-segment
  /// opacity variation — simulating graphite catching paper texture.
  ///
  /// The hash is position-based so grain is stable across repaints (no shimmer).
  static double grainFactor(double x, double y, double intensity) {
    return rendering.grainFactor(x, y, intensity);
  }

  /// Velocity-based opacity factor — fast strokes lighten (pencil skipping
  /// over paper), slow strokes stay dark (graphite depositing).
  ///
  /// Returns a value in [0.6, 1.0].
  static double velocityFactor(StrokePoint p0, StrokePoint p1) {
    return rendering.velocityFactor(p0, p1);
  }

  // ---------------------------------------------------------------------------
  // Stroke rendering
  // ---------------------------------------------------------------------------

  /// Draw a single stroke with pressure-sensitive width and tool-specific effects.
  void _drawStroke(Canvas canvas, Stroke stroke) {
    final points = stroke.points;
    if (points.isEmpty) return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // Apply stroke color and opacity
    final baseColor = Color(stroke.color);
    final baseAlpha = stroke.opacity;
    paint.color = baseColor.withValues(alpha: baseAlpha);

    // Tool-specific adjustments
    final isPencil = stroke.tool == ToolType.pencil;
    switch (stroke.tool) {
      case ToolType.highlighter:
        paint.color = paint.color.withValues(alpha: 0.3);
        paint.blendMode = BlendMode.srcOver;
      case ToolType.pencil:
        // Pencil rendering is handled per-segment below
        break;
      case ToolType.eraser:
        paint.blendMode = BlendMode.clear;
      case ToolType.pen:
      case ToolType.marker:
      case ToolType.brush:
        break;
    }

    // Single-point stroke: draw a filled circle (tap/dot)
    if (points.length == 1) {
      final p = points.first;
      final effectivePressure = isPencil
          ? pencilPressure(p.pressure, exponent: pressureExponent)
          : p.pressure;
      final radius =
          stroke.weight * math.max(effectivePressure, 0.1) / 2.0;

      double fillAlpha = baseAlpha;
      if (isPencil) {
        fillAlpha = baseAlpha * 0.7 * math.max(effectivePressure, 0.1);
      }

      final fillPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = baseColor.withValues(alpha: fillAlpha)
        ..blendMode = paint.blendMode
        ..isAntiAlias = true;
      canvas.drawCircle(Offset(p.x, p.y), radius, fillPaint);
      return;
    }

    // Multi-point stroke: draw segments with per-point pressure width
    if (isPencil) {
      _drawPencilStroke(canvas, stroke, paint, baseColor, baseAlpha);
    } else {
      _drawStandardStroke(canvas, stroke, paint);
    }
  }

  /// Standard (non-pencil) stroke rendering: linear pressure → width.
  void _drawStandardStroke(Canvas canvas, Stroke stroke, Paint paint) {
    final points = stroke.points;
    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];

      // Interpolate pressure between the two endpoints for smooth transitions
      final avgPressure = (p0.pressure + p1.pressure) / 2.0;
      paint.strokeWidth = stroke.weight * math.max(avgPressure, 0.1);

      canvas.drawLine(
        Offset(p0.x, p0.y),
        Offset(p1.x, p1.y),
        paint,
      );
    }
  }

  /// Pencil-specific rendering with grain, tilt, velocity, and pressure curve.
  void _drawPencilStroke(
    Canvas canvas,
    Stroke stroke,
    Paint paint,
    Color baseColor,
    double baseAlpha,
  ) {
    final points = stroke.points;
    final pencilPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..blendMode = paint.blendMode;

    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];

      // --- Pressure ---
      final avgRawPressure = (p0.pressure + p1.pressure) / 2.0;
      final pencilP = pencilPressure(avgRawPressure, exponent: pressureExponent);

      // --- Tilt ---
      final avgTiltX = (p0.tiltX + p1.tiltX) / 2.0;
      final tiltMult = tiltWidthMultiplier(avgTiltX);
      final tiltFade = tiltOpacityFade(avgTiltX);

      // --- Grain ---
      final avgX = (p0.x + p1.x) / 2.0;
      final avgY = (p0.y + p1.y) / 2.0;
      final grain = grainFactor(avgX, avgY, grainIntensity);

      // --- Velocity ---
      final velFactor = velocityFactor(p0, p1);

      // --- Apply pressure mode ---
      double effectiveWidth;
      double effectiveAlpha;

      switch (pressureMode) {
        case PressureMode.width:
          effectiveWidth =
              stroke.weight * math.max(pencilP, 0.1) * tiltMult;
          effectiveAlpha =
              baseAlpha * 0.7 * grain * velFactor * tiltFade;
        case PressureMode.opacity:
          effectiveWidth = stroke.weight * tiltMult;
          effectiveAlpha = baseAlpha *
              0.7 *
              math.max(pencilP, 0.1) *
              grain *
              velFactor *
              tiltFade;
        case PressureMode.both:
          effectiveWidth =
              stroke.weight * math.max(pencilP, 0.1) * tiltMult;
          effectiveAlpha = baseAlpha *
              0.7 *
              math.max(pencilP, 0.1) *
              grain *
              velFactor *
              tiltFade;
      }

      pencilPaint.strokeWidth = effectiveWidth;
      pencilPaint.color =
          baseColor.withValues(alpha: effectiveAlpha.clamp(0.01, 1.0));

      canvas.drawLine(
        Offset(p0.x, p0.y),
        Offset(p1.x, p1.y),
        pencilPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant SketchPainter oldDelegate) {
    // Always repaint. Rebuilds are already gated by ChangeNotifier —
    // if we get here, something changed. Identity-comparing the mutable
    // committedStrokes list was causing the "clear canvas doesn't repaint"
    // bug because clear() empties the same List object (same reference).
    return true;
  }
}
