import 'dart:ui';

/// Identifies a tile by its grid column and row in world space.
///
/// Tiles are [tileWorldSize] × [tileWorldSize] world-unit squares. The tile at
/// (col=0, row=0) covers world rect (0, 0, tileWorldSize, tileWorldSize).
/// Negative columns/rows are valid (infinite canvas).
class TileKey {
  final int col;
  final int row;

  const TileKey(this.col, this.row);

  /// World-space rectangle for this tile.
  Rect worldRect(double tileSize) =>
      Rect.fromLTWH(col * tileSize, row * tileSize, tileSize, tileSize);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TileKey && col == other.col && row == other.row;

  @override
  int get hashCode => Object.hash(col, row);

  @override
  String toString() => 'TileKey($col, $row)';
}
