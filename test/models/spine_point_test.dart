import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/spine_point.dart';

void main() {
  group('SpinePoint', () {
    group('construction', () {
      test('stores x, y, pressure', () {
        const sp = SpinePoint(100.5, 200.75, 0.6);
        expect(sp.x, equals(100.5));
        expect(sp.y, equals(200.75));
        expect(sp.pressure, equals(0.6));
      });

      test('packedSize is exactly 12 bytes', () {
        expect(SpinePoint.packedSize, equals(12));
      });
    });

    group('binary serialization', () {
      test('toBytes produces 12 bytes', () {
        const sp = SpinePoint(50.0, 150.0, 0.9);
        final bytes = sp.toBytes();
        expect(bytes.length, equals(12));
      });

      test('round-trip toBytes/fromBytes preserves values at Float32 precision', () {
        const sp = SpinePoint(123.456, 789.012, 0.5);
        final bytes = sp.toBytes();
        final restored = SpinePoint.fromBytes(bytes);

        expect(restored.x, closeTo(123.456, 0.01));
        expect(restored.y, closeTo(789.012, 0.01));
        expect(restored.pressure, closeTo(0.5, 0.0001));
        expect(restored, equals(sp));
      });

      test('packAll/unpackAll round-trip for multiple points', () {
        final points = [
          const SpinePoint(0.0, 0.0, 0.0),
          const SpinePoint(50.0, 100.0, 0.5),
          const SpinePoint(200.0, 400.0, 1.0),
        ];

        final blob = SpinePoint.packAll(points);
        expect(blob.length, equals(3 * 12));

        final restored = SpinePoint.unpackAll(blob);
        expect(restored.length, equals(3));
        for (int i = 0; i < points.length; i++) {
          expect(restored[i], equals(points[i]));
        }
      });

      test('empty list packs to empty blob', () {
        final blob = SpinePoint.packAll([]);
        expect(blob.length, equals(0));
      });

      test('empty blob unpacks to empty list', () {
        final blob = SpinePoint.packAll([]);
        final points = SpinePoint.unpackAll(blob);
        expect(points.length, equals(0));
      });

      test('fromBytes with offset reads correct data', () {
        final points = [
          const SpinePoint(10.0, 20.0, 0.3),
          const SpinePoint(30.0, 40.0, 0.7),
          const SpinePoint(50.0, 60.0, 0.9),
        ];
        final blob = SpinePoint.packAll(points);

        // Read the second point using offset
        final second = SpinePoint.fromBytes(blob, SpinePoint.packedSize);
        expect(second.x, closeTo(30.0, 0.01));
        expect(second.y, closeTo(40.0, 0.01));
        expect(second.pressure, closeTo(0.7, 0.001));
      });
    });

    group('equality', () {
      test('equal points are equal', () {
        const a = SpinePoint(100.0, 200.0, 0.5);
        const b = SpinePoint(100.0, 200.0, 0.5);
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('different points are not equal', () {
        const a = SpinePoint(100.0, 200.0, 0.5);
        const b = SpinePoint(100.1, 200.0, 0.5);
        expect(a, isNot(equals(b)));
      });

      test('round-trip equality uses Float32 precision', () {
        // Value that differs at Float64 precision but matches at Float32
        const sp = SpinePoint(0.1, 0.2, 0.3);
        final restored = SpinePoint.fromBytes(sp.toBytes());
        expect(restored, equals(sp));
      });
    });

    group('toString', () {
      test('produces readable output', () {
        const sp = SpinePoint(100.0, 200.0, 0.5);
        expect(sp.toString(), contains('SpinePoint'));
        expect(sp.toString(), contains('100.0'));
        expect(sp.toString(), contains('200.0'));
      });
    });
  });
}
