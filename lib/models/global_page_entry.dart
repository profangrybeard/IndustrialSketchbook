import 'sketch_page.dart';

/// A page paired with its chapter context, for the global page strip.
///
/// Carries chapter title and accent color so the PageStrip and
/// DeveloperOverlay can display chapter context without extra lookups.
/// Not persisted — exists only as a view model for the UI layer.
class GlobalPageEntry {
  final SketchPage page;
  final String chapterId;
  final String chapterTitle;
  final int chapterColor;

  /// Zero-based index of this chapter in the notebook.
  final int chapterIndex;

  /// Total number of chapters in the notebook.
  final int totalChapters;

  const GlobalPageEntry({
    required this.page,
    required this.chapterId,
    required this.chapterTitle,
    required this.chapterColor,
    required this.chapterIndex,
    required this.totalChapters,
  });
}
