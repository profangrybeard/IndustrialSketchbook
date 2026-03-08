import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:industrial_sketchbook/models/chapter.dart';
import 'package:industrial_sketchbook/models/notebook.dart';
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
  const chapterAId = 'chapter-a';

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

    // Seed: notebook → chapter A (order 0) → page-a1
    await db.insertNotebook(const Notebook(
      id: testNotebookId,
      title: 'Test Notebook',
      ownerId: 'local',
    ));
    await db.insertChapter(const Chapter(
      id: chapterAId,
      notebookId: testNotebookId,
      title: 'Chapter A',
      order: 0,
    ));
    await db.insertPage(const SketchPage(
      id: 'page-a1',
      chapterId: chapterAId,
      pageNumber: 0,
    ));
  });

  tearDown(() async {
    await db.close();
  });

  group('Chapter CRUD (CHT) — Layer 4a', () {
    // CHT-001: Create chapter assigns next sort_order
    test('CHT-001: create chapter assigns next sort_order', () async {
      // Chapter A exists at order 0
      await db.insertChapter(const Chapter(
        id: 'chapter-b',
        notebookId: testNotebookId,
        title: 'Chapter B',
        order: 1,
      ));

      final chapterB = await db.getChapter('chapter-b');
      expect(chapterB, isNotNull);
      expect(chapterB!.order, equals(1));
    });

    // CHT-002: getChaptersByNotebook returns chapters in sort_order
    test('CHT-002: getChaptersByNotebook returns chapters in sort_order',
        () async {
      // Insert chapters out of order
      await db.insertChapter(const Chapter(
        id: 'chapter-c',
        notebookId: testNotebookId,
        title: 'Chapter C',
        order: 2,
      ));
      await db.insertChapter(const Chapter(
        id: 'chapter-b',
        notebookId: testNotebookId,
        title: 'Chapter B',
        order: 1,
      ));

      final chapters = await db.getChaptersByNotebook(testNotebookId);
      expect(chapters.length, equals(3));
      expect(chapters[0].id, equals(chapterAId)); // order 0
      expect(chapters[1].id, equals('chapter-b')); // order 1
      expect(chapters[2].id, equals('chapter-c')); // order 2
    });

    // CHT-003: updateChapter changes title
    test('CHT-003: updateChapter changes title', () async {
      var chapter = await db.getChapter(chapterAId);
      expect(chapter!.title, equals('Chapter A'));

      await db.updateChapter(chapter.copyWith(title: 'Renamed Chapter'));

      chapter = await db.getChapter(chapterAId);
      expect(chapter!.title, equals('Renamed Chapter'));
    });

    // CHT-004: updateChapter changes color
    test('CHT-004: updateChapter changes color', () async {
      var chapter = await db.getChapter(chapterAId);
      final originalColor = chapter!.color;

      const newColor = 0xFFFF5722; // deep orange
      await db.updateChapter(chapter.copyWith(color: newColor));

      chapter = await db.getChapter(chapterAId);
      expect(chapter!.color, equals(newColor));
      expect(chapter.color, isNot(equals(originalColor)));
    });

    // CHT-005: deleteChapter removes chapter record
    test('CHT-005: deleteChapter removes chapter record', () async {
      // Need at least 2 chapters (can't delete last one)
      await db.insertChapter(const Chapter(
        id: 'chapter-b',
        notebookId: testNotebookId,
        title: 'Chapter B',
        order: 1,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-b1',
        chapterId: 'chapter-b',
        pageNumber: 0,
      ));

      final result = await db.deleteChapter('chapter-b');
      expect(result, isTrue);

      final deleted = await db.getChapter('chapter-b');
      expect(deleted, isNull);
    });

    // CHT-006: deleteChapter cascade-removes pages and their strokes
    test('CHT-006: deleteChapter cascade-removes pages and strokes', () async {
      // Create chapter B with a page and strokes
      await db.insertChapter(const Chapter(
        id: 'chapter-b',
        notebookId: testNotebookId,
        title: 'Chapter B',
        order: 1,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-b1',
        chapterId: 'chapter-b',
        pageNumber: 0,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-b2',
        chapterId: 'chapter-b',
        pageNumber: 1,
      ));

      // Draw strokes on both pages
      await persistStroke(
        'stroke-b1',
        'page-b1',
        [makePoint(10, 10), makePoint(20, 20)],
      );
      await persistStroke(
        'stroke-b2',
        'page-b2',
        [makePoint(30, 30), makePoint(40, 40)],
      );

      // Verify data exists
      expect(await db.getPage('page-b1'), isNotNull);
      expect(await db.getPage('page-b2'), isNotNull);
      expect((await db.getStrokesByPageId('page-b1')).length, equals(1));
      expect((await db.getStrokesByPageId('page-b2')).length, equals(1));

      // Delete chapter B
      await db.deleteChapter('chapter-b');

      // Verify cascade: pages gone
      expect(await db.getPage('page-b1'), isNull);
      expect(await db.getPage('page-b2'), isNull);

      // Verify cascade: strokes gone
      expect((await db.getStrokesByPageId('page-b1')).length, equals(0));
      expect((await db.getStrokesByPageId('page-b2')).length, equals(0));

      // Verify cascade: individual strokes gone
      expect(await db.getStroke('stroke-b1'), isNull);
      expect(await db.getStroke('stroke-b2'), isNull);

      // Verify cascade: stroke order gone
      expect((await db.getPageStrokeOrder('page-b1')).length, equals(0));
      expect((await db.getPageStrokeOrder('page-b2')).length, equals(0));
    });

    // CHT-007: deleteChapter does NOT affect other chapters
    test('CHT-007: deleteChapter does not affect other chapters', () async {
      // Create chapter B
      await db.insertChapter(const Chapter(
        id: 'chapter-b',
        notebookId: testNotebookId,
        title: 'Chapter B',
        order: 1,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-b1',
        chapterId: 'chapter-b',
        pageNumber: 0,
      ));

      // Draw on chapter A's page
      await persistStroke(
        'stroke-a1',
        'page-a1',
        [makePoint(10, 10), makePoint(20, 20)],
      );

      // Draw on chapter B's page
      await persistStroke(
        'stroke-b1',
        'page-b1',
        [makePoint(30, 30), makePoint(40, 40)],
      );

      // Delete chapter B
      await db.deleteChapter('chapter-b');

      // Chapter A is untouched
      final chapterA = await db.getChapter(chapterAId);
      expect(chapterA, isNotNull);
      expect(chapterA!.title, equals('Chapter A'));

      // Chapter A's page is untouched
      final pageA1 = await db.getPage('page-a1');
      expect(pageA1, isNotNull);

      // Chapter A's strokes are untouched
      final strokes = await db.getStrokesByPageId('page-a1');
      expect(strokes.length, equals(1));
      expect(strokes.first.id, equals('stroke-a1'));
    });

    // CHT-008: Cannot delete last chapter in notebook
    test('CHT-008: cannot delete last chapter in notebook', () async {
      // Only chapter A exists
      expect(await db.getChapterCount(testNotebookId), equals(1));

      final result = await db.deleteChapter(chapterAId);
      expect(result, isFalse);

      // Chapter still exists
      final chapter = await db.getChapter(chapterAId);
      expect(chapter, isNotNull);
    });

    // CHT-009: reorderChapters updates sort_order correctly
    test('CHT-009: reorderChapters updates sort_order correctly', () async {
      // Create chapters B and C
      await db.insertChapter(const Chapter(
        id: 'chapter-b',
        notebookId: testNotebookId,
        title: 'Chapter B',
        order: 1,
      ));
      await db.insertChapter(const Chapter(
        id: 'chapter-c',
        notebookId: testNotebookId,
        title: 'Chapter C',
        order: 2,
      ));

      // Reorder: C, A, B
      await db.reorderChapters(['chapter-c', chapterAId, 'chapter-b']);

      final chapters = await db.getChaptersByNotebook(testNotebookId);
      expect(chapters.length, equals(3));
      expect(chapters[0].id, equals('chapter-c')); // now order 0
      expect(chapters[1].id, equals(chapterAId)); // now order 1
      expect(chapters[2].id, equals('chapter-b')); // now order 2
    });

    // CHT-010: movePageToChapter re-parents page to new chapter
    test('CHT-010: movePageToChapter re-parents page to new chapter',
        () async {
      // Create chapter B
      await db.insertChapter(const Chapter(
        id: 'chapter-b',
        notebookId: testNotebookId,
        title: 'Chapter B',
        order: 1,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-b1',
        chapterId: 'chapter-b',
        pageNumber: 0,
      ));

      // Add a second page to chapter A so moving page-a1 doesn't leave it empty
      await db.insertPage(const SketchPage(
        id: 'page-a2',
        chapterId: chapterAId,
        pageNumber: 1,
      ));

      // Move page-a1 to chapter B at position 1
      await db.movePageToChapter('page-a1', 'chapter-b', 1);

      // Verify page-a1 is now in chapter B
      final movedPage = await db.getPage('page-a1');
      expect(movedPage!.chapterId, equals('chapter-b'));
      expect(movedPage.pageNumber, equals(1));

      // Verify chapter B has 2 pages
      final chapterBPages = await db.getPagesByChapter('chapter-b');
      expect(chapterBPages.length, equals(2));
      expect(chapterBPages[0].id, equals('page-b1')); // pageNumber 0
      expect(chapterBPages[1].id, equals('page-a1')); // pageNumber 1
    });

    // CHT-011: movePageToChapter re-numbers old chapter (closes gap)
    test('CHT-011: movePageToChapter re-numbers old chapter (closes gap)',
        () async {
      // Create 3 pages in chapter A: page-a1 (0), page-a2 (1), page-a3 (2)
      await db.insertPage(const SketchPage(
        id: 'page-a2',
        chapterId: chapterAId,
        pageNumber: 1,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-a3',
        chapterId: chapterAId,
        pageNumber: 2,
      ));

      // Create chapter B with one page
      await db.insertChapter(const Chapter(
        id: 'chapter-b',
        notebookId: testNotebookId,
        title: 'Chapter B',
        order: 1,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-b1',
        chapterId: 'chapter-b',
        pageNumber: 0,
      ));

      // Move page-a2 (middle page) to chapter B
      await db.movePageToChapter('page-a2', 'chapter-b', 1);

      // Chapter A should now have contiguous numbering: page-a1(0), page-a3(1)
      final chapterAPages = await db.getPagesByChapter(chapterAId);
      expect(chapterAPages.length, equals(2));
      expect(chapterAPages[0].id, equals('page-a1'));
      expect(chapterAPages[0].pageNumber, equals(0));
      expect(chapterAPages[1].id, equals('page-a3'));
      expect(chapterAPages[1].pageNumber, equals(1)); // shifted down from 2
    });

    // CHT-012: movePageToChapter assigns correct pageNumber in new chapter
    test('CHT-012: movePageToChapter assigns correct pageNumber in new chapter',
        () async {
      // Chapter B with 2 pages: page-b1 (0), page-b2 (1)
      await db.insertChapter(const Chapter(
        id: 'chapter-b',
        notebookId: testNotebookId,
        title: 'Chapter B',
        order: 1,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-b1',
        chapterId: 'chapter-b',
        pageNumber: 0,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-b2',
        chapterId: 'chapter-b',
        pageNumber: 1,
      ));

      // Add second page in chapter A so it won't be empty
      await db.insertPage(const SketchPage(
        id: 'page-a2',
        chapterId: chapterAId,
        pageNumber: 1,
      ));

      // Move page-a1 to chapter B at position 1 (between b1 and b2)
      await db.movePageToChapter('page-a1', 'chapter-b', 1);

      // Chapter B pages: page-b1(0), page-a1(1), page-b2(2)
      final chapterBPages = await db.getPagesByChapter('chapter-b');
      expect(chapterBPages.length, equals(3));
      expect(chapterBPages[0].id, equals('page-b1'));
      expect(chapterBPages[0].pageNumber, equals(0));
      expect(chapterBPages[1].id, equals('page-a1'));
      expect(chapterBPages[1].pageNumber, equals(1));
      expect(chapterBPages[2].id, equals('page-b2'));
      expect(chapterBPages[2].pageNumber, equals(2)); // shifted up from 1
    });

    // CHT-013: getChapterCount accurate after create/delete
    test('CHT-013: getChapterCount accurate after create/delete', () async {
      expect(await db.getChapterCount(testNotebookId), equals(1));

      // Add two chapters
      await db.insertChapter(const Chapter(
        id: 'chapter-b',
        notebookId: testNotebookId,
        title: 'Chapter B',
        order: 1,
      ));
      await db.insertChapter(const Chapter(
        id: 'chapter-c',
        notebookId: testNotebookId,
        title: 'Chapter C',
        order: 2,
      ));
      expect(await db.getChapterCount(testNotebookId), equals(3));

      // Delete one (needs a page first)
      await db.insertPage(const SketchPage(
        id: 'page-b1',
        chapterId: 'chapter-b',
        pageNumber: 0,
      ));
      await db.deleteChapter('chapter-b');
      expect(await db.getChapterCount(testNotebookId), equals(2));

      // Count for non-existent notebook is 0
      expect(await db.getChapterCount('no-such-notebook'), equals(0));
    });

    // CHT-014: Delete nonexistent chapter returns false
    test('CHT-014: delete nonexistent chapter returns false', () async {
      final result = await db.deleteChapter('no-such-chapter');
      expect(result, isFalse);
    });
  });
}
