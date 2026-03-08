import 'page_style.dart';

/// Background grid overlay style for the canvas.
///
/// Controls what pattern (if any) is drawn over the paper background.
enum GridStyle {
  /// No grid overlay — plain paper.
  none(label: 'None', icon: 'crop_free'),

  /// Evenly spaced dots at grid intersections.
  dots(label: 'Dots', icon: 'grid_4x4'),

  /// Full ruled grid lines at regular intervals.
  lines(label: 'Lines', icon: 'grid_on');

  const GridStyle({required this.label, required this.icon});

  /// User-facing label shown in the palette.
  final String label;

  /// Material icon name (used for lookup in the palette).
  final String icon;

  /// Convert to [PageStyle] for database persistence.
  ///
  /// Mapping: none → plain, dots → dot, lines → grid.
  PageStyle toPageStyle() {
    switch (this) {
      case GridStyle.none:
        return PageStyle.plain;
      case GridStyle.dots:
        return PageStyle.dot;
      case GridStyle.lines:
        return PageStyle.grid;
    }
  }

  /// Convert from [PageStyle] for canvas rendering.
  ///
  /// Isometric and perspective map to none (handled by separate painters).
  static GridStyle fromPageStyle(PageStyle pageStyle) {
    switch (pageStyle) {
      case PageStyle.plain:
      case PageStyle.isometric:
      case PageStyle.perspective:
        return GridStyle.none;
      case PageStyle.dot:
        return GridStyle.dots;
      case PageStyle.grid:
        return GridStyle.lines;
    }
  }
}
