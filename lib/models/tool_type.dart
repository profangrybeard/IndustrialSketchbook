/// Drawing tool types (TDD §3.2).
///
/// Controls renderer behaviour — each tool has different pressure response,
/// opacity blending, and edge treatment.
enum ToolType {
  pen,
  pencil,
  marker,
  brush,
  eraser,
  highlighter;

  /// Serialize to string for JSON/SQLite storage.
  String toJson() => name;

  /// Deserialize from string.
  static ToolType fromJson(String value) =>
      ToolType.values.firstWhere((e) => e.name == value);
}
