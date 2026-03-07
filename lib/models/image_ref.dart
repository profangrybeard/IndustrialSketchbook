/// An image pin on a specific page (TDD §3.5).
///
/// Stored in [SketchPage.attachments]. Points back to [GalleryImage] by id.
class ImageRef {
  /// FK → GalleryImage.id.
  final String imageId;

  /// Pin anchor X in canvas coordinates.
  final double anchorX;

  /// Pin anchor Y in canvas coordinates.
  final double anchorY;

  /// Stroke IDs of annotations drawn over this image.
  final List<String> annotationStrokeIds;

  /// When the image was pinned to this page.
  final DateTime pinnedAt;

  const ImageRef({
    required this.imageId,
    required this.anchorX,
    required this.anchorY,
    this.annotationStrokeIds = const [],
    required this.pinnedAt,
  });

  Map<String, dynamic> toJson() => {
        'imageId': imageId,
        'anchorX': anchorX,
        'anchorY': anchorY,
        'annotationStrokeIds': annotationStrokeIds,
        'pinnedAt': pinnedAt.toUtc().toIso8601String(),
      };

  factory ImageRef.fromJson(Map<String, dynamic> json) => ImageRef(
        imageId: json['imageId'] as String,
        anchorX: (json['anchorX'] as num).toDouble(),
        anchorY: (json['anchorY'] as num).toDouble(),
        annotationStrokeIds:
            (json['annotationStrokeIds'] as List?)?.cast<String>() ?? [],
        pinnedAt: DateTime.parse(json['pinnedAt'] as String),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImageRef &&
          imageId == other.imageId &&
          anchorX == other.anchorX &&
          anchorY == other.anchorY;

  @override
  int get hashCode => Object.hash(imageId, anchorX, anchorY);
}
