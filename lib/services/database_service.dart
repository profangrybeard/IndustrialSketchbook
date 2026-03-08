import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../models/chapter.dart';
import '../models/notebook.dart';
import '../models/sketch_page.dart';
import '../models/stroke.dart';
import '../models/stroke_point.dart';

/// SQLite database service (TDD §2, Appendix A).
///
/// Manages the stroke log (source of truth), sync queue, OCR cache,
/// and FTS5 search index. Uses WAL mode for async writes that don't
/// block the drawing thread.
///
/// ## Schema
///
/// See TDD Appendix A for the complete table definitions.
class DatabaseService {
  Database? _db;

  /// The active database instance. Throws if not initialized.
  Database get db {
    final database = _db;
    if (database == null) {
      throw StateError('DatabaseService not initialized. Call initialize() first.');
    }
    return database;
  }

  /// Whether the database has been initialized.
  bool get isInitialized => _db != null;

  /// Initialize the database, creating all tables.
  ///
  /// Uses WAL journal mode for concurrent reads during writes
  /// (TDD §4.1: "WAL mode, async isolate write").
  Future<void> initialize({String? path}) async {
    final dbPath = path ?? p.join(await getDatabasesPath(), 'industrial_sketchbook.db');

    _db = await openDatabase(
      dbPath,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: (db) async {
        // Enable WAL mode for better concurrent read/write performance
        // Use rawQuery because journal_mode returns a result set
        await db.rawQuery('PRAGMA journal_mode=WAL');
        // Enable foreign keys
        await db.execute('PRAGMA foreign_keys=ON');
      },
    );
  }

