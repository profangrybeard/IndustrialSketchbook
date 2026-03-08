import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chapter.dart';
import '../providers/database_provider.dart';
import '../providers/notebook_provider.dart';
import 'color_wheel_dialog.dart';

/// Right-side slide-in panel for chapter management (Layer 4c).
///
/// Provides rename, recolor, reorder, delete chapters, move pages between
/// chapters, and jump-to-chapter navigation. Triggered from the PageStrip
/// organize button.
class OrganizePanel extends ConsumerStatefulWidget {
  const OrganizePanel({
    required this.onClose,
    required this.onNavigateToChapter,
    required this.onSwitchToPage,
    super.key,
  });

  /// Close the panel.
  final VoidCallback onClose;

  /// Navigate to the first page of a chapter (by chapter ID).
  final ValueChanged<String> onNavigateToChapter;

  /// Switch to a specific page (triggers full canvas reload).
  final ValueChanged<String> onSwitchToPage;

  @override
  ConsumerState<OrganizePanel> createState() => _OrganizePanelState();
}

class _OrganizePanelState extends ConsumerState<OrganizePanel> {
  /// Which chapter title is currently being inline-edited.
  String? _editingChapterId;

  /// Controller for the inline title editor.
  final _titleController = TextEditingController();

  /// Target chapter for move-page operation.
  String? _selectedTargetChapterId;

