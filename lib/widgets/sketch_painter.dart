import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/grid_style.dart';
import '../models/pressure_mode.dart';
import '../models/stroke.dart';
import '../models/stroke_point.dart';
import '../models/tool_type.dart';

/// Custom painter that renders committed strokes and the active in-flight
/// stroke with pressure-sensitive line width (TDD §4.1).
///
/// Rendering approach:
/// - Each stroke is drawn as a series of line segments between consecutive
///   points, with per-segment width = `stroke.weight * point.pressure`.
/// - Single-point strokes (taps) are drawn as filled circles.
/// - Tombstoned strokes are skipped.
///
/// Pencil tool rendering (Phase 2.6):
/// - Non-linear pressure curve (`pow(pressure, 1.8)`) for natural resistance
/// - Tilt-based width variation for side-shading
/// - Position-based grain texture for paper drag feel
/// - Velocity-based lightening for fast-stroke skipping
/// - Pressure mode: width, opacity, or both
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
    final luminance = bg.computeLuminance();
    if (luminance > 0.5) {
      // Light paper: blend 35% toward mid-gray — gives ~#D3D3D3 on white
      return Color.lerp(bg, const Color(0xFF808080), 0.35)!;
    } else {
      // Dark paper: blend 35% toward light gray — gives ~#666 on #2D2D2D
      return Color.lerp(bg, const Color(0xFFD0D0D0), 0.35)!;
    }
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
  /// Exponent 1.8: at 0.5 pressure → ~0.29 effective (subtle).
  /// At 0.8 pressure → ~0.67 effective (medium mark).
  /// At 1.0 pressure → 1.0 (full).
  static double pencilPressure(double rawPressure) {
    return math.pow(rawPressure.clamp(0.0, 1.0), 1.8).toDouble();
  }

  /// Tilt-based width multiplier — tilting the stylus sideways widens the
  /// stroke (simulating flat-shading with side of pencil lead).
  ///
  /// At 0° tilt (upright): multiplier = 1.0 (normal line).
  /// At ±60° tilt (flat): multiplier = 3.0 (wide shading stroke).
  static double tiltWidthMultiplier(double tiltX) {
    final tiltFraction = (tiltX.abs() / 60.0).clamp(0.0, 1.0);
    return 1.0 + tiltFraction * 2.0;
  }

  /// Tilt-based opacity fade — flat pencil produces lighter marks.
  static double tiltOpacityFade(double tiltX) {
    final tiltFraction = (tiltX.abs() / 60.0).clamp(0.0, 1.0);
    return 1.0 - tiltFraction * 0.3;
  }

  /// Position-based deterministic grain texture.
  ///
  /// Returns a value in [1 - intensity, 1.0] that creates subtle per-segment
  /// opacity variation — simulating graphite catching paper texture.
  ///
  /// The hash is position-based so grain is stable across repaints (no shimmer).
  static double grainFactor(double x, double y, double intensity) {
    if (intensity <= 0) return 1.0;
    // Deterministic pseudo-random from position
    final hash = ((x * 73.0 + y * 179.0) % 1.0).abs();
    return (1.0 - intensity) + hash * intensity;
  }

  /// Velocity-based opacity factor — fast strokes lighten (pencil skipping
  /// over paper), slow strokes stay dark (graphite depositing).
  ///
  /// Returns a value in [0.6, 1.0].
  static double velocityFactor(StrokePoint p0, StrokePoint p1) {
    final dt = (p1.timestamp - p0.timestamp).abs();
    if (dt <= 0) return 1.0;

    final dx = p1.x - p0.x;
    final dy = p1.y - p0.y;
    final dist = math.sqrt(dx * dx + dy * dy);
    final velocity = dist / (dt / 1000.0); // pixels per millisecond

    // Fast strokes (>1.0 px/ms) lighten; slow strokes stay full
    final factor = 1.0 - ((velocity - 1.0) / 3.0).clamp(0.0, 0.4);
    return factor.clamp(0.6, 1.0);
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
      final effectivePressure =
          isPencil ? pencilPressure(p.pressure) : p.pressure;
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
      final pencilP = pencilPressure(avgRawPressure);

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
