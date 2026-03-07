import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';

void main() {
  group('StrokePoint', () {
    // -----------------------------------------------------------------------
    // DRW-001: StrokePoint captures all stylus fields
    //
    // Construct StrokePoint from known values; assert all fields match
    // to Float32 precision.
    // Priority: P0
    // -----------------------------------------------------------------------
    group('DRW-001: captures all stylus fields', () {
      test('all 7 fields match input values', () {
        final point = StrokePoint(
          x: 150.5,
          y: 300.75,
          pressure: 0.65,
          tiltX: -15.0,
          tiltY: 30.0,
          twist: 180.0,
          timestamp: 1700000000000000,
        );

        // Float32 precision: values may lose precision when packed
        expect(point.x, closeTo(150.5, 0.01));
        expect(point.y, closeTo(300.75, 0.01));
        expect(point.pressure, closeTo(0.65, 0.001));
        expect(point.tiltX, closeTo(-15.0, 0.01));
        expect(point.tiltY, closeTo(30.0, 0.01));
        expect(point.twist, closeTo(180.0, 0.01));
        expect(point.timestamp, equals(1700000000000000));
      });

      test('edge case: zero pressure (no contact)', () {
        final point = StrokePoint(
          x: 0.0,
          y: 0.0,
          pressure: 0.0,
          tiltX: 0.0,
          tiltY: 0.0,
          twist: 0.0,
          timestamp: 0,
        );

        expect(point.pressure, equals(0.0));
      });

      test('edge case: maximum pressure', () {
        final point = StrokePoint(
          x: 0.0,
          y: 0.0,
          pressure: 1.0,
          tiltX: 0.0,
          tiltY: 0.0,
          twist: 0.0,
          timestamp: 0,
        );

        expect(point.pressure, equals(1.0));
      });

      test('edge case: extreme tilt values', () {
        final point = StrokePoint(
          x: 0.0,
          y: 0.0,
          pressure: 0.5,
          tiltX: -90.0,
          tiltY: 90.0,
          twist: 360.0,
          timestamp: 0,
        );

        expect(point.tiltX, equals(-90.0));
        expect(point.tiltY, equals(90.0));
        expect(point.twist, equals(360.0));
      });
    });

    // -----------------------------------------------------------------------
    // Binary serialization round-trip
    // -----------------------------------------------------------------------
    group('binary serialization', () {
      test('toBytes produces exactly 32 bytes', () {
        final point = StrokePoint(
          x: 100.0,
          y: 200.0,
          pressure: 0.5,
          tiltX: 10.0,
          tiltY: -20.0,
          twist: 45.0,
          timestamp: 1700000000000000,
        );

        final bytes = point.toBytes();
        expect(bytes.length, equals(StrokePoint.packedSize));
        expect(bytes.length, equals(32));
      });

      test('round-trip: toBytes → fromBytes preserves all fields', () {
        final original = StrokePoint(
          x: 150.5,
          y: 300.75,
          pressure: 0.65,
          tiltX: -15.0,
          tiltY: 30.0,
          twist: 180.0,
          timestamp: 1700000000000000,
        );

        final bytes = original.toBytes();
        final restored = StrokePoint.fromBytes(bytes);

        // Float32 precision comparison
        expect(restored.x, closeTo(original.x, 0.01));
        expect(restored.y, closeTo(original.y, 0.01));
        expect(restored.pressure, closeTo(original.pressure, 0.001));
        expect(restored.tiltX, closeTo(original.tiltX, 0.01));
        expect(restored.tiltY, closeTo(original.tiltY, 0.01));
        expect(restored.twist, closeTo(original.twist, 0.01));
        expect(restored.timestamp, equals(original.timestamp));
      });

      test('packAll/unpackAll round-trip for multiple points', () {
        final points = [
          StrokePoint(
              x: 10.0, y: 20.0, pressure: 0.3,
              tiltX: 5.0, tiltY: -5.0, twist: 0.0,
              timestamp: 1000000),
          StrokePoint(
              x: 15.0, y: 25.0, pressure: 0.5,
              tiltX: 10.0, tiltY: -10.0, twist: 45.0,
              timestamp: 1000001),
          StrokePoint(
              x: 20.0, y: 30.0, pressure: 0.8,
              tiltX: 15.0, tiltY: -15.0, twist: 90.0,
              timestamp: 1000002),
        ];

        final blob = StrokePoint.packAll(points);
        expect(blob.length, equals(3 * StrokePoint.packedSize));

        final restored = StrokePoint.unpackAll(blob);
        expect(restored.length, equals(3));

        for (int i = 0; i < points.length; i++) {
          expect(restored[i].x, closeTo(points[i].x, 0.01));
          expect(restored[i].y, closeTo(points[i].y, 0.01));
          expect(restored[i].pressure, closeTo(points[i].pressure, 0.001));
          expect(restored[i].timestamp, equals(points[i].timestamp));
        }
      });
    });

    // -----------------------------------------------------------------------
    // JSON serialization
    // -----------------------------------------------------------------------
    group('JSON serialization', () {
      test('toJson/fromJson round-trip', () {
        final original = StrokePoint(
          x: 150.5,
          y: 300.75,
          pressure: 0.65,
          tiltX: -15.0,
          tiltY: 30.0,
          twist: 180.0,
          timestamp: 1700000000000000,
        );

        final json = original.toJson();
        final restored = StrokePoint.fromJson(json);

        expect(restored.x, equals(original.x));
        expect(restored.y, equals(original.y));
        expect(restored.pressure, equals(original.pressure));
        expect(restored.tiltX, equals(original.tiltX));
        expect(restored.tiltY, equals(original.tiltY));
        expect(restored.twist, equals(original.twist));
        expect(restored.timestamp, equals(original.timestamp));
      });
    });
  });
}
