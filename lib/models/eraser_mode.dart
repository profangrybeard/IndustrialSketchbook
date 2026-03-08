/// Eraser behavior modes (Phase 2.7).
///
/// Controls how the eraser tool removes strokes from the canvas.
enum EraserMode {
  /// Standard partial eraser — splits strokes at the eraser radius,
  /// removing only the segments that overlap. Default behavior.
  standard(label: 'Standard'),

  /// History eraser — removes whole strokes in reverse chronological
  /// order. First pass removes the newest stroke at that position,
  /// second pass removes the next-newest, and so on.
  history(label: 'History');

  const EraserMode({required this.label});

  /// Display label for the palette UI.
  final String label;
}
