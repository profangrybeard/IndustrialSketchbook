import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/pressure_mode.dart';
import '../models/stroke.dart';
import '../models/stroke_point.dart';
import '../models/tool_type.dart';
import '../utils/perf_metrics.dart';

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
// Cubic Bezier evaluation
// ---------------------------------------------------------------------------

/// Minimum sub-segments per Catmull-Rom curve segment.
const int _minSubdivisions = 4;

/// Maximum sub-segments per segment. Beyond this, edge smoothing
/// (Catmull-Rom cubics on the ribbon outline) provides equivalent
/// visual quality. Caps cost for very fast strokes.
const int _maxSubdivisions = 50;

/// Default target arc length for live drawing (maximum fidelity).
const double _defaultTargetArcLength = 0.5;

/// Coarser arc length for cached/replay rendering (6x faster, near-identical).
const double replayTargetArcLength = 3.0;

/// Compute adaptive subdivision count based on segment chord length.
/// Long segments (fast strokes on big tablets) get more subdivisions;
/// short segments (slow drawing) stay at minimum.
/// Capped at [_maxSubdivisions] — beyond that, edge smoothing handles it.
int _adaptiveSubdivisions(double chordLength, {double targetArcLength = _defaultTargetArcLength}) {
  final n = (chordLength / targetArcLength).ceil();
  if (n < _minSubdivisions) return _minSubdivisions;
  if (n > _maxSubdivisions) return _maxSubdivisions;
  return n;
}

/// Evaluate a cubic Bezier curve at parameter [t] (0..1).
double _cubicEval(double t, double a, double b, double c, double d) {
  final mt = 1.0 - t;
  return mt * mt * mt * a +
      3 * mt * mt * t * b +
      3 * mt * t * t * c +
      t * t * t * d;
}

// ---------------------------------------------------------------------------
// Ribbon geometry
// ---------------------------------------------------------------------------

/// A point on the stroke spine with its computed half-width.
class _SpinePoint {
  final double x, y, halfWidth;
  const _SpinePoint(this.x, this.y, this.halfWidth);
}

/// Build a filled ribbon polygon from a list of spine points.
///
/// For each spine point, computes the perpendicular to the tangent direction
/// and offsets by ±halfWidth to get left/right edge vertices. The resulting
/// closed polygon is filled as a single shape — no segment joins.
///
/// Semicircle caps are drawn at the start and end for round endings.
void _drawRibbon(Canvas canvas, List<_SpinePoint> spine, Paint fillPaint) {
  if (spine.length < 2) {
    // Single point — draw a circle
    final p = spine[0];
    canvas.drawCircle(Offset(p.x, p.y), p.halfWidth, fillPaint);
    return;
  }

  final leftEdge = <Offset>[];
  final rightEdge = <Offset>[];

  for (int i = 0; i < spine.length; i++) {
    final cur = spine[i];

    // Compute tangent direction
    double tx, ty;
    if (i == 0) {
      tx = spine[1].x - cur.x;
      ty = spine[1].y - cur.y;
    } else if (i == spine.length - 1) {
      tx = cur.x - spine[i - 1].x;
      ty = cur.y - spine[i - 1].y;
    } else {
      // Average of forward and backward tangent for smoothness
      tx = spine[i + 1].x - spine[i - 1].x;
      ty = spine[i + 1].y - spine[i - 1].y;
    }

    // Normalize tangent
    final len = math.sqrt(tx * tx + ty * ty);
    if (len < 1e-8) {
      // Degenerate — use previous direction or arbitrary
      if (leftEdge.isNotEmpty) {
        leftEdge.add(leftEdge.last);
        rightEdge.add(rightEdge.last);
      } else {
        leftEdge.add(Offset(cur.x, cur.y - cur.halfWidth));
        rightEdge.add(Offset(cur.x, cur.y + cur.halfWidth));
      }
      continue;
    }

    final nx = tx / len;
    final ny = ty / len;

    // Perpendicular (rotate 90°): (-ny, nx) = left, (ny, -nx) = right
    final hw = cur.halfWidth;
    leftEdge.add(Offset(cur.x - ny * hw, cur.y + nx * hw));
    rightEdge.add(Offset(cur.x + ny * hw, cur.y - nx * hw));
  }

  // Build closed path with smooth edges using Catmull-Rom on edge vertices.
  final path = Path();

  // Start cap (semicircle)
  final startCenter = spine.first;
  final startCapRect = Rect.fromCircle(
      center: Offset(startCenter.x, startCenter.y),
      radius: startCenter.halfWidth);
  final startLeft = leftEdge.first;
  final startAngle = math.atan2(
      startLeft.dy - startCenter.y, startLeft.dx - startCenter.x);
  path.arcTo(startCapRect, startAngle, math.pi, true);

  // Right edge (forward) — smooth with Catmull-Rom cubics
  _addSmoothEdge(path, rightEdge);

  // End cap (semicircle)
  final endCenter = spine.last;
  final endCapRect = Rect.fromCircle(
      center: Offset(endCenter.x, endCenter.y),
      radius: endCenter.halfWidth);
  final endRight = rightEdge.last;
  final endAngle = math.atan2(
      endRight.dy - endCenter.y, endRight.dx - endCenter.x);
  path.arcTo(endCapRect, endAngle, math.pi, false);

  // Left edge (backward) — smooth with Catmull-Rom cubics
  final leftReversed = leftEdge.reversed.toList();
  _addSmoothEdge(path, leftReversed);

  path.close();
  canvas.drawPath(path, fillPaint);
}

