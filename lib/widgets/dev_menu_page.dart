import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chapter.dart';
import '../models/notebook.dart';
import '../models/sketch_page.dart';
import '../models/sync_state.dart';
import '../providers/database_provider.dart';
import '../providers/sync_provider.dart';

/// Developer menu — dangerous tools for schema resets & debugging.
///
/// Contains:
/// - Toggle dev info overlay visibility
/// - Force Push (moved from SyncSettingsPage)
/// - Purge all local data (nuclear reset for schema changes)
class DevMenuPage extends ConsumerStatefulWidget {
  const DevMenuPage({
    required this.devOverlayVisible,
    required this.onDevOverlayToggled,
    super.key,
  });

  final bool devOverlayVisible;
  final ValueChanged<bool> onDevOverlayToggled;

  @override
  ConsumerState<DevMenuPage> createState() => _DevMenuPageState();
}

class _DevMenuPageState extends ConsumerState<DevMenuPage> {
  late bool _overlayVisible;

  @override
  void initState() {
    super.initState();
    _overlayVisible = widget.devOverlayVisible;
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncStateProvider);
    final isBusy = syncState is SyncPushing || syncState is SyncPulling;

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        title: const Text('Dev Menu'),
        backgroundColor: const Color(0xFF2A2A2A),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- Dev Overlay Toggle ---
            const Text(
              'DEBUG',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Dev Info Overlay',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                subtitle: const Text('Show perf stats, stroke counts, memory',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
                value: _overlayVisible,
                activeColor: Colors.blueAccent,
                onChanged: (v) {
                  setState(() => _overlayVisible = v);
                  widget.onDevOverlayToggled(v);
                },
              ),
            ),

            const SizedBox(height: 32),

            // --- Sync Tools ---
            const Text(
              'SYNC',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: isBusy ? null : () => ref.read(syncEngineProvider).forcePush(),
                icon: const Icon(Icons.cloud_upload_outlined, size: 20),
                label: const Text('Force Push (overwrite cloud)'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.orange,
                  side: const BorderSide(color: Colors.orange, width: 1),
                  disabledForegroundColor: Colors.white24,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),

            const SizedBox(height: 32),

            // --- Danger Zone ---
            const Text(
              'DANGER ZONE',
              style: TextStyle(
                color: Colors.redAccent,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _confirmPurge(context),
                icon: const Icon(Icons.delete_forever, size: 20),
                label: const Text('Purge All Data'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent, width: 1),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Deletes all notebooks, chapters, pages, strokes, snapshots, '
              'and sync queue. The app will restart with a fresh default notebook.',
              style: TextStyle(color: Colors.white24, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmPurge(BuildContext context) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Purge ALL data?',
            style: TextStyle(color: Colors.redAccent)),
        content: const Text(
          'This will permanently delete every stroke, page, chapter, and '
          'notebook on this device. Cloud data is NOT affected.\n\n'
          'This cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Purge Everything'),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed != true) return;
      final db = ref.read(databaseServiceProvider).value;
      if (db == null) return;

      await db.purgeAllData();

      // Re-seed defaults so the app has something to show
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

      if (!mounted) return;
      // Pop back to canvas — return 'purged' so canvas knows to reload
      Navigator.of(context).pop('purged');
    });
  }
}
