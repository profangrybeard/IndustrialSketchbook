/// How stylus pressure affects pencil stroke rendering.
///
/// Controls whether pressure modulates width, opacity, or both.
/// This is a rendering-time setting — the raw pressure data is always
/// captured in [StrokePoint] regardless of mode.
enum PressureMode {
  /// Pressure controls stroke width only (default, classic behavior).
  width(label: 'Width'),

  /// Pressure controls stroke opacity only (consistent width).
  opacity(label: 'Opacity'),

  /// Pressure controls both width and opacity simultaneously.
  both(label: 'Both');

  const PressureMode({required this.label});

  /// User-facing label shown in the palette.
  final String label;
}
