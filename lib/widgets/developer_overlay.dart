import 'package:flutter/material.dart';

import '../config/build_info.dart';
import '../services/drawing_service.dart';
import '../utils/perf_metrics.dart';

/// Draggable developer overlay showing build revision and per-sketch memory
/// stats plus live rendering performance metrics.
///
/// Defaults to a safe position inside the canvas (60, 60) and can be dragged
/// anywhere on screen. Uses [GestureDetector] for drag handling — finger/mouse
/// drags move the overlay, while stylus input passes through to the canvas
/// via [Listener] filtering.
class DeveloperOverlay extends StatefulWidget {
  const DeveloperOverlay({
    required this.drawingService,
    this.currentPageIndex = 0,
    this.totalPages = 1,
    this.chapterIndex = 0,
    this.totalChapters = 1,
    super.key,
  });

  final DrawingService drawingService;

  /// Zero-based index of the current page (global, across all chapters).
  final int currentPageIndex;

  /// Total pages across all chapters.
  final int totalPages;

  /// Zero-based index of the current chapter.
  final int chapterIndex;

  /// Total number of chapters in the notebook.
  final int totalChapters;

  @override
  State<DeveloperOverlay> createState() => _DeveloperOverlayState();
}

class _DeveloperOverlayState extends State<DeveloperOverlay> {
  // Default position — inside safe area on tablet
  double _x = 60;
  double _y = 60;

  @override
  Widget build(BuildContext context) {
    final strokes = widget.drawingService.committedStrokes;
    final erasedIds = widget.drawingService.erasedStrokeIds;

    // Count visible strokes (exclude tombstones + erased)
    int visibleStrokes = 0;
    int totalPoints = 0;
    for (final s in strokes) {
      if (s.isTombstone) continue;
      if (erasedIds.contains(s.id)) continue;
      visibleStrokes++;
      totalPoints += s.points.length;
    }

    // Include inflight stroke in point count
    final inflight = widget.drawingService.inflightStroke;
    if (inflight != null) totalPoints += inflight.points.length;

    // Memory estimate: 32 bytes/point (packed binary) + ~200 bytes/stroke
    // metadata (id, pageId, tool, color, weight, opacity, createdAt, etc.)
    final estimatedBytes = totalPoints * 32 + strokes.length * 200;
    final memoryStr = _formatBytes(estimatedBytes);

    // Perf metrics
    final perf = PerfMetrics.instance;
    final activeMs = (perf.activeStrokePaintAvgUs / 1000).toStringAsFixed(1);
    final activeMaxMs = (perf.activeStrokePaintMaxUs / 1000).toStringAsFixed(1);
    final fps = perf.estimatedFps > 0 ? perf.estimatedFps.toStringAsFixed(0) : '-';
    final committedMs = (perf.committedPaintUs / 1000).toStringAsFixed(1);

    return Positioned(
      left: _x,
      top: _y,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _x += details.delta.dx;
            _y += details.delta.dy;
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            'rev $buildRevision \u00b7 $buildDate\n'
            'pg ${widget.currentPageIndex + 1}/${widget.totalPages} \u00b7 '
            'ch ${widget.chapterIndex + 1}/${widget.totalChapters} \u00b7 '
            '$visibleStrokes strokes \u00b7 ${_formatNumber(totalPoints)} pts\n'
            '$memoryStr\n'
            'active: ${activeMs}ms avg / ${activeMaxMs}ms max \u00b7 ~${fps}fps\n'
            'inflight: ${perf.inflightPointCount}pts \u2192 ${_formatNumber(perf.inflightSpinePointCount)}sp \u00b7 ${perf.inflightSaveLayerCount}lyr\n'
            'commit: ${committedMs}ms [${perf.committedPaintType}] \u00b7 ${perf.committedStrokeCount}str',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 10,
              fontFamily: 'monospace',
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  }

  /// Format a number with comma separators (e.g., 2340 → "2,340").
  static String _formatNumber(int n) {
    if (n < 1000) return n.toString();
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  /// Format byte count as human-readable string.
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '~$bytes B';
    if (bytes < 1024 * 1024) {
      return '~${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '~${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
