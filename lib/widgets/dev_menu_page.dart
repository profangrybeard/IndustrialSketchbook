import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chapter.dart';
import '../models/notebook.dart';
import '../models/sketch_page.dart';
import '../models/sync_state.dart';
import '../providers/database_provider.dart';
import '../providers/drawing_provider.dart';
import '../providers/sync_provider.dart';

/// Developer menu — runtime quality tuning + dangerous tools.
///
/// Contains:
/// - Toggle dev info overlay visibility
/// - Runtime quality sliders (arc length, grain, pressure, deadzone)
/// - Force Push (sync)
/// - Purge all local data (nuclear reset)
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
    final ds = ref.watch(drawingServiceProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        title: const Text('Dev Menu'),
        backgroundColor: const Color(0xFF2A2A2A),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // --- Dev Overlay Toggle ---
          _sectionHeader('DEBUG'),
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

          // --- Rendering Quality ---
          _sectionHeader('RENDERING QUALITY'),
          const SizedBox(height: 4),
          const Text(
            'Runtime only — does not affect stored stroke data.',
            style: TextStyle(color: Colors.white24, fontSize: 11),
          ),
          const SizedBox(height: 16),

          _qualitySlider(
            label: 'Live Arc Length',
            value: ds.liveArcLength,
            min: 0.1,
            max: 3.0,
            defaultValue: 0.5,
            description: 'Fidelity while drawing. Lower = smoother, higher = faster.',
            onChanged: (v) => ds.liveArcLength = v,
          ),

          _qualitySlider(
            label: 'Replay Arc Length',
            value: ds.replayArcLength,
            min: 0.5,
            max: 5.0,
            defaultValue: 1.5,
            description: 'Fidelity for cached/committed strokes. Affects pen-up quality.',
            onChanged: (v) => ds.replayArcLength = v,
          ),

          _qualitySlider(
            label: 'Grain Intensity',
            value: ds.effectiveGrainIntensity,
            min: 0.0,
            max: 1.0,
            defaultValue: ds.currentLead?.grainIntensity ?? 0.25,
            description: 'Pencil texture grain. Overrides lead preset when changed.',
            onChanged: (v) => ds.grainIntensityOverride = v,
            onReset: () => ds.grainIntensityOverride = null,
            isOverridden: ds.grainIntensityOverride != null,
          ),

          _qualitySlider(
            label: 'Pressure Exponent',
            value: ds.effectivePressureExponent,
            min: 0.5,
            max: 4.0,
            defaultValue: ds.pressureCurve.exponent,
            description: 'Pressure curve power. Higher = heavier touch needed. Overrides curve preset.',
            onChanged: (v) => ds.pressureExponentOverride = v,
            onReset: () => ds.pressureExponentOverride = null,
            isOverridden: ds.pressureExponentOverride != null,
          ),

          _qualitySlider(
            label: 'Pressure Deadzone',
            value: ds.pressureDeadzone,
            min: 0.0,
            max: 0.30,
            defaultValue: 0.12,
            description: 'Minimum pressure to register a stroke. Prevents accidental marks.',
            onChanged: (v) => ds.pressureDeadzone = v,
          ),

          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                ds.liveArcLength = 0.5;
                ds.replayArcLength = 1.5;
                ds.grainIntensityOverride = null;
                ds.pressureExponentOverride = null;
                ds.pressureDeadzone = 0.12;
                ds.saveToolState();
              },
              icon: const Icon(Icons.restore, size: 16),
              label: const Text('Reset All to Defaults'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white38,
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ),

          const SizedBox(height: 24),

          // --- Sync Tools ---
          _sectionHeader('SYNC', color: Colors.white70),
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
          _sectionHeader('DANGER ZONE', color: Colors.redAccent),
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
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text, {Color color = Colors.white70}) {
    return Text(
      text,
      style: TextStyle(
        color: color,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _qualitySlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required double defaultValue,
    required String description,
    required ValueChanged<double> onChanged,
    VoidCallback? onReset,
    bool isOverridden = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const Spacer(),
              Text(
                value.toStringAsFixed(2),
                style: TextStyle(
                  color: isOverridden ? Colors.amber : Colors.white70,
                  fontSize: 14,
                  fontFamily: 'monospace',
                ),
              ),
              if (onReset != null && isOverridden) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    onReset();
                    ref.read(drawingServiceProvider).saveToolState();
                  },
                  child: const Icon(Icons.close, size: 14, color: Colors.white38),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(
            description,
            style: const TextStyle(color: Colors.white24, fontSize: 11),
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: Colors.blueAccent,
              inactiveTrackColor: Colors.white12,
              thumbColor: Colors.blueAccent,
              overlayColor: Colors.blueAccent.withAlpha(40),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: (v) {
                onChanged(v);
              },
              onChangeEnd: (_) {
                ref.read(drawingServiceProvider).saveToolState();
              },
            ),
          ),
        ],
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
