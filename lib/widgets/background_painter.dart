import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/grid_style.dart';
import 'stroke_rendering.dart' as rendering;

/// Layer 1 painter: paper background + infinite grid overlay.
///
/// Renders only the grid visible within [viewportRect] (world coordinates).
/// Lives **outside** the Flutter Transform — handles its own world→screen
/// mapping using [viewportRect] and [zoom].
///
/// LOD: At high zoom (>4x) grid subdivisions appear; at low zoom (<0.5x)
/// every other line/dot is skipped to prevent visual noise.
class BackgroundPainter extends CustomPainter {
  BackgroundPainter({
    required this.paperColor,
    required this.gridStyle,
    required this.gridSpacing,
    required this.viewportRect,
    required this.zoom,
  });

  /// Default paper background color.
  static const defaultPaperColor = Color(0xFFF5F5F0);

  final Color paperColor;
  final GridStyle gridStyle;
  final double gridSpacing;

  /// World-space rectangle currently visible on screen.
  final Rect viewportRect;

  /// Current zoom factor.
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    // Paper background fills the entire screen
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = paperColor
        ..style = PaintingStyle.fill,
    );

    if (gridStyle == GridStyle.none || gridSpacing <= 0) return;

    // LOD: adjust effective spacing based on zoom
    double effectiveSpacing = gridSpacing;
    if (zoom > 4.0) {
      effectiveSpacing = gridSpacing / 2;
    } else if (zoom < 0.5) {
      effectiveSpacing = gridSpacing * 2;
    }

    switch (gridStyle) {
      case GridStyle.dots:
        _drawDots(canvas, size, effectiveSpacing);
      case GridStyle.lines:
        _drawLines(canvas, size, effectiveSpacing);
      case GridStyle.none:
        break;
    }
  }

  /// Convert world point to screen point.
  Offset _worldToScreen(double wx, double wy) => Offset(
        (wx - viewportRect.left) * zoom,
        (wy - viewportRect.top) * zoom,
      );

  void _drawDots(Canvas canvas, Size size, double spacing) {
    final dotPaint = Paint()
      ..color = rendering.gridColorForBackground(paperColor)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    // Dot radius scales with zoom for visual consistency
    final dotRadius = (1.2 * zoom).clamp(0.5, 3.0);

    // Start from the first grid line visible in the viewport
    final startX =
        (viewportRect.left / spacing).floor() * spacing;
    final startY =
        (viewportRect.top / spacing).floor() * spacing;

    for (double wx = startX; wx <= viewportRect.right; wx += spacing) {
      for (double wy = startY; wy <= viewportRect.bottom; wy += spacing) {
        final screen = _worldToScreen(wx, wy);
        canvas.drawCircle(screen, dotRadius, dotPaint);
      }
    }
  }

  void _drawLines(Canvas canvas, Size size, double spacing) {
    final linePaint = Paint()
      ..color = rendering.gridColorForBackground(paperColor)
      ..style = PaintingStyle.stroke
      ..strokeWidth = (0.6 * zoom).clamp(0.3, 2.0)
      ..isAntiAlias = true;

    final startX =
        (viewportRect.left / spacing).floor() * spacing;
    final startY =
        (viewportRect.top / spacing).floor() * spacing;

    // Vertical lines
    for (double wx = startX; wx <= viewportRect.right; wx += spacing) {
      final sx = (wx - viewportRect.left) * zoom;
      canvas.drawLine(Offset(sx, 0), Offset(sx, size.height), linePaint);
    }

    // Horizontal lines
    for (double wy = startY; wy <= viewportRect.bottom; wy += spacing) {
      final sy = (wy - viewportRect.top) * zoom;
      canvas.drawLine(Offset(0, sy), Offset(size.width, sy), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant BackgroundPainter oldDelegate) {
    return paperColor != oldDelegate.paperColor ||
        gridStyle != oldDelegate.gridStyle ||
        gridSpacing != oldDelegate.gridSpacing ||
        viewportRect != oldDelegate.viewportRect ||
        zoom != oldDelegate.zoom;
  }
}
