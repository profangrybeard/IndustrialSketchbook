import 'dart:ui';

import '../models/stroke.dart';

/// Unbounded uniform grid hash for O(1) spatial lookup of strokes by region.
///
/// Each cell is [cellSize]×[cellSize] logical pixels. A stroke is inserted
/// into every cell its bounding rect overlaps (typically 1–4 cells).
/// Queries return the set of stroke IDs whose bounding rects overlap the
/// queried region.
///
/// Unlike a bounded grid, this supports infinite coordinates (negative and
/// arbitrarily large) via hash-based cell keys (Cantor pairing function).
///
/// Used by the eraser (hit testing), dirty-region rebuild, and tiled rendering.
class SpatialGrid {
  SpatialGrid(this.cellSize);

  final double cellSize;

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

  /// Hash a (col, row) pair into a single int key.
  ///
  /// Uses Cantor pairing on non-negative indices. Negative grid coordinates
  /// are mapped to non-negative via zigzag encoding (0 → 0, -1 → 1, 1 → 2,
  /// -2 → 3, 2 → 4, …) so all ints produce unique, non-negative values.
  static int cellKey(int col, int row) {
    final c = col >= 0 ? 2 * col : -2 * col - 1;
    final r = row >= 0 ? 2 * row : -2 * row - 1;
    return (c + r) * (c + r + 1) ~/ 2 + r;
  }

  /// Compute cell keys that overlap [rect]. No clamping — works for any coords.
  List<int> _cellKeysForRect(Rect rect) {
    final colMin = (rect.left / cellSize).floor();
    final colMax = (rect.right / cellSize).floor();
    final rowMin = (rect.top / cellSize).floor();
    final rowMax = (rect.bottom / cellSize).floor();

    final keys = <int>[];
    for (int r = rowMin; r <= rowMax; r++) {
      for (int c = colMin; c <= colMax; c++) {
        keys.add(cellKey(c, r));
      }
    }
    return keys;
  }
}