/// Append a smooth Catmull-Rom curve through [edge] points to [path].
///
/// Converts each pair of consecutive edge vertices to a cubic Bezier
/// using Catmull-Rom control point derivation. This smooths out the
/// polygon facets on the ribbon outline.
void _addSmoothEdge(Path path, List<Offset> edge) {
  if (edge.length <= 2) {
    // Too few points for Catmull-Rom — just use lines
    for (final p in edge) {
      path.lineTo(p.dx, p.dy);
    }
    return;
  }

  // Move/line to the first point
  path.lineTo(edge[0].dx, edge[0].dy);

  for (int i = 0; i < edge.length - 1; i++) {
    final e0 = edge[i > 0 ? i - 1 : 0];
    final e1 = edge[i];
    final e2 = edge[i + 1];
    final e3 = edge[i + 2 < edge.length ? i + 2 : edge.length - 1];

    // Catmull-Rom → cubic Bezier control points
    final cp1x = e1.dx + (e2.dx - e0.dx) / 6;
    final cp1y = e1.dy + (e2.dy - e0.dy) / 6;
    final cp2x = e2.dx - (e3.dx - e1.dx) / 6;
    final cp2y = e2.dy - (e3.dy - e1.dy) / 6;

    path.cubicTo(cp1x, cp1y, cp2x, cp2y, e2.dx, e2.dy);
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
  double targetArcLength = _defaultTargetArcLength,
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
        pressureMode, grainIntensity, pressureExponent,
        targetArcLength: targetArcLength);
  } else {
    _renderStandardStroke(canvas, stroke, paint, targetArcLength: targetArcLength);
  }
}

