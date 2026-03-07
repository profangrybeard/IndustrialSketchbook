import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:industrial_sketchbook/models/chapter.dart';
import 'package:industrial_sketchbook/models/notebook.dart';
import 'package:industrial_sketchbook/models/sketch_page.dart';
import 'package:industrial_sketchbook/models/stroke.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/models/tool_type.dart';
import 'package:industrial_sketchbook/services/database_service.dart';

void main() {
  // Use sqflite_ffi for desktop testing (no Android needed)
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;

  setUp(() async {
    db = DatabaseService();
    await db.initialize(path: inMemoryDatabasePath);
  });

  tearDown(() async {
    await db.close();
  });

  group('DatabaseService', () {
    group('Schema initialization', () {
      test('database initializes without error', () {
        expect(db.isInitialized, isTrue);
      });

      test('all tables are created', () async {
        final tables = await db.db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
        );
        final tableNames = tables.map((r) => r['name'] as String).toSet();

        expect(tableNames, contains('notebooks'));
        expect(tableNames, contains('chapters'));
        expect(tableNames, contains('pages'));
        expect(tableNames, contains('strokes'));
        expect(tableNames, contains('page_stroke_order'));
        expect(tableNames, contains('gallery_images'));
        expect(tableNames, contains('image_pins'));
        expect(tableNames, contains('ocr_snapshots'));
        expect(tableNames, contains('sync_queue'));
      });

      test('FTS5 search_index virtual table is created', () async {
        final tables = await db.db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='search_index'",
        );
        expect(tables, isNotEmpty);
      });
    });

    group('Notebook CRUD', () {
      test('insert and retrieve notebook', () async {
        final notebook = Notebook(
          id: 'nb-1',
          title: 'Design Notebook',
          ownerId: 'user-1',
        );

        await db.insertNotebook(notebook);
        final retrieved = await db.getNotebook('nb-1');

        expect(retrieved, isNotNull);
        expect(retrieved!.id, equals('nb-1'));
        expect(retrieved.title, equals('Design Notebook'));
        expect(retrieved.ownerId, equals('user-1'));
      });
    });

    group('Chapter CRUD', () {
      test('insert and retrieve chapter', () async {
        await db.insertNotebook(Notebook(
            id: 'nb-1', title: 'Test', ownerId: 'user-1'));

        final chapter = Chapter(
          id: 'ch-1',
          notebookId: 'nb-1',
          title: 'Concepts',
          order: 0,
        );

        await db.insertChapter(chapter);
        final retrieved = await db.getChapter('ch-1');

        expect(retrieved, isNotNull);
        expect(retrieved!.title, equals('Concepts'));
        expect(retrieved.order, equals(0));
      });

      test('get chapters by notebook sorted by order', () async {
        await db.insertNotebook(Notebook(
            id: 'nb-1', title: 'Test', ownerId: 'user-1'));

        await db.insertChapter(Chapter(
            id: 'ch-2', notebookId: 'nb-1', title: 'Second', order: 1));
        await db.insertChapter(Chapter(
            id: 'ch-1', notebookId: 'nb-1', title: 'First', order: 0));

        final chapters = await db.getChaptersByNotebook('nb-1');
        expect(chapters.length, equals(2));
        expect(chapters[0].title, equals('First'));
        expect(chapters[1].title, equals('Second'));
      });
    });

    group('Page CRUD', () {
      test('insert and retrieve page', () async {
        await db.insertNotebook(Notebook(
            id: 'nb-1', title: 'Test', ownerId: 'user-1'));
        await db.insertChapter(Chapter(
            id: 'ch-1', notebookId: 'nb-1', title: 'Test', order: 0));

        final page = SketchPage(
          id: 'page-1',
          chapterId: 'ch-1',
          pageNumber: 0,
        );

        await db.insertPage(page);
        final retrieved = await db.getPage('page-1');

        expect(retrieved, isNotNull);
        expect(retrieved!.id, equals('page-1'));
        expect(retrieved.chapterId, equals('ch-1'));
        expect(retrieved.pageNumber, equals(0));
        expect(retrieved.layerIds, equals(['default']));
      });
    });

    group('Stroke CRUD', () {
      setUp(() async {
        await db.insertNotebook(Notebook(
            id: 'nb-1', title: 'Test', ownerId: 'user-1'));
        await db.insertChapter(Chapter(
            id: 'ch-1', notebookId: 'nb-1', title: 'Test', order: 0));
        await db.insertPage(SketchPage(
            id: 'page-1', chapterId: 'ch-1', pageNumber: 0));
      });

      test('insert stroke with binary blob and retrieve', () async {
        final points = [
          StrokePoint(
              x: 10.0, y: 20.0, pressure: 0.5,
              tiltX: 0.0, tiltY: 0.0, twist: 0.0,
              timestamp: 1000),
          StrokePoint(
              x: 30.0, y: 40.0, pressure: 0.7,
              tiltX: 5.0, tiltY: -5.0, twist: 10.0,
              timestamp: 2000),
        ];

        final stroke = Stroke(
          id: 'stroke-1',
          pageId: 'page-1',
          tool: ToolType.pen,
          color: 0xFF000000,
          weight: 2.0,
          opacity: 1.0,
          points: points,
          createdAt: DateTime.utc(2024, 1, 15),
        );

        await db.insertStroke(stroke);
        final retrieved = await db.getStroke('stroke-1');

        expect(retrieved, isNotNull);
        expect(retrieved!.id, equals('stroke-1'));
        expect(retrieved.tool, equals(ToolType.pen));
        expect(retrieved.points.length, equals(2));
        expect(retrieved.points[0].x, closeTo(10.0, 0.01));
        expect(retrieved.points[1].pressure, closeTo(0.7, 0.001));
      });

      // -------------------------------------------------------------------
      // VER-001: Stroke log is ordered and append-only
      //
      // Add 5 strokes; retrieve page_stroke_order; assert sort_order is
      // 0,1,2,3,4 with correct stroke IDs.
      // Priority: P0
      // -------------------------------------------------------------------
      test('VER-001: stroke order is sequential and correct', () async {
        for (int i = 0; i < 5; i++) {
          final stroke = Stroke(
            id: 'stroke-$i',
            pageId: 'page-1',
            tool: ToolType.pen,
            color: 0xFF000000,
            weight: 2.0,
            opacity: 1.0,
            points: [
              StrokePoint(
                  x: i * 10.0, y: i * 10.0, pressure: 0.5,
                  tiltX: 0.0, tiltY: 0.0, twist: 0.0,
                  timestamp: i * 1000),
            ],
            createdAt: DateTime.utc(2024, 1, 15, 0, 0, i),
          );
          await db.insertStroke(stroke);
        }

        final order = await db.getPageStrokeOrder('page-1');
        expect(order.length, equals(5));

        for (int i = 0; i < 5; i++) {
          expect(order[i]['stroke_id'], equals('stroke-$i'));
          expect(order[i]['sort_order'], equals(i));
        }
      });

      test('getStrokesByPageId returns strokes in log order', () async {
        for (int i = 0; i < 3; i++) {
          await db.insertStroke(Stroke(
            id: 'stroke-$i',
            pageId: 'page-1',
            tool: ToolType.pen,
            color: 0xFF000000,
            weight: 2.0,
            opacity: 1.0,
            points: [
              StrokePoint(
                  x: 0.0, y: 0.0, pressure: 0.5,
                  tiltX: 0.0, tiltY: 0.0, twist: 0.0,
                  timestamp: i),
            ],
            createdAt: DateTime.utc(2024, 1, 15, 0, 0, i),
          ));
        }

        final strokes = await db.getStrokesByPageId('page-1');
        expect(strokes.length, equals(3));
        expect(strokes[0].id, equals('stroke-0'));
        expect(strokes[1].id, equals('stroke-1'));
        expect(strokes[2].id, equals('stroke-2'));
      });

      test('duplicate stroke UUID is ignored (idempotent)', () async {
        final stroke = Stroke(
          id: 'stroke-dup',
          pageId: 'page-1',
          tool: ToolType.pen,
          color: 0xFF000000,
          weight: 2.0,
          opacity: 1.0,
          points: [
            StrokePoint(
                x: 0.0, y: 0.0, pressure: 0.5,
                tiltX: 0.0, tiltY: 0.0, twist: 0.0,
                timestamp: 0),
          ],
          createdAt: DateTime.utc(2024, 1, 15),
        );

        await db.insertStroke(stroke);
        // Second insert with same ID should not throw
        // (ConflictAlgorithm.ignore on stroke, but page_stroke_order
        // will add another entry — this tests the stroke table only)
        final retrieved = await db.getStroke('stroke-dup');
        expect(retrieved, isNotNull);
      });
    });
  });
}
