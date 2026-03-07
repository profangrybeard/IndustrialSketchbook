/// Pencil lead presets that apply weight and opacity values (Phase 2.5).
///
/// Each lead defines a weight multiplier (applied to a base weight)
/// and an opacity value. The actual weight/opacity are stored on the
/// Stroke — the lead is just a convenient preset selector.
enum PencilLead {
  fine(label: 'Fine (HB)', weightMultiplier: 0.5, opacity: 0.8),
  medium(label: 'Medium (2B)', weightMultiplier: 1.0, opacity: 0.7),
  bold(label: 'Bold (4B)', weightMultiplier: 1.8, opacity: 0.85),
  soft(label: 'Soft (6B)', weightMultiplier: 2.5, opacity: 0.6);

  const PencilLead({
    required this.label,
    required this.weightMultiplier,
    required this.opacity,
  });

  /// User-facing label (e.g. "Fine (HB)").
  final String label;

  /// Multiplied against a base weight to get the final stroke weight.
  final double weightMultiplier;

  /// Opacity applied to the stroke when this lead is selected.
  final double opacity;
}
