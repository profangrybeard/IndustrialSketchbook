/// Top-level container (TDD §3.4).
///
/// One notebook per user in v1. Contains ordered chapters.
class Notebook {
  /// Globally unique identifier.
  final String id;

  /// User-facing notebook title.
  final String title;

  /// Owner user ID (for future multi-user sync).
  final String ownerId;

  /// Ordered list of chapter IDs.
  final List<String> chapterIds;

  const Notebook({
    required this.id,
    required this.title,
    required this.ownerId,
    this.chapterIds = const [],
  });

  Notebook copyWith({
    String? title,
    List<String>? chapterIds,
  }) {
    return Notebook(
      id: id,
      title: title ?? this.title,
      ownerId: ownerId,
      chapterIds: chapterIds ?? this.chapterIds,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'ownerId': ownerId,
        'chapterIds': chapterIds,
      };

  factory Notebook.fromJson(Map<String, dynamic> json) => Notebook(
        id: json['id'] as String,
        title: json['title'] as String,
        ownerId: json['ownerId'] as String,
        chapterIds: (json['chapterIds'] as List?)?.cast<String>() ?? [],
      );

  Map<String, dynamic> toDbMap() => {
        'id': id,
        'title': title,
        'owner_id': ownerId,
      };

  factory Notebook.fromDbMap(Map<String, dynamic> map) => Notebook(
        id: map['id'] as String,
        title: map['title'] as String,
        ownerId: map['owner_id'] as String,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Notebook && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
