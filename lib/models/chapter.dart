/// A user-named grouping of pages within a notebook (TDD §3.4).
///
/// Chapters are reorderable and have an optional accent color.
class Chapter {
  /// Globally unique identifier.
  final String id;

  /// FK → Notebook.id.
  final String notebookId;

  /// User-facing chapter title.
  final String title;

  /// Display order within notebook.
  final int order;

  /// Accent color as ARGB packed integer.
  final int color;

  /// Ordered list of page IDs in this chapter.
  final List<String> pageIds;

  const Chapter({
    required this.id,
    required this.notebookId,
    required this.title,
    required this.order,
    this.color = 0xFF607D8B, // blueGrey default
    this.pageIds = const [],
  });

  Chapter copyWith({
    String? title,
    int? order,
    int? color,
    List<String>? pageIds,
  }) {
    return Chapter(
      id: id,
      notebookId: notebookId,
      title: title ?? this.title,
      order: order ?? this.order,
      color: color ?? this.color,
      pageIds: pageIds ?? this.pageIds,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'notebookId': notebookId,
        'title': title,
        'order': order,
        'color': color,
        'pageIds': pageIds,
      };

  factory Chapter.fromJson(Map<String, dynamic> json) => Chapter(
        id: json['id'] as String,
        notebookId: json['notebookId'] as String,
        title: json['title'] as String,
        order: json['order'] as int,
        color: json['color'] as int? ?? 0xFF607D8B,
        pageIds: (json['pageIds'] as List?)?.cast<String>() ?? [],
      );

  Map<String, dynamic> toDbMap() => {
        'id': id,
        'notebook_id': notebookId,
        'title': title,
        'sort_order': order,
        'color': color,
      };

  factory Chapter.fromDbMap(Map<String, dynamic> map) => Chapter(
        id: map['id'] as String,
        notebookId: map['notebook_id'] as String,
        title: map['title'] as String,
        order: map['sort_order'] as int,
        color: map['color'] as int? ?? 0xFF607D8B,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Chapter && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
