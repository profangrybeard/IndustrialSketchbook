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
}
