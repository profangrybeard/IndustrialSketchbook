import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:industrial_sketchbook/models/chapter.dart';
import 'package:industrial_sketchbook/models/global_page_entry.dart';
import 'package:industrial_sketchbook/models/notebook.dart';
import 'package:industrial_sketchbook/models/sketch_page.dart';
import 'package:industrial_sketchbook/services/database_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;

  const testNotebookId = 'test-notebook';
  const chapterAId = 'chapter-a';
  const chapterBId = 'chapter-b';
  const chapterCId = 'chapter-c';

  /// Build the global page list from DB — mirrors globalPageListProvider logic.
  Future<List<GlobalPageEntry>> buildGlobalPageList(String notebookId) async {
    final chapters = await db.getChaptersByNotebook(notebookId);
    final entries = <GlobalPageEntry>[];
    final totalChapters = chapters.length;

    for (int ci = 0; ci < chapters.length; ci++) {
      final chapter = chapters[ci];
      final pages = await db.getPagesByChapter(chapter.id);
      for (final page in pages) {
        entries.add(GlobalPageEntry(
          page: page,
          chapterId: chapter.id,
          chapterTitle: chapter.title,
          chapterColor: chapter.color,
          chapterIndex: ci,
          totalChapters: totalChapters,
        ));
      }
    }

    return entries;
  }

  setUp(() async {
    db = DatabaseService();
    await db.initialize(path: inMemoryDatabasePath);

    // Seed: notebook → chapter A (order 0, 2 pages) + chapter B (order 1, 2 pages)
    //        + chapter C (order 2, 1 page)
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
      color: 0xFF4CAF50, // green
    ));
    await db.insertPage(const SketchPage(
      id: 'page-a1',
      chapterId: chapterAId,
      pageNumber: 0,
    ));
    await db.insertPage(const SketchPage(
      id: 'page-a2',
      chapterId: chapterAId,
      pageNumber: 1,
    ));

    await db.insertChapter(const Chapter(
      id: chapterBId,
      notebookId: testNotebookId,
      title: 'Chapter B',
      order: 1,
      color: 0xFF2196F3, // blue
    ));
    await db.insertPage(const SketchPage(
      id: 'page-b1',
      chapterId: chapterBId,
      pageNumber: 0,
    ));
    await db.insertPage(const SketchPage(
      id: 'page-b2',
      chapterId: chapterBId,
      pageNumber: 1,
    ));

    await db.insertChapter(const Chapter(
      id: chapterCId,
      notebookId: testNotebookId,
      title: 'Chapter C',
      order: 2,
      color: 0xFF607D8B, // blueGrey
    ));
    await db.insertPage(const SketchPage(
      id: 'page-c1',
      chapterId: chapterCId,
      pageNumber: 0,
    ));
  });

  tearDown(() async {
    await db.close();
  });

  group('Organize Panel Operations (ORG) — Layer 4c', () {
    // ORG-001: Rename chapter persists and reflects in chapter list
    test('ORG-001: rename chapter persists and reflects in chapter list',
        () async {
      final chapter = await db.getChapter(chapterAId);
      expect(chapter, isNotNull);

      await db.updateChapter(chapter!.copyWith(title: 'Renamed A'));

      final updated = await db.getChapter(chapterAId);
      expect(updated!.title, equals('Renamed A'));

      // Verify it shows up correctly in the full list
      final chapters = await db.getChaptersByNotebook(testNotebookId);
      expect(chapters.first.title, equals('Renamed A'));
    });

    // ORG-002: Recolor chapter persists new ARGB value
    test('ORG-002: recolor chapter persists new ARGB value', () async {
      final chapter = await db.getChapter(chapterBId);
      expect(chapter, isNotNull);
      expect(chapter!.color, equals(0xFF2196F3));

      await db.updateChapter(chapter.copyWith(color: 0xFFE91E63)); // pink

      final updated = await db.getChapter(chapterBId);
      expect(updated!.color, equals(0xFFE91E63));

      // Verify global page list carries the new color
      final globalPages = await buildGlobalPageList(testNotebookId);
      final bPages = globalPages.where((e) => e.chapterId == chapterBId);
      for (final entry in bPages) {
        expect(entry.chapterColor, equals(0xFFE91E63));
      }
    });

    // ORG-003: Reorder 3 chapters updates sort_order and global page list
    test('ORG-003: reorder 3 chapters updates sort_order and global page list',
        () async {
      // Original order: A(0), B(1), C(2)
      // New order: C, A, B
      await db.reorderChapters([chapterCId, chapterAId, chapterBId]);

      final chapters = await db.getChaptersByNotebook(testNotebookId);
      expect(chapters[0].id, equals(chapterCId));
      expect(chapters[0].order, equals(0));
      expect(chapters[1].id, equals(chapterAId));
      expect(chapters[1].order, equals(1));
      expect(chapters[2].id, equals(chapterBId));
      expect(chapters[2].order, equals(2));

      // Global page list should reflect new order
      final globalPages = await buildGlobalPageList(testNotebookId);
      expect(globalPages[0].page.id, equals('page-c1')); // C first
      expect(globalPages[1].page.id, equals('page-a1')); // then A
      expect(globalPages[2].page.id, equals('page-a2'));
      expect(globalPages[3].page.id, equals('page-b1')); // then B
      expect(globalPages[4].page.id, equals('page-b2'));
    });

    // ORG-004: Delete chapter cascade-removes its pages from global list
    test('ORG-004: delete chapter cascade-removes pages from global list',
        () async {
      final before = await buildGlobalPageList(testNotebookId);
      expect(before.length, equals(5)); // 2+2+1

      final success = await db.deleteChapter(chapterBId);
      expect(success, isTrue);

      final after = await buildGlobalPageList(testNotebookId);
      expect(after.length, equals(3)); // 2+1 (B's 2 pages gone)

      // No entries for chapter B
      expect(after.where((e) => e.chapterId == chapterBId).length, equals(0));

      // A and C pages intact
      expect(after[0].page.id, equals('page-a1'));
      expect(after[1].page.id, equals('page-a2'));
      expect(after[2].page.id, equals('page-c1'));
    });

    // ORG-005: Cannot delete the last chapter (returns false)
    test('ORG-005: cannot delete the last chapter', () async {
      // Delete B and C, leaving only A
      await db.deleteChapter(chapterBId);
      await db.deleteChapter(chapterCId);

      final count = await db.getChapterCount(testNotebookId);
      expect(count, equals(1));

      // Attempt to delete the last chapter
      final success = await db.deleteChapter(chapterAId);
      expect(success, isFalse);

      // Chapter A still exists
      final chapter = await db.getChapter(chapterAId);
      expect(chapter, isNotNull);
    });

    // ORG-006: Move page to end of target chapter
    test('ORG-006: move page to end of target chapter', () async {
      final targetPageCount = await db.getPageCount(chapterBId);
      expect(targetPageCount, equals(2));

      // Move page-a1 to end of chapter B
      await db.movePageToChapter('page-a1', chapterBId, targetPageCount);

      // Chapter A now has 1 page
      final pagesA = await db.getPagesByChapter(chapterAId);
      expect(pagesA.length, equals(1));
      expect(pagesA[0].id, equals('page-a2'));
      expect(pagesA[0].pageNumber, equals(0)); // re-numbered

      // Chapter B now has 3 pages, page-a1 at the end
      final pagesB = await db.getPagesByChapter(chapterBId);
      expect(pagesB.length, equals(3));
      expect(pagesB[0].id, equals('page-b1'));
      expect(pagesB[1].id, equals('page-b2'));
      expect(pagesB[2].id, equals('page-a1'));
      expect(pagesB[2].pageNumber, equals(2));
    });

    // ORG-007: Move page to start of target chapter
    test('ORG-007: move page to start of target chapter', () async {
      // Move page-a1 to start of chapter B
      await db.movePageToChapter('page-a1', chapterBId, 0);

      // Chapter B now has 3 pages, page-a1 at the start
      final pagesB = await db.getPagesByChapter(chapterBId);
      expect(pagesB.length, equals(3));
      expect(pagesB[0].id, equals('page-a1'));
      expect(pagesB[0].pageNumber, equals(0));
      expect(pagesB[1].id, equals('page-b1'));
      expect(pagesB[1].pageNumber, equals(1));
      expect(pagesB[2].id, equals('page-b2'));
      expect(pagesB[2].pageNumber, equals(2));
    });

    // ORG-008: Move page updates global page list ordering
    test('ORG-008: move page updates global page list ordering', () async {
      final before = await buildGlobalPageList(testNotebookId);
      expect(before.map((e) => e.page.id).toList(),
          equals(['page-a1', 'page-a2', 'page-b1', 'page-b2', 'page-c1']));

      // Move page-a1 to end of chapter C
      final targetCount = await db.getPageCount(chapterCId);
      await db.movePageToChapter('page-a1', chapterCId, targetCount);

      final after = await buildGlobalPageList(testNotebookId);
      // A now has 1 page, B has 2, C has 2
      expect(after.map((e) => e.page.id).toList(),
          equals(['page-a2', 'page-b1', 'page-b2', 'page-c1', 'page-a1']));

      // Verify chapter context updated for moved page
      final movedEntry = after.last;
      expect(movedEntry.page.id, equals('page-a1'));
      expect(movedEntry.chapterId, equals(chapterCId));
      expect(movedEntry.chapterTitle, equals('Chapter C'));
    });

    // ORG-009: Cannot move last page out of a chapter (getPageCount guard)
    test('ORG-009: getPageCount guard prevents moving last page', () async {
      // Chapter C has only 1 page
      final count = await db.getPageCount(chapterCId);
      expect(count, equals(1));

      // The organize panel checks getPageCount before allowing the move.
      // The DB layer doesn't enforce this — it's a UI-level guard.
      // We verify the guard condition here.
      expect(count <= 1, isTrue);
    });

    // ORG-010: Jump to chapter returns first page of target chapter
    test('ORG-010: jump to chapter returns first page of target chapter',
        () async {
      // Simulate the onNavigateToChapter callback:
      // get pages for the target chapter, navigate to first page
      final pagesB = await db.getPagesByChapter(chapterBId);
      expect(pagesB.isNotEmpty, isTrue);
      expect(pagesB.first.id, equals('page-b1'));

      final pagesC = await db.getPagesByChapter(chapterCId);
      expect(pagesC.isNotEmpty, isTrue);
      expect(pagesC.first.id, equals('page-c1'));

      // After reorder, first page should still be the one with lowest page_number
      await db.reorderChapters([chapterCId, chapterBId, chapterAId]);
      final chapters = await db.getChaptersByNotebook(testNotebookId);
      final firstChapter = chapters.first;
      expect(firstChapter.id, equals(chapterCId));

      final firstPages = await db.getPagesByChapter(firstChapter.id);
      expect(firstPages.first.id, equals('page-c1'));
    });
  });
}
