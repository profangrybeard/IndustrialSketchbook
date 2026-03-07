import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/notebook.dart';
import '../models/chapter.dart';
import 'database_provider.dart';

/// Provides the current notebook.
///
/// In v1 there is one notebook per user (TDD §3.4).
/// This provider loads the default notebook or creates one if none exists.
///
/// TODO Phase 1: Implement default notebook creation on first launch.
final currentNotebookProvider = FutureProvider<Notebook?>((ref) async {
  final db = await ref.watch(databaseServiceProvider.future);
  // TODO: Load default notebook from DB
  return null; // Stub — no notebook until Phase 1 implementation
});

/// Provides all chapters for the current notebook.
///
/// Sorted by [Chapter.order] ascending.
final chaptersProvider = FutureProvider<List<Chapter>>((ref) async {
  final notebook = await ref.watch(currentNotebookProvider.future);
  if (notebook == null) return [];

  final db = await ref.watch(databaseServiceProvider.future);
  return db.getChaptersByNotebook(notebook.id);
});