  /// Whether to move the page to the end (true) or start (false) of the
  /// target chapter.
  bool _moveToEnd = true;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final chaptersAsync = ref.watch(chaptersProvider);
    final currentChapterId = ref.watch(currentChapterIdProvider);
    final currentPageId = ref.watch(currentPageIdProvider);

    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      width: 320,
      child: Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              bottomLeft: Radius.circular(14),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 16,
                offset: const Offset(-4, 0),
              ),
            ],
          ),
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: _buildChapterList(chaptersAsync, currentChapterId),
              ),
              _buildPageActionsSection(
                chaptersAsync,
                currentChapterId,
                currentPageId,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header
  // ---------------------------------------------------------------------------

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color.fromRGBO(255, 255, 255, 0.1)),
        ),
      ),
      child: Row(
        children: [
          const Text(
            'ORGANIZE',
            style: TextStyle(
              color: Color.fromRGBO(255, 255, 255, 0.6),
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close),
            iconSize: 20,
            color: const Color.fromRGBO(255, 255, 255, 0.6),
            onPressed: widget.onClose,
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Chapter list (reorderable)
  // ---------------------------------------------------------------------------

  Widget _buildChapterList(
    AsyncValue<List<Chapter>> chaptersAsync,
    String currentChapterId,
  ) {
    return chaptersAsync.when(
      data: (chapters) {
        if (chapters.isEmpty) {
          return const Center(
            child: Text(
              'No chapters',
              style: TextStyle(color: Color.fromRGBO(255, 255, 255, 0.4)),
            ),
          );
        }

        return ReorderableListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: chapters.length,
          onReorder: (oldIndex, newIndex) =>
              _handleReorder(chapters, oldIndex, newIndex),
          proxyDecorator: _proxyDecorator,
          itemBuilder: (context, index) {
            final chapter = chapters[index];
            final isCurrent = chapter.id == currentChapterId;
            final isEditing = _editingChapterId == chapter.id;

            return _ChapterTile(
              key: ValueKey(chapter.id),
              index: index,
              chapter: chapter,
              isCurrent: isCurrent,
              isEditing: isEditing,
              titleController: isEditing ? _titleController : null,
              onTap: () => widget.onNavigateToChapter(chapter.id),
              onTapTitle: () => _startEditing(chapter),
              onSubmitTitle: (newTitle) => _submitTitle(chapter, newTitle),
              onTapColor: () => _pickColor(chapter),
              onDelete: chapters.length > 1
                  ? () => _confirmDelete(chapter)
                  : null,
            );
          },
        );
      },
      loading: () => const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      error: (_, __) => const Center(
        child: Text(
          'Error loading chapters',
          style: TextStyle(color: Color.fromRGBO(255, 255, 255, 0.4)),
        ),
      ),
    );
  }

  /// Decoration for the dragged item during reorder.
  Widget _proxyDecorator(Widget child, int index, Animation<double> animation) {
    return Material(
      color: Colors.transparent,
      elevation: 4,
      shadowColor: Colors.black54,
      child: child,
    );
  }

  // ---------------------------------------------------------------------------
  // Page actions section
  // ---------------------------------------------------------------------------

  Widget _buildPageActionsSection(
    AsyncValue<List<Chapter>> chaptersAsync,
    String currentChapterId,
    String currentPageId,
  ) {
    return chaptersAsync.when(
      data: (chapters) {
        final currentChapter = chapters.firstWhere(
          (c) => c.id == currentChapterId,
          orElse: () => chapters.first,
        );

        final targets =
            chapters.where((c) => c.id != currentChapterId).toList();

        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: Color.fromRGBO(255, 255, 255, 0.1)),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Section header
              const Text(
                'CURRENT PAGE',
                style: TextStyle(
                  color: Color.fromRGBO(255, 255, 255, 0.5),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 8),

              // Current page context
              Text(
                'In "${currentChapter.title}"',
                style: const TextStyle(
                  color: Color.fromRGBO(255, 255, 255, 0.7),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 10),

              // Action buttons row: Delete page
              Row(
                children: [
                  // Delete page button
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: OutlinedButton.icon(
                        onPressed: () => _confirmDeletePage(currentPageId),
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('Delete Page'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          side: const BorderSide(
                            color: Color.fromRGBO(255, 82, 82, 0.4),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              // Move section (only if multiple chapters exist)
              if (targets.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Text(
                  'MOVE TO',
                  style: TextStyle(
                    color: Color.fromRGBO(255, 255, 255, 0.5),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 8),

                // Target chapter chips
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final chapter in targets)
                      _ChapterChip(
                        chapter: chapter,
                        isSelected: _selectedTargetChapterId == chapter.id,
                        onTap: () {
                          setState(() {
                            _selectedTargetChapterId = chapter.id;
                          });
                        },
                      ),
                  ],
                ),

                // Position selector + move button (visible when target selected)
                if (_selectedTargetChapterId != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text(
                        'Position:',
                        style: TextStyle(
                          color: Color.fromRGBO(255, 255, 255, 0.5),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _PositionChip(
                        label: 'Start',
                        isSelected: !_moveToEnd,
                        onTap: () => setState(() => _moveToEnd = false),
                      ),
                      const SizedBox(width: 6),
                      _PositionChip(
                        label: 'End',
                        isSelected: _moveToEnd,
                        onTap: () => setState(() => _moveToEnd = true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 36,
                    child: FilledButton(
                      onPressed: _executeMovePage,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text('MOVE'),
                    ),
                  ),
                ],
              ],
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// Show a confirmation dialog before deleting the current page.
  Future<void> _confirmDeletePage(String pageId) async {
    final db = await ref.read(databaseServiceProvider.future);
    final currentChapterId = ref.read(currentChapterIdProvider);
    final pages = await db.getPagesByChapter(currentChapterId);
    final isLastPageInChapter = pages.length <= 1;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Page?'),
        content: Text(
          isLastPageInChapter
              ? 'This is the last page in this chapter.\n'
                'Deleting it will also remove the chapter.\n'
                'This cannot be undone.'
              : 'Delete this page and all its strokes?\n'
                'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final pageIndex = pages.indexWhere((p) => p.id == pageId);

    final success = await db.deletePage(pageId);
    if (success) {
      // Page deleted (chapter still has other pages).
      ref.invalidate(pagesForChapterProvider);
      ref.invalidate(globalPageListProvider);

      // Navigate to the next page, or previous if we deleted the last one.
      String targetPageId;
      if (pageIndex < pages.length - 1) {
        targetPageId = pages[pageIndex + 1].id;
      } else if (pageIndex > 0) {
        targetPageId = pages[pageIndex - 1].id;
      } else {
        return;
      }
      widget.onSwitchToPage(targetPageId);
      return;
    }

    // deletePage returned false — this is the last page in the chapter.
    // Auto-delete the chapter too, unless it's the only chapter.
    final chapterCount = await db.getChapterCount(defaultNotebookId);
    if (chapterCount <= 1) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot delete the last page in the last chapter'),
          ),
        );
      }
      return;
    }

    // Delete the entire chapter (cascade-deletes the page too).
    final chapterDeleted = await db.deleteChapter(currentChapterId);
    if (!chapterDeleted) return;

    ref.invalidate(chaptersProvider);
    ref.invalidate(pagesForChapterProvider);
    ref.invalidate(globalPageListProvider);

    // Navigate to the first page of an adjacent chapter.
    final remainingChapters = await db.getChaptersByNotebook(defaultNotebookId);
    if (remainingChapters.isNotEmpty) {
      widget.onNavigateToChapter(remainingChapters.first.id);
    }
  }

  /// Begin inline editing a chapter title.
  void _startEditing(Chapter chapter) {
    setState(() {
      _editingChapterId = chapter.id;
      _titleController.text = chapter.title;
    });
  }

  /// Submit an inline title edit.
  Future<void> _submitTitle(Chapter chapter, String newTitle) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty || trimmed == chapter.title) {
      setState(() => _editingChapterId = null);
      return;
    }
    final db = (await ref.read(databaseServiceProvider.future));
    await db.updateChapter(chapter.copyWith(title: trimmed));
    ref.invalidate(chaptersProvider);
    ref.invalidate(globalPageListProvider);
    if (mounted) setState(() => _editingChapterId = null);
  }

  /// Open the color picker dialog for a chapter.
  Future<void> _pickColor(Chapter chapter) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => ColorWheelDialog(
        initialColor: Color(chapter.color),
        onColorPicked: (color) async {
          final db = await ref.read(databaseServiceProvider.future);
          await db.updateChapter(chapter.copyWith(color: color.toARGB32()));
          ref.invalidate(chaptersProvider);
          ref.invalidate(globalPageListProvider);
        },
      ),
    );
  }

  /// Show a confirmation dialog before deleting a chapter.
  Future<void> _confirmDelete(Chapter chapter) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Chapter?'),
        content: Text(
          'Delete "${chapter.title}" and all its pages?\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final db = await ref.read(databaseServiceProvider.future);
    final currentChapterId = ref.read(currentChapterIdProvider);

    final success = await db.deleteChapter(chapter.id);
    if (!success) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot delete the last chapter')),
        );
      }
      return;
    }

    // If the user was viewing a page in the deleted chapter, navigate away.
    if (chapter.id == currentChapterId) {
      final chapters = await db.getChaptersByNotebook(defaultNotebookId);
      if (chapters.isNotEmpty) {
        widget.onNavigateToChapter(chapters.first.id);
      }
    }

    ref.invalidate(chaptersProvider);
    ref.invalidate(globalPageListProvider);
    ref.invalidate(pagesForChapterProvider);
  }

  /// Reorder chapters after a drag-and-drop.
  Future<void> _handleReorder(
    List<Chapter> chapters,
    int oldIndex,
    int newIndex,
  ) async {
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex == newIndex) return;

    final reordered = List<Chapter>.from(chapters);
    final item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);

    final db = await ref.read(databaseServiceProvider.future);
    await db.reorderChapters(reordered.map((c) => c.id).toList());
    ref.invalidate(chaptersProvider);
    ref.invalidate(globalPageListProvider);
  }

  /// Execute the move-page operation.
  Future<void> _executeMovePage() async {
    if (_selectedTargetChapterId == null) return;

    final db = await ref.read(databaseServiceProvider.future);
    final currentPageId = ref.read(currentPageIdProvider);
    final currentChapterId = ref.read(currentChapterIdProvider);

    // Guard: do not move the last page out of a chapter.
    final sourcePageCount = await db.getPageCount(currentChapterId);
    if (sourcePageCount <= 1) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Cannot move the last page out of a chapter'),
          ),
        );
      }
      return;
    }

    final targetPageNumber = _moveToEnd
        ? await db.getPageCount(_selectedTargetChapterId!)
        : 0;

    await db.movePageToChapter(
      currentPageId,
      _selectedTargetChapterId!,
      targetPageNumber,
    );

    // Update current chapter to the target.
    ref.read(currentChapterIdProvider.notifier).state =
        _selectedTargetChapterId!;

    ref.invalidate(chaptersProvider);
    ref.invalidate(globalPageListProvider);
    ref.invalidate(pagesForChapterProvider);

    if (mounted) {
      setState(() {
        _selectedTargetChapterId = null;
        _moveToEnd = true;
      });
    }
  }
}

