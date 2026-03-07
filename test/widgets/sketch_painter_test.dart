import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/widgets/sketch_painter.dart';

void main() {
  // ---------------------------------------------------------------------------
  // pencilPressure — non-linear pressure curve
  // ---------------------------------------------------------------------------
  group('pencilPressure', () {
    test('zero pressure returns zero', () {
      expect(SketchPainter.pencilPressure(0.0), closeTo(0.0, 0.001));
    });

    test('full pressure returns 1.0', () {
      expect(SketchPainter.pencilPressure(1.0), closeTo(1.0, 0.001));
    });

    test('mid pressure is less than linear (curve bows down)', () {
      final result = SketchPainter.pencilPressure(0.5);
      // pow(0.5, 1.8) ≈ 0.287
      expect(result, lessThan(0.5));
      expect(result, closeTo(math.pow(0.5, 1.8), 0.001));
    });

    test('light pressure (0.2) produces very light value', () {
      final result = SketchPainter.pencilPressure(0.2);
      // pow(0.2, 1.8) ≈ 0.054
      expect(result, lessThan(0.1));
      expect(result, closeTo(math.pow(0.2, 1.8), 0.001));
    });

    test('heavy pressure (0.9) is close to linear', () {
      final result = SketchPainter.pencilPressure(0.9);
      // pow(0.9, 1.8) ≈ 0.822
      expect(result, greaterThan(0.8));
      expect(result, closeTo(math.pow(0.9, 1.8), 0.001));
    });

    test('clamps negative pressure to zero', () {
      expect(SketchPainter.pencilPressure(-0.5), closeTo(0.0, 0.001));
    });

    test('clamps pressure above 1.0', () {
      expect(SketchPainter.pencilPressure(1.5), closeTo(1.0, 0.001));
    });
  });

  // ---------------------------------------------------------------------------
  // tiltWidthMultiplier — tilt-based width variation
  // ---------------------------------------------------------------------------
  group('tiltWidthMultiplier', () {
    test('zero tilt returns 1.0 (no widening)', () {
      expect(SketchPainter.tiltWidthMultiplier(0.0), closeTo(1.0, 0.001));
    });

    test('60° tilt returns 3.0 (maximum widening)', () {
      expect(SketchPainter.tiltWidthMultiplier(60.0), closeTo(3.0, 0.001));
    });

    test('30° tilt returns midpoint (2.0)', () {
      expect(SketchPainter.tiltWidthMultiplier(30.0), closeTo(2.0, 0.001));
    });

    test('negative tilt uses absolute value', () {
      expect(SketchPainter.tiltWidthMultiplier(-45.0),
          closeTo(SketchPainter.tiltWidthMultiplier(45.0), 0.001));
    });

    test('tilt beyond 60° is clamped to 3.0', () {
      expect(SketchPainter.tiltWidthMultiplier(90.0), closeTo(3.0, 0.001));
    });
  });

  // ---------------------------------------------------------------------------
  // tiltOpacityFade — flat pencil produces lighter marks
  // ---------------------------------------------------------------------------
  group('tiltOpacityFade', () {
    test('zero tilt returns 1.0 (no fade)', () {
      expect(SketchPainter.tiltOpacityFade(0.0), closeTo(1.0, 0.001));
    });

    test('60° tilt returns 0.7 (30% fade)', () {
      expect(SketchPainter.tiltOpacityFade(60.0), closeTo(0.7, 0.001));
    });

    test('30° tilt returns 0.85 (15% fade)', () {
      expect(SketchPainter.tiltOpacityFade(30.0), closeTo(0.85, 0.001));
    });
  });

  // ---------------------------------------------------------------------------
  // grainFactor — position-based texture
  // ---------------------------------------------------------------------------
  group('grainFactor', () {
    test('zero intensity returns 1.0 (no grain)', () {
      expect(SketchPainter.grainFactor(10.0, 20.0, 0.0), closeTo(1.0, 0.001));
    });

    test('grain is deterministic for same position', () {
      final a = SketchPainter.grainFactor(100.0, 200.0, 0.3);
      final b = SketchPainter.grainFactor(100.0, 200.0, 0.3);
      expect(a, equals(b));
    });

    test('grain varies for different positions', () {
      final a = SketchPainter.grainFactor(100.0, 200.0, 0.3);
      final b = SketchPainter.grainFactor(117.3, 243.7, 0.3);
      // They should generally differ (deterministic hash)
      expect(a, isNot(closeTo(b, 0.001)));
    });

    test('grain with intensity 0.3 is in range [0.7, 1.0]', () {
      // Test a spread of positions
      for (double x = 0; x < 50; x += 3.7) {
        for (double y = 0; y < 50; y += 5.1) {
          final g = SketchPainter.grainFactor(x, y, 0.3);
          expect(g, greaterThanOrEqualTo(0.7 - 0.001));
          expect(g, lessThanOrEqualTo(1.0 + 0.001));
        }
      }
    });

    test('higher intensity gives wider variation range', () {
      // With intensity 0.4, range is [0.6, 1.0]
      // With intensity 0.15, range is [0.85, 1.0]
      // We can't test the exact min/max easily, but we can check bounds
      for (double x = 0; x < 30; x += 2.3) {
        final g = SketchPainter.grainFactor(x, x * 1.5, 0.4);
        expect(g, greaterThanOrEqualTo(0.6 - 0.001));
        expect(g, lessThanOrEqualTo(1.0 + 0.001));
      }
    });
  });

  // ---------------------------------------------------------------------------
  // velocityFactor — speed-based lightening
  // ---------------------------------------------------------------------------
  group('velocityFactor', () {
    StrokePoint makePoint(double x, double y, {int timestamp = 0}) {
      return StrokePoint(
        x: x,
        y: y,
        pressure: 0.5,
        tiltX: 0,
        tiltY: 0,
        twist: 0,
        timestamp: timestamp,
      );
    }

    test('zero time delta returns 1.0', () {
      final p0 = makePoint(0, 0, timestamp: 1000);
      final p1 = makePoint(10, 0, timestamp: 1000);
      expect(SketchPainter.velocityFactor(p0, p1), closeTo(1.0, 0.001));
    });

    test('slow movement returns close to 1.0', () {
      // 1 pixel over 10ms = 0.1 px/ms — very slow
      final p0 = makePoint(0, 0, timestamp: 0);
      final p1 = makePoint(1, 0, timestamp: 10000); // 10ms in microseconds
      final result = SketchPainter.velocityFactor(p0, p1);
      expect(result, closeTo(1.0, 0.05));
    });

    test('fast movement returns reduced factor', () {
      // 100 pixels over 5ms = 20 px/ms — very fast
      final p0 = makePoint(0, 0, timestamp: 0);
      final p1 = makePoint(100, 0, timestamp: 5000);
      final result = SketchPainter.velocityFactor(p0, p1);
      expect(result, lessThanOrEqualTo(0.65));
      expect(result, greaterThanOrEqualTo(0.6));
    });

    test('velocity factor is clamped to [0.6, 1.0]', () {
      // Extremely fast: 500 pixels over 1ms
      final p0 = makePoint(0, 0, timestamp: 0);
      final p1 = makePoint(500, 0, timestamp: 1000);
      final result = SketchPainter.velocityFactor(p0, p1);
      expect(result, greaterThanOrEqualTo(0.6));
      expect(result, lessThanOrEqualTo(1.0));
    });
  });

  // ---------------------------------------------------------------------------
  // gridColorForBackground — contrast computation
  // ---------------------------------------------------------------------------
  group('gridColorForBackground', () {
    test('light background gets darker grid color', () {
      final gridColor =
          SketchPainter.gridColorForBackground(const Color(0xFFFFFFFF));
      final gridLuminance = gridColor.computeLuminance();
      final bgLuminance = const Color(0xFFFFFFFF).computeLuminance();
      expect(gridLuminance, lessThan(bgLuminance));
    });

    test('dark background gets lighter grid color', () {
      final gridColor =
          SketchPainter.gridColorForBackground(const Color(0xFF2D2D2D));
      final gridLuminance = gridColor.computeLuminance();
      final bgLuminance = const Color(0xFF2D2D2D).computeLuminance();
      expect(gridLuminance, greaterThan(bgLuminance));
    });
  });
}
