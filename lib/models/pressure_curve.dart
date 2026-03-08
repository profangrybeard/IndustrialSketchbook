/// Preset pressure-to-effect curves for pencil rendering (Phase 2.7).
///
/// Each curve controls the exponent in `pow(rawPressure, exponent)`:
/// - Lower exponents → more responsive (linear feel)
/// - Higher exponents → more resistance (need to press harder for bold marks)
///
/// The curve affects whichever channel [PressureMode] is set to (width, opacity, or both).
enum PressureCurve {
  /// 1:1 linear pass-through — no curve at all.
  linear(label: 'Linear', exponent: 1.0),

  /// Gentle resistance — slightly softer than linear.
  light(label: 'Light', exponent: 1.4),

  /// Default natural graphite feel — matches Phase 2.6 behavior.
  natural(label: 'Natural', exponent: 1.8),

  /// Strong resistance — light touches produce very faint marks.
  heavy(label: 'Heavy', exponent: 2.5);

  const PressureCurve({required this.label, required this.exponent});

  /// Display label for the palette UI.
  final String label;

  /// Power-curve exponent applied to raw stylus pressure (0.0–1.0).
  final double exponent;
}
