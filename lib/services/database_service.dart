import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../models/chapter.dart';
import '../models/notebook.dart';
import '../models/sketch_page.dart';
import '../models/stroke.dart';
import '../utils/coordinate_utils.dart';

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

  /// Reference scale for coordinate conversion.
  ///
  /// When set (via [CoordinateUtils.initialize]), all stroke reads/writes
  /// convert between reference units (DB) and world coordinates (in-memory).
  double? get _referenceScale =>
      CoordinateUtils.isInitialized ? CoordinateUtils.referenceScale : null;

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
      version: 6,
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

  /// Create all tables — v4 clean-slate schema.
  ///
  /// No migration path from v1–v3 (user approved data wipe for perf overhaul).
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
        archive_raw_data INTEGER NOT NULL DEFAULT 0,
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
    // v4: raw_points_blob (archive) + render_points_blob (compact normalized)
    // v6: coord_format (0 = legacy world coords, 1 = reference units)
    batch.execute('''
      CREATE TABLE strokes (
        id TEXT PRIMARY KEY,
        page_id TEXT NOT NULL,
        layer_id TEXT NOT NULL DEFAULT 'default',
        tool TEXT NOT NULL,
        color INTEGER NOT NULL,
        weight REAL NOT NULL,
        opacity REAL NOT NULL,
        raw_points_blob BLOB NOT NULL,
        render_points_blob BLOB,
        spine_blob BLOB,
        coord_format INTEGER NOT NULL DEFAULT 0,
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

    // Raster snapshots for instant page switching (Phase 3)
    batch.execute('''
      CREATE TABLE page_snapshots (
        page_id TEXT PRIMARY KEY,
        png_blob BLOB NOT NULL,
        stroke_version INTEGER NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (page_id) REFERENCES pages(id)
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

  /// Migrate from earlier schema versions to v4.
  ///
  /// v3 → v4: renamed points_blob → raw_points_blob,
  ///          renamed fitted_points_blob → render_points_blob,
  ///          added archive_raw_data column to chapters.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 4) {
      // Rename stroke blob columns
      await db.execute(
          'ALTER TABLE strokes RENAME COLUMN points_blob TO raw_points_blob');

      // fitted_points_blob may or may not exist (added in v3)
      try {
        await db.execute(
            'ALTER TABLE strokes RENAME COLUMN fitted_points_blob TO render_points_blob');
      } on DatabaseException {
        // Column didn't exist (v1/v2 → v4) — add it fresh
        await db.execute(
            'ALTER TABLE strokes ADD COLUMN render_points_blob BLOB');
      }

      // archive_raw_data may already exist; ADD COLUMN is a no-op error if so
      try {
        await db.execute(
            'ALTER TABLE chapters ADD COLUMN archive_raw_data INTEGER NOT NULL DEFAULT 0');
      } on DatabaseException {
        // Column already exists — fine
      }
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE strokes ADD COLUMN spine_blob BLOB');
    }
    if (oldVersion < 6) {
      await db.execute(
          'ALTER TABLE strokes ADD COLUMN coord_format INTEGER NOT NULL DEFAULT 0');
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
      // Insert the stroke record (converted to reference units if scale available)
      await txn.insert('strokes', stroke.toDbMap(referenceScale: _referenceScale),
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
    if (strokes.isEmpty) return;
    await db.transaction((txn) async {
      // Query MAX(sort_order) once per page instead of once per stroke (N+1 fix).
      final Map<String, int> nextOrder = {};

      final scale = _referenceScale;
      for (final stroke in strokes) {
        await txn.insert('strokes', stroke.toDbMap(referenceScale: scale),
            conflictAlgorithm: ConflictAlgorithm.ignore);

        if (!nextOrder.containsKey(stroke.pageId)) {
          final maxOrder = Sqflite.firstIntValue(await txn.rawQuery(
                'SELECT MAX(sort_order) FROM page_stroke_order WHERE page_id = ?',
                [stroke.pageId],
              )) ??
              -1;
          nextOrder[stroke.pageId] = maxOrder + 1;
        }

        final order = nextOrder[stroke.pageId]!;
        await txn.insert('page_stroke_order', {
          'page_id': stroke.pageId,
          'stroke_id': stroke.id,
          'sort_order': order,
        });
        nextOrder[stroke.pageId] = order + 1;
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
    final scale = _referenceScale;
    return rows.map((r) => Stroke.fromDbMap(r, referenceScale: scale)).toList();
  }

  /// Get a single stroke by ID.
  Future<Stroke?> getStroke(String id) async {
    final rows = await db.query('strokes', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Stroke.fromDbMap(rows.first, referenceScale: _referenceScale);
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

  // ---------------------------------------------------------------------------
  // Sync — Phase 3.2 (Google Drive journal sync)
  // ---------------------------------------------------------------------------

  /// Get all strokes that haven't been synced yet (synced = 0).
  ///
  /// Returns both regular strokes and tombstones — both need uploading.
  /// Get all strokes that haven't been synced yet (synced = 0).
  ///
  /// Returns strokes in their DB format (reference units for format-1).
  /// No denormalization — sync push sends reference-unit values directly.
  Future<List<Stroke>> getUnsyncedStrokes() async {
    final maps = await db.query(
      'strokes',
      where: 'synced = ?',
      whereArgs: [0],
      orderBy: 'created_at ASC',
    );
    // No referenceScale — return raw DB values for sync export
    return maps.map((m) => Stroke.fromDbMap(m)).toList();
  }

  /// Batch-mark strokes as synced after successful upload.
  ///
  /// Handles SQLite's 999 variable limit by chunking.
  Future<void> markStrokesSynced(List<String> strokeIds) async {
    if (strokeIds.isEmpty) return;
    const chunkSize = 999;
    await db.transaction((txn) async {
      for (var i = 0; i < strokeIds.length; i += chunkSize) {
        final chunk = strokeIds.sublist(
            i, i + chunkSize > strokeIds.length ? strokeIds.length : i + chunkSize);
        final placeholders = List.filled(chunk.length, '?').join(',');
        await txn.rawUpdate(
          'UPDATE strokes SET synced = 1 WHERE id IN ($placeholders)',
          chunk,
        );
      }
    });
  }

  /// Mark ALL strokes as unsynced (for force push — re-upload everything).
  Future<void> markAllStrokesUnsynced() async {
    await db.rawUpdate('UPDATE strokes SET synced = 0');
  }

    /// Insert a stroke only if its UUID doesn't already exist (for pull/merge).
  ///
  /// Returns true if the stroke was inserted, false if it already existed.
  Future<bool> insertStrokeIfNotExists(Stroke stroke) async {
    final existing = await db.query(
      'strokes',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [stroke.id],
      limit: 1,
    );
    if (existing.isNotEmpty) return false;

    // Insert stroke and page_stroke_order in a transaction
    await db.transaction((txn) async {
      await txn.insert('strokes', stroke.toDbMap(referenceScale: _referenceScale),
          conflictAlgorithm: ConflictAlgorithm.ignore);

      // Only add to page_stroke_order if not a tombstone
      if (!stroke.isTombstone) {
        final maxOrder = await txn.rawQuery(
          'SELECT COALESCE(MAX(sort_order), -1) AS max_order '
          'FROM page_stroke_order WHERE page_id = ?',
          [stroke.pageId],
        );
        final nextOrder =
            ((maxOrder.first['max_order'] as int?) ?? -1) + 1;
        await txn.insert('page_stroke_order', {
          'page_id': stroke.pageId,
          'stroke_id': stroke.id,
          'sort_order': nextOrder,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });

    // Mark as synced since it came from a remote journal
    await markStrokeSynced(stroke.id);
    return true;
  }

  /// Get all notebooks.
  Future<List<Notebook>> getAllNotebooks() async {
    final maps = await db.query('notebooks');
    return maps.map(Notebook.fromDbMap).toList();
  }

  /// Get all chapters across all notebooks.
  Future<List<Chapter>> getAllChapters() async {
    final maps = await db.query('chapters', orderBy: 'sort_order ASC');
    return maps.map(Chapter.fromDbMap).toList();
  }

  /// Get all pages across all chapters.
  Future<List<SketchPage>> getAllPages() async {
    final maps = await db.query('pages', orderBy: 'page_number ASC');
    return maps.map(SketchPage.fromDbMap).toList();
  }

  /// Upsert a chapter (insert or replace — for pull/merge).
  Future<void> upsertChapter(Chapter chapter) async {
    await db.insert('chapters', chapter.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Upsert a page (insert or replace — for pull/merge).
  Future<void> upsertPage(SketchPage page) async {
    await db.insert('pages', page.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---------------------------------------------------------------------------
  // Page Snapshots (Phase 3 — instant page switching)
  // ---------------------------------------------------------------------------

  /// Save or update a page's raster snapshot (PNG).
  Future<void> savePageSnapshot({
    required String pageId,
    required Uint8List pngBlob,
    required int strokeVersion,
    required int width,
    required int height,
  }) async {
    await db.insert(
      'page_snapshots',
      {
        'page_id': pageId,
        'png_blob': pngBlob,
        'stroke_version': strokeVersion,
        'width': width,
        'height': height,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get a page's snapshot PNG blob, or null if none exists.
  Future<Uint8List?> getPageSnapshot(String pageId) async {
    final rows = await db.query(
      'page_snapshots',
      columns: ['png_blob'],
      where: 'page_id = ?',
      whereArgs: [pageId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['png_blob'] as Uint8List;
  }

  /// Delete a page's snapshot (e.g. on page clear or page delete).
  Future<void> deletePageSnapshot(String pageId) async {
    await db.delete(
      'page_snapshots',
      where: 'page_id = ?',
      whereArgs: [pageId],
    );
  }

  // ---------------------------------------------------------------------------
  // Spine blob backfill (Option A — pre-baked spine points)
  // ---------------------------------------------------------------------------

  /// Update the spine_blob for a single stroke.
  Future<void> updateSpineBlob(String strokeId, Uint8List spineBlob) async {
    await db.update(
      'strokes',
      {'spine_blob': spineBlob},
      where: 'id = ?',
      whereArgs: [strokeId],
    );
  }

  /// Get IDs of non-tombstone strokes that don't have pre-baked spine data.
  Future<List<String>> getStrokeIdsWithoutSpines({int limit = 100}) async {
    final rows = await db.query(
      'strokes',
      columns: ['id'],
      where: 'spine_blob IS NULL AND is_tombstone = 0',
      limit: limit,
    );
    return rows.map((r) => r['id'] as String).toList();
  }

  /// Purge ALL data from the database — nuclear option for dev/schema resets.
  ///
  /// Drops all rows from every table in dependency order, then re-creates
  /// a fresh default notebook/chapter/page so the app doesn't crash on reload.
  Future<void> purgeAllData() async {
    await db.transaction((txn) async {
      // Delete in dependency order (children first)
      await txn.delete('page_snapshots');
      await txn.delete('sync_queue');
      await txn.delete('ocr_snapshots');
      await txn.delete('image_pins');
      await txn.delete('gallery_images');
      await txn.delete('page_stroke_order');
      await txn.delete('strokes');
      await txn.delete('pages');
      await txn.delete('chapters');
      await txn.delete('notebooks');
    });
  }
}
