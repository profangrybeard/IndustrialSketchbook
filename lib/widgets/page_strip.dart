import 'package:flutter/material.dart';

/// Page navigation bar with chapter context (Layer 4b).
///
/// Shows global page position, chapter name with accent color,
/// prev/next buttons that cross chapter boundaries, and buttons
/// for creating new pages and chapters.
///
/// Positioned at bottom-center of the canvas, away from the floating
/// palette (left/right edges) and developer overlay (top-left).
class PageStrip extends StatelessWidget {
  const PageStrip({
    required this.currentPage,
    required this.totalPages,
    required this.chapterTitle,
    required this.chapterColor,
    required this.chapterIndex,
    required this.totalChapters,
    required this.onNewPage,
    required this.onNewChapter,
    this.onPrevPage,
    this.onNextPage,
    this.onOrganize,
    this.isLoading = false,
    super.key,
  });

  /// Zero-based global index of the current page (across all chapters).
  final int currentPage;

  /// Total number of pages across all chapters.
  final int totalPages;

  /// Title of the chapter containing the current page.
  final String chapterTitle;

  /// ARGB accent color of the current chapter.
  final int chapterColor;

  /// Zero-based index of the current chapter.
  final int chapterIndex;

  /// Total number of chapters in the notebook.
  final int totalChapters;

  /// Navigate to the previous page (null = at first page, button disabled).
  final VoidCallback? onPrevPage;

  /// Navigate to the next page (null = at last page, button disabled).
  final VoidCallback? onNextPage;

  /// Create a new blank page in the current chapter.
  final VoidCallback onNewPage;

  /// Create a new chapter with one blank page.
  final VoidCallback onNewChapter;

  /// Open the organize panel (null = button hidden).
  final VoidCallback? onOrganize;

  /// Whether strokes are currently loading for the active page.
  /// Shows a thin progress bar above the strip.
  final bool isLoading;

  static const _labelStyle = TextStyle(
    color: Color.fromRGBO(255, 255, 255, 0.85),
    fontSize: 12,
    fontFamily: 'monospace',
    fontWeight: FontWeight.w500,
  );

  @override
  Widget build(BuildContext context) {
    final accentColor = Color(chapterColor);
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;

    return Positioned(
      bottom: 12 + bottomInset,
      left: 8,
      right: 8,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Thin loading progress bar — animates while strokes load
            AnimatedOpacity(
              opacity: isLoading ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  width: 140,
                  height: 3,
                  child: isLoading
                      ? const LinearProgressIndicator(
                          backgroundColor: Color.fromRGBO(100, 150, 255, 0.2),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Color.fromRGBO(70, 130, 255, 0.9),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Previous page (crosses chapter boundaries)
              _stripButton(
                icon: Icons.chevron_left,
                onPressed: onPrevPage,
                tooltip: 'Previous page',
              ),

              // Global page indicator
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '${currentPage + 1}/$totalPages',
                  style: _labelStyle,
                ),
              ),

              // Next page (crosses chapter boundaries)
              _stripButton(
                icon: Icons.chevron_right,
                onPressed: onNextPage,
                tooltip: 'Next page',
              ),

              // Divider
              _verticalDivider(),

              // Chapter context: colored dot + title + ch M/N
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: accentColor,
                  shape: BoxShape.circle,
                ),
              ),
              Flexible(
                child: Text(
                  chapterTitle,
                  style: _labelStyle,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  'ch ${chapterIndex + 1}/$totalChapters',
                  style: _labelStyle.copyWith(
                    color: const Color.fromRGBO(255, 255, 255, 0.5),
                  ),
                ),
              ),

              // Organize chapters
              _verticalDivider(),

              _stripButton(
                icon: Icons.toc,
                onPressed: onOrganize,
                tooltip: 'Organize chapters',
              ),

              // Divider
              _verticalDivider(),

              // New page (in current chapter)
              _stripButton(
                icon: Icons.add,
                onPressed: onNewPage,
                tooltip: 'New page',
              ),

              // New chapter
              _stripButton(
                icon: Icons.bookmark_add,
                onPressed: onNewChapter,
                tooltip: 'New chapter',
              ),
            ],
          ),
        ),
          ],
        ),
      ),
    );
  }

  Widget _verticalDivider() {
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: const Color.fromRGBO(255, 255, 255, 0.2),
    );
  }

  Widget _stripButton({
    required IconData icon,
    required VoidCallback? onPressed,
    required String tooltip,
  }) {
    final enabled = onPressed != null;
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        icon: Icon(icon),
        iconSize: 18,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        color: enabled
            ? const Color.fromRGBO(255, 255, 255, 0.85)
            : const Color.fromRGBO(255, 255, 255, 0.25),
        onPressed: onPressed,
        tooltip: tooltip,
      ),
    );
  }
}