/// Standard (non-pencil) stroke rendering: filled ribbon with pressure-
/// varying width.
///
/// Instead of drawing N independent line segments (which create visible
/// join artifacts at width transitions), this computes the stroke as a
/// single filled polygon:
///
/// 1. Walk the Catmull-Rom spline with [_subdivisions] per segment
/// 2. At each evaluated point, compute the tangent direction
/// 3. Offset perpendicular to tangent by ±halfWidth → left/right edges
/// 4. Close left + reversed right into a single Path, fill it
///
/// This eliminates ALL segment boundary artifacts because there are no
/// segments — it's one continuous filled shape with smooth width variation
/// encoded in the polygon outline.
///
/// Round end caps are drawn as semicircles at the first and last points.
void _renderStandardStroke(Canvas canvas, Stroke stroke, Paint paint, {double targetArcLength = _defaultTargetArcLength}) {
  final points = stroke.points;

  // Isolate stroke rendering to prevent alpha compounding
  canvas.saveLayer(stroke.boundingRect, Paint());

  final fillPaint = Paint()
    ..style = PaintingStyle.fill
    ..isAntiAlias = true
    ..blendMode = BlendMode.src
    ..color = paint.color;

  // 2 points: use ribbon for consistency
  if (points.length == 2) {
    final spinePoints = <_SpinePoint>[
      _SpinePoint(points[0].x, points[0].y,
          stroke.weight * math.max(points[0].pressure, 0.1) / 2.0),
      _SpinePoint(points[1].x, points[1].y,
          stroke.weight * math.max(points[1].pressure, 0.1) / 2.0),
    ];
    _drawRibbon(canvas, spinePoints, fillPaint);
    canvas.restore();
    return;
  }

  // 3+ points: evaluate Catmull-Rom spline → spine points with half-widths
  final spinePoints = <_SpinePoint>[];

  // Add the first point
  spinePoints.add(_SpinePoint(points[0].x, points[0].y,
      stroke.weight * math.max(points[0].pressure, 0.1) / 2.0));

  for (int i = 0; i < points.length - 1; i++) {
    final p0 = points[i > 0 ? i - 1 : 0];
    final p1 = points[i];
    final p2 = points[i + 1];
    final p3 = points[i + 2 < points.length ? i + 2 : points.length - 1];

    // Catmull-Rom → cubic Bezier control points
    final cp1x = p1.x + (p2.x - p0.x) / 6;
    final cp1y = p1.y + (p2.y - p0.y) / 6;
    final cp2x = p2.x - (p3.x - p1.x) / 6;
    final cp2y = p2.y - (p3.y - p1.y) / 6;

    // Adaptive subdivision: longer segments get more subdivisions
    final chordLen = math.sqrt(
        (p2.x - p1.x) * (p2.x - p1.x) + (p2.y - p1.y) * (p2.y - p1.y));
    final subs = _adaptiveSubdivisions(chordLen);

    for (int s = 1; s <= subs; s++) {
      final t = s / subs;
      final x = _cubicEval(t, p1.x, cp1x, cp2x, p2.x);
      final y = _cubicEval(t, p1.y, cp1y, cp2y, p2.y);
      final pressure = p1.pressure + (p2.pressure - p1.pressure) * t;
      final halfW = stroke.weight * math.max(pressure, 0.1) / 2.0;
      spinePoints.add(_SpinePoint(x, y, halfW));
    }
  }

  PerfMetrics.instance.lastStrokeSpinePoints = spinePoints.length;
  PerfMetrics.instance.lastStrokeChunkCount = 0;
  _drawRibbon(canvas, spinePoints, fillPaint);
  canvas.restore();
}

