import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/pressure_mode.dart';
import '../models/stroke.dart';
import '../models/stroke_point.dart';
import '../models/tool_type.dart';

/// Shared stroke rendering functions used by all canvas layer painters.
///
/// Extracted from [SketchPainter] in Phase 2.8 so that
/// [CommittedStrokesPainter], [ActiveStrokePainter], and the legacy
/// [SketchPainter] can share the same rendering code.

// ---------------------------------------------------------------------------
// Static helpers (unchanged from Phase 2.6/2.7)
// ---------------------------------------------------------------------------

/// Non-linear pressure curve for pencil.
///
/// Light touches stay very light, heavy pressure gives bold marks.
/// The [exponent] controls curve shape:
/// - 1.0 = linear (no curve)
/// - 1.4 = light resistance
/// - 1.8 = natural graphite feel (default, Phase 2.6 behavior)
/// - 2.5 = heavy resistance
double pencilPressure(double rawPressure, {double exponent = 1.8}) {
  return math.pow(rawPressure.clamp(0.0, 1.0), exponent).toDouble();
}

/// Tilt-based width multiplier — tilting the stylus sideways widens the
/// stroke (simulating flat-shading with side of pencil lead).
///
/// At 0° tilt (upright): multiplier = 1.0 (normal line).
/// At ±60° tilt (flat): multiplier = 3.0 (wide shading stroke).
double tiltWidthMultiplier(double tiltX) {
  final tiltFraction = (tiltX.abs() / 60.0).clamp(0.0, 1.0);
  return 1.0 + tiltFraction * 2.0;
}

/// Tilt-based opacity fade — flat pencil produces lighter marks.
double tiltOpacityFade(double tiltX) {
  final tiltFraction = (tiltX.abs() / 60.0).clamp(0.0, 1.0);
  return 1.0 - tiltFraction * 0.3;
}

/// Position-based deterministic grain texture.
///
/// Returns a value in [1 - intensity, 1.0] that creates subtle per-segment
/// opacity variation — simulating graphite catching paper texture.
///
/// The hash is position-based so grain is stable across repaints (no shimmer).
double grainFactor(double x, double y, double intensity) {
  if (intensity <= 0) return 1.0;
  // Deterministic pseudo-random from position
  final hash = ((x * 73.0 + y * 179.0) % 1.0).abs();
  return (1.0 - intensity) + hash * intensity;
}

/// Velocity-based opacity factor — fast strokes lighten (pencil skipping
/// over paper), slow strokes stay dark (graphite depositing).
///
/// Returns a value in [0.6, 1.0].
double velocityFactor(StrokePoint p0, StrokePoint p1) {
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

/// Compute a grid overlay color that auto-contrasts against the background.
///
/// Light backgrounds get noticeably darker grid marks; dark backgrounds get
/// lighter ones. Returns a fully opaque color.
Color gridColorForBackground(Color bg) {
  final luminance = bg.computeLuminance();
  if (luminance > 0.5) {
    return Color.lerp(bg, const Color(0xFF808080), 0.35)!;
  } else {
    return Color.lerp(bg, const Color(0xFFD0D0D0), 0.35)!;
  }
}

// ---------------------------------------------------------------------------
// Stroke rendering
// ---------------------------------------------------------------------------

/// Render a single stroke with pressure-sensitive width and tool-specific
/// effects.
///
/// This is the shared rendering entry point used by all three layer painters.
void renderStroke(
  Canvas canvas,
  Stroke stroke, {
  required PressureMode pressureMode,
  required double grainIntensity,
  required double pressureExponent,
}) {
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
    final radius = stroke.weight * math.max(effectivePressure, 0.1) / 2.0;

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

  // Multi-point stroke
  if (isPencil) {
    _renderPencilStroke(canvas, stroke, paint, baseColor, baseAlpha,
        pressureMode, grainIntensity, pressureExponent);
  } else {
    _renderStandardStroke(canvas, stroke, paint);
  }
}

/// Standard (non-pencil) stroke rendering: linear pressure to width.
///
/// Uses [canvas.saveLayer] + [BlendMode.src] to prevent alpha compounding
/// at segment joints. Without this, each segment's round cap overlaps the
/// adjacent segment's cap, and the overlapping alpha values compound
/// (srcOver blending), creating dark spots at every shared point —
/// especially visible at stroke ends where points cluster tightly.
///
/// With saveLayer: segments draw into an isolated buffer using src mode
/// (each segment replaces, not blends). The buffer is then composited
/// onto the canvas with normal srcOver blending — one pass, no compounding.
void _renderStandardStroke(Canvas canvas, Stroke stroke, Paint paint) {
  final points = stroke.points;

  // Isolate stroke rendering to prevent alpha compounding
  canvas.saveLayer(stroke.boundingRect, Paint());

  final segPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true
    ..blendMode = BlendMode.src; // REPLACE, don't blend within the layer

  for (int i = 0; i < points.length - 1; i++) {
    final p0 = points[i];
    final p1 = points[i + 1];

    final avgPressure = (p0.pressure + p1.pressure) / 2.0;
    segPaint.strokeWidth = stroke.weight * math.max(avgPressure, 0.1);
    segPaint.color = paint.color;

    canvas.drawLine(Offset(p0.x, p0.y), Offset(p1.x, p1.y), segPaint);
  }

  canvas.restore();
}

/// Pencil-specific rendering with grain, tilt, velocity, and pressure curve.
///
/// Uses [canvas.saveLayer] + [BlendMode.src] to prevent alpha compounding
/// at segment joints — the root cause of dark dots/blobs at stroke ends
/// and boundaries. See [_renderStandardStroke] for detailed explanation.
void _renderPencilStroke(
  Canvas canvas,
  Stroke stroke,
  Paint paint,
  Color baseColor,
  double baseAlpha,
  PressureMode pressureMode,
  double grainIntensity,
  double pressureExponent,
) {
  final points = stroke.points;

  // Isolate stroke rendering to prevent alpha compounding
  canvas.saveLayer(stroke.boundingRect, Paint());

  final pencilPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true
    ..blendMode = BlendMode.src; // REPLACE, don't blend within the layer

  for (int i = 0; i < points.length - 1; i++) {
    final p0 = points[i];
    final p1 = points[i + 1];

    // --- Pressure ---
    final avgRawPressure = (p0.pressure + p1.pressure) / 2.0;
    final pencilP =
        pencilPressure(avgRawPressure, exponent: pressureExponent);

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
        effectiveAlpha = baseAlpha * 0.7 * grain * velFactor * tiltFade;
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

    canvas.drawLine(Offset(p0.x, p0.y), Offset(p1.x, p1.y), pencilPaint);
  }

  canvas.restore();
}
