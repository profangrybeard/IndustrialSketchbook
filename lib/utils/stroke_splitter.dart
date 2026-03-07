import 'dart:ui';

import '../models/stroke_point.dart';

/// Split a stroke's points into contiguous segments, removing points
/// within [eraserRadius] of [eraserPosition].
///
/// Returns:
/// - `null` if no points were erased (stroke is unaffected)
/// - Empty list if ALL points were erased
/// - List of point segments (each with >= 1 point) otherwise
List<List<StrokePoint>>? splitStrokePoints({
  required List<StrokePoint> points,
  required Offset eraserPosition,
  required double eraserRadius,
}) {
  final radiusSq = eraserRadius * eraserRadius;
  final erasedIndices = <int>{};

  for (int i = 0; i < points.length; i++) {
    final dx = points[i].x - eraserPosition.dx;
    final dy = points[i].y - eraserPosition.dy;
    if (dx * dx + dy * dy <= radiusSq) {
      erasedIndices.add(i);
    }
  }

  // No points hit — stroke is unaffected
  if (erasedIndices.isEmpty) return null;

  // Split remaining points into contiguous segments
  final segments = <List<StrokePoint>>[];
  var currentSegment = <StrokePoint>[];

  for (int i = 0; i < points.length; i++) {
    if (!erasedIndices.contains(i)) {
      currentSegment.add(points[i]);
    } else if (currentSegment.isNotEmpty) {
      segments.add(currentSegment);
      currentSegment = <StrokePoint>[];
    }
  }
  if (currentSegment.isNotEmpty) {
    segments.add(currentSegment);
  }

  return segments;
}
