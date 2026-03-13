import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/chapter.dart';
import '../models/notebook.dart';
import '../models/sketch_page.dart';
import '../services/database_service.dart';
import '../services/migration_service.dart';
import '../utils/coordinate_utils.dart';

/// Default entity IDs used for the Phase 2 single-page canvas.
const defaultNotebookId = 'default-notebook';
const defaultChapterId = 'default-chapter';
const defaultPageId = 'default-page';

/// Provides a singleton [DatabaseService] instance.
///
/// Initialized asynchronously at app startup. All services that need
/// database access should depend on this provider.
///
/// Seeds a default notebook → chapter → page on first run so that
/// stroke persistence has valid foreign key targets.
///
/// Usage:
/// ```dart
/// final dbAsync = ref.watch(databaseServiceProvider);
/// dbAsync.when(
///   data: (db) => /* use db */,
///   loading: () => /* show spinner */,
///   error: (e, s) => /* show error */,
/// );
/// ```
final databaseServiceProvider = FutureProvider<DatabaseService>((ref) async {
  // Initialize coordinate system. Deferred from main() because the view
  // may not have metrics yet at startup (physicalSize is zero until the
  // Android surface is created and viewport metrics are sent to the engine).
  await _ensureCoordinateSystemReady();

  final db = DatabaseService();
  await db.initialize();

  // Seed default notebook → chapter → page if they don't exist yet
  await _seedDefaults(db);

  // Migrate legacy world-coordinate strokes to reference units (Option B).
  // Fire-and-forget: mixed format-0/format-1 pages work fine since
  // fromDbMap handles each row independently. Migration runs in the
  // background while the user starts drawing.
  final migration = MigrationService(db.db);
  migration.migrateToReferenceUnits();

  // Clean up on dispose
  ref.onDispose(() => db.close());

  return db;
});

/// Unique device identifier for sync (Phase 3).
///
/// Generated once per app install and stored in SharedPreferences.
/// Used to identify which device uploaded a sync journal.
final deviceIdProvider = FutureProvider<String>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  const key = 'sync_device_id';
  var deviceId = prefs.getString(key);
  if (deviceId == null) {
    deviceId = const Uuid().v4();
    await prefs.setString(key, deviceId);
  }
  return deviceId;
});


/// Wait for the view to have valid metrics, then initialize [CoordinateUtils].
///
/// On Android, `PlatformDispatcher.views.first.physicalSize` is zero at
/// startup until the native surface is created and viewport metrics are
/// sent to the Dart engine. This typically takes ~200ms. We poll every 10ms
/// so the app starts as soon as metrics arrive (loading spinner is visible
/// during this wait).
Future<void> _ensureCoordinateSystemReady() async {
  if (CoordinateUtils.isInitialized) return;

  final view = PlatformDispatcher.instance.views.first;

  for (var i = 0; i < 100; i++) {
    final logicalWidth = view.physicalSize.width / view.devicePixelRatio;
    if (logicalWidth > 0) {
      CoordinateUtils.initialize(logicalWidth);
      debugPrint(
        '[CoordinateUtils] Initialized: width=$logicalWidth '
        'scale=${CoordinateUtils.referenceScale.toStringAsFixed(4)}',
      );
      return;
    }
    await Future.delayed(const Duration(milliseconds: 10));
  }

  // Extreme fallback — should never happen on real devices.
  debugPrint('[CoordinateUtils] WARNING: metrics timeout, using 400px fallback');
  CoordinateUtils.initialize(400.0);
}

/// Create the default notebook, chapter, and page if they don't already exist.
Future<void> _seedDefaults(DatabaseService db) async {
  final existing = await db.getNotebook(defaultNotebookId);
  if (existing != null) return; // Already seeded

  await db.insertNotebook(const Notebook(
    id: defaultNotebookId,
    title: 'My Sketchbook',
    ownerId: 'local',
  ));

  await db.insertChapter(const Chapter(
    id: defaultChapterId,
    notebookId: defaultNotebookId,
    title: 'Untitled Chapter',
    order: 0,
  ));

  await db.insertPage(const SketchPage(
    id: defaultPageId,
    chapterId: defaultChapterId,
    pageNumber: 0,
  ));
}
