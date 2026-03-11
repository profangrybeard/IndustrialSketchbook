import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chapter.dart';
import '../models/notebooks_snapshot.dart';
import '../models/render_point.dart';
import '../models/sketch_page.dart';
import '../models/sync_journal.dart';
import '../models/stroke.dart';
import '../models/stroke_point.dart';
import '../models/sync_state.dart';
import 'database_service.dart';
import 'drive_service.dart';

/// Sync engine for Google Drive journal-based sync (Phase 3.2).
///
/// Orchestrates pull (download journals from other devices) and push
/// (upload unsynced strokes). Pull-first ensures we have remote structure
/// before our push merges it with local data.
///
/// ## Pull Flow (runs first)
/// 1. Download notebooks.json → upsert chapters/pages
/// 2. List journal files from other devices (newer than last pull)
/// 3. Download and merge each journal via insertStrokeIfNotExists()
/// 4. Update last pull timestamp
///
/// ## Push Flow (runs second)
/// 1. Query unsynced strokes from SQLite
/// 2. Bundle into journal JSON (batches of 500)
/// 3. Upload journal to Drive appDataFolder
/// 4. Upload notebooks.json (full merged structure snapshot)
/// 5. Mark uploaded strokes as synced
class SyncEngine extends ChangeNotifier {
  SyncEngine(this._drive, this._db, this._deviceId);

  final DriveService _drive;
  final DatabaseService _db;
  final String _deviceId;

  SyncState _state = const SyncIdle();
  SyncState get state => _state;

  DateTime? _lastSyncTime;
  DateTime? get lastSyncTime => _lastSyncTime;

  /// Last sync summary for UI feedback.
  String _lastSyncSummary = '';
  String get lastSyncSummary => _lastSyncSummary;

  static const _lastSyncKey = 'sync_last_sync_iso8601';
  static const _lastPullKey = 'sync_last_pull_iso8601';
  static const _maxBatchSize = 500;

  /// Logical canvas width of this device (for cross-device coordinate scaling).
  double get _localCanvasWidth {
    final view = ui.PlatformDispatcher.instance.views.first;
    return view.physicalSize.width / view.devicePixelRatio;
  }

  /// Logical canvas height of this device (for v2 renderData denormalization).
  double get _localCanvasHeight {
    final view = ui.PlatformDispatcher.instance.views.first;
    return view.physicalSize.height / view.devicePixelRatio;
  }

