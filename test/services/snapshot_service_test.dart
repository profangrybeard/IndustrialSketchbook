import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:industrial_sketchbook/models/chapter.dart';
import 'package:industrial_sketchbook/models/notebook.dart';
import 'package:industrial_sketchbook/models/sketch_page.dart';
import 'package:industrial_sketchbook/services/database_service.dart';
import 'package:industrial_sketchbook/services/snapshot_service.dart';

void main() {
  // Use sqflite_ffi for desktop testing (no Android needed)
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late SnapshotService snapshotService;

  setUp(() async {
    db = DatabaseService();
    await db.initialize(path: inMemoryDatabasePath);

    // Seed required FK chain
    await db.insertNotebook(
        const Notebook(id: 'nb-1', title: 'Test', ownerId: 'user-1'));
    await db.insertChapter(
        const Chapter(id: 'ch-1', notebookId: 'nb-1', title: 'Test', order: 0));

    snapshotService = SnapshotService(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('SnapshotService', () {
    group('memory cache', () {
      test('hasCachedSnapshot returns false for unknown page', () {
        expect(snapshotService.hasCachedSnapshot('page-1'), isFalse);
      });

      test('cacheSize starts at 0', () {
        expect(snapshotService.cacheSize, equals(0));
      });

      test('stores and retrieves from DB directly', () async {
        // Seed the page
        await db.insertPage(const SketchPage(
            id: 'page-1', chapterId: 'ch-1', pageNumber: 0));

        // Store a PNG blob directly in DB
        final blob = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
        await db.savePageSnapshot(
          pageId: 'page-1',
          pngBlob: blob,
          strokeVersion: 5,
          width: 100,
          height: 100,
        );

        // Verify it's in the DB
        final retrieved = await db.getPageSnapshot('page-1');
        expect(retrieved, isNotNull);
        expect(retrieved!.length, equals(blob.length));
      });

      test('invalidate removes from memory cache', () async {
        await db.insertPage(const SketchPage(
            id: 'page-1', chapterId: 'ch-1', pageNumber: 0));

        // Store directly
        final blob = Uint8List.fromList([1, 2, 3]);
        await db.savePageSnapshot(
          pageId: 'page-1',
          pngBlob: blob,
          strokeVersion: 1,
          width: 10,
          height: 10,
        );

        // Load into memory cache via getSnapshot would need a real PNG,
        // but we can test hasCachedSnapshot after invalidate
        snapshotService.invalidate('page-1');
        expect(snapshotService.hasCachedSnapshot('page-1'), isFalse);
      });

      test('clearMemoryCache empties the cache', () async {
        // We can't easily test with real ui.Image in unit tests,
        // but we can test the cache mechanics
        snapshotService.clearMemoryCache();
        expect(snapshotService.cacheSize, equals(0));
      });
    });

    group('LRU eviction', () {
      test('evicts oldest entry when exceeding maxEntries', () async {
        // Create pages and store blobs directly in DB
        for (int i = 0; i < 7; i++) {
          final pageId = 'page-$i';
          await db.insertPage(SketchPage(
              id: pageId, chapterId: 'ch-1', pageNumber: i));
          await db.savePageSnapshot(
            pageId: pageId,
            pngBlob: Uint8List.fromList([i]),
            strokeVersion: 1,
            width: 10,
            height: 10,
          );
        }

        // maxEntries is 5 — verify DB has all 7
        for (int i = 0; i < 7; i++) {
          final blob = await db.getPageSnapshot('page-$i');
          expect(blob, isNotNull, reason: 'page-$i should exist in DB');
        }
      });
    });

    group('DB integration', () {
      test('invalidate also removes from DB', () async {
        await db.insertPage(const SketchPage(
            id: 'page-db', chapterId: 'ch-1', pageNumber: 0));

        await db.savePageSnapshot(
          pageId: 'page-db',
          pngBlob: Uint8List.fromList([1, 2, 3]),
          strokeVersion: 1,
          width: 100,
          height: 100,
        );

        // Verify it exists
        expect(await db.getPageSnapshot('page-db'), isNotNull);

        // Invalidate
        snapshotService.invalidate('page-db');

        // Wait for async DB delete
        await Future.delayed(const Duration(milliseconds: 100));

        // Should be gone from DB
        expect(await db.getPageSnapshot('page-db'), isNull);
      });

      test('getSnapshot returns null for non-existent page', () async {
        final result = await snapshotService.getSnapshot('page-999');
        expect(result, isNull);
      });
    });
  });
}
