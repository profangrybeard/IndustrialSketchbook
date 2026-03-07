import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chapter.dart';
import '../models/notebook.dart';
import '../models/sketch_page.dart';
import '../services/database_service.dart';

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
  final db = DatabaseService();
  await db.initialize();

  // Seed default notebook → chapter → page if they don't exist yet
  await _seedDefaults(db);

  // Clean up on dispose
  ref.onDispose(() => db.close());

  return db;
});

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
