import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/perspective_config.dart';

void main() {
  group('PerspectiveConfig', () {
    // -----------------------------------------------------------------------
    // PER-001: PerspectiveConfig serializes and deserializes
    //
    // Create config with 2 vanishing points; serialize to JSON; deserialize;
    // assert all VP coordinates match.
    // Priority: P0
    // -----------------------------------------------------------------------
    group('PER-001: JSON serialization round-trip', () {
      test('2-point perspective: all VP coordinates match after round-trip', () {
        final original = PerspectiveConfig(
          vanishingPoints: [
            VanishingPoint(x: 100.0, y: 400.0),
            VanishingPoint(x: 900.0, y: 400.0),
          ],
          horizonY: 400.0,
        );

        final json = original.toJson();
        final restored = PerspectiveConfig.fromJson(json);

        expect(restored.vanishingPoints.length,
            equals(original.vanishingPoints.length));
        expect(restored.vanishingPoints[0].x,
            equals(original.vanishingPoints[0].x));
        expect(restored.vanishingPoints[0].y,
            equals(original.vanishingPoints[0].y));
        expect(restored.vanishingPoints[1].x,
            equals(original.vanishingPoints[1].x));
        expect(restored.vanishingPoints[1].y,
            equals(original.vanishingPoints[1].y));
        expect(restored.horizonY, equals(original.horizonY));
        expect(restored.pointCount, equals(2));
      });

      test('1-point perspective round-trip', () {
        final original = PerspectiveConfig(
          vanishingPoints: [
            VanishingPoint(x: 500.0, y: 300.0),
          ],
          horizonY: 300.0,
        );

        final json = original.toJson();
        final restored = PerspectiveConfig.fromJson(json);

        expect(restored.vanishingPoints.length, equals(1));
        expect(restored.vanishingPoints[0].x, equals(500.0));
        expect(restored.vanishingPoints[0].y, equals(300.0));
        expect(restored.horizonY, equals(300.0));
        expect(restored.pointCount, equals(1));
      });

      test('JSON can be encoded to string and back', () {
        final original = PerspectiveConfig(
          vanishingPoints: [
            VanishingPoint(x: 100.0, y: 400.0),
            VanishingPoint(x: 900.0, y: 400.0),
          ],
          horizonY: 400.0,
        );

        final jsonString = jsonEncode(original.toJson());
        final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
        final restored = PerspectiveConfig.fromJson(decoded);

        expect(restored, equals(original));
      });

      test('equality: identical configs are equal', () {
        final a = PerspectiveConfig(
          vanishingPoints: [
            VanishingPoint(x: 100.0, y: 400.0),
            VanishingPoint(x: 900.0, y: 400.0),
          ],
          horizonY: 400.0,
        );

        final b = PerspectiveConfig(
          vanishingPoints: [
            VanishingPoint(x: 100.0, y: 400.0),
            VanishingPoint(x: 900.0, y: 400.0),
          ],
          horizonY: 400.0,
        );

        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('equality: different configs are not equal', () {
        final a = PerspectiveConfig(
          vanishingPoints: [VanishingPoint(x: 100.0, y: 400.0)],
          horizonY: 400.0,
        );

        final b = PerspectiveConfig(
          vanishingPoints: [VanishingPoint(x: 200.0, y: 400.0)],
          horizonY: 400.0,
        );

        expect(a, isNot(equals(b)));
      });
    });
  });

  group('VanishingPoint', () {
    test('JSON round-trip', () {
      final original = VanishingPoint(x: 123.456, y: 789.012);
      final json = original.toJson();
      final restored = VanishingPoint.fromJson(json);

      expect(restored.x, equals(original.x));
      expect(restored.y, equals(original.y));
      expect(restored, equals(original));
    });
  });
}
