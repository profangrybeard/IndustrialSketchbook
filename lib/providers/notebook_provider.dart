import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/notebook.dart';
import '../models/chapter.dart';
import '../models/sketch_page.dart';
import 'database_provider.dart';

/// Provides the current notebook.
///
/// In v1 there is one notebook per user (TDD §3.4).
/// This provider loads the default notebook or creates one if none exists.
///
/// Loads the default notebook from the database.
/// In v1 there is one notebook per user, seeded on first launch.
final currentNotebookProvider = FutureProvider<Notebook?>((ref) async {
  final db = await ref.watch(databaseServiceProvider.future);
  return db.getNotebook(defaultNotebookId);
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

/// Tracks the currently displayed page ID.
///
/// Changed when the user navigates between pages via the page strip.
/// Initialized to [defaultPageId] (the seeded first page).
final currentPageIdProvider = StateProvider<String>((ref) => defaultPageId);

/// Provides all pages for the default chapter, ordered by pageNumber.
///
/// Used by the page strip to show "Page X of Y" and for navigation.
final pagesForChapterProvider = FutureProvider<List<SketchPage>>((ref) async {
  final db = await ref.watch(databaseServiceProvider.future);
  return db.getPagesByChapter(defaultChapterId);
});
