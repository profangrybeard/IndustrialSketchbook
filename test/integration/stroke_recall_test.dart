import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:industrial_sketchbook/models/chapter.dart';
import 'package:industrial_sketchbook/models/notebook.dart';
import 'package:industrial_sketchbook/models/sketch_page.dart';
import 'package:industrial_sketchbook/models/stroke.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/models/tool_type.dart';
import 'package:industrial_sketchbook/services/database_service.dart';
import 'package:industrial_sketchbook/models/undo_action.dart';
import 'package:industrial_sketchbook/services/drawing_service.dart';

void main() {
  // Use sqflite_ffi for desktop testing (no Android needed)
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late DrawingService drawingService;

  const testNotebookId = 'test-notebook';
  const testChapterId = 'test-chapter';
  const testPageId = 'test-page';

  /// Helper to create a StrokePoint at a given position.
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

  /// Helper: draw a stroke via the DrawingService and persist to DB.
  Future<Stroke> drawAndPersist(
    String strokeId,
    List<StrokePoint> points,
  ) async {
    drawingService.onPointerDown(
      strokeId: strokeId,
      pageId: testPageId,
      point: points.first,
    );
    for (int i = 1; i < points.length; i++) {
      drawingService.onPointerMove(points[i]);
    }
    final committed = drawingService.onPointerUp()!;
    await db.insertStroke(committed);
    return committed;
  }

  setUp(() async {
    db = DatabaseService();
    await db.initialize(path: inMemoryDatabasePath);
    drawingService = DrawingService();

    // Seed the foreign key chain: notebook → chapter → page
    await db.insertNotebook(const Notebook(
      id: testNotebookId,
      title: 'Test Notebook',
      ownerId: 'local',
    ));
    await db.insertChapter(const Chapter(
      id: testChapterId,
      notebookId: testNotebookId,
      title: 'Test Chapter',
      order: 0,
    ));
    await db.insertPage(const SketchPage(
      id: testPageId,
      chapterId: testChapterId,
      pageNumber: 0,
    ));
  });

  tearDown(() async {
    await db.close();
  });

  group('Stroke Recall (SAV) — Layer 1', () {
    // SAV-001: Strokes survive simulated restart
    test('SAV-001: strokes survive app restart', () async {
      // Draw 3 strokes and persist
      await drawAndPersist('s1', [
        makePoint(10, 10, timestamp: 1000),
        makePoint(20, 20, timestamp: 2000),
      ]);
      await drawAndPersist('s2', [
        makePoint(30, 30, timestamp: 3000),
        makePoint(40, 40, timestamp: 4000),
      ]);
      await drawAndPersist('s3', [
        makePoint(50, 50, timestamp: 5000),
        makePoint(60, 60, timestamp: 6000),
      ]);

      expect(drawingService.committedStrokes.length, equals(3));

      // --- Simulate app restart ---
      // Create a fresh DrawingService (like the app would on cold start)
      final freshService = DrawingService();
      expect(freshService.committedStrokes.length, equals(0));

      // Load strokes from database (this is the path we're wiring)
      final strokes = await db.getStrokesByPageId(testPageId);
      freshService.loadStrokes(strokes);

      // Assert: all 3 strokes loaded
      expect(freshService.committedStrokes.length, equals(3));
      expect(freshService.committedStrokes[0].id, equals('s1'));
      expect(freshService.committedStrokes[1].id, equals('s2'));
      expect(freshService.committedStrokes[2].id, equals('s3'));
    });

    // SAV-002: Stroke order preserved across restart
    test('SAV-002: stroke order preserved across restart', () async {
      // Draw 5 strokes in known order
      for (int i = 0; i < 5; i++) {
        await drawAndPersist('stroke-$i', [
          makePoint(i * 10.0, i * 10.0, timestamp: i * 1000),
          makePoint(i * 10.0 + 5, i * 10.0 + 5, timestamp: i * 1000 + 500),
        ]);
      }

      // Verify page_stroke_order in DB
      final orderRows = await db.getPageStrokeOrder(testPageId);
      expect(orderRows.length, equals(5));
      for (int i = 0; i < 5; i++) {
        expect(orderRows[i]['stroke_id'], equals('stroke-$i'));
        expect(orderRows[i]['sort_order'], equals(i));
      }

      // Simulate restart — load into fresh service
      final freshService = DrawingService();
      final strokes = await db.getStrokesByPageId(testPageId);
      freshService.loadStrokes(strokes);

      // Assert order matches
      expect(freshService.committedStrokes.length, equals(5));
      for (int i = 0; i < 5; i++) {
        expect(freshService.committedStrokes[i].id, equals('stroke-$i'));
      }
    });

    // SAV-003: Tombstones survive restart and erased strokes remain hidden
    test('SAV-003: tombstones survive restart', () async {
      // Draw a stroke
      await drawAndPersist('s1', [
        makePoint(10, 10, timestamp: 1000),
        makePoint(20, 20, timestamp: 2000),
      ]);

      // Erase it (create tombstone)
      final tombstone = Stroke.tombstone(
        id: 'tombstone-1',
        pageId: testPageId,
        targetStrokeId: 's1',
        createdAt: DateTime.now().toUtc(),
      );
      drawingService.addCommittedStrokes([tombstone]);
      await db.insertStroke(tombstone);

      // Verify: original still in memory, tombstone marks it erased
      expect(drawingService.erasedStrokeIds, contains('s1'));

      // --- Simulate restart ---
      final freshService = DrawingService();
      final strokes = await db.getStrokesByPageId(testPageId);
      freshService.loadStrokes(strokes);

      // Assert: both rows loaded, erased set recomputed
      expect(freshService.committedStrokes.length, equals(2)); // original + tombstone
      expect(freshService.erasedStrokeIds, contains('s1'));

      // Verify the original stroke is hidden but present
      final visible = freshService.committedStrokes
          .where((s) =>
              !s.isTombstone && !freshService.erasedStrokeIds.contains(s.id))
          .toList();
      expect(visible, isEmpty); // s1 is erased — no visible strokes
    });

    // SAV-004: Load latency under target for large page
    test('SAV-004: large page loads within target latency', () async {
      // Create 500 strokes with 50 points each (25,000 total points)
      for (int s = 0; s < 500; s++) {
        final points = <StrokePoint>[];
        for (int p = 0; p < 50; p++) {
          points.add(makePoint(
            s * 10.0 + p * 0.2,
            s * 10.0 + p * 0.2,
            timestamp: s * 100000 + p * 1000,
          ));
        }

        final stroke = Stroke(
          id: 'perf-stroke-$s',
          pageId: testPageId,
          tool: ToolType.pencil,
          color: 0xFF000000,
          weight: 2.0,
          opacity: 1.0,
          points: points,
          createdAt: DateTime.now().toUtc(),
        );
        await db.insertStroke(stroke);
      }

      // Measure load time
      final stopwatch = Stopwatch()..start();
      final strokes = await db.getStrokesByPageId(testPageId);
      final freshService = DrawingService();
      freshService.loadStrokes(strokes);
      stopwatch.stop();

      expect(freshService.committedStrokes.length, equals(500));
      // Target: < 500ms (generous for CI; real device should be < 100ms)
      expect(stopwatch.elapsedMilliseconds, lessThan(500));
    });

    // SAV-005: Empty page loads without error
    test('SAV-005: empty page loads without error', () async {
      final strokes = await db.getStrokesByPageId(testPageId);
      expect(strokes, isEmpty);

      final freshService = DrawingService();
      freshService.loadStrokes(strokes);

      expect(freshService.committedStrokes, isEmpty);
      expect(freshService.inflightStroke, isNull);
      expect(freshService.strokeVersion, greaterThanOrEqualTo(0));
    });

    // SAV-006: loadStrokes clears undo history
    test('SAV-006: loadStrokes clears undo history', () async {
      // Build up undo history
      await drawAndPersist('s1', [
        makePoint(10, 10),
        makePoint(20, 20),
      ]);
      drawingService.pushUndoAction(
        UndoAction(strokesAdded: drawingService.committedStrokes.toList()),
      );
      expect(drawingService.canUndo, isTrue);

      // Load strokes (simulates page navigation or restart)
      final strokes = await db.getStrokesByPageId(testPageId);
      drawingService.loadStrokes(strokes);

      // Undo history cleared
      expect(drawingService.canUndo, isFalse);
      expect(drawingService.canRedo, isFalse);
    });

    // SAV-007: Stroke point data integrity through DB round-trip
    test('SAV-007: stroke point data survives DB round-trip', () async {
      // Draw a stroke with specific pressure/tilt values
      final originalPoints = [
        StrokePoint(
          x: 100.5,
          y: 200.75,
          pressure: 0.73,
          tiltX: 15.5,
          tiltY: -8.2,
          twist: 45.0,
          timestamp: 1234567890,
        ),
        StrokePoint(
          x: 110.3,
          y: 210.9,
          pressure: 0.85,
          tiltX: 12.0,
          tiltY: -5.1,
          twist: 48.0,
          timestamp: 1234568890,
        ),
      ];

      await drawAndPersist('precise-stroke', originalPoints);

      // Load from DB
      final strokes = await db.getStrokesByPageId(testPageId);
      expect(strokes.length, equals(1));

      final loaded = strokes.first;
      expect(loaded.points.length, equals(2));

      // Verify point data within Float32 precision
      for (int i = 0; i < originalPoints.length; i++) {
        final orig = originalPoints[i];
        final load = loaded.points[i];
        expect(load.x, closeTo(orig.x, 0.01));
        expect(load.y, closeTo(orig.y, 0.01));
        expect(load.pressure, closeTo(orig.pressure, 0.001));
        expect(load.tiltX, closeTo(orig.tiltX, 0.1));
        expect(load.tiltY, closeTo(orig.tiltY, 0.1));
        expect(load.twist, closeTo(orig.twist, 0.1));
        expect(load.timestamp, equals(orig.timestamp));
      }

      // Verify stroke metadata
      expect(loaded.id, equals('precise-stroke'));
      expect(loaded.pageId, equals(testPageId));
      expect(loaded.tool, equals(ToolType.pencil));
      expect(loaded.color, equals(0xFF000000));
      expect(loaded.weight, closeTo(2.0, 0.001));
      expect(loaded.opacity, closeTo(1.0, 0.001));
    });
  });
}
