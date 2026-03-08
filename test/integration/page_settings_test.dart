import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:industrial_sketchbook/models/chapter.dart';
import 'package:industrial_sketchbook/models/grid_config.dart';
import 'package:industrial_sketchbook/models/grid_style.dart';
import 'package:industrial_sketchbook/models/notebook.dart';
import 'package:industrial_sketchbook/models/page_style.dart';
import 'package:industrial_sketchbook/models/sketch_page.dart';
import 'package:industrial_sketchbook/services/database_service.dart';

void main() {
  // Use sqflite_ffi for desktop testing (no Android needed)
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;

  const testNotebookId = 'test-notebook';
  const testChapterId = 'test-chapter';
  const testPageId = 'test-page';

  setUp(() async {
    db = DatabaseService();
    await db.initialize(path: inMemoryDatabasePath);

    // Seed foreign key chain
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

  group('Page Settings Persistence (PGS) — Layer 2', () {
    // PGS-001: Grid style persists via page style
    test('PGS-001: grid style persists per page', () async {
      // Default page starts as plain
      var page = await db.getPage(testPageId);
      expect(page!.style, equals(PageStyle.plain));
      expect(GridStyle.fromPageStyle(page.style), equals(GridStyle.none));

      // Change to dot grid
      final updated = page.copyWith(style: GridStyle.dots.toPageStyle());
      await db.updatePageSettings(updated);

      // Reload and verify
      page = await db.getPage(testPageId);
      expect(page!.style, equals(PageStyle.dot));
      expect(GridStyle.fromPageStyle(page.style), equals(GridStyle.dots));
    });

    // PGS-002: Grid spacing persists via gridConfig
    test('PGS-002: grid spacing persists per page', () async {
      // Set grid config with custom spacing
      var page = await db.getPage(testPageId);
      final updated = page!.copyWith(
        style: PageStyle.dot,
        gridConfig: const GridConfig(spacing: 40.0),
      );
      await db.updatePageSettings(updated);

      // Reload and verify
      page = await db.getPage(testPageId);
      expect(page!.gridConfig, isNotNull);
      expect(page.gridConfig!.spacing, equals(40.0));
    });

    // PGS-003: Paper color persists per page
    test('PGS-003: paper color persists per page', () async {
      // Default is warm white
      var page = await db.getPage(testPageId);
      expect(page!.paperColor, equals(0xFFF5F5F0));

      // Change to tan
      const tanColor = 0xFFD2B48C;
      final updated = page.copyWith(paperColor: tanColor);
      await db.updatePageSettings(updated);

      // Reload and verify
      page = await db.getPage(testPageId);
      expect(page!.paperColor, equals(tanColor));
    });

    // PGS-004: Default page has correct default settings
    test('PGS-004: default page has correct defaults', () async {
      final page = await db.getPage(testPageId);
      expect(page, isNotNull);
      expect(page!.style, equals(PageStyle.plain));
      expect(page.gridConfig, isNull);
      expect(page.paperColor, equals(0xFFF5F5F0));
    });

    // PGS-005: Page settings round-trip through DB
    test('PGS-005: page settings serialize round-trip', () async {
      // Set all settings
      var page = await db.getPage(testPageId);
      final updated = page!.copyWith(
        style: PageStyle.grid,
        gridConfig: const GridConfig(
          spacing: 35.0,
          color: 0xFF808080,
          lineWeight: 1.0,
        ),
        paperColor: 0xFF1A1A2E,
      );
      await db.updatePageSettings(updated);

      // Reload and verify all fields survived
      page = await db.getPage(testPageId);
      expect(page!.style, equals(PageStyle.grid));
      expect(page.gridConfig, isNotNull);
      expect(page.gridConfig!.spacing, equals(35.0));
      expect(page.gridConfig!.color, equals(0xFF808080));
      expect(page.gridConfig!.lineWeight, equals(1.0));
      expect(page.paperColor, equals(0xFF1A1A2E));
    });

    // PGS-006: GridStyle <-> PageStyle mapping is bidirectional
    test('PGS-006: GridStyle/PageStyle mapping is consistent', () {
      // none -> plain -> none
      expect(GridStyle.none.toPageStyle(), equals(PageStyle.plain));
      expect(GridStyle.fromPageStyle(PageStyle.plain), equals(GridStyle.none));

      // dots -> dot -> dots
      expect(GridStyle.dots.toPageStyle(), equals(PageStyle.dot));
      expect(GridStyle.fromPageStyle(PageStyle.dot), equals(GridStyle.dots));

      // lines -> grid -> lines
      expect(GridStyle.lines.toPageStyle(), equals(PageStyle.grid));
      expect(GridStyle.fromPageStyle(PageStyle.grid), equals(GridStyle.lines));

      // Perspective/isometric fall back to none
      expect(
          GridStyle.fromPageStyle(PageStyle.perspective), equals(GridStyle.none));
      expect(
          GridStyle.fromPageStyle(PageStyle.isometric), equals(GridStyle.none));
    });

    // PGS-007: updatePageSettings only touches settings columns
    test('PGS-007: updatePageSettings preserves structural fields', () async {
      // Verify structural fields are untouched by settings update
      var page = await db.getPage(testPageId);
      final originalChapterId = page!.chapterId;
      final originalPageNumber = page.pageNumber;

      // Update settings
      final updated = page.copyWith(
        style: PageStyle.dot,
        paperColor: 0xFFFF0000,
      );
      await db.updatePageSettings(updated);

      // Verify structural fields unchanged
      page = await db.getPage(testPageId);
      expect(page!.chapterId, equals(originalChapterId));
      expect(page.pageNumber, equals(originalPageNumber));
      expect(page.style, equals(PageStyle.dot));
      expect(page.paperColor, equals(0xFFFF0000));
    });

    // PGS-008: Multiple pages have independent settings
    test('PGS-008: pages have independent settings', () async {
      // Create a second page
      await db.insertPage(const SketchPage(
        id: 'page-2',
        chapterId: testChapterId,
        pageNumber: 1,
      ));

      // Set different settings on each
      var page1 = await db.getPage(testPageId);
      await db.updatePageSettings(page1!.copyWith(
        style: PageStyle.dot,
        paperColor: 0xFFFFFFFF,
      ));

      var page2 = await db.getPage('page-2');
      await db.updatePageSettings(page2!.copyWith(
        style: PageStyle.grid,
        paperColor: 0xFF1A1A2E,
      ));

      // Reload and verify independence
      page1 = await db.getPage(testPageId);
      page2 = await db.getPage('page-2');

      expect(page1!.style, equals(PageStyle.dot));
      expect(page1.paperColor, equals(0xFFFFFFFF));

      expect(page2!.style, equals(PageStyle.grid));
      expect(page2.paperColor, equals(0xFF1A1A2E));
    });

    // PGS-009: DB migration adds paper_color column
    test('PGS-009: v2 schema includes paper_color column', () async {
      // This test validates the column exists (covered implicitly by PGS-003,
      // but we test the raw SQL to be explicit)
      final rows = await db.db.rawQuery(
        "PRAGMA table_info('pages')",
      );
      final columnNames = rows.map((r) => r['name'] as String).toSet();
      expect(columnNames, contains('paper_color'));
    });
  });
}
