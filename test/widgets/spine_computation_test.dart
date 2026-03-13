import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/spine_point.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/widgets/stroke_rendering.dart';

/// Helper to create a StrokePoint with minimal fields.
StrokePoint _sp(double x, double y, {double pressure = 0.5}) {
  return StrokePoint(
    x: x,
    y: y,
    pressure: pressure,
    tiltX: 0.0,
    tiltY: 0.0,
    twist: 0.0,
    timestamp: 0,
  );
}

void main() {
  group('computeSpinePoints', () {
    test('empty input returns empty list', () {
      final result = computeSpinePoints([]);
      expect(result, isEmpty);
    });

    test('single point returns single spine point', () {
      final result = computeSpinePoints([_sp(100, 200, pressure: 0.7)]);
      expect(result.length, equals(1));
      expect(result[0].x, closeTo(100.0, 0.01));
      expect(result[0].y, closeTo(200.0, 0.01));
      expect(result[0].pressure, closeTo(0.7, 0.001));
    });

    test('two points produces subdivided spine', () {
      final result = computeSpinePoints([
        _sp(0, 0, pressure: 0.3),
        _sp(100, 0, pressure: 0.8),
      ]);

      // Should have more than 2 points (Catmull-Rom subdivision adds intermediate points)
      expect(result.length, greaterThan(2));

      // First point matches input
      expect(result.first.x, closeTo(0.0, 0.01));
      expect(result.first.y, closeTo(0.0, 0.01));
      expect(result.first.pressure, closeTo(0.3, 0.001));

      // Last point matches input
      expect(result.last.x, closeTo(100.0, 0.01));
      expect(result.last.y, closeTo(0.0, 0.01));
      expect(result.last.pressure, closeTo(0.8, 0.001));
    });

    test('pressure is linearly interpolated between control points', () {
      final result = computeSpinePoints([
        _sp(0, 0, pressure: 0.0),
        _sp(100, 0, pressure: 1.0),
      ]);

      // Pressures should monotonically increase from 0.0 to 1.0
      for (int i = 1; i < result.length; i++) {
        expect(result[i].pressure, greaterThanOrEqualTo(result[i - 1].pressure),
            reason: 'Pressure should increase monotonically at index $i');
      }
    });

    test('three-point curve generates smooth subdivision', () {
      final result = computeSpinePoints([
        _sp(0, 0),
        _sp(50, 100),
        _sp(100, 0),
      ]);

      // Should produce many intermediate spine points
      expect(result.length, greaterThan(5));

      // First and last should approximately match input
      expect(result.first.x, closeTo(0.0, 0.01));
      expect(result.first.y, closeTo(0.0, 0.01));
      expect(result.last.x, closeTo(100.0, 0.5));
      expect(result.last.y, closeTo(0.0, 0.5));
    });

    test('coarser targetArcLength produces fewer spine points', () {
      final points = [
        _sp(0, 0),
        _sp(50, 100),
        _sp(100, 0),
        _sp(150, 100),
      ];

      final fine = computeSpinePoints(points, targetArcLength: 1.0);
      final coarse = computeSpinePoints(points, targetArcLength: 5.0);

      expect(fine.length, greaterThan(coarse.length),
          reason: 'Finer arc length should produce more spine points');
    });

    test('default targetArcLength uses replayTargetArcLength (3.0)', () {
      final points = [
        _sp(0, 0),
        _sp(300, 0),
      ];

      // Default should be replayTargetArcLength = 3.0
      final defaultResult = computeSpinePoints(points);
      final explicit3 = computeSpinePoints(points, targetArcLength: 3.0);

      expect(defaultResult.length, equals(explicit3.length));
    });

    test('all spine points have valid pressure (0.0-1.0 range)', () {
      final result = computeSpinePoints([
        _sp(0, 0, pressure: 0.2),
        _sp(50, 50, pressure: 0.8),
        _sp(100, 0, pressure: 0.4),
      ]);

      for (final sp in result) {
        expect(sp.pressure, greaterThanOrEqualTo(0.0));
        expect(sp.pressure, lessThanOrEqualTo(1.0));
      }
    });

    test('spine points can be packed and unpacked', () {
      final spines = computeSpinePoints([
        _sp(0, 0, pressure: 0.3),
        _sp(100, 200, pressure: 0.7),
        _sp(200, 100, pressure: 0.5),
      ]);

      final blob = SpinePoint.packAll(spines);
      final restored = SpinePoint.unpackAll(blob);

      expect(restored.length, equals(spines.length));
      for (int i = 0; i < spines.length; i++) {
        expect(restored[i].x, closeTo(spines[i].x, 0.01));
        expect(restored[i].y, closeTo(spines[i].y, 0.01));
        expect(restored[i].pressure, closeTo(spines[i].pressure, 0.001));
      }
    });
  });
}
