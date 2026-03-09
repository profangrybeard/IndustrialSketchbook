import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/utils/curve_fitter.dart';

void main() {
  /// Helper to create a StrokePoint at a given position.
  StrokePoint makePoint(
    double x,
    double y, {
    double pressure = 0.5,
    double tiltX = 0.0,
    double tiltY = 0.0,
    int timestamp = 0,
  }) {
    return StrokePoint(
      x: x,
      y: y,
      pressure: pressure,
      tiltX: tiltX,
      tiltY: tiltY,
      twist: 0.0,
      timestamp: timestamp,
    );
  }

  group('CurveFitter', () {
    // -----------------------------------------------------------------------
    // FIT-001: Straight line reduces to 2 endpoints
    // -----------------------------------------------------------------------
    test('FIT-001: straight line reduces to 2 endpoints', () {
      // 10 collinear points along y = x
      final points = List.generate(
        10,
        (i) => makePoint(i * 10.0, i * 10.0, timestamp: i * 1000),
      );

      final result = CurveFitter.simplify(points, tolerance: 0.5);

      expect(result.length, equals(2));
      expect(result.first.x, equals(0.0));
      expect(result.first.y, equals(0.0));
      expect(result.last.x, equals(90.0));
      expect(result.last.y, equals(90.0));
    });

    // -----------------------------------------------------------------------
    // FIT-002: L-shaped stroke keeps the corner point
    // -----------------------------------------------------------------------
    test('FIT-002: L-shaped stroke keeps corner point', () {
      // Horizontal then vertical — sharp 90° corner
      final points = [
        makePoint(0, 0, timestamp: 0),
        makePoint(10, 0, timestamp: 1000),
        makePoint(20, 0, timestamp: 2000),
        makePoint(30, 0, timestamp: 3000),
        makePoint(40, 0, timestamp: 4000), // corner
        makePoint(40, 10, timestamp: 5000),
        makePoint(40, 20, timestamp: 6000),
        makePoint(40, 30, timestamp: 7000),
        makePoint(40, 40, timestamp: 8000),
      ];

      final result = CurveFitter.simplify(points, tolerance: 0.5);

      // Must keep first, corner (40,0), and last
      expect(result.length, greaterThanOrEqualTo(3));
      // Corner point must be present
      expect(result.any((p) => p.x == 40.0 && p.y == 0.0), isTrue);
    });

    // -----------------------------------------------------------------------
    // FIT-003: Circle-like stroke keeps enough points for smooth rendering
    // -----------------------------------------------------------------------
    test('FIT-003: circle-like stroke keeps enough points', () {
      // Generate 72 points on a circle of radius 50. With a higher
      // tolerance (2.0), RDP can skip points on gently curved arcs
      // while keeping enough for the Catmull-Rom renderer to produce
      // a smooth circle.
      final points = List.generate(72, (i) {
        final angle = i * 2 * math.pi / 72;
        return makePoint(
          50 + 50 * math.cos(angle),
          50 + 50 * math.sin(angle),
          timestamp: i * 1000,
        );
      });

      final result = CurveFitter.simplify(points, tolerance: 2.0);

      // Should keep enough for a recognizable circle but reduce from 72
      expect(result.length, greaterThan(4));
      expect(result.length, lessThan(points.length));
    });

    // -----------------------------------------------------------------------
    // FIT-004: Single point returns unchanged
    // -----------------------------------------------------------------------
    test('FIT-004: single point returns unchanged', () {
      final points = [makePoint(42, 99)];
      final result = CurveFitter.simplify(points);

      expect(result.length, equals(1));
      expect(result[0].x, equals(42.0));
      expect(result[0].y, equals(99.0));
    });

    // -----------------------------------------------------------------------
    // FIT-005: Two points return unchanged
    // -----------------------------------------------------------------------
    test('FIT-005: two points return unchanged', () {
      final points = [
        makePoint(0, 0, timestamp: 0),
        makePoint(100, 200, timestamp: 1000),
      ];

      final result = CurveFitter.simplify(points);

      expect(result.length, equals(2));
      expect(result[0].x, equals(0.0));
      expect(result[1].x, equals(100.0));
    });

    // -----------------------------------------------------------------------
    // FIT-006: Pressure spike in straight section preserves that point
    // -----------------------------------------------------------------------
    test('FIT-006: pressure spike on straight section is preserved', () {
      // Straight line with a pressure spike in the middle
      final points = [
        makePoint(0, 0, pressure: 0.5, timestamp: 0),
        makePoint(10, 0, pressure: 0.5, timestamp: 1000),
        makePoint(20, 0, pressure: 0.5, timestamp: 2000),
        makePoint(30, 0, pressure: 0.9, timestamp: 3000), // spike!
        makePoint(40, 0, pressure: 0.5, timestamp: 4000),
        makePoint(50, 0, pressure: 0.5, timestamp: 5000),
        makePoint(60, 0, pressure: 0.5, timestamp: 6000),
      ];

      final result = CurveFitter.simplify(
        points,
        tolerance: 0.5,
        pressureTolerance: 0.05,
      );

      // The pressure spike at (30,0) must be kept even though the
      // line is geometrically straight
      expect(result.any((p) => p.x == 30.0 && p.pressure == 0.9), isTrue);
    });

    // -----------------------------------------------------------------------
    // FIT-007: Tilt change in straight section preserves that point
    // -----------------------------------------------------------------------
    test('FIT-007: tilt change on straight section is preserved', () {
      // Straight line with a tilt change in the middle
      final points = [
        makePoint(0, 0, tiltX: 0.0, timestamp: 0),
        makePoint(10, 0, tiltX: 0.0, timestamp: 1000),
        makePoint(20, 0, tiltX: 0.0, timestamp: 2000),
        makePoint(30, 0, tiltX: 30.0, timestamp: 3000), // tilt!
        makePoint(40, 0, tiltX: 0.0, timestamp: 4000),
        makePoint(50, 0, tiltX: 0.0, timestamp: 5000),
        makePoint(60, 0, tiltX: 0.0, timestamp: 6000),
      ];

      final result = CurveFitter.simplify(
        points,
        tolerance: 0.5,
        tiltTolerance: 5.0,
      );

      // The tilt change at (30,0) must be kept
      expect(result.any((p) => p.x == 30.0 && p.tiltX == 30.0), isTrue);
    });

    // -----------------------------------------------------------------------
    // FIT-008: Max error of fitted output is within tolerance
    // -----------------------------------------------------------------------
    test('FIT-008: max error is within tolerance', () {
      // Generate a wavy line with some noise
      final points = List.generate(50, (i) {
        final x = i * 2.0;
        final y = math.sin(i * 0.3) * 20.0 + (i % 3) * 0.1;
        return makePoint(x, y, timestamp: i * 1000);
      });

      const tolerance = 1.0;
      final result = CurveFitter.simplify(points, tolerance: tolerance);

      // For every removed point, verify it is within tolerance of the
      // line segment between its two nearest kept neighbors
      final keptIndices = <int>[];
      for (int i = 0; i < points.length; i++) {
        if (result.any((r) =>
            r.x == points[i].x &&
            r.y == points[i].y &&
            r.timestamp == points[i].timestamp)) {
          keptIndices.add(i);
        }
      }

      for (int i = 0; i < points.length; i++) {
        if (keptIndices.contains(i)) continue;

        // Find surrounding kept indices
        int? prevKept, nextKept;
        for (final k in keptIndices) {
          if (k < i) prevKept = k;
          if (k > i && nextKept == null) nextKept = k;
        }
        if (prevKept == null || nextKept == null) continue;

        final a = points[prevKept];
        final b = points[nextKept];
        final p = points[i];

        // Perpendicular distance
        final dx = b.x - a.x;
        final dy = b.y - a.y;
        final lenSq = dx * dx + dy * dy;
        if (lenSq < 1e-10) continue;
        final dist =
            ((p.x - a.x) * dy - (p.y - a.y) * dx).abs() / math.sqrt(lenSq);

        expect(dist, lessThanOrEqualTo(tolerance + 1e-9),
            reason:
                'Point $i at (${p.x}, ${p.y}) has distance $dist from segment');
      }
    });

    // -----------------------------------------------------------------------
    // FIT-009: Original point order is preserved
    // -----------------------------------------------------------------------
    test('FIT-009: original point order is preserved', () {
      // Zigzag pattern
      final points = [
        makePoint(0, 0, timestamp: 0),
        makePoint(10, 20, timestamp: 1000),
        makePoint(20, 0, timestamp: 2000),
        makePoint(30, 20, timestamp: 3000),
        makePoint(40, 0, timestamp: 4000),
        makePoint(50, 20, timestamp: 5000),
      ];

      final result = CurveFitter.simplify(points, tolerance: 0.5);

      // Verify timestamps are strictly increasing (proves order preservation)
      for (int i = 1; i < result.length; i++) {
        expect(result[i].timestamp, greaterThan(result[i - 1].timestamp),
            reason: 'Point $i timestamp should be > point ${i - 1}');
      }

      // First and last always kept
      expect(result.first.timestamp, equals(points.first.timestamp));
      expect(result.last.timestamp, equals(points.last.timestamp));
    });

    // -----------------------------------------------------------------------
    // Edge cases
    // -----------------------------------------------------------------------
    test('empty input returns empty', () {
      final result = CurveFitter.simplify([]);
      expect(result, isEmpty);
    });

    test('all points identical returns 2 endpoints', () {
      final points = List.generate(
        5,
        (_) => makePoint(10, 20, timestamp: 0),
      );
      final result = CurveFitter.simplify(points, tolerance: 0.5);
      // First and last are always kept
      expect(result.length, equals(2));
    });

    test('high tolerance reduces more aggressively', () {
      // Zigzag — low tolerance keeps corners, high tolerance removes some
      final points = [
        makePoint(0, 0, timestamp: 0),
        makePoint(10, 5, timestamp: 1000),
        makePoint(20, 0, timestamp: 2000),
        makePoint(30, 5, timestamp: 3000),
        makePoint(40, 0, timestamp: 4000),
      ];

      final lowTol = CurveFitter.simplify(points, tolerance: 0.5);
      final highTol = CurveFitter.simplify(points, tolerance: 10.0);

      expect(highTol.length, lessThanOrEqualTo(lowTol.length));
    });

    test('tiltY deviation also preserved', () {
      final points = [
        makePoint(0, 0, tiltY: 0.0, timestamp: 0),
        makePoint(10, 0, tiltY: 0.0, timestamp: 1000),
        makePoint(20, 0, tiltY: 0.0, timestamp: 2000),
        makePoint(30, 0, tiltY: 25.0, timestamp: 3000), // tiltY spike!
        makePoint(40, 0, tiltY: 0.0, timestamp: 4000),
        makePoint(50, 0, tiltY: 0.0, timestamp: 5000),
      ];

      final result = CurveFitter.simplify(
        points,
        tolerance: 0.5,
        tiltTolerance: 5.0,
      );

      expect(result.any((p) => p.x == 30.0 && p.tiltY == 25.0), isTrue);
    });
  });

  group('CurveFitter.chaikinSmooth', () {
    test('CHK-001: single point returns unchanged', () {
      final points = [makePoint(10, 20)];
      final result = CurveFitter.chaikinSmooth(points);
      expect(result.length, equals(1));
    });

    test('CHK-002: two points return unchanged', () {
      final points = [
        makePoint(0, 0, timestamp: 0),
        makePoint(100, 100, timestamp: 1000),
      ];
      final result = CurveFitter.chaikinSmooth(points);
      expect(result.length, equals(2));
    });

    test('CHK-003: 1 iteration increases point count', () {
      final points = [
        makePoint(0, 0, timestamp: 0),
        makePoint(50, 0, timestamp: 1000),
        makePoint(50, 50, timestamp: 2000),
        makePoint(0, 50, timestamp: 3000),
      ];

      final result = CurveFitter.chaikinSmooth(points, iterations: 1);

      // 4 points → first + 2*(4-1) interior + last = 8 points
      expect(result.length, equals(8));
    });

    test('CHK-004: first and last points are preserved exactly', () {
      final points = [
        makePoint(10, 20, pressure: 0.3, timestamp: 100),
        makePoint(50, 60, pressure: 0.8, timestamp: 500),
        makePoint(90, 30, pressure: 0.5, timestamp: 900),
      ];

      final result = CurveFitter.chaikinSmooth(points);

      expect(result.first.x, equals(10.0));
      expect(result.first.y, equals(20.0));
      expect(result.first.pressure, equals(0.3));
      expect(result.first.timestamp, equals(100));
      expect(result.last.x, equals(90.0));
      expect(result.last.y, equals(30.0));
      expect(result.last.pressure, equals(0.5));
      expect(result.last.timestamp, equals(900));
    });

    test('CHK-005: sharp corner is smoothed', () {
      // 90° corner at (50, 0)
      final points = [
        makePoint(0, 0, timestamp: 0),
        makePoint(50, 0, timestamp: 1000),
        makePoint(50, 50, timestamp: 2000),
      ];

      final result = CurveFitter.chaikinSmooth(points);

      // The sharp corner at (50,0) should be replaced by two points
      // that cut the corner: one at 3/4 toward the corner,
      // one at 1/4 past it. Neither should be at exactly (50,0).
      final cornerPoints = result.where(
          (p) => p.x == 50.0 && p.y == 0.0);
      expect(cornerPoints, isEmpty,
          reason: 'Sharp corner should be smoothed away');
    });

    test('CHK-006: pressure is interpolated through smoothed points', () {
      final points = [
        makePoint(0, 0, pressure: 0.2, timestamp: 0),
        makePoint(50, 0, pressure: 0.8, timestamp: 1000),
        makePoint(100, 0, pressure: 0.4, timestamp: 2000),
      ];

      final result = CurveFitter.chaikinSmooth(points);

      // All interior points should have pressure between 0.2 and 0.8
      for (final p in result) {
        expect(p.pressure, greaterThanOrEqualTo(0.2 - 1e-9));
        expect(p.pressure, lessThanOrEqualTo(0.8 + 1e-9));
      }
    });

    test('CHK-007: 2 iterations produces smoother result than 1', () {
      // L-shape corner
      final points = [
        makePoint(0, 0, timestamp: 0),
        makePoint(50, 0, timestamp: 1000),
        makePoint(50, 50, timestamp: 2000),
        makePoint(0, 50, timestamp: 3000),
      ];

      final smooth1 = CurveFitter.chaikinSmooth(points, iterations: 1);
      final smooth2 = CurveFitter.chaikinSmooth(points, iterations: 2);

      // 2 iterations should produce more points
      expect(smooth2.length, greaterThan(smooth1.length));
    });

    test('CHK-008: timestamp order is preserved', () {
      final points = [
        makePoint(0, 0, timestamp: 0),
        makePoint(10, 20, timestamp: 1000),
        makePoint(30, 10, timestamp: 2000),
        makePoint(50, 30, timestamp: 3000),
      ];

      final result = CurveFitter.chaikinSmooth(points);

      for (int i = 1; i < result.length; i++) {
        expect(result[i].timestamp, greaterThanOrEqualTo(result[i - 1].timestamp),
            reason: 'Timestamps must be non-decreasing');
      }
    });
  });
}
