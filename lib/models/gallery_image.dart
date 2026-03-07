/// The canonical image record (TDD §3.5).
///
/// Images live in a parallel gallery index — they are referenced by pages,
/// never embedded. [pageRefs] is bidirectional: the gallery knows every page
/// that references this image.
class GalleryImage {
  /// Globally unique identifier.
  final String id;

  /// FK → Notebook.id.
  final String notebookId;

  /// Image source descriptor (e.g., "camera", "files", "import").
  final String source;

  /// Local file system path to the image.
  final String localPath;

  /// Cloud storage reference (Supabase object path). Null until synced.
  final String? cloudStorageRef;

  /// User-assigned tags for organization.
  final List<String> tags;

  /// Page IDs that reference this image (bidirectional with ImageRef).
  final List<String> pageRefs;

  const GalleryImage({
    required this.id,
    required this.notebookId,
    required this.source,
    required this.localPath,
    this.cloudStorageRef,
    this.tags = const [],
    this.pageRefs = const [],
  });

  /// Create a copy with updated fields.
  GalleryImage copyWith({
    String? cloudStorageRef,
    List<String>? tags,
    List<String>? pageRefs,
  }) {
    return GalleryImage(
      id: id,
      notebookId: notebookId,
      source: source,
      localPath: localPath,
      cloudStorageRef: cloudStorageRef ?? this.cloudStorageRef,
      tags: tags ?? this.tags,
      pageRefs: pageRefs ?? this.pageRefs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'notebookId': notebookId,
        'source': source,
        'localPath': localPath,
        'cloudStorageRef': cloudStorageRef,
        'tags': tags,
        'pageRefs': pageRefs,
      };

  factory GalleryImage.fromJson(Map<String, dynamic> json) => GalleryImage(
        id: json['id'] as String,
        notebookId: json['notebookId'] as String,
        source: json['source'] as String,
        localPath: json['localPath'] as String,
        cloudStorageRef: json['cloudStorageRef'] as String?,
        tags: (json['tags'] as List?)?.cast<String>() ?? [],
        pageRefs: (json['pageRefs'] as List?)?.cast<String>() ?? [],
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is GalleryImage && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