  /// Initialize — load persisted last sync time.
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final iso = prefs.getString(_lastSyncKey);
    if (iso != null) {
      _lastSyncTime = DateTime.parse(iso);
      _state = SyncSuccess(_lastSyncTime!);
      notifyListeners();
    }
  }

  /// Full sync: pull first (get remote structure), then push.
  ///
  /// Pull-first ensures we have the remote device's pages in our DB
  /// before pushing our notebooks.json (which includes merged structure).
  Future<void> syncNow() async {
    if (_state is SyncPushing || _state is SyncPulling) return; // guard

    try {
      _state = const SyncPulling();
      notifyListeners();
      final pulled = await _pull();

      _state = const SyncPushing();
      notifyListeners();
      final pushed = await _push();

      _lastSyncTime = DateTime.now();
      await _saveLastSyncTime();
      _lastSyncSummary = 'Pulled $pulled, pushed $pushed strokes';
      _state = SyncSuccess(_lastSyncTime!);
      notifyListeners();

      debugPrint('Sync complete: pulled $pulled strokes, pushed $pushed strokes');
    } catch (e, stack) {
      debugPrint('Sync error: $e\n$stack');
      _state = SyncError(e.toString());
      notifyListeners();
    }
  }

  /// Force push: wipe all Drive data and re-upload everything from this device.
  ///
  /// Makes this device's local data the sole source of truth.
  Future<void> forcePush() async {
    if (_state is SyncPushing || _state is SyncPulling) return;

    try {
      _state = const SyncPushing();
      notifyListeners();

      // 1. Delete ALL files from Drive appDataFolder
      _state = const SyncPushing(phase: 'Clearing cloud data...');
      notifyListeners();
      final allFiles = await _drive.listFiles();
      for (final file in allFiles) {
        await _drive.deleteFile(file.id);
      }
      debugPrint('Force push: deleted ${allFiles.length} files from Drive');

      // 2. Mark all strokes as unsynced so they get re-uploaded
      _state = const SyncPushing(phase: 'Preparing strokes...');
      notifyListeners();
      await _db.markAllStrokesUnsynced();

      // 3. Normal push (uploads everything)
      final pushed = await _push();

      // 4. Clear pull time so other devices re-pull everything
      await _clearLastPullTime();

      _lastSyncTime = DateTime.now();
      await _saveLastSyncTime();
      _lastSyncSummary = 'Force pushed $pushed strokes';
      _state = SyncSuccess(_lastSyncTime!);
      notifyListeners();

      debugPrint('Force push complete: uploaded $pushed strokes');
    } catch (e, stack) {
      debugPrint('Force push error: $e\n$stack');
      _state = SyncError(e.toString());
      notifyListeners();
    }
  }

  /// Push unsynced strokes to Drive. Returns count of strokes pushed.
  ///
  /// Phase 4: uses v2 compact format (renderData only, gzip compressed).
  /// Tombstone compaction omits stroke+tombstone pairs from the same batch.
  Future<int> _push() async {
    _state = const SyncPushing(phase: 'Checking unsynced strokes...');
    notifyListeners();
    final strokes = await _db.getUnsyncedStrokes();
    debugPrint('Push: ${strokes.length} unsynced strokes to upload');
    if (strokes.isEmpty) {
      // Still push notebooks.json for structure changes
      await _pushNotebooksSnapshot();
      return 0;
    }

    // Phase 4: tombstone compaction — if a stroke and its tombstone are
    // both in the push batch, omit both (the net effect is no change).
    final compacted = _compactTombstones(strokes);
    final compactedCount = strokes.length - compacted.length;
    if (compactedCount > 0) {
      debugPrint('Push: compacted $compactedCount strokes '
          '(${compactedCount ~/ 2} stroke+tombstone pairs)');
    }

    int pushed = 0;
    // Split into batches of 500
    for (var i = 0; i < compacted.length; i += _maxBatchSize) {
      final end = (i + _maxBatchSize > compacted.length)
          ? compacted.length
          : i + _maxBatchSize;
      final batch = compacted.sublist(i, end);

      final journal = SyncJournal(
        version: 2,
        deviceId: _deviceId,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        strokes: batch,
      );

      final filename =
          'journal_${_deviceId}_${DateTime.now().millisecondsSinceEpoch}.json.gz';
      await _drive.uploadGzip(filename, journal.toJson());

      // Mark the original strokes (including compacted ones) as synced
      final batchIds = batch.map((s) => s.id).toList();
      await _db.markStrokesSynced(batchIds);
      pushed += batch.length;
      _state = SyncPushing(
        phase: 'Uploading strokes...',
        pushed: pushed,
        total: compacted.length,
      );
      notifyListeners();
      debugPrint('Push: uploaded batch of ${batch.length} strokes ($filename)');
    }

    // Mark compacted strokes as synced too (they were omitted from upload
    // but shouldn't be re-uploaded next time)
    if (compactedCount > 0) {
      final allIds = strokes.map((s) => s.id).toList();
      final pushedIds = compacted.map((s) => s.id).toSet();
      final compactedIds =
          allIds.where((id) => !pushedIds.contains(id)).toList();
      if (compactedIds.isNotEmpty) {
        await _db.markStrokesSynced(compactedIds);
      }
    }

    // Upload structure snapshot after strokes
    _state = SyncPushing(
      phase: 'Uploading structure...',
      pushed: pushed,
      total: compacted.length,
    );
    notifyListeners();
    await _pushNotebooksSnapshot();
    return pushed;
  }

  /// Remove stroke+tombstone pairs from a batch.
  ///
  /// If a tombstone targets a stroke that's also in the batch, both are
  /// omitted — the net effect is zero (the stroke was drawn and erased
  /// in the same sync cycle).
  List<Stroke> _compactTombstones(List<Stroke> strokes) {
    // Build a set of stroke IDs targeted by tombstones in this batch
    final tombstoneTargets = <String>{};
    final tombstoneIds = <String>{};
    for (final s in strokes) {
      if (s.isTombstone && s.erasesStrokeId != null) {
        tombstoneTargets.add(s.erasesStrokeId!);
        tombstoneIds.add(s.id);
      }
    }

    // Check which targets actually exist in this batch
    final strokeIds = strokes.map((s) => s.id).toSet();
    final compactableTargets = tombstoneTargets.intersection(strokeIds);
    if (compactableTargets.isEmpty) return strokes;

    // Find tombstone IDs that target compactable strokes
    final compactableTombstones = <String>{};
    for (final s in strokes) {
      if (s.isTombstone &&
          s.erasesStrokeId != null &&
          compactableTargets.contains(s.erasesStrokeId)) {
        compactableTombstones.add(s.id);
      }
    }

    // Filter out both the compacted strokes and their tombstones
    return strokes
        .where((s) =>
            !compactableTargets.contains(s.id) &&
            !compactableTombstones.contains(s.id))
        .toList();
  }

  /// Upload notebooks.json — full structure snapshot (last-write-wins).
  Future<void> _pushNotebooksSnapshot() async {
    final notebooks = await _db.getAllNotebooks();
    final chapters = await _db.getAllChapters();
    final pages = await _db.getAllPages();

    final snapshot = NotebooksSnapshot(
      deviceId: _deviceId,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      notebooks: notebooks.map((n) => n.toJson()).toList(),
      chapters: chapters.map((c) => c.toJson()).toList(),
      pages: pages.map((p) => p.toJson()).toList(),
    );

    debugPrint('Push structure: ${notebooks.length} notebooks, '
        '${chapters.length} chapters, ${pages.length} pages');

    // Find existing notebooks.json or create new
    final files = await _drive.listFiles(nameContains: 'notebooks.json');
    if (files.isNotEmpty) {
      await _drive.updateJson(files.first.id, snapshot.toJson());
    } else {
      await _drive.uploadJson('notebooks.json', snapshot.toJson());
    }
  }

  /// Pull journals from other devices. Returns count of strokes imported.
  Future<int> _pull() async {
    // 1. Download and merge structure
    _state = const SyncPulling(phase: 'Downloading structure...');
    notifyListeners();
    await _pullNotebooksSnapshot();

    // 2. List all journal files from OTHER devices
    final allJournals = await _drive.listFiles(nameContains: 'journal_');
    debugPrint('Pull: found ${allJournals.length} total journals on Drive');
    final otherDeviceJournals =
        allJournals.where((f) => !f.name.contains(_deviceId)).toList();
    debugPrint('Pull: ${otherDeviceJournals.length} from other devices '
        '(my deviceId: $_deviceId)');

    if (otherDeviceJournals.isEmpty) return 0;

    // 3. Filter to journals newer than last pull
    final lastPull = await _loadLastPullTime();
    debugPrint('Pull: lastPullTime = $lastPull');
    final newJournals = lastPull == null
        ? otherDeviceJournals
        : otherDeviceJournals
            .where((f) => f.createdTime.isAfter(lastPull))
            .toList();
    debugPrint('Pull: ${newJournals.length} journals newer than lastPull');

    if (newJournals.isEmpty) return 0;

    _state = SyncPulling(
      phase: 'Downloading journals...',
      journalsTotal: newJournals.length,
    );
    notifyListeners();

    // 4. Download and merge each journal (per-stroke error handling)
    // Phase 4: v2 journals (.json.gz) use downloadGzip; v1 (.json) use downloadJson.
    // v2 journals have normalized coordinates — no scaling needed.
    // v1 journals may need cross-device canvasWidth scaling (legacy).
    final localWidth = _localCanvasWidth;
    int imported = 0;
    int skipped = 0;
    int errors = 0;
    int journalsDone = 0;
    for (final file in newJournals) {
      try {
        // Detect format from filename extension
        final isGzip = file.name.endsWith('.json.gz');
        final json = isGzip
            ? await _drive.downloadGzip(file.id)
            : await _drive.downloadJson(file.id);
        final journal = SyncJournal.fromJson(json);
        debugPrint('Pull: processing ${file.name} '
            '(v${journal.version}, ${journal.strokes.length} strokes)');

        // v1 journals: legacy scaling if canvas widths differ
        // v2 journals: coordinates are normalized 0.0–1.0, no scaling needed
        final needsScale = journal.version < 2 &&
            journal.canvasWidth != null &&
            localWidth > 0 &&
            (journal.canvasWidth! - localWidth).abs() > 10;
        final scaleFactor =
            needsScale ? localWidth / journal.canvasWidth! : 1.0;
        if (needsScale) {
          debugPrint('Pull: v1 scaling '
              '${journal.canvasWidth!.toStringAsFixed(0)}'
              ' -> ${localWidth.toStringAsFixed(0)}'
              ' (factor=${scaleFactor.toStringAsFixed(3)})');
        }

        for (final stroke in journal.strokes) {
          try {
            // v1: legacy coordinate scaling
            // v2: denormalize renderData (0.0–1.0) to device-pixel points
            Stroke s;
            if (needsScale) {
              s = _scaleStroke(stroke, scaleFactor);
            } else if (journal.version >= 2) {
              s = _denormalizeStroke(stroke);
            } else {
              s = stroke;
            }
            final inserted = await _db.insertStrokeIfNotExists(s);
            if (inserted) {
              imported++;
            } else {
              skipped++;
            }
          } catch (e) {
            // Per-stroke catch: skip strokes with missing pages (FK error)
            // or other DB issues without killing the whole journal
            errors++;
          }
        }
        journalsDone++;
        _state = SyncPulling(
          phase: 'Importing strokes...',
          journalsDone: journalsDone,
          journalsTotal: newJournals.length,
          imported: imported,
        );
        notifyListeners();
      } catch (e) {
        debugPrint('Failed to download journal ${file.name}: $e');
      }
    }

    debugPrint('Pull complete: imported $imported new, '
        'skipped $skipped existing, $errors errors');
    // 5. Save pull timestamp
    await _saveLastPullTime(DateTime.now());
    return imported;
  }

  /// Download and merge notebooks.json (structure).
  Future<void> _pullNotebooksSnapshot() async {
    final files = await _drive.listFiles(nameContains: 'notebooks.json');
    if (files.isEmpty) {
      debugPrint('Pull structure: no notebooks.json on Drive');
      return;
    }

    final json = await _drive.downloadJson(files.first.id);
    final snapshot = NotebooksSnapshot.fromJson(json);
    debugPrint('Pull structure: ${snapshot.notebooks.length} notebooks, '
        '${snapshot.chapters.length} chapters, '
        '${snapshot.pages.length} pages from device=${snapshot.deviceId}');

    // Upsert chapters and pages (last-write-wins)
    for (final chapterJson in snapshot.chapters) {
      final ch = Chapter.fromJson(chapterJson);
      debugPrint('  upsert chapter: ${ch.id} "${ch.title}"');
      await _db.upsertChapter(ch);
    }
    for (final pageJson in snapshot.pages) {
      final pg = SketchPage.fromJson(pageJson);
      debugPrint('  upsert page: ${pg.id} chapter=${pg.chapterId}');
      await _db.upsertPage(pg);
    }
    debugPrint('Pull structure: upsert complete');
  }

  /// Scale stroke coordinates and weight for cross-device display.
  Stroke _scaleStroke(Stroke stroke, double factor) {
    final scaledPoints = stroke.points
        .map((p) => StrokePoint(
              x: p.x * factor,
              y: p.y * factor,
              pressure: p.pressure,
              tiltX: p.tiltX,
              tiltY: p.tiltY,
              twist: p.twist,
              timestamp: p.timestamp,
            ))
        .toList();
    return Stroke(
      id: stroke.id,
      pageId: stroke.pageId,
      layerId: stroke.layerId,
      tool: stroke.tool,
      color: stroke.color,
      weight: stroke.weight * factor,
      opacity: stroke.opacity,
      points: scaledPoints,
      createdAt: stroke.createdAt,
      isTombstone: stroke.isTombstone,
      erasesStrokeId: stroke.erasesStrokeId,
      synced: stroke.synced,
    );
  }

  /// Denormalize a v2 synced stroke: convert renderData (0.0–1.0) into
  /// device-pixel [StrokePoint] objects so the rendering pipeline can display
  /// them via the [renderPoints] bridge getter.
  ///
  /// If the stroke has no renderData (e.g. tombstones), returns it unchanged.
  Stroke _denormalizeStroke(Stroke stroke) {
    final rd = stroke.renderData;
    if (rd == null || rd.isEmpty) return stroke;

    final w = _localCanvasWidth;
    final h = _localCanvasHeight;
    final denormalized = rd
        .map((rp) => StrokePoint(
              x: rp.x * w,
              y: rp.y * h,
              pressure: rp.pressure,
              tiltX: 0.0,
              tiltY: 0.0,
              twist: 0.0,
              timestamp: 0,
            ))
        .toList();

    return Stroke(
      id: stroke.id,
      pageId: stroke.pageId,
      layerId: stroke.layerId,
      tool: stroke.tool,
      color: stroke.color,
      weight: stroke.weight,
      opacity: stroke.opacity,
      points: denormalized,
      renderData: rd,
      createdAt: stroke.createdAt,
      isTombstone: stroke.isTombstone,
      erasesStrokeId: stroke.erasesStrokeId,
      synced: true,
    );
  }

  // ---------------------------------------------------------------------------
  // Persistence helpers
  // ---------------------------------------------------------------------------

  Future<void> _saveLastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _lastSyncKey, _lastSyncTime!.toUtc().toIso8601String());
  }

  Future<DateTime?> _loadLastPullTime() async {
    final prefs = await SharedPreferences.getInstance();
    final iso = prefs.getString(_lastPullKey);
    return iso != null ? DateTime.parse(iso) : null;
  }

  Future<void> _saveLastPullTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastPullKey, time.toUtc().toIso8601String());
  }

  Future<void> _clearLastPullTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastPullKey);
  }
}
