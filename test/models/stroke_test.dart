import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/render_point.dart';
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
    // renderData serialization (v4: normalized RenderPoints)
    // -----------------------------------------------------------------------
    group('renderData serialization', () {
      test('JSON round-trip with renderData', () {
        final rawPoints = [
          makePoint(0, 0, timestamp: 0),
          makePoint(10, 5, timestamp: 1000),
          makePoint(20, 0, timestamp: 2000),
          makePoint(30, 5, timestamp: 3000),
          makePoint(40, 0, timestamp: 4000),
        ];
        final render = [
          const RenderPoint(x: 0.0, y: 0.0, pressure: 0.5),
          const RenderPoint(x: 1.0, y: 0.5, pressure: 0.5),
        ];

        final original = Stroke(
          id: 'render-test',
          pageId: 'page-1',
          tool: ToolType.pen,
          color: 0xFF000000,
          weight: 2.0,
          opacity: 1.0,
          points: rawPoints,
          renderData: render,
          createdAt: DateTime.utc(2024, 1, 15),
        );

        final json = original.toJson();
        expect(json.containsKey('renderData'), isTrue);

        final restored = Stroke.fromJson(json);
        expect(restored.renderData, isNotNull);
        expect(restored.renderData!.length, equals(2));
        expect(restored.points.length, equals(5));
      });

      test('JSON round-trip without renderData (null)', () {
        final original = makeStroke();
        final json = original.toJson();
        expect(json.containsKey('renderData'), isFalse);

        final restored = Stroke.fromJson(json);
        expect(restored.renderData, isNull);
      });

      test('renderData stores normalized coordinates', () {
        final render = [
          const RenderPoint(x: 0.25, y: 0.75, pressure: 0.6),
        ];

        final stroke = Stroke(
          id: 's1',
          pageId: 'page-1',
          tool: ToolType.pen,
          color: 0xFF000000,
          weight: 2.0,
          opacity: 1.0,
          points: [makePoint(250, 750)],
          renderData: render,
          createdAt: DateTime.utc(2024, 1, 1),
        );

        expect(stroke.renderData, same(render));
        expect(stroke.renderData!.first.x, closeTo(0.25, 0.001));
        expect(stroke.renderData!.first.y, closeTo(0.75, 0.001));
      });

      test('renderData is null when not provided', () {
        final stroke = makeStroke();
        expect(stroke.renderData, isNull);
      });

      test('DB map round-trip with renderData', () {
        final rawPoints = [
          makePoint(0, 0, timestamp: 0),
          makePoint(50, 50, timestamp: 1000),
          makePoint(100, 0, timestamp: 2000),
        ];
        final render = [
          const RenderPoint(x: 0.0, y: 0.0, pressure: 0.5),
          const RenderPoint(x: 0.5, y: 0.5, pressure: 0.7),
          const RenderPoint(x: 1.0, y: 0.0, pressure: 0.5),
        ];

        final original = Stroke(
          id: 'db-render',
          pageId: 'page-1',
          tool: ToolType.pencil,
          color: 0xFF333333,
          weight: 3.0,
          opacity: 0.8,
          points: rawPoints,
          renderData: render,
          createdAt: DateTime.utc(2024, 6, 1),
        );

        final dbMap = original.toDbMap();
        expect(dbMap['render_points_blob'], isNotNull);

        final restored = Stroke.fromDbMap(dbMap);
        expect(restored.renderData, isNotNull);
        expect(restored.renderData!.length, equals(3));
        expect(restored.points.length, equals(3));
        // Verify render point values survive binary round-trip
        expect(restored.renderData![1].x, closeTo(0.5, 0.001));
        expect(restored.renderData![1].pressure, closeTo(0.7, 0.001));
      });

      test('DB map round-trip without renderData', () {
        final original = makeStroke();
        final dbMap = original.toDbMap();
        expect(dbMap['render_points_blob'], isNull);

        final restored = Stroke.fromDbMap(dbMap);
        expect(restored.renderData, isNull);
      });

      test('tombstone has no renderData', () {
        final tombstone = Stroke.tombstone(
          id: 'ts-1',
          pageId: 'page-1',
          targetStrokeId: 'target-1',
          createdAt: DateTime.utc(2024, 1, 1),
        );
        expect(tombstone.renderData, isNull);
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
