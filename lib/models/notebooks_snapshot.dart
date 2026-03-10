/// Full notebook/chapter/page structure snapshot for sync (Phase 3.2).
///
/// Uploaded as notebooks.json to Google Drive appDataFolder.
/// Uses last-write-wins strategy — the most recent snapshot wins.
class NotebooksSnapshot {
  const NotebooksSnapshot({
    required this.deviceId,
    required this.updatedAt,
    required this.notebooks,
    required this.chapters,
    required this.pages,
  });

  /// Device that created this snapshot.
  final String deviceId;

  /// ISO 8601 UTC timestamp when this snapshot was created.
  final String updatedAt;

  /// All notebooks as JSON maps (Notebook.toJson() format).
  final List<Map<String, dynamic>> notebooks;

  /// All chapters as JSON maps (Chapter.toJson() format).
  final List<Map<String, dynamic>> chapters;

  /// All pages as JSON maps (SketchPage.toJson() format).
  final List<Map<String, dynamic>> pages;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'updatedAt': updatedAt,
        'notebooks': notebooks,
        'chapters': chapters,
        'pages': pages,
      };

  factory NotebooksSnapshot.fromJson(Map<String, dynamic> json) =>
      NotebooksSnapshot(
        deviceId: json['deviceId'] as String,
        updatedAt: json['updatedAt'] as String,
        notebooks: (json['notebooks'] as List)
            .map((n) => Map<String, dynamic>.from(n as Map))
            .toList(),
        chapters: (json['chapters'] as List)
            .map((c) => Map<String, dynamic>.from(c as Map))
            .toList(),
        pages: (json['pages'] as List)
            .map((p) => Map<String, dynamic>.from(p as Map))
            .toList(),
      );
}