// =============================================================================
// Private sub-widgets
// =============================================================================

/// A single chapter row in the organize list.
class _ChapterTile extends StatelessWidget {
  const _ChapterTile({
    required this.index,
    required this.chapter,
    required this.isCurrent,
    required this.isEditing,
    required this.onTap,
    required this.onTapTitle,
    required this.onSubmitTitle,
    required this.onTapColor,
    required this.onDelete,
    this.titleController,
    super.key,
  });

  /// Position in the reorderable list (for drag handle).
  final int index;
  final Chapter chapter;
  final bool isCurrent;
  final bool isEditing;
  final TextEditingController? titleController;
  final VoidCallback onTap;
  final VoidCallback onTapTitle;
  final ValueChanged<String> onSubmitTitle;
  final VoidCallback onTapColor;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final accentColor = Color(chapter.color);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isCurrent
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isCurrent
              ? Border(
                  left: BorderSide(color: accentColor, width: 3),
                )
              : null,
        ),
        child: Row(
          children: [
            // Drag handle
            ReorderableDragStartListener(
              index: index,
              child: const Icon(
                Icons.drag_handle,
                size: 18,
                color: Color.fromRGBO(255, 255, 255, 0.3),
              ),
            ),
            const SizedBox(width: 8),

            // Color dot (tappable)
            GestureDetector(
              onTap: onTapColor,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: accentColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color.fromRGBO(255, 255, 255, 0.3),
                    width: 1,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),

            // Title (tappable → inline edit)
            Expanded(
              child: isEditing
                  ? TextField(
                      controller: titleController,
                      autofocus: true,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                        border: UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.blueAccent),
                        ),
                        focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.blueAccent),
                        ),
                      ),
                      onSubmitted: onSubmitTitle,
                      onTapOutside: (_) {
                        if (titleController != null) {
                          onSubmitTitle(titleController!.text);
                        }
                      },
                    )
                  : GestureDetector(
                      onTap: onTapTitle,
                      child: Text(
                        chapter.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
            ),
            const SizedBox(width: 8),

            // Delete button (hidden for last chapter)
            if (onDelete != null)
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  iconSize: 16,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  color: const Color.fromRGBO(255, 255, 255, 0.35),
                  onPressed: onDelete,
                  tooltip: 'Delete chapter',
                ),
              ),
          ],
        ),
      ),
    );
  }

}

/// A small chip showing a chapter as a move-page target.
class _ChapterChip extends StatelessWidget {
  const _ChapterChip({
    required this.chapter,
    required this.isSelected,
    required this.onTap,
  });

  final Chapter chapter;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accentColor = Color(chapter.color);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.blueAccent.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? Colors.blueAccent
                : const Color.fromRGBO(255, 255, 255, 0.15),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: accentColor,
                shape: BoxShape.circle,
              ),
            ),
            Text(
              chapter.title,
              style: TextStyle(
                color: isSelected
                    ? Colors.white
                    : const Color.fromRGBO(255, 255, 255, 0.7),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small chip for selecting Start / End position.
class _PositionChip extends StatelessWidget {
  const _PositionChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.blueAccent.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected
                ? Colors.blueAccent
                : const Color.fromRGBO(255, 255, 255, 0.15),
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected
                ? Colors.white
                : const Color.fromRGBO(255, 255, 255, 0.6),
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
