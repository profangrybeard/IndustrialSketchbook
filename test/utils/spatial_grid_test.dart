import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/stroke.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/models/tool_type.dart';
import 'package:industrial_sketchbook/utils/spatial_grid.dart';

/// Create a minimal non-tombstone Stroke with given bounding box.
Stroke _makeStroke(String id, double x1, double y1, double x2, double y2) {
  return Stroke(
    id: id,
    pageId: 'page-1',
    tool: ToolType.pencil,
    color: 0xFF000000,
    weight: 2.0,
    opacity: 1.0,
    points: [
      StrokePoint(
          x: x1, y: y1, pressure: 0.5, tiltX: 0, tiltY: 0, twist: 0, timestamp: 0),
      StrokePoint(
          x: x2, y: y2, pressure: 0.5, tiltX: 0, tiltY: 0, twist: 0, timestamp: 0),
    ],
    createdAt: DateTime.now(),
  );
}

void main() {
  group('SpatialGrid', () {
    test('GRID-001: insert and query overlapping rect returns stroke', () {
      final grid = SpatialGrid(128, 1200, 800);
      grid.insert('s1', const Rect.fromLTWH(50, 50, 100, 100));

      final result = grid.queryRect(const Rect.fromLTWH(60, 60, 20, 20));
      expect(result, contains('s1'));
    });

    test('GRID-002: query non-overlapping rect returns empty', () {
      final grid = SpatialGrid(128, 1200, 800);
      grid.insert('s1', const Rect.fromLTWH(50, 50, 100, 100));

      final result = grid.queryRect(const Rect.fromLTWH(500, 500, 20, 20));
      expect(result, isEmpty);
    });

    test('GRID-003: many strokes, query returns only overlapping', () {
      final grid = SpatialGrid(128, 1200, 800);
      // Scatter 100 strokes across the canvas
      for (int i = 0; i < 100; i++) {
        final x = (i % 10) * 120.0;
        final y = (i ~/ 10) * 80.0;
        grid.insert('s$i', Rect.fromLTWH(x, y, 50, 50));
      }

      // Query a small area that should only hit a few strokes
      final result = grid.queryRect(const Rect.fromLTWH(0, 0, 60, 60));
      expect(result, contains('s0'));
      // Should not contain distant strokes
      expect(result, isNot(contains('s99')));
    });

    test('GRID-004: remove stroke, no longer returned', () {
      final grid = SpatialGrid(128, 1200, 800);
      grid.insert('s1', const Rect.fromLTWH(50, 50, 100, 100));
      grid.remove('s1');

      final result = grid.queryRect(const Rect.fromLTWH(60, 60, 20, 20));
      expect(result, isEmpty);
    });

    test('GRID-005: stroke spanning multiple cells returned from any cell', () {
      final grid = SpatialGrid(128, 1200, 800);
      // Stroke spans from (0,0) to (400,400) — many cells
      grid.insert('s1', const Rect.fromLTWH(0, 0, 400, 400));

      // Query top-left corner
      final r1 = grid.queryRect(const Rect.fromLTWH(0, 0, 10, 10));
      expect(r1, contains('s1'));

      // Query bottom-right area
      final r2 = grid.queryRect(const Rect.fromLTWH(350, 350, 10, 10));
      expect(r2, contains('s1'));

      // Query middle
      final r3 = grid.queryRect(const Rect.fromLTWH(200, 200, 10, 10));
      expect(r3, contains('s1'));
    });

    test('GRID-006: rebuild matches individual inserts', () {
      final strokes = [
        _makeStroke('s1', 10, 10, 100, 100),
        _makeStroke('s2', 300, 300, 400, 400),
        _makeStroke('s3', 600, 100, 700, 200),
      ];

      // Build via rebuild
      final grid1 = SpatialGrid(128, 1200, 800);
      grid1.rebuild(strokes, {});

      // Build via individual inserts
      final grid2 = SpatialGrid(128, 1200, 800);
      for (final s in strokes) {
        grid2.insert(s.id, s.boundingRect);
      }

      // Query the same rect, both should return same IDs
      final queryRect = const Rect.fromLTWH(0, 0, 150, 150);
      expect(grid1.queryRect(queryRect), equals(grid2.queryRect(queryRect)));

      final queryRect2 = const Rect.fromLTWH(280, 280, 150, 150);
      expect(grid1.queryRect(queryRect2), equals(grid2.queryRect(queryRect2)));
    });

    test('GRID-007: queryPoint with radius', () {
      final grid = SpatialGrid(128, 1200, 800);
      grid.insert('s1', const Rect.fromLTWH(100, 100, 50, 50));

      // Point inside the stroke's bounding rect
      final r1 = grid.queryPoint(const Offset(125, 125), 10);
      expect(r1, contains('s1'));

      // Point far away
      final r2 = grid.queryPoint(const Offset(800, 800), 10);
      expect(r2, isEmpty);
    });

    test('GRID-008: empty grid returns empty set', () {
      final grid = SpatialGrid(128, 1200, 800);
      final result = grid.queryRect(const Rect.fromLTWH(0, 0, 1200, 800));
      expect(result, isEmpty);
    });

    test('GRID-009: strokes on cell boundary belong to adjacent cells', () {
      final grid = SpatialGrid(128, 1200, 800);
      // Place stroke exactly at cell boundary (128, 128)
      grid.insert('s1', const Rect.fromLTWH(120, 120, 16, 16));

      // Query cell (0,0) — should contain s1
      final r1 = grid.queryRect(const Rect.fromLTWH(0, 0, 127, 127));
      expect(r1, contains('s1'));

      // Query cell (1,1) — should also contain s1
      final r2 = grid.queryRect(const Rect.fromLTWH(129, 129, 10, 10));
      expect(r2, contains('s1'));
    });

    test('rebuild skips tombstones and erased strokes', () {
      final strokes = [
        _makeStroke('s1', 10, 10, 100, 100),
        _makeStroke('s2', 200, 200, 300, 300),
        Stroke.tombstone(
          id: 't1',
          pageId: 'page-1',
          targetStrokeId: 's1',
          createdAt: DateTime.now(),
        ),
      ];

      final grid = SpatialGrid(128, 1200, 800);
      grid.rebuild(strokes, {'s1'});

      // s1 is erased, t1 is a tombstone — neither should be in the grid
      final all = grid.queryRect(const Rect.fromLTWH(0, 0, 1200, 800));
      expect(all, equals({'s2'}));
    });

    test('clear removes all entries', () {
      final grid = SpatialGrid(128, 1200, 800);
      grid.insert('s1', const Rect.fromLTWH(50, 50, 100, 100));
      grid.insert('s2', const Rect.fromLTWH(500, 500, 100, 100));
      expect(grid.strokeCount, 2);

      grid.clear();
      expect(grid.strokeCount, 0);
      expect(grid.queryRect(const Rect.fromLTWH(0, 0, 1200, 800)), isEmpty);
    });

    test('strokeCount tracks insertions and removals', () {
      final grid = SpatialGrid(128, 1200, 800);
      expect(grid.strokeCount, 0);

      grid.insert('s1', const Rect.fromLTWH(0, 0, 50, 50));
      expect(grid.strokeCount, 1);

      grid.insert('s2', const Rect.fromLTWH(100, 100, 50, 50));
      expect(grid.strokeCount, 2);

      grid.remove('s1');
      expect(grid.strokeCount, 1);
    });

    test('removing non-existent stroke is a no-op', () {
      final grid = SpatialGrid(128, 1200, 800);
      grid.insert('s1', const Rect.fromLTWH(0, 0, 50, 50));
      grid.remove('nonexistent');
      expect(grid.strokeCount, 1);
    });

    test('negative coordinates handled gracefully', () {
      final grid = SpatialGrid(128, 1200, 800);
      // Stroke partially off-screen (negative coords clamped to cell 0)
      grid.insert('s1', const Rect.fromLTWH(-50, -50, 100, 100));

      final result = grid.queryRect(const Rect.fromLTWH(0, 0, 50, 50));
      expect(result, contains('s1'));
    });
  });
}
