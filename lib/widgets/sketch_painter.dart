import 'dart:math' as math;

import 'package:flutter/material.dart';

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
class SketchPainter extends CustomPainter {
  SketchPainter({
    required this.committedStrokes,
    this.inflightStroke,
    this.gridSpacing = 25.0,
    this.erasedStrokeIds = const {},
  });

  /// The paper background color. Single source of truth.
  static const paperColor = Color(0xFFF5F5F0); // warm white / light cream

  /// Compute a dot color that auto-contrasts against the given background.
  ///
  /// Light backgrounds get subtly darker dots; dark backgrounds get lighter dots.
  /// Returns a fully opaque color — no alpha tricks that become invisible at
  /// small radii.
  static Color dotColorForBackground(Color bg) {
    final luminance = bg.computeLuminance();
    if (luminance > 0.5) {
      // Light paper: blend toward a warm gray
      return Color.lerp(bg, const Color(0xFF9E9E9E), 0.25)!;
    } else {
      // Dark paper: blend toward a light gray
      return Color.lerp(bg, const Color(0xFFE0E0E0), 0.25)!;
    }
  }

  /// All finalized strokes for the current page.
  final List<Stroke> committedStrokes;

  /// The stroke currently being drawn (pen is down), or null.
  final Stroke? inflightStroke;

  /// Dot grid spacing in logical pixels. Dots are drawn as the background.
  final double gridSpacing;

  /// Set of stroke IDs that have been erased via tombstone strokes.
  /// These strokes are skipped during rendering.
  final Set<String> erasedStrokeIds;

  @override
  void paint(Canvas canvas, Size size) {
    // Draw dot grid background
    _drawDotGrid(canvas, size);

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

  /// Draw a light paper background with a dot grid overlay.
  ///
  /// Always paints the paper background regardless of system theme.
  /// Skips dots when `gridSpacing <= 0` (grid disabled).
  void _drawDotGrid(Canvas canvas, Size size) {
    // Paper background — always light regardless of theme
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = paperColor
        ..style = PaintingStyle.fill,
    );

    // Skip dots if grid is disabled
    if (gridSpacing <= 0) return;

    // Auto-contrasting dots: fully opaque, subtle but visible
    final dotPaint = Paint()
      ..color = dotColorForBackground(paperColor)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    const dotRadius = 1.0;

    for (double x = gridSpacing; x < size.width; x += gridSpacing) {
      for (double y = gridSpacing; y < size.height; y += gridSpacing) {
        canvas.drawCircle(Offset(x, y), dotRadius, dotPaint);
      }
    }
  }

  /// Draw a single stroke with pressure-sensitive width.
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
    paint.color = baseColor.withValues(alpha: stroke.opacity);

    // Tool-specific adjustments
    switch (stroke.tool) {
      case ToolType.highlighter:
        paint.color = paint.color.withValues(alpha: 0.3);
        paint.blendMode = BlendMode.srcOver;
      case ToolType.pencil:
        // Slightly thinner, lower opacity for pencil feel
        paint.color = paint.color.withValues(
          alpha: math.min(1.0, stroke.opacity * 0.7),
        );
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
      final radius = stroke.weight * math.max(p.pressure, 0.1) / 2.0;
      final fillPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = paint.color
        ..blendMode = paint.blendMode
        ..isAntiAlias = true;
      canvas.drawCircle(Offset(p.x, p.y), radius, fillPaint);
      return;
    }

    // Multi-point stroke: draw segments with per-point pressure width
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

  @override
  bool shouldRepaint(covariant SketchPainter oldDelegate) {
    // Always repaint. Rebuilds are already gated by ChangeNotifier —
    // if we get here, something changed. Identity-comparing the mutable
    // committedStrokes list was causing the "clear canvas doesn't repaint"
    // bug because clear() empties the same List object (same reference).
    return true;
  }
}
