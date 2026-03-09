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
  });

  tearDown(() async {
    await db.close();
  });

  group('Cross-Chapter Navigation (CCN) — Layer 4b', () {
    // CCN-001: Global page list returns pages across 2 chapters in correct order
    test('CCN-001: global page list returns pages across chapters in order',
        () async {
      final globalPages = await buildGlobalPageList(testNotebookId);

      expect(globalPages.length, equals(4));
      expect(globalPages[0].page.id, equals('page-a1'));
      expect(globalPages[1].page.id, equals('page-a2'));
      expect(globalPages[2].page.id, equals('page-b1'));
      expect(globalPages[3].page.id, equals('page-b2'));
    });

    // CCN-002: Global page list respects chapter sort_order after reorder
    test('CCN-002: global page list respects chapter sort_order after reorder',
        () async {
      // Reorder: B before A
      await db.reorderChapters([chapterBId, chapterAId]);

      final globalPages = await buildGlobalPageList(testNotebookId);

      expect(globalPages.length, equals(4));
      // B pages first (now order 0)
      expect(globalPages[0].page.id, equals('page-b1'));
      expect(globalPages[1].page.id, equals('page-b2'));
      // A pages second (now order 1)
      expect(globalPages[2].page.id, equals('page-a1'));
      expect(globalPages[3].page.id, equals('page-a2'));
    });

    // CCN-003: Global page list carries correct chapter metadata per page
    test('CCN-003: global page list carries correct chapter metadata',
        () async {
      final globalPages = await buildGlobalPageList(testNotebookId);

      // Chapter A pages
      expect(globalPages[0].chapterId, equals(chapterAId));
      expect(globalPages[0].chapterTitle, equals('Chapter A'));
      expect(globalPages[0].chapterColor, equals(0xFF4CAF50));
      expect(globalPages[0].chapterIndex, equals(0));
      expect(globalPages[0].totalChapters, equals(2));

      expect(globalPages[1].chapterId, equals(chapterAId));
      expect(globalPages[1].chapterIndex, equals(0));

      // Chapter B pages
      expect(globalPages[2].chapterId, equals(chapterBId));
      expect(globalPages[2].chapterTitle, equals('Chapter B'));
      expect(globalPages[2].chapterColor, equals(0xFF2196F3));
      expect(globalPages[2].chapterIndex, equals(1));
      expect(globalPages[2].totalChapters, equals(2));

      expect(globalPages[3].chapterId, equals(chapterBId));
      expect(globalPages[3].chapterIndex, equals(1));
    });

    // CCN-004: Forward from last page of ch A lands on first page of ch B
    test('CCN-004: forward from last page of ch A lands on first page of ch B',
        () async {
      final globalPages = await buildGlobalPageList(testNotebookId);

      // page-a2 is at index 1, next is index 2 (page-b1)
      final currentIndex =
          globalPages.indexWhere((e) => e.page.id == 'page-a2');
      expect(currentIndex, equals(1));

      final nextPage = globalPages[currentIndex + 1];
      expect(nextPage.page.id, equals('page-b1'));
      expect(nextPage.chapterId, equals(chapterBId));
    });

    // CCN-005: Backward from first page of ch B lands on last page of ch A
    test(
        'CCN-005: backward from first page of ch B lands on last page of ch A',
        () async {
      final globalPages = await buildGlobalPageList(testNotebookId);

      // page-b1 is at index 2, prev is index 1 (page-a2)
      final currentIndex =
          globalPages.indexWhere((e) => e.page.id == 'page-b1');
      expect(currentIndex, equals(2));

      final prevPage = globalPages[currentIndex - 1];
      expect(prevPage.page.id, equals('page-a2'));
      expect(prevPage.chapterId, equals(chapterAId));
    });

    // CCN-006: Global index is correct across 3 chapters
    test('CCN-006: global index is correct across 3 chapters', () async {
      // Add chapter C with 1 page
      await db.insertChapter(const Chapter(
        id: 'chapter-c',
        notebookId: testNotebookId,
        title: 'Chapter C',
        order: 2,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-c1',
        chapterId: 'chapter-c',
        pageNumber: 0,
      ));

      final globalPages = await buildGlobalPageList(testNotebookId);

      expect(globalPages.length, equals(5));
      // Verify indices
      expect(globalPages[0].page.id, equals('page-a1')); // global 0
      expect(globalPages[1].page.id, equals('page-a2')); // global 1
      expect(globalPages[2].page.id, equals('page-b1')); // global 2
      expect(globalPages[3].page.id, equals('page-b2')); // global 3
      expect(globalPages[4].page.id, equals('page-c1')); // global 4

      // Chapter indices
      expect(globalPages[4].chapterIndex, equals(2));
      expect(globalPages[4].totalChapters, equals(3));
    });

    // CCN-007: No prev before first page of first chapter
    test('CCN-007: no prev before first page of first chapter', () async {
      final globalPages = await buildGlobalPageList(testNotebookId);

      final firstIndex =
          globalPages.indexWhere((e) => e.page.id == 'page-a1');
      expect(firstIndex, equals(0));
      // In the UI, onPrevPage would be null when safeIndex == 0
      expect(firstIndex > 0, isFalse);
    });

    // CCN-008: No next after last page of last chapter
    test('CCN-008: no next after last page of last chapter', () async {
      final globalPages = await buildGlobalPageList(testNotebookId);

      final lastIndex =
          globalPages.indexWhere((e) => e.page.id == 'page-b2');
      expect(lastIndex, equals(globalPages.length - 1));
      // In the UI, onNextPage would be null when safeIndex == length - 1
      expect(lastIndex < globalPages.length - 1, isFalse);
    });

    // CCN-009: New chapter gets title "Chapter N" with correct sort_order
    test('CCN-009: new chapter gets correct title and sort_order', () async {
      // Simulate _createNewChapter: get count, insert at end
      final chapterCount = await db.getChapterCount(testNotebookId);
      expect(chapterCount, equals(2));

      await db.insertChapter(Chapter(
        id: 'chapter-new',
        notebookId: testNotebookId,
        title: 'Chapter ${chapterCount + 1}',
        order: chapterCount,
      ));

      final newChapter = await db.getChapter('chapter-new');
      expect(newChapter, isNotNull);
      expect(newChapter!.title, equals('Chapter 3'));
      expect(newChapter.order, equals(2));

      // Verify it appears last in the list
      final chapters = await db.getChaptersByNotebook(testNotebookId);
      expect(chapters.last.id, equals('chapter-new'));
    });

    // CCN-010: New chapter contains exactly one blank page
    test('CCN-010: new chapter contains exactly one blank page', () async {
      // Create new chapter with one page (mirrors _createNewChapter)
      final chapterCount = await db.getChapterCount(testNotebookId);
      await db.insertChapter(Chapter(
        id: 'chapter-new',
        notebookId: testNotebookId,
        title: 'Chapter ${chapterCount + 1}',
        order: chapterCount,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-new1',
        chapterId: 'chapter-new',
        pageNumber: 0,
      ));

      final pages = await db.getPagesByChapter('chapter-new');
      expect(pages.length, equals(1));
      expect(pages.first.id, equals('page-new1'));
      expect(pages.first.pageNumber, equals(0));
    });

    // CCN-011: Global page list grows by 1 after new chapter creation
    test('CCN-011: global page list grows by 1 after new chapter creation',
        () async {
      final before = await buildGlobalPageList(testNotebookId);
      expect(before.length, equals(4));

      // Create new chapter with one page
      final chapterCount = await db.getChapterCount(testNotebookId);
      await db.insertChapter(Chapter(
        id: 'chapter-new',
        notebookId: testNotebookId,
        title: 'Chapter ${chapterCount + 1}',
        order: chapterCount,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-new1',
        chapterId: 'chapter-new',
        pageNumber: 0,
      ));

      final after = await buildGlobalPageList(testNotebookId);
      expect(after.length, equals(5));
      expect(after.last.page.id, equals('page-new1'));
      expect(after.last.chapterTitle, equals('Chapter 3'));
    });

    // CCN-012: Existing chapters/pages unaffected by new chapter creation
    test('CCN-012: existing chapters/pages unaffected by new chapter',
        () async {
      // Create new chapter
      final chapterCount = await db.getChapterCount(testNotebookId);
      await db.insertChapter(Chapter(
        id: 'chapter-new',
        notebookId: testNotebookId,
        title: 'Chapter ${chapterCount + 1}',
        order: chapterCount,
      ));
      await db.insertPage(const SketchPage(
        id: 'page-new1',
        chapterId: 'chapter-new',
        pageNumber: 0,
      ));

      // Verify original chapters are unchanged
      final chapterA = await db.getChapter(chapterAId);
      expect(chapterA!.title, equals('Chapter A'));
      expect(chapterA.order, equals(0));

      final chapterB = await db.getChapter(chapterBId);
      expect(chapterB!.title, equals('Chapter B'));
      expect(chapterB.order, equals(1));

      // Verify original pages are unchanged
      final pagesA = await db.getPagesByChapter(chapterAId);
      expect(pagesA.length, equals(2));
      expect(pagesA[0].id, equals('page-a1'));
      expect(pagesA[1].id, equals('page-a2'));

      final pagesB = await db.getPagesByChapter(chapterBId);
      expect(pagesB.length, equals(2));
      expect(pagesB[0].id, equals('page-b1'));
      expect(pagesB[1].id, equals('page-b2'));
    });
  });
}
