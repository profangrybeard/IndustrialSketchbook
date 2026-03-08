import 'package:flutter/material.dart';

/// Minimal page navigation bar (Layer 3).
///
/// Shows current page position, prev/next buttons, and a new-page button.
/// Positioned at bottom-center of the canvas, away from the floating
/// palette (left/right edges) and developer overlay (top-left).
class PageStrip extends StatelessWidget {
  const PageStrip({
    required this.currentPage,
    required this.totalPages,
    required this.onNewPage,
    this.onPrevPage,
    this.onNextPage,
    super.key,
  });

  /// Zero-based index of the current page.
  final int currentPage;

  /// Total number of pages in the chapter.
  final int totalPages;

  /// Navigate to the previous page (null = at first page, button disabled).
  final VoidCallback? onPrevPage;

  /// Navigate to the next page (null = at last page, button disabled).
  final VoidCallback? onNextPage;

  /// Create a new blank page and switch to it.
  final VoidCallback onNewPage;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 12,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Previous page
              _stripButton(
                icon: Icons.chevron_left,
                onPressed: onPrevPage,
                tooltip: 'Previous page',
              ),

              // Page indicator
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Page ${currentPage + 1} / $totalPages',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),

              // Next page
              _stripButton(
                icon: Icons.chevron_right,
                onPressed: onNextPage,
                tooltip: 'Next page',
              ),

              // Divider
              Container(
                width: 1,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: Colors.white.withValues(alpha: 0.2),
              ),

              // New page
              _stripButton(
                icon: Icons.add,
                onPressed: onNewPage,
                tooltip: 'New page',
              ),
            ],
          ),
        ),
      ),
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
            ? Colors.white.withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: 0.25),
        onPressed: onPressed,
        tooltip: tooltip,
      ),
    );
  }
}
