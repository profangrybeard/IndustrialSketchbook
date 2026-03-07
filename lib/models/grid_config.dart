import 'dart:ui';

/// Grid background configuration (TDD §3.3).
///
/// Required when [PageStyle] is grid, dot, or isometric.
/// Serializable to JSON for SQLite persistence.
class GridConfig {
  /// Distance between grid lines/dots in canvas units.
  final double spacing;

  /// Grid line color as ARGB packed integer.
  final int color;

  /// Line weight in canvas units.
  final double lineWeight;

  const GridConfig({
    this.spacing = 20.0,
    this.color = 0x33FFFFFF, // 20% white
    this.lineWeight = 0.5,
  });

  Map<String, dynamic> toJson() => {
        'spacing': spacing,
        'color': color,
        'lineWeight': lineWeight,
      };

  factory GridConfig.fromJson(Map<String, dynamic> json) => GridConfig(
        spacing: (json['spacing'] as num).toDouble(),
        color: json['color'] as int,
        lineWeight: (json['lineWeight'] as num).toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GridConfig &&
          spacing == other.spacing &&
          color == other.color &&
          lineWeight == other.lineWeight;

  @override
  int get hashCode => Object.hash(spacing, color, lineWeight);

  @override
  String toString() =>
      'GridConfig(spacing: $spacing, color: 0x${color.toRadixString(16)}, lineWeight: $lineWeight)';
}