/// Pencil-specific rendering: filled ribbon with pressure/tilt-varying width
/// and opacity modulation via grain, velocity, and tilt effects.
///
/// Uses the same ribbon approach as [_renderStandardStroke] to eliminate
/// join artifacts. Pencil-specific effects (grain, velocity fade, tilt opacity)
/// are applied as a weighted average across the stroke.
///
/// The ribbon provides smooth pressure-varying width. Opacity variation
/// is achieved by rendering the ribbon in short overlapping sections with
/// locally-computed opacity, clipped to the overall ribbon shape.
void _renderPencilStroke(
  Canvas canvas,
  Stroke stroke,
  Paint paint,
  Color baseColor,
  double baseAlpha,
  PressureMode pressureMode,
  double grainIntensity,
  double pressureExponent, {
  double targetArcLength = _defaultTargetArcLength,
}
) {
  final points = stroke.points;

  // Isolate stroke rendering to prevent alpha compounding
  canvas.saveLayer(stroke.boundingRect, Paint());

  // 2 points: simple ribbon
  if (points.length == 2) {
    final p0 = points[0];
    final p1 = points[1];
    final pencilP0 = pencilPressure(p0.pressure, exponent: pressureExponent);
    final pencilP1 = pencilPressure(p1.pressure, exponent: pressureExponent);
    final tilt0 = tiltWidthMultiplier(p0.tiltX);
    final tilt1 = tiltWidthMultiplier(p1.tiltX);

    double hw0, hw1;
    switch (pressureMode) {
      case PressureMode.opacity:
        hw0 = stroke.weight * tilt0 / 2.0;
        hw1 = stroke.weight * tilt1 / 2.0;
      case PressureMode.width:
      case PressureMode.both:
        hw0 = stroke.weight * math.max(pencilP0, 0.1) * tilt0 / 2.0;
        hw1 = stroke.weight * math.max(pencilP1, 0.1) * tilt1 / 2.0;
    }

    final avgPencilP = (pencilP0 + pencilP1) / 2.0;
    final avgTiltFade = (tiltOpacityFade(p0.tiltX) + tiltOpacityFade(p1.tiltX)) / 2.0;
    final grain = grainFactor((p0.x + p1.x) / 2, (p0.y + p1.y) / 2, grainIntensity);
    final velFactor = velocityFactor(p0, p1);

    double alpha;
    switch (pressureMode) {
      case PressureMode.width:
        alpha = baseAlpha * 0.7 * grain * velFactor * avgTiltFade;
      case PressureMode.opacity:
      case PressureMode.both:
        alpha = baseAlpha * 0.7 * math.max(avgPencilP, 0.1) * grain * velFactor * avgTiltFade;
    }

    final spinePoints = <_SpinePoint>[
      _SpinePoint(p0.x, p0.y, hw0),
      _SpinePoint(p1.x, p1.y, hw1),
    ];
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true
      ..blendMode = BlendMode.src
      ..color = baseColor.withValues(alpha: alpha.clamp(0.01, 1.0));
    _drawRibbon(canvas, spinePoints, fillPaint);
    canvas.restore();
    return;
  }

  // 3+ points: evaluate Catmull-Rom spline → spine points with half-widths
  // and per-point opacity for pencil effects.
  final spinePoints = <_SpinePoint>[];
  final spineAlphas = <double>[];

  // Compute properties for first point
  final firstP = points[0];
  final firstPencilP = pencilPressure(firstP.pressure, exponent: pressureExponent);
  final firstTiltMult = tiltWidthMultiplier(firstP.tiltX);
  final firstTiltFade = tiltOpacityFade(firstP.tiltX);
  double firstHW;
  switch (pressureMode) {
    case PressureMode.opacity:
      firstHW = stroke.weight * firstTiltMult / 2.0;
    case PressureMode.width:
    case PressureMode.both:
      firstHW = stroke.weight * math.max(firstPencilP, 0.1) * firstTiltMult / 2.0;
  }
  spinePoints.add(_SpinePoint(firstP.x, firstP.y, firstHW));

  double firstAlpha;
  switch (pressureMode) {
    case PressureMode.width:
      firstAlpha = baseAlpha * 0.7 * firstTiltFade;
    case PressureMode.opacity:
    case PressureMode.both:
      firstAlpha = baseAlpha * 0.7 * math.max(firstPencilP, 0.1) * firstTiltFade;
  }
  spineAlphas.add(firstAlpha.clamp(0.01, 1.0));

  for (int i = 0; i < points.length - 1; i++) {
    final p0 = points[i > 0 ? i - 1 : 0];
    final p1 = points[i];
    final p2 = points[i + 1];
    final p3 = points[i + 2 < points.length ? i + 2 : points.length - 1];

    // Catmull-Rom → cubic Bezier control points
    final cp1x = p1.x + (p2.x - p0.x) / 6;
    final cp1y = p1.y + (p2.y - p0.y) / 6;
    final cp2x = p2.x - (p3.x - p1.x) / 6;
    final cp2y = p2.y - (p3.y - p1.y) / 6;

    // Adaptive subdivision: longer segments get more subdivisions
    final chordLen = math.sqrt(
        (p2.x - p1.x) * (p2.x - p1.x) + (p2.y - p1.y) * (p2.y - p1.y));
    final subs = _adaptiveSubdivisions(chordLen);

    for (int s = 1; s <= subs; s++) {
      final t = s / subs;
      final x = _cubicEval(t, p1.x, cp1x, cp2x, p2.x);
      final y = _cubicEval(t, p1.y, cp1y, cp2y, p2.y);

      final pressure = p1.pressure + (p2.pressure - p1.pressure) * t;
      final tiltX = p1.tiltX + (p2.tiltX - p1.tiltX) * t;
      final tiltMult = tiltWidthMultiplier(tiltX);
      final tiltFade = tiltOpacityFade(tiltX);
      final pencilP = pencilPressure(pressure, exponent: pressureExponent);
      final grain = grainFactor(x, y, grainIntensity);

      // Approximate velocity from original segment endpoints
      final dt = ((p2.timestamp - p1.timestamp).abs() / subs);
      final prevSp = spinePoints.last;
      final dx = x - prevSp.x;
      final dy = y - prevSp.y;
      final dist = math.sqrt(dx * dx + dy * dy);
      final velocity = dt > 0 ? dist / (dt / 1000.0) : 0.0;
      final velFactor =
          (1.0 - ((velocity - 1.0) / 3.0).clamp(0.0, 0.4)).clamp(0.6, 1.0);

      double hw;
      double alpha;
      switch (pressureMode) {
        case PressureMode.width:
          hw = stroke.weight * math.max(pencilP, 0.1) * tiltMult / 2.0;
          alpha = baseAlpha * 0.7 * grain * velFactor * tiltFade;
        case PressureMode.opacity:
          hw = stroke.weight * tiltMult / 2.0;
          alpha = baseAlpha * 0.7 * math.max(pencilP, 0.1) * grain * velFactor * tiltFade;
        case PressureMode.both:
          hw = stroke.weight * math.max(pencilP, 0.1) * tiltMult / 2.0;
          alpha = baseAlpha * 0.7 * math.max(pencilP, 0.1) * grain * velFactor * tiltFade;
      }

      spinePoints.add(_SpinePoint(x, y, hw));
      spineAlphas.add(alpha.clamp(0.01, 1.0));
    }
  }

  PerfMetrics.instance.lastStrokeSpinePoints = spinePoints.length;

  // Render ribbon in chunks to preserve opacity variation.
  // Each chunk is a short ribbon section with locally-averaged opacity.
  // Chunk size of ~8 spine points balances smoothness vs opacity granularity.
  int chunkCount = 0;
  const chunkSize = 8;
  for (int start = 0; start < spinePoints.length - 1; start += chunkSize - 1) {
    final end = math.min(start + chunkSize, spinePoints.length);
    final chunk = spinePoints.sublist(start, end);

    // Average opacity for this chunk
    double avgAlpha = 0;
    for (int j = start; j < end; j++) {
      avgAlpha += spineAlphas[j];
    }
    avgAlpha /= (end - start);

    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true
      ..blendMode = BlendMode.src
      ..color = baseColor.withValues(alpha: avgAlpha.clamp(0.01, 1.0));

    _drawRibbon(canvas, chunk, fillPaint);
    chunkCount++;
  }
  PerfMetrics.instance.lastStrokeChunkCount = chunkCount;

  canvas.restore();
}

