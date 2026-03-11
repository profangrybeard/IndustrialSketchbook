import 'dart:math' as math;

import '../models/stroke_point.dart';

/// Multi-dimensional Ramer-Douglas-Peucker simplification for stroke points.
///
/// Reduces raw stylus samples (Level 0, 240Hz) into a smaller set of key
/// points (Level 1) that produce visually identical output through the
/// existing Catmull-Rom rendering pipeline.
///
/// Unlike pure geometric RDP, this considers pressure and tilt channels:
/// points where pressure or tilt changes significantly are always preserved,
/// even on geometrically straight sections. This ensures pen-pressure events
/// that affect rendering are never smoothed away.
class CurveFitter {
  /// Simplify a stroke's points using multi-dimensional RDP.
  ///
  /// [tolerance] is the max perpendicular distance in canvas units.
  /// Points where pressure changes by more than [pressureTolerance] from
  /// the interpolated value are always kept.
  /// Points where tilt changes by more than [tiltTolerance] degrees from
  /// the interpolated value are always kept.
  ///
  /// Returns the simplified point list (subset of the original, in order).
  /// Always returns at least the input points for 0-, 1-, or 2-point strokes.
  static List<StrokePoint> simplify(
    List<StrokePoint> points, {
    double tolerance = 0.5,
    double pressureTolerance = 0.05,
    double tiltTolerance = 5.0,
  }) {
    if (points.length <= 2) return List.of(points);

    // Boolean mask: true = keep this point
    final keep = List.filled(points.length, false);
    keep[0] = true;
    keep[points.length - 1] = true;

    _rdpRange(points, keep, 0, points.length - 1, tolerance, pressureTolerance,
        tiltTolerance);

    // Collect kept points in original order
    final result = <StrokePoint>[];
    for (int i = 0; i < points.length; i++) {
      if (keep[i]) result.add(points[i]);
    }
    return result;
  }

  /// Recursive RDP on the range [start..end] (inclusive).
  static void _rdpRange(
    List<StrokePoint> points,
    List<bool> keep,
    int start,
    int end,
    double tolerance,
    double pressureTolerance,
    double tiltTolerance,
  ) {
    if (end - start <= 1) return; // no interior points

    final pStart = points[start];
    final pEnd = points[end];

    // Find the interior point with maximum deviation
    double maxDist = 0.0;
    int maxIndex = start;

    for (int i = start + 1; i < end; i++) {
      final p = points[i];

      // Geometric perpendicular distance
      final geoDist = _perpendicularDistance(p, pStart, pEnd);

      // Pressure deviation from linear interpolation
      final t = (i - start) / (end - start);
      final interpolatedPressure =
          pStart.pressure + (pEnd.pressure - pStart.pressure) * t;
      final pressureDist = (p.pressure - interpolatedPressure).abs();

      // Tilt deviation from linear interpolation
      final interpolatedTiltX =
          pStart.tiltX + (pEnd.tiltX - pStart.tiltX) * t;
      final interpolatedTiltY =
          pStart.tiltY + (pEnd.tiltY - pStart.tiltY) * t;
      final tiltDistX = (p.tiltX - interpolatedTiltX).abs();
      final tiltDistY = (p.tiltY - interpolatedTiltY).abs();

      // Force-keep if pressure or tilt deviates significantly
      if (pressureDist > pressureTolerance ||
          tiltDistX > tiltTolerance ||
          tiltDistY > tiltTolerance) {
        keep[i] = true;
      }

      if (geoDist > maxDist) {
        maxDist = geoDist;
        maxIndex = i;
      }
    }

    // If max geometric distance exceeds tolerance, keep that point and recurse
    if (maxDist > tolerance) {
      keep[maxIndex] = true;
      _rdpRange(
          points, keep, start, maxIndex, tolerance, pressureTolerance, tiltTolerance);
      _rdpRange(
          points, keep, maxIndex, end, tolerance, pressureTolerance, tiltTolerance);
    }
  }

  /// Chaikin corner-cutting subdivision.
  ///
  /// Each iteration replaces every segment with two new points at 1/4 and
  /// 3/4 along the segment, smoothing corners while preserving the overall
  /// shape. All StrokePoint channels (pressure, tilt, twist, timestamp)
  /// are linearly interpolated.
  ///
  /// For an open curve with N points, one iteration produces 2*(N-1) points.
  /// First and last points are preserved exactly.
  ///
  /// [iterations] controls smoothing strength. 1 is usually sufficient
  /// for eliminating faceting on fast/sparse strokes.
  static List<StrokePoint> chaikinSmooth(
    List<StrokePoint> points, {
    int iterations = 1,
  }) {
    if (points.length <= 2) return List.of(points);

    var current = points;
    for (int iter = 0; iter < iterations; iter++) {
      final smoothed = <StrokePoint>[];

      // Preserve the first point exactly
      smoothed.add(current.first);

      for (int i = 0; i < current.length - 1; i++) {
        final a = current[i];
        final b = current[i + 1];

        // Q = 3/4 A + 1/4 B (closer to A)
        smoothed.add(_lerp(a, b, 0.25));

        // R = 1/4 A + 3/4 B (closer to B)
        smoothed.add(_lerp(a, b, 0.75));
      }

      // Preserve the last point exactly
      smoothed.add(current.last);

      current = smoothed;
    }

    return current;
  }

  /// Linearly interpolate all StrokePoint channels at parameter [t] (0..1).
  static StrokePoint _lerp(StrokePoint a, StrokePoint b, double t) {
    return StrokePoint(
      x: a.x + (b.x - a.x) * t,
      y: a.y + (b.y - a.y) * t,
      pressure: a.pressure + (b.pressure - a.pressure) * t,
      tiltX: a.tiltX + (b.tiltX - a.tiltX) * t,
      tiltY: a.tiltY + (b.tiltY - a.tiltY) * t,
      twist: a.twist + (b.twist - a.twist) * t,
      timestamp: a.timestamp + ((b.timestamp - a.timestamp) * t).round(),
    );
  }

  /// Perpendicular distance from point [p] to the line segment [a]-[b].
  static double _perpendicularDistance(
      StrokePoint p, StrokePoint a, StrokePoint b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final lenSq = dx * dx + dy * dy;

    if (lenSq < 1e-10) {
      // a and b are the same point — distance is just point-to-point
      final px = p.x - a.x;
      final py = p.y - a.y;
      return math.sqrt(px * px + py * py);
    }

    // Standard perpendicular distance formula:
    // |cross product| / |line length|
    final cross = ((p.x - a.x) * dy - (p.y - a.y) * dx).abs();
    return cross / math.sqrt(lenSq);
  }
}
