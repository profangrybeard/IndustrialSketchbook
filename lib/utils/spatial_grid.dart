import 'dart:math';
import 'dart:ui';

import '../models/stroke.dart';

/// Uniform grid hash for O(1) spatial lookup of strokes by region.
///
/// Each cell is [cellSize]×[cellSize] logical pixels. A stroke is inserted
/// into every cell its [Stroke.boundingRect] overlaps (typically 1–4 cells).
/// Queries return the set of stroke IDs whose bounding rects overlap the
/// queried region.
///
/// Used by the eraser (hit testing) and dirty-region rebuild (finding
/// strokes that overlap a damaged rect).
class SpatialGrid {
  SpatialGrid(this.cellSize, this.canvasWidth, this.canvasHeight)
      : _columns = max(1, (canvasWidth / cellSize).ceil()),
        _rows = max(1, (canvasHeight / cellSize).ceil());

  final double cellSize;
  final double canvasWidth;
  final double canvasHeight;
  final int _columns;
  final int _rows;

  /// Cell key → stroke IDs occupying that cell.
  final Map<int, Set<String>> _cells = {};

  /// Stroke ID → cell keys it occupies (for O(1) removal).
  final Map<String, List<int>> _strokeCells = {};

  /// Number of strokes currently in the grid.
  int get strokeCount => _strokeCells.length;

  /// Insert a stroke into every cell its bounding rect overlaps.
  void insert(String strokeId, Rect boundingRect) {
    final keys = _cellKeysForRect(boundingRect);
    _strokeCells[strokeId] = keys;
    for (final key in keys) {
      (_cells[key] ??= <String>{}).add(strokeId);
    }
  }

  /// Remove a stroke from the grid.
  void remove(String strokeId) {
    final keys = _strokeCells.remove(strokeId);
    if (keys == null) return;
    for (final key in keys) {
      _cells[key]?.remove(strokeId);
    }
  }

  /// Return all stroke IDs whose bounding rects overlap [rect].
  Set<String> queryRect(Rect rect) {
    final result = <String>{};
    final keys = _cellKeysForRect(rect);
    for (final key in keys) {
      final cell = _cells[key];
      if (cell != null) result.addAll(cell);
    }
    return result;
  }

  /// Convenience: query a circle region (for eraser hit testing).
  Set<String> queryPoint(Offset point, double radius) {
    return queryRect(Rect.fromCircle(center: point, radius: radius));
  }

  /// Clear all entries.
  void clear() {
    _cells.clear();
    _strokeCells.clear();
  }

  /// Bulk rebuild from a list of strokes, skipping tombstones and erased IDs.
  void rebuild(List<Stroke> strokes, Set<String> erasedIds) {
    clear();
    for (final stroke in strokes) {
      if (stroke.isTombstone) continue;
      if (erasedIds.contains(stroke.id)) continue;
      if (stroke.points.isEmpty) continue;
      insert(stroke.id, stroke.boundingRect);
    }
  }

  /// Compute cell keys that overlap [rect].
  List<int> _cellKeysForRect(Rect rect) {
    final colMin = max(0, (rect.left / cellSize).floor());
    final colMax = min(_columns - 1, (rect.right / cellSize).floor());
    final rowMin = max(0, (rect.top / cellSize).floor());
    final rowMax = min(_rows - 1, (rect.bottom / cellSize).floor());

    final keys = <int>[];
    for (int r = rowMin; r <= rowMax; r++) {
      for (int c = colMin; c <= colMax; c++) {
        keys.add(r * _columns + c);
      }
    }
    return keys;
  }
}
