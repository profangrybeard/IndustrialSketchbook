/// Pencil lead presets that apply weight, opacity, and grain values (Phase 2.6).
///
/// Each lead defines a weight multiplier (applied to a base weight),
/// an opacity value, and a grain intensity. The actual weight/opacity are
/// stored on the Stroke — the lead is just a convenient preset selector.
///
/// Grain intensity controls how much per-segment texture variation is
/// applied during rendering — simulating how soft graphite catches more
/// paper texture than hard graphite.
enum PencilLead {
  fine(
    label: 'Fine (HB)',
    weightMultiplier: 0.5,
    opacity: 0.8,
    grainIntensity: 0.15,
  ),
  medium(
    label: 'Medium (2B)',
    weightMultiplier: 1.0,
    opacity: 0.7,
    grainIntensity: 0.25,
  ),
  bold(
    label: 'Bold (4B)',
    weightMultiplier: 1.8,
    opacity: 0.85,
    grainIntensity: 0.30,
  ),
  soft(
    label: 'Soft (6B)',
    weightMultiplier: 2.5,
    opacity: 0.6,
    grainIntensity: 0.40,
  );

  const PencilLead({
    required this.label,
    required this.weightMultiplier,
    required this.opacity,
    required this.grainIntensity,
  });

  /// User-facing label (e.g. "Fine (HB)").
  final String label;

  /// Multiplied against a base weight to get the final stroke weight.
  final double weightMultiplier;

  /// Opacity applied to the stroke when this lead is selected.
  final double opacity;

  /// How much per-segment texture variation to apply (0.0–1.0).
  ///
  /// Hard leads (HB) have low grain — smooth, consistent marks.
  /// Soft leads (6B) have high grain — visible paper texture in strokes.
  final double grainIntensity;
}
