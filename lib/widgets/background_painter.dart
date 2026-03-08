import 'package:flutter/material.dart';

import '../models/grid_style.dart';
import 'stroke_rendering.dart' as rendering;

/// Layer 1 painter: paper background + grid overlay (Phase 2.8).
///
/// Separated from [SketchPainter] so that [RepaintBoundary] caching prevents
/// the grid (1600+ dots at default spacing) from being redrawn on every
/// pointer move. Only repaints when paper color, grid style, or spacing change.
class BackgroundPainter extends CustomPainter {
  BackgroundPainter({
    required this.paperColor,
    required this.gridStyle,
    required this.gridSpacing,
  });

  /// Default paper background color.
  static const defaultPaperColor = Color(0xFFF5F5F0); // warm white / light cream

  /// Paper background color.
  final Color paperColor;

  /// Which grid style to draw (dots, lines, or none).
  final GridStyle gridStyle;

  /// Grid spacing in logical pixels.
  final double gridSpacing;

  @override
  void paint(Canvas canvas, Size size) {
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
        break;
    }
  }

  /// Draw evenly spaced dots at grid intersections.
  void _drawDots(Canvas canvas, Size size) {
    final dotPaint = Paint()
      ..color = rendering.gridColorForBackground(paperColor)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

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
      ..color = rendering.gridColorForBackground(paperColor)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..isAntiAlias = true;

    for (double x = gridSpacing; x < size.width; x += gridSpacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
    }
    for (double y = gridSpacing; y < size.height; y += gridSpacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant BackgroundPainter oldDelegate) {
    return paperColor != oldDelegate.paperColor ||
        gridStyle != oldDelegate.gridStyle ||
        gridSpacing != oldDelegate.gridSpacing;
  }
}
