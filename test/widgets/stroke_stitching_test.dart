import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/services/drawing_service.dart';

void main() {
  StrokePoint makePoint(double x, double y,
      {double pressure = 0.5, int timestamp = 0}) {
    return StrokePoint(
      x: x,
      y: y,
      pressure: pressure,
      tiltX: 0.0,
      tiltY: 0.0,
      twist: 0.0,
      timestamp: timestamp,
    );
  }

  group('stroke stitching via DrawingService', () {
    late DrawingService service;

    setUp(() {
      service = DrawingService();
    });

    test('stitchPoint prepends bridge point to new stroke', () {
      final stitchPt = makePoint(100, 100, timestamp: 1000);
      final newPt = makePoint(105, 105, timestamp: 2000);

      service.onPointerDown(
        strokeId: 's1',
        pageId: 'p1',
        point: newPt,
        stitchPoint: stitchPt,
      );

      final inflight = service.inflightStroke!;
      expect(inflight.points.length, equals(2));
      // First point is the stitch (bridge) point
      expect(inflight.points[0].x, equals(100));
      expect(inflight.points[0].y, equals(100));
      // Second point is the actual pen-down position
      expect(inflight.points[1].x, equals(105));
      expect(inflight.points[1].y, equals(105));
    });

    test('without stitchPoint, stroke starts with 1 point', () {
      service.onPointerDown(
        strokeId: 's1',
        pageId: 'p1',
        point: makePoint(50, 50),
      );

      expect(service.inflightStroke!.points.length, equals(1));
    });

    test('stitched stroke moves carry both stitch and new points', () {
      service.onPointerDown(
        strokeId: 's1',
        pageId: 'p1',
        point: makePoint(105, 105, timestamp: 2000),
        stitchPoint: makePoint(100, 100, timestamp: 1000),
      );

      service.onPointerMove(makePoint(110, 110, timestamp: 3000));
      service.onPointerMove(makePoint(115, 115, timestamp: 4000));

      final inflight = service.inflightStroke!;
      expect(inflight.points.length, equals(4));
      // stitch, pen-down, move1, move2
      expect(inflight.points[0].x, equals(100)); // stitch
      expect(inflight.points[1].x, equals(105)); // pen-down
      expect(inflight.points[2].x, equals(110)); // move1
      expect(inflight.points[3].x, equals(115)); // move2
    });

    test('stitched stroke commits with stitch point intact', () {
      service.onPointerDown(
        strokeId: 's1',
        pageId: 'p1',
        point: makePoint(105, 105),
        stitchPoint: makePoint(100, 100),
      );
      service.onPointerMove(makePoint(110, 110));

      final committed = service.onPointerUp()!;
      expect(committed.points.length, equals(3));
      expect(committed.points[0].x, equals(100)); // stitch preserved
    });

    test('stitch point preserves pressure from previous stroke end', () {
      final stitchPt = makePoint(100, 100, pressure: 0.3, timestamp: 1000);
      final newPt = makePoint(105, 105, pressure: 0.7, timestamp: 2000);

      service.onPointerDown(
        strokeId: 's1',
        pageId: 'p1',
        point: newPt,
        stitchPoint: stitchPt,
      );

      final inflight = service.inflightStroke!;
      expect(inflight.points[0].pressure, equals(0.3)); // from prev stroke
      expect(inflight.points[1].pressure, equals(0.7)); // new stroke
    });

    test('consecutive strokes can be independently stitched', () {
      // First stroke
      service.onPointerDown(
        strokeId: 's1',
        pageId: 'p1',
        point: makePoint(0, 0),
      );
      service.onPointerMove(makePoint(10, 10));
      final first = service.onPointerUp()!;
      expect(first.points.length, equals(2));

      // Second stroke stitched to first
      service.onPointerDown(
        strokeId: 's2',
        pageId: 'p1',
        point: makePoint(12, 12),
        stitchPoint: first.points.last,
      );
      service.onPointerMove(makePoint(20, 20));
      final second = service.onPointerUp()!;
      expect(second.points.length, equals(3)); // stitch + down + move
      expect(second.points[0].x, equals(10)); // stitch from first.last

      // Third stroke stitched to second
      service.onPointerDown(
        strokeId: 's3',
        pageId: 'p1',
        point: makePoint(22, 22),
        stitchPoint: second.points.last,
      );
      service.onPointerMove(makePoint(30, 30));
      final third = service.onPointerUp()!;
      expect(third.points.length, equals(3)); // stitch + down + move
      expect(third.points[0].x, equals(20)); // stitch from second.last
    });
  });
}
