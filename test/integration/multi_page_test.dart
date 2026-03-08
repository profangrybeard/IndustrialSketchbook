import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:industrial_sketchbook/models/chapter.dart';
import 'package:industrial_sketchbook/models/grid_config.dart';
import 'package:industrial_sketchbook/models/notebook.dart';
import 'package:industrial_sketchbook/models/page_style.dart';
import 'package:industrial_sketchbook/models/sketch_page.dart';
import 'package:industrial_sketchbook/models/stroke.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/models/tool_type.dart';
import 'package:industrial_sketchbook/services/database_service.dart';
import 'package:industrial_sketchbook/services/drawing_service.dart';

void main() {
  // Use sqflite_ffi for desktop testing (no Android needed)
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late DrawingService drawingService;

  const testNotebookId = 'test-notebook';
  const testChapterId = 'test-chapter';
  const pageAId = 'page-a';

  /// Helper to create a StrokePoint.
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

  /// Helper: create a stroke and persist to DB for a given page.
  Future<Stroke> persistStroke(
    String strokeId,
    String pageId,
    List<StrokePoint> points,
  ) async {
    drawingService.onPointerDown(
      strokeId: strokeId,
      pageId: pageId,
      point: points.first,
    );
    for (int i = 1; i < points.length; i++) {
      drawingService.onPointerMove(points[i]);
    }
    final committed = drawingService.onPointerUp()!;
    await db.insertStroke(committed);
    // Clear drawing service so strokes don't accumulate across helpers
    drawingService.clear();
    drawingService.clearUndoHistory();
    return committed;
  }

  setUp(() async {
    db = DatabaseService();
    await db.initialize(path: inMemoryDatabasePath);
    drawingService = DrawingService();

    // Seed foreign key chain: notebook → chapter → page A
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
      id: pageAId,
      chapterId: testChapterId,
      pageNumber: 0,
    ));
  });

  tearDown(() async {
    await db.close();
  });

  group('Multi-Page Data Operations (MPG) — Layer 3a', () {
    // MPG-001: Create second page with auto-assigned pageNumber
    test('MPG-001: new page gets next sequential pageNumber', () async {
      // Page A already exists at pageNumber 0
      final count = await db.getPageCount(testChapterId);
      expect(count, equals(1));

      // Create page B at the next position
      await db.insertPage(SketchPage(
        id: 'page-b',
        chapterId: testChapterId,
        pageNumber: count, // Should be 1
      ));

      final newCount = await db.getPageCount(testChapterId);
      expect(newCount, equals(2));

      final pageB = await db.getPage('page-b');
      expect(pageB!.pageNumber, equals(1));
    });

    // MPG-002: Pages returned in pageNumber order
    test('MPG-002: getPagesByChapter returns pages ordered by pageNumber',
        () async {
      // Insert pages out of order
      await db.insertPage(const SketchPage(
        id: 'page-c',
        chapterId: testChapterId,
        pageNumber: 2,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-b',
        chapterId: testChapterId,
        pageNumber: 1,
      ));

      final pages = await db.getPagesByChapter(testChapterId);
      expect(pages.length, equals(3));
      expect(pages[0].id, equals(pageAId)); // pageNumber 0
      expect(pages[1].id, equals('page-b')); // pageNumber 1
      expect(pages[2].id, equals('page-c')); // pageNumber 2
    });

    // MPG-003: Strokes isolated between pages
    test('MPG-003: strokes on page A do not appear on page B', () async {
      // Create page B
      await db.insertPage(const SketchPage(
        id: 'page-b',
        chapterId: testChapterId,
        pageNumber: 1,
      ));

      // Draw strokes on page A
      await persistStroke(
        'stroke-a1',
        pageAId,
        [makePoint(10, 10), makePoint(20, 20), makePoint(30, 30)],
      );
      await persistStroke(
        'stroke-a2',
        pageAId,
        [makePoint(40, 40), makePoint(50, 50)],
      );

      // Draw a stroke on page B
      await persistStroke(
        'stroke-b1',
        'page-b',
        [makePoint(100, 100), makePoint(200, 200)],
      );

      // Verify isolation
      final pageAStrokes = await db.getStrokesByPageId(pageAId);
      expect(pageAStrokes.length, equals(2));
      expect(pageAStrokes.map((s) => s.id), containsAll(['stroke-a1', 'stroke-a2']));

      final pageBStrokes = await db.getStrokesByPageId('page-b');
      expect(pageBStrokes.length, equals(1));
      expect(pageBStrokes.first.id, equals('stroke-b1'));
    });

    // MPG-004: New page starts with default settings
    test('MPG-004: new page has correct defaults', () async {
      await db.insertPage(const SketchPage(
        id: 'page-fresh',
        chapterId: testChapterId,
        pageNumber: 1,
      ));

      final page = await db.getPage('page-fresh');
      expect(page, isNotNull);
      expect(page!.style, equals(PageStyle.plain));
      expect(page.gridConfig, isNull);
      expect(page.paperColor, equals(0xFFF5F5F0));
      expect(page.layerIds, equals(['default']));
    });

    // MPG-005: deletePage removes the page record
    test('MPG-005: deletePage removes page record', () async {
      // Need at least 2 pages (can't delete last one)
      await db.insertPage(const SketchPage(
        id: 'page-b',
        chapterId: testChapterId,
        pageNumber: 1,
      ));

      final result = await db.deletePage('page-b');
      expect(result, isTrue);

      final deleted = await db.getPage('page-b');
      expect(deleted, isNull);
    });

    // MPG-006: deletePage cascade-removes strokes and stroke order
    test('MPG-006: deletePage cascade-removes strokes and stroke order',
        () async {
      // Create page B with strokes
      await db.insertPage(const SketchPage(
        id: 'page-b',
        chapterId: testChapterId,
        pageNumber: 1,
      ));

      await persistStroke(
        'stroke-b1',
        'page-b',
        [makePoint(10, 10), makePoint(20, 20)],
      );
      await persistStroke(
        'stroke-b2',
        'page-b',
        [makePoint(30, 30), makePoint(40, 40)],
      );

      // Verify strokes exist
      var strokes = await db.getStrokesByPageId('page-b');
      expect(strokes.length, equals(2));

      // Delete the page
      await db.deletePage('page-b');

      // Verify strokes are gone
      strokes = await db.getStrokesByPageId('page-b');
      expect(strokes.length, equals(0));

      // Verify stroke order entries are gone
      final orderRows = await db.getPageStrokeOrder('page-b');
      expect(orderRows.length, equals(0));

      // Verify individual strokes are deleted
      expect(await db.getStroke('stroke-b1'), isNull);
      expect(await db.getStroke('stroke-b2'), isNull);
    });

    // MPG-007: deletePage does NOT affect other pages' strokes
    test('MPG-007: deletePage does not affect other pages\' strokes',
        () async {
      // Create page B
      await db.insertPage(const SketchPage(
        id: 'page-b',
        chapterId: testChapterId,
        pageNumber: 1,
      ));

      // Draw on both pages
      await persistStroke(
        'stroke-a1',
        pageAId,
        [makePoint(10, 10), makePoint(20, 20)],
      );
      await persistStroke(
        'stroke-b1',
        'page-b',
        [makePoint(100, 100), makePoint(200, 200)],
      );

      // Delete page B
      await db.deletePage('page-b');

      // Page A strokes are untouched
      final pageAStrokes = await db.getStrokesByPageId(pageAId);
      expect(pageAStrokes.length, equals(1));
      expect(pageAStrokes.first.id, equals('stroke-a1'));
    });

    // MPG-008: getPageCount accurate after create and delete
    test('MPG-008: getPageCount accurate after create/delete', () async {
      expect(await db.getPageCount(testChapterId), equals(1));

      // Add two pages
      await db.insertPage(const SketchPage(
        id: 'page-b',
        chapterId: testChapterId,
        pageNumber: 1,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-c',
        chapterId: testChapterId,
        pageNumber: 2,
      ));
      expect(await db.getPageCount(testChapterId), equals(3));

      // Delete one
      await db.deletePage('page-b');
      expect(await db.getPageCount(testChapterId), equals(2));

      // Count for non-existent chapter is 0
      expect(await db.getPageCount('no-such-chapter'), equals(0));
    });

    // MPG-009: Cannot delete the last page in a chapter
    test('MPG-009: cannot delete last page in chapter', () async {
      // Only page A exists
      expect(await db.getPageCount(testChapterId), equals(1));

      final result = await db.deletePage(pageAId);
      expect(result, isFalse);

      // Page still exists
      final page = await db.getPage(pageAId);
      expect(page, isNotNull);
    });

    // MPG-010: Page settings are independent across pages
    test('MPG-010: page settings independent across pages', () async {
      // Create page B
      await db.insertPage(const SketchPage(
        id: 'page-b',
        chapterId: testChapterId,
        pageNumber: 1,
      ));

      // Set different settings on each page
      var pageA = await db.getPage(pageAId);
      await db.updatePageSettings(pageA!.copyWith(
        style: PageStyle.dot,
        gridConfig: const GridConfig(spacing: 40.0),
        paperColor: 0xFFFFFFFF,
      ));

      var pageB = await db.getPage('page-b');
      await db.updatePageSettings(pageB!.copyWith(
        style: PageStyle.grid,
        gridConfig: const GridConfig(spacing: 20.0),
        paperColor: 0xFF1A1A2E,
      ));

      // Reload and verify independence
      pageA = await db.getPage(pageAId);
      pageB = await db.getPage('page-b');

      expect(pageA!.style, equals(PageStyle.dot));
      expect(pageA.gridConfig!.spacing, equals(40.0));
      expect(pageA.paperColor, equals(0xFFFFFFFF));

      expect(pageB!.style, equals(PageStyle.grid));
      expect(pageB.gridConfig!.spacing, equals(20.0));
      expect(pageB.paperColor, equals(0xFF1A1A2E));
    });

    // MPG-011: Delete nonexistent page returns false
    test('MPG-011: delete nonexistent page returns false', () async {
      final result = await db.deletePage('no-such-page');
      expect(result, isFalse);
    });

    // MPG-012: Strokes load correctly after page switching simulation
    test('MPG-012: stroke load simulates page switching', () async {
      // Create page B
      await db.insertPage(const SketchPage(
        id: 'page-b',
        chapterId: testChapterId,
        pageNumber: 1,
      ));

      // Draw on page A
      await persistStroke(
        'stroke-a1',
        pageAId,
        [makePoint(10, 10), makePoint(20, 20), makePoint(30, 30)],
      );

      // Draw on page B
      await persistStroke(
        'stroke-b1',
        'page-b',
        [makePoint(100, 100), makePoint(200, 200)],
      );

      // Simulate switching to page A: load strokes
      final pageAStrokes = await db.getStrokesByPageId(pageAId);
      drawingService.loadStrokes(pageAStrokes);
      expect(drawingService.committedStrokes.length, equals(1));
      expect(drawingService.committedStrokes.first.id, equals('stroke-a1'));
      expect(drawingService.canUndo, isFalse); // undo cleared on load

      // Simulate switching to page B
      final pageBStrokes = await db.getStrokesByPageId('page-b');
      drawingService.loadStrokes(pageBStrokes);
      expect(drawingService.committedStrokes.length, equals(1));
      expect(drawingService.committedStrokes.first.id, equals('stroke-b1'));
    });
  });
}