/// Apply pencil-specific paint properties (pressure, tilt, grain, velocity)
/// for a segment between two points.
void _applyPencilPaint(
  Paint pencilPaint,
  StrokePoint p0,
  StrokePoint p1,
  Stroke stroke,
  Color baseColor,
  double baseAlpha,
  PressureMode pressureMode,
  double grainIntensity,
  double pressureExponent,
) {
  final avgRawPressure = (p0.pressure + p1.pressure) / 2.0;
  final pencilP = pencilPressure(avgRawPressure, exponent: pressureExponent);

  final avgTiltX = (p0.tiltX + p1.tiltX) / 2.0;
  final tiltMult = tiltWidthMultiplier(avgTiltX);
  final tiltFade = tiltOpacityFade(avgTiltX);

  final avgX = (p0.x + p1.x) / 2.0;
  final avgY = (p0.y + p1.y) / 2.0;
  final grain = grainFactor(avgX, avgY, grainIntensity);

  final velFactor = velocityFactor(p0, p1);

  double effectiveWidth;
  double effectiveAlpha;

  switch (pressureMode) {
    case PressureMode.width:
      effectiveWidth = stroke.weight * math.max(pencilP, 0.1) * tiltMult;
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
      effectiveWidth = stroke.weight * math.max(pencilP, 0.1) * tiltMult;
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
}
