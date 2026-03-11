import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/stroke.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/models/tool_type.dart';

void main() {
  /// Helper to create a StrokePoint at a given position.
  StrokePoint makePoint(double x, double y, {int timestamp = 0}) {
    return StrokePoint(
      x: x,
      y: y,
      pressure: 0.5,
      tiltX: 0.0,
      tiltY: 0.0,
      twist: 0.0,
      timestamp: timestamp,
    );
  }

  /// Helper to create a test stroke with known points.
  Stroke makeStroke({
    String id = 'test-stroke-1',
    String pageId = 'page-1',
    ToolType tool = ToolType.pen,
    double weight = 4.0,
    List<StrokePoint>? points,
  }) {
    return Stroke(
      id: id,
      pageId: pageId,
      tool: tool,
      color: 0xFF000000,
      weight: weight,
      opacity: 1.0,
      points: points ??
          [
            makePoint(10.0, 20.0, timestamp: 1000),
            makePoint(30.0, 40.0, timestamp: 2000),
            makePoint(50.0, 10.0, timestamp: 3000),
          ],
      createdAt: DateTime.utc(2024, 1, 15, 12, 0, 0),
    );
  }

  group('Stroke', () {
    // -----------------------------------------------------------------------
    // DRW-002: Stroke.boundingRect is correct
    //
    // Construct Stroke with known points; assert boundingRect is inflated
    // by weight/2 on all sides.
    // Priority: P0
    // -----------------------------------------------------------------------
    group('DRW-002: boundingRect', () {
      test('boundingRect inflated by weight/2 on all sides', () {
        final stroke = makeStroke(
          weight: 4.0,
          points: [
            makePoint(10.0, 20.0),
            makePoint(30.0, 40.0),
            makePoint(50.0, 10.0),
          ],
        );

        final rect = stroke.boundingRect;
        const halfWeight = 4.0 / 2.0; // 2.0

        // Min/max from points: x: 10–50, y: 10–40
        // After inflation by halfWeight (2.0):
        expect(rect.left, closeTo(10.0 - halfWeight, 0.001));   // 8.0
        expect(rect.top, closeTo(10.0 - halfWeight, 0.001));    // 8.0
        expect(rect.right, closeTo(50.0 + halfWeight, 0.001));  // 52.0
        expect(rect.bottom, closeTo(40.0 + halfWeight, 0.001)); // 42.0
      });

      test('single point stroke has rect of weight x weight', () {
        final stroke = makeStroke(
          weight: 6.0,
          points: [makePoint(100.0, 200.0)],
        );

        final rect = stroke.boundingRect;
        const halfWeight = 6.0 / 2.0;

        expect(rect.left, closeTo(100.0 - halfWeight, 0.001));
        expect(rect.top, closeTo(200.0 - halfWeight, 0.001));
        expect(rect.right, closeTo(100.0 + halfWeight, 0.001));
        expect(rect.bottom, closeTo(200.0 + halfWeight, 0.001));
        expect(rect.width, closeTo(6.0, 0.001));
        expect(rect.height, closeTo(6.0, 0.001));
      });

      test('empty points returns Rect.zero', () {
        final stroke = Stroke(
          id: 'empty',
          pageId: 'page-1',
          tool: ToolType.pen,
          color: 0xFF000000,
          weight: 2.0,
          opacity: 1.0,
          points: const [],
          createdAt: DateTime.utc(2024, 1, 1),
        );

        expect(stroke.boundingRect, equals(Rect.zero));
      });
    });

    // -----------------------------------------------------------------------
    // DRW-003: Stroke serialization round-trip
    //
    // Serialize Stroke to JSON; deserialize; assert all fields equal original.
    // Priority: P0
    // -----------------------------------------------------------------------
    group('DRW-003: JSON serialization round-trip', () {
      test('full equality including nested StrokePoint list', () {
        final original = makeStroke();
        final json = original.toJson();
        final restored = Stroke.fromJson(json);

        expect(restored.id, equals(original.id));
        expect(restored.pageId, equals(original.pageId));
        expect(restored.layerId, equals(original.layerId));
        expect(restored.tool, equals(original.tool));
        expect(restored.color, equals(original.color));
        expect(restored.weight, equals(original.weight));
        expect(restored.opacity, equals(original.opacity));
        expect(restored.createdAt, equals(original.createdAt));
        expect(restored.isTombstone, equals(original.isTombstone));
        expect(restored.erasesStrokeId, equals(original.erasesStrokeId));
        expect(restored.synced, equals(original.synced));

        // Verify nested points
        expect(restored.points.length, equals(original.points.length));
        for (int i = 0; i < original.points.length; i++) {
          expect(restored.points[i].x, equals(original.points[i].x));
          expect(restored.points[i].y, equals(original.points[i].y));
          expect(restored.points[i].pressure,
              equals(original.points[i].pressure));
          expect(restored.points[i].tiltX, equals(original.points[i].tiltX));
          expect(restored.points[i].tiltY, equals(original.points[i].tiltY));
          expect(restored.points[i].twist, equals(original.points[i].twist));
          expect(restored.points[i].timestamp,
              equals(original.points[i].timestamp));
        }
      });

      test('JSON can be encoded to string and back', () {
        final original = makeStroke();
        final jsonString = jsonEncode(original.toJson());
        final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
        final restored = Stroke.fromJson(decoded);

        expect(restored.id, equals(original.id));
        expect(restored.points.length, equals(original.points.length));
      });

      test('tombstone stroke round-trips correctly', () {
        final tombstone = Stroke.tombstone(
          id: 'tombstone-1',
          pageId: 'page-1',
          targetStrokeId: 'stroke-to-erase',
          createdAt: DateTime.utc(2024, 1, 15, 12, 30, 0),
        );

        final json = tombstone.toJson();
        final restored = Stroke.fromJson(json);

        expect(restored.isTombstone, isTrue);
        expect(restored.erasesStrokeId, equals('stroke-to-erase'));
        expect(restored.tool, equals(ToolType.eraser));
      });
    });

    // -----------------------------------------------------------------------
    // FittedPoints serialization
    // -----------------------------------------------------------------------
    group('fittedPoints serialization', () {
      test('JSON round-trip with fittedPoints', () {
        final rawPoints = [
          makePoint(0, 0, timestamp: 0),
          makePoint(10, 5, timestamp: 1000),
          makePoint(20, 0, timestamp: 2000),
          makePoint(30, 5, timestamp: 3000),
          makePoint(40, 0, timestamp: 4000),
        ];
        final fitted = [rawPoints.first, rawPoints.last];

        final original = Stroke(
          id: 'fitted-test',
          pageId: 'page-1',
          tool: ToolType.pen,
          color: 0xFF000000,
          weight: 2.0,
          opacity: 1.0,
          points: rawPoints,
          fittedPoints: fitted,
          createdAt: DateTime.utc(2024, 1, 15),
        );

        final json = original.toJson();
        expect(json.containsKey('fittedPoints'), isTrue);

        final restored = Stroke.fromJson(json);
        expect(restored.fittedPoints, isNotNull);
        expect(restored.fittedPoints!.length, equals(2));
        expect(restored.points.length, equals(5));
        expect(restored.renderPoints.length, equals(2));
      });

      test('JSON round-trip without fittedPoints (null)', () {
        final original = makeStroke();
        final json = original.toJson();
        expect(json.containsKey('fittedPoints'), isFalse);

        final restored = Stroke.fromJson(json);
        expect(restored.fittedPoints, isNull);
        // renderPoints falls back to raw points
        expect(restored.renderPoints.length, equals(restored.points.length));
      });

      test('renderPoints returns fittedPoints when available', () {
        final rawPoints = [
          makePoint(0, 0),
          makePoint(10, 10),
          makePoint(20, 20),
        ];
        final fitted = [rawPoints.first, rawPoints.last];

        final stroke = Stroke(
          id: 's1',
          pageId: 'page-1',
          tool: ToolType.pen,
          color: 0xFF000000,
          weight: 2.0,
          opacity: 1.0,
          points: rawPoints,
          fittedPoints: fitted,
          createdAt: DateTime.utc(2024, 1, 1),
        );

        expect(stroke.renderPoints, same(fitted));
        expect(stroke.renderPoints.length, equals(2));
      });

      test('renderPoints falls back to points when fittedPoints is null', () {
        final stroke = makeStroke();
        expect(stroke.fittedPoints, isNull);
        expect(stroke.renderPoints, same(stroke.points));
      });

      test('DB map round-trip with fittedPoints', () {
        final rawPoints = [
          makePoint(0, 0, timestamp: 0),
          makePoint(50, 50, timestamp: 1000),
          makePoint(100, 0, timestamp: 2000),
        ];
        final fitted = [rawPoints.first, rawPoints.last];

        final original = Stroke(
          id: 'db-fitted',
          pageId: 'page-1',
          tool: ToolType.pencil,
          color: 0xFF333333,
          weight: 3.0,
          opacity: 0.8,
          points: rawPoints,
          fittedPoints: fitted,
          createdAt: DateTime.utc(2024, 6, 1),
        );

        final dbMap = original.toDbMap();
        expect(dbMap['fitted_points_blob'], isNotNull);

        final restored = Stroke.fromDbMap(dbMap);
        expect(restored.fittedPoints, isNotNull);
        expect(restored.fittedPoints!.length, equals(2));
        expect(restored.points.length, equals(3));
      });

      test('DB map round-trip without fittedPoints', () {
        final original = makeStroke();
        final dbMap = original.toDbMap();
        expect(dbMap['fitted_points_blob'], isNull);

        final restored = Stroke.fromDbMap(dbMap);
        expect(restored.fittedPoints, isNull);
      });
    });

    // -----------------------------------------------------------------------
    // DRW-008: Single-point tap creates valid stroke
    //
    // Stroke.points.length == 1; no crash.
    // Priority: P1
    // -----------------------------------------------------------------------
    group('DRW-008: single-point tap', () {
      test('stroke with exactly 1 point is valid', () {
        final stroke = makeStroke(
          points: [makePoint(100.0, 200.0)],
        );

        expect(stroke.points.length, equals(1));
        expect(stroke.boundingRect, isNot(equals(Rect.zero)));
        // Should not throw
        final json = stroke.toJson();
        final restored = Stroke.fromJson(json);
        expect(restored.points.length, equals(1));
      });
    });
  });
}
