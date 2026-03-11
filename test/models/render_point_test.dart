import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/render_point.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';

void main() {
  group('RenderPoint', () {
    group('construction', () {
      test('stores x, y, pressure', () {
        const rp = RenderPoint(x: 0.5, y: 0.75, pressure: 0.6);
        expect(rp.x, equals(0.5));
        expect(rp.y, equals(0.75));
        expect(rp.pressure, equals(0.6));
      });

      test('packedSize is exactly 12 bytes', () {
        expect(RenderPoint.packedSize, equals(12));
      });
    });

    group('binary serialization', () {
      test('toBytes produces 12 bytes', () {
        const rp = RenderPoint(x: 0.3, y: 0.7, pressure: 0.9);
        final bytes = rp.toBytes();
        expect(bytes.length, equals(12));
      });

      test('round-trip toBytes/fromBytes preserves values at Float32 precision', () {
        const rp = RenderPoint(x: 0.123456, y: 0.987654, pressure: 0.5);
        final bytes = rp.toBytes();
        final restored = RenderPoint.fromBytes(bytes);

        // Float32 precision: ~7 significant digits
        expect(restored.x, closeTo(0.123456, 0.0001));
        expect(restored.y, closeTo(0.987654, 0.0001));
        expect(restored.pressure, closeTo(0.5, 0.0001));
        expect(restored, equals(rp));
      });

      test('packAll/unpackAll round-trip for multiple points', () {
        final points = [
          const RenderPoint(x: 0.0, y: 0.0, pressure: 0.0),
          const RenderPoint(x: 0.5, y: 0.5, pressure: 0.5),
          const RenderPoint(x: 1.0, y: 1.0, pressure: 1.0),
        ];

        final blob = RenderPoint.packAll(points);
        expect(blob.length, equals(3 * 12));

        final restored = RenderPoint.unpackAll(blob);
        expect(restored.length, equals(3));
        for (int i = 0; i < points.length; i++) {
          expect(restored[i], equals(points[i]));
        }
      });

      test('empty list packs to empty blob', () {
        final blob = RenderPoint.packAll([]);
        expect(blob.length, equals(0));

        final restored = RenderPoint.unpackAll(blob);
        expect(restored, isEmpty);
      });

      test('fromBytes with offset reads correct data', () {
        final points = [
          const RenderPoint(x: 0.1, y: 0.2, pressure: 0.3),
          const RenderPoint(x: 0.4, y: 0.5, pressure: 0.6),
        ];
        final blob = RenderPoint.packAll(points);

        // Read the second point using offset
        final second = RenderPoint.fromBytes(blob, 12);
        expect(second, equals(points[1]));
      });
    });

    group('JSON serialization', () {
      test('toJson produces minimal map', () {
        const rp = RenderPoint(x: 0.5, y: 0.75, pressure: 0.8);
        final json = rp.toJson();

        expect(json.keys.length, equals(3));
        expect(json['x'], equals(0.5));
        expect(json['y'], equals(0.75));
        expect(json['pressure'], equals(0.8));
      });

      test('round-trip toJson/fromJson', () {
        const rp = RenderPoint(x: 0.333, y: 0.666, pressure: 0.999);
        final json = rp.toJson();
        final restored = RenderPoint.fromJson(json);

        expect(restored.x, equals(0.333));
        expect(restored.y, equals(0.666));
        expect(restored.pressure, equals(0.999));
      });

      test('JSON can be encoded to string and back', () {
        const rp = RenderPoint(x: 0.5, y: 0.5, pressure: 0.5);
        final jsonString = jsonEncode(rp.toJson());
        final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
        final restored = RenderPoint.fromJson(decoded);

        expect(restored.x, equals(0.5));
        expect(restored.y, equals(0.5));
        expect(restored.pressure, equals(0.5));
      });
    });

    group('fromStrokePoint normalization', () {
      test('normalizes device coordinates to 0.0-1.0', () {
        final sp = StrokePoint(
          x: 500.0,
          y: 300.0,
          pressure: 0.7,
          tiltX: 10.0,
          tiltY: -5.0,
          twist: 45.0,
          timestamp: 12345,
        );

        final rp = RenderPoint.fromStrokePoint(
          sp,
          canvasWidth: 1000.0,
          canvasHeight: 600.0,
        );

        expect(rp.x, closeTo(0.5, 0.0001));
        expect(rp.y, closeTo(0.5, 0.0001));
        expect(rp.pressure, closeTo(0.7, 0.0001));
      });

      test('preserves pressure unchanged', () {
        final sp = StrokePoint(
          x: 0.0,
          y: 0.0,
          pressure: 0.42,
          tiltX: 0.0,
          tiltY: 0.0,
          twist: 0.0,
          timestamp: 0,
        );

        final rp = RenderPoint.fromStrokePoint(
          sp,
          canvasWidth: 1920.0,
          canvasHeight: 1080.0,
        );

        expect(rp.pressure, closeTo(0.42, 0.0001));
      });

      test('origin maps to (0,0)', () {
        final sp = StrokePoint(
          x: 0.0,
          y: 0.0,
          pressure: 0.5,
          tiltX: 0.0,
          tiltY: 0.0,
          twist: 0.0,
          timestamp: 0,
        );

        final rp = RenderPoint.fromStrokePoint(
          sp,
          canvasWidth: 1000.0,
          canvasHeight: 600.0,
        );

        expect(rp.x, closeTo(0.0, 0.0001));
        expect(rp.y, closeTo(0.0, 0.0001));
      });

      test('canvas edge maps to (1,1)', () {
        final sp = StrokePoint(
          x: 2560.0,
          y: 1600.0,
          pressure: 1.0,
          tiltX: 0.0,
          tiltY: 0.0,
          twist: 0.0,
          timestamp: 0,
        );

        final rp = RenderPoint.fromStrokePoint(
          sp,
          canvasWidth: 2560.0,
          canvasHeight: 1600.0,
        );

        expect(rp.x, closeTo(1.0, 0.0001));
        expect(rp.y, closeTo(1.0, 0.0001));
      });

      test('handles zero canvas dimensions gracefully', () {
        final sp = StrokePoint(
          x: 100.0,
          y: 200.0,
          pressure: 0.5,
          tiltX: 0.0,
          tiltY: 0.0,
          twist: 0.0,
          timestamp: 0,
        );

        final rp = RenderPoint.fromStrokePoint(
          sp,
          canvasWidth: 0.0,
          canvasHeight: 0.0,
        );

        expect(rp.x, equals(0.0));
        expect(rp.y, equals(0.0));
      });
    });

    group('toCanvas denormalization', () {
      test('denormalizes back to device coordinates', () {
        const rp = RenderPoint(x: 0.5, y: 0.5, pressure: 0.8);
        final offset = rp.toCanvas(1000.0, 600.0);

        expect(offset.dx, closeTo(500.0, 0.01));
        expect(offset.dy, closeTo(300.0, 0.01));
      });

      test('normalization + denormalization round-trip', () {
        final sp = StrokePoint(
          x: 750.0,
          y: 420.0,
          pressure: 0.65,
          tiltX: 0.0,
          tiltY: 0.0,
          twist: 0.0,
          timestamp: 0,
        );

        final rp = RenderPoint.fromStrokePoint(
          sp,
          canvasWidth: 1500.0,
          canvasHeight: 840.0,
        );
        final offset = rp.toCanvas(1500.0, 840.0);

        expect(offset.dx, closeTo(750.0, 0.1));
        expect(offset.dy, closeTo(420.0, 0.1));
      });

      test('different canvas sizes produce correct denormalization', () {
        const rp = RenderPoint(x: 0.5, y: 0.5, pressure: 0.5);

        // On a phone (1080x1920)
        final phone = rp.toCanvas(1080.0, 1920.0);
        expect(phone.dx, closeTo(540.0, 0.01));
        expect(phone.dy, closeTo(960.0, 0.01));

        // On a tablet (2560x1600)
        final tablet = rp.toCanvas(2560.0, 1600.0);
        expect(tablet.dx, closeTo(1280.0, 0.01));
        expect(tablet.dy, closeTo(800.0, 0.01));
      });
    });

    group('equality', () {
      test('equal points compare as equal', () {
        const a = RenderPoint(x: 0.5, y: 0.5, pressure: 0.5);
        const b = RenderPoint(x: 0.5, y: 0.5, pressure: 0.5);
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('different points compare as not equal', () {
        const a = RenderPoint(x: 0.5, y: 0.5, pressure: 0.5);
        const b = RenderPoint(x: 0.6, y: 0.5, pressure: 0.5);
        expect(a, isNot(equals(b)));
      });

      test('equality uses Float32 precision', () {
        // These values are equal at Float32 precision but differ at Float64
        final f32 = Float32List(1);
        f32[0] = 0.1;
        final f32Value = f32[0].toDouble(); // Float32 truncated

        final a = RenderPoint(x: 0.1, y: 0.0, pressure: 0.0);
        final b = RenderPoint(x: f32Value, y: 0.0, pressure: 0.0);
        expect(a, equals(b));
      });
    });

    group('edge cases', () {
      test('boundary values 0.0 and 1.0 round-trip through binary', () {
        const rp = RenderPoint(x: 0.0, y: 1.0, pressure: 0.0);
        final restored = RenderPoint.fromBytes(rp.toBytes());
        expect(restored.x, equals(0.0));
        expect(restored.y, equals(1.0));
        expect(restored.pressure, equals(0.0));
      });

      test('toString is human-readable', () {
        const rp = RenderPoint(x: 0.5, y: 0.75, pressure: 0.8);
        expect(rp.toString(), contains('0.5000'));
        expect(rp.toString(), contains('0.7500'));
        expect(rp.toString(), contains('0.800'));
      });
    });
  });
}
