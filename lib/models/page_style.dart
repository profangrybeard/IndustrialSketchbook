/// Page background style (TDD §3.3).
///
/// Determines the overlay painter used for the canvas background.
/// Grid, dot, and isometric styles require a [GridConfig].
/// Perspective style requires a [PerspectiveConfig].
enum PageStyle {
  plain,
  grid,
  dot,
  isometric,
  perspective;

  /// Serialize to string for JSON/SQLite storage.
  String toJson() => name;

  /// Deserialize from string.
  static PageStyle fromJson(String value) =>
      PageStyle.values.firstWhere((e) => e.name == value);
}