  /// Migrate schema between versions.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v2: Add paper_color column to pages table (Layer 2 — page settings)
      await db.execute(
        'ALTER TABLE pages ADD COLUMN paper_color INTEGER NOT NULL DEFAULT ${0xFFF5F5F0}',
      );
    }
  }

  /// Create all tables (TDD Appendix A).
  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    // Top-level container
    batch.execute('''
      CREATE TABLE notebooks (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        owner_id TEXT NOT NULL
      )
    ''');

    // Named page groups
    batch.execute('''
      CREATE TABLE chapters (
        id TEXT PRIMARY KEY,
        notebook_id TEXT NOT NULL,
        title TEXT NOT NULL,
        sort_order INTEGER NOT NULL,
        color INTEGER NOT NULL DEFAULT 4284513675,
        FOREIGN KEY (notebook_id) REFERENCES notebooks(id)
      )
    ''');

    // Canvas metadata
    batch.execute('''
      CREATE TABLE pages (
        id TEXT PRIMARY KEY,
        chapter_id TEXT NOT NULL,
        page_number INTEGER NOT NULL,
        style TEXT NOT NULL DEFAULT 'plain',
        grid_config_json TEXT,
        perspective_config_json TEXT,
        parent_page_id TEXT,
        branch_point_stroke_id TEXT,
        branch_page_ids_json TEXT NOT NULL DEFAULT '[]',
        layer_ids_json TEXT NOT NULL DEFAULT '["default"]',
        paper_color INTEGER NOT NULL DEFAULT ${0xFFF5F5F0},
        FOREIGN KEY (chapter_id) REFERENCES chapters(id)
      )
    ''');

    // The event log — source of truth (TDD §2)
    batch.execute('''
      CREATE TABLE strokes (
        id TEXT PRIMARY KEY,
        page_id TEXT NOT NULL,
        layer_id TEXT NOT NULL DEFAULT 'default',
        tool TEXT NOT NULL,
        color INTEGER NOT NULL,
        weight REAL NOT NULL,
        opacity REAL NOT NULL,
        points_blob BLOB NOT NULL,
        created_at TEXT NOT NULL,
        is_tombstone INTEGER NOT NULL DEFAULT 0,
        erases_stroke_id TEXT,
        synced INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (page_id) REFERENCES pages(id)
      )
    ''');

    // Ordered stroke log per page
    batch.execute('''
      CREATE TABLE page_stroke_order (
        page_id TEXT NOT NULL,
        stroke_id TEXT NOT NULL,
        sort_order INTEGER NOT NULL,
        PRIMARY KEY (page_id, stroke_id),
        FOREIGN KEY (page_id) REFERENCES pages(id),
        FOREIGN KEY (stroke_id) REFERENCES strokes(id)
      )
    ''');

    // Parallel image index (TDD §3.5)
    batch.execute('''
      CREATE TABLE gallery_images (
        id TEXT PRIMARY KEY,
        notebook_id TEXT NOT NULL,
        source TEXT NOT NULL,
        local_path TEXT NOT NULL,
        cloud_storage_ref TEXT,
        tags_json TEXT NOT NULL DEFAULT '[]',
        page_refs_json TEXT NOT NULL DEFAULT '[]',
        FOREIGN KEY (notebook_id) REFERENCES notebooks(id)
      )
    ''');

    // Image pinned to canvas location
    batch.execute('''
      CREATE TABLE image_pins (
        page_id TEXT NOT NULL,
        image_id TEXT NOT NULL,
        anchor_x REAL NOT NULL,
        anchor_y REAL NOT NULL,
        annotation_stroke_ids_json TEXT NOT NULL DEFAULT '[]',
        pinned_at TEXT NOT NULL,
        PRIMARY KEY (page_id, image_id),
        FOREIGN KEY (page_id) REFERENCES pages(id),
        FOREIGN KEY (image_id) REFERENCES gallery_images(id)
      )
    ''');

    // Cached OCR results (TDD §4.2)
    batch.execute('''
      CREATE TABLE ocr_snapshots (
        id TEXT PRIMARY KEY,
        page_id TEXT NOT NULL,
        stroke_count INTEGER NOT NULL,
        regions_json TEXT NOT NULL,
        captured_at TEXT NOT NULL,
        FOREIGN KEY (page_id) REFERENCES pages(id)
      )
    ''');

    // Pending sync outbox (TDD §4.3)
    batch.execute('''
      CREATE TABLE sync_queue (
        id TEXT PRIMARY KEY,
        event_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        retry_count INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');

    await batch.commit(noResult: true);

    // FTS5 virtual table must be created outside the batch —
    // sqflite batches don't reliably handle CREATE VIRTUAL TABLE.
    // Note: Android system SQLite may not include the FTS5 module.
    // If unavailable, search will be disabled until sqlite3_flutter_libs
    // is added to bundle a full SQLite build with FTS5 support.
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
          page_id,
          chapter_id,
          text,
          canvas_x,
          canvas_y
        )
      ''');
    } on DatabaseException catch (e) {
      // FTS5 not available on this device — search index will not be created
      print('Warning: FTS5 not available, full-text search disabled: $e');
    }
  }

  /// Close the database connection.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ---------------------------------------------------------------------------
  // Notebook CRUD
  // ---------------------------------------------------------------------------

  Future<void> insertNotebook(Notebook notebook) async {
    await db.insert('notebooks', notebook.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Notebook?> getNotebook(String id) async {
    final rows = await db.query('notebooks', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Notebook.fromDbMap(rows.first);
  }

  // ---------------------------------------------------------------------------
  // Chapter CRUD
  // ---------------------------------------------------------------------------

  Future<void> insertChapter(Chapter chapter) async {
    await db.insert('chapters', chapter.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Chapter?> getChapter(String id) async {
    final rows = await db.query('chapters', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Chapter.fromDbMap(rows.first);
  }

  Future<List<Chapter>> getChaptersByNotebook(String notebookId) async {
    final rows = await db.query(
      'chapters',
      where: 'notebook_id = ?',
      whereArgs: [notebookId],
      orderBy: 'sort_order ASC',
    );
    return rows.map(Chapter.fromDbMap).toList();
  }

  /// Update a chapter's title, color, and sort_order.
  Future<void> updateChapter(Chapter chapter) async {
    await db.update(
      'chapters',
      {
        'title': chapter.title,
        'color': chapter.color,
        'sort_order': chapter.order,
      },
      where: 'id = ?',
      whereArgs: [chapter.id],
    );
  }

  /// Delete a chapter and cascade-remove all its pages, strokes, and stroke
  /// order entries.
  ///
  /// Safety guard: cannot delete the last chapter in a notebook.
  /// Returns false if the chapter doesn't exist or is the last one.
  Future<bool> deleteChapter(String chapterId) async {
    final chapter = await getChapter(chapterId);
    if (chapter == null) return false;

    // Safety: don't delete the last chapter in the notebook
    final count = await getChapterCount(chapter.notebookId);
    if (count <= 1) return false;

    await db.transaction((txn) async {
      // Get all pages in this chapter
      final pageRows = await txn.query(
        'pages',
        columns: ['id'],
        where: 'chapter_id = ?',
        whereArgs: [chapterId],
      );

      // For each page: delete stroke_order, delete strokes
      for (final row in pageRows) {
        final pageId = row['id'] as String;
        await txn.delete(
          'page_stroke_order',
          where: 'page_id = ?',
          whereArgs: [pageId],
        );
        await txn.delete(
          'strokes',
          where: 'page_id = ?',
          whereArgs: [pageId],
        );
      }

      // Delete all pages in the chapter
      await txn.delete(
        'pages',
        where: 'chapter_id = ?',
        whereArgs: [chapterId],
      );

      // Delete the chapter record
      await txn.delete(
        'chapters',
        where: 'id = ?',
        whereArgs: [chapterId],
      );
    });

    return true;
  }

  /// Bulk-update sort_order for chapters based on list position.
  ///
  /// The first ID in [chapterIds] gets sort_order 0, the second gets 1, etc.
  Future<void> reorderChapters(List<String> chapterIds) async {
    await db.transaction((txn) async {
      for (int i = 0; i < chapterIds.length; i++) {
        await txn.update(
          'chapters',
          {'sort_order': i},
          where: 'id = ?',
          whereArgs: [chapterIds[i]],
        );
      }
    });
  }

  /// Move a page to a different chapter at a specific position.
  ///
  /// Re-numbers both the source and target chapters so page numbers
  /// remain contiguous (no gaps).
  Future<void> movePageToChapter(
    String pageId,
    String targetChapterId,
    int targetPageNumber,
  ) async {
    await db.transaction((txn) async {
      // 1. Get the page's current location
      final pageRows = await txn.query(
        'pages',
        where: 'id = ?',
        whereArgs: [pageId],
      );
      if (pageRows.isEmpty) return;
      final oldChapterId = pageRows.first['chapter_id'] as String;
      final oldPageNumber = pageRows.first['page_number'] as int;

      // 2. Remove from old chapter: shift down page_numbers above the gap
      await txn.rawUpdate(
        'UPDATE pages SET page_number = page_number - 1 '
        'WHERE chapter_id = ? AND page_number > ?',
        [oldChapterId, oldPageNumber],
      );

      // 3. Make room in new chapter: shift up page_numbers at or above target
      await txn.rawUpdate(
        'UPDATE pages SET page_number = page_number + 1 '
        'WHERE chapter_id = ? AND page_number >= ?',
        [targetChapterId, targetPageNumber],
      );

      // 4. Update the page's chapter and position
      await txn.update(
        'pages',
        {
          'chapter_id': targetChapterId,
          'page_number': targetPageNumber,
        },
        where: 'id = ?',
        whereArgs: [pageId],
      );
    });
  }

  /// Get the number of chapters in a notebook.
  ///
  /// Used for the "cannot delete last chapter" safety guard and for
  /// "Chapter X of Y" display.
  Future<int> getChapterCount(String notebookId) async {
    final result = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM chapters WHERE notebook_id = ?',
      [notebookId],
    ));
    return result ?? 0;
  }

  // ---------------------------------------------------------------------------
  // Page CRUD
  // ---------------------------------------------------------------------------

  Future<void> insertPage(SketchPage page) async {
    await db.insert('pages', page.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<SketchPage?> getPage(String id) async {
    final rows = await db.query('pages', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return SketchPage.fromDbMap(rows.first);
  }

  Future<List<SketchPage>> getPagesByChapter(String chapterId) async {
    final rows = await db.query(
      'pages',
      where: 'chapter_id = ?',
      whereArgs: [chapterId],
      orderBy: 'page_number ASC',
    );
    return rows.map(SketchPage.fromDbMap).toList();
  }

  /// Get the number of pages in a chapter.
  ///
  /// Used for assigning pageNumber to new pages and for "Page X of Y" display.
  Future<int> getPageCount(String chapterId) async {
    final result = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM pages WHERE chapter_id = ?',
      [chapterId],
    ));
    return result ?? 0;
  }

  /// Delete a page and all its associated data (strokes, stroke order).
  ///
  /// Cascade-deletes in a single transaction to maintain referential integrity.
  /// Returns false if this is the last page in its chapter (safety guard —
  /// a chapter must always have at least one page).
  Future<bool> deletePage(String pageId) async {
    // Look up the page to find its chapter
    final page = await getPage(pageId);
    if (page == null) return false;

    // Safety: don't delete the last page in a chapter
    final count = await getPageCount(page.chapterId);
    if (count <= 1) return false;

    await db.transaction((txn) async {
      // 1. Remove stroke ordering entries
      await txn.delete(
        'page_stroke_order',
        where: 'page_id = ?',
        whereArgs: [pageId],
      );

      // 2. Remove strokes belonging to this page
      await txn.delete(
        'strokes',
        where: 'page_id = ?',
        whereArgs: [pageId],
      );

      // 3. Remove the page record
      await txn.delete(
        'pages',
        where: 'id = ?',
        whereArgs: [pageId],
      );
    });

    return true;
  }

  /// Update page visual settings (style, grid config, paper color).
  ///
  /// Called when the user changes grid style, spacing, or paper color
  /// via the floating palette. Only updates the settings columns —
  /// does not touch structural fields (chapterId, branches, etc.).
  Future<void> updatePageSettings(SketchPage page) async {
    await db.update(
      'pages',
      {
        'style': page.style.toJson(),
        'grid_config_json': page.gridConfig != null
            ? jsonEncode(page.gridConfig!.toJson())
            : null,
        'paper_color': page.paperColor,
      },
      where: 'id = ?',
      whereArgs: [page.id],
    );
  }

  // ---------------------------------------------------------------------------
  // Stroke CRUD — the core of the event log
  // ---------------------------------------------------------------------------

  /// Insert a stroke and add it to the page's stroke order.
  ///
  /// This is the primary write path. Called on pen-up (TDD §4.1).
  /// Target latency: < 5ms (WAL mode, async isolate write).
  Future<void> insertStroke(Stroke stroke) async {
    await db.transaction((txn) async {
      // Insert the stroke record
      await txn.insert('strokes', stroke.toDbMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore);

      // Get the next sort_order for this page
      final maxOrder = Sqflite.firstIntValue(await txn.rawQuery(
            'SELECT MAX(sort_order) FROM page_stroke_order WHERE page_id = ?',
            [stroke.pageId],
          )) ??
          -1;

      // Add to page_stroke_order
      await txn.insert('page_stroke_order', {
        'page_id': stroke.pageId,
        'stroke_id': stroke.id,
        'sort_order': maxOrder + 1,
      });
    });
  }

  /// Insert multiple strokes in a single transaction (batch write).
  ///
  /// Used by partial erasing to persist the tombstone + new segments
  /// atomically.
  Future<void> insertStrokes(List<Stroke> strokes) async {
    await db.transaction((txn) async {
      for (final stroke in strokes) {
        await txn.insert('strokes', stroke.toDbMap(),
            conflictAlgorithm: ConflictAlgorithm.ignore);

        final maxOrder = Sqflite.firstIntValue(await txn.rawQuery(
              'SELECT MAX(sort_order) FROM page_stroke_order WHERE page_id = ?',
              [stroke.pageId],
            )) ??
            -1;

        await txn.insert('page_stroke_order', {
          'page_id': stroke.pageId,
          'stroke_id': stroke.id,
          'sort_order': maxOrder + 1,
        });
      }
    });
  }

  /// Get all strokes for a page, ordered by the stroke log.
  ///
  /// This is the primary read path for rendering (TDD §4.1).
  Future<List<Stroke>> getStrokesByPageId(String pageId) async {
    final rows = await db.rawQuery('''
      SELECT s.* FROM strokes s
      INNER JOIN page_stroke_order pso ON s.id = pso.stroke_id
      WHERE pso.page_id = ?
      ORDER BY pso.sort_order ASC
    ''', [pageId]);
    return rows.map(Stroke.fromDbMap).toList();
  }

  /// Get a single stroke by ID.
  Future<Stroke?> getStroke(String id) async {
    final rows = await db.query('strokes', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Stroke.fromDbMap(rows.first);
  }

  /// Get the ordered stroke IDs for a page (for VER-001 test).
  Future<List<Map<String, dynamic>>> getPageStrokeOrder(String pageId) async {
    return db.query(
      'page_stroke_order',
      where: 'page_id = ?',
      whereArgs: [pageId],
      orderBy: 'sort_order ASC',
    );
  }

  /// Delete strokes by their IDs (used by undo to reverse previous actions).
  ///
  /// Removes both the stroke records and their page_stroke_order entries
  /// in a single transaction. This is the minimal relaxation of the
  /// append-only invariant — only undo calls delete, and only for
  /// strokes it previously added.
  Future<void> deleteStrokes(String pageId, List<String> strokeIds) async {
    if (strokeIds.isEmpty) return;
    await db.transaction((txn) async {
      for (final id in strokeIds) {
        await txn.delete(
          'page_stroke_order',
          where: 'page_id = ? AND stroke_id = ?',
          whereArgs: [pageId, id],
        );
        await txn.delete(
          'strokes',
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
  }

  /// Mark a stroke as synced.
  Future<void> markStrokeSynced(String strokeId) async {
    await db.update(
      'strokes',
      {'synced': 1},
      where: 'id = ?',
      whereArgs: [strokeId],
    );
  }

  // ---------------------------------------------------------------------------
  // Sync Queue (TDD §4.3)
  // ---------------------------------------------------------------------------

  /// Enqueue a sync event.
  Future<void> enqueueSyncEvent({
    required String id,
    required String eventType,
    required String entityId,
    required Map<String, dynamic> payload,
  }) async {
    await db.insert('sync_queue', {
      'id': id,
      'event_type': eventType,
      'entity_id': entityId,
      'payload_json': jsonEncode(payload),
      'status': 'pending',
      'retry_count': 0,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Get all pending sync events, ordered by creation time.
  Future<List<Map<String, dynamic>>> getPendingSyncEvents() async {
    return db.query(
      'sync_queue',
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'created_at ASC',
    );
  }
}
