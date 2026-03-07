import 'dart:convert';

import 'grid_config.dart';
import 'image_ref.dart';
import 'page_style.dart';
import 'perspective_config.dart';

/// The canvas entity (TDD §3.3).
///
/// A page does not store stroke data directly — it stores an ordered list
/// of stroke IDs. Strokes are looked up by ID for rendering.
///
/// ## Branch Invariant
///
/// All strokes up to and including [branchPointStrokeId] are shared with
/// the parent. They are not duplicated in storage. The branch page's
/// [strokeIds] includes the full ordered history (shared + own).
/// Rendering resolves shared strokes by following [parentPageId].
class SketchPage {
  /// Globally unique identifier.
  final String id;

  /// FK → Chapter.id. Owning chapter.
  final String chapterId;

  /// Display order within chapter (>= 0).
  final int pageNumber;

  /// Background overlay type.
  final PageStyle style;

  /// Grid/dot/isometric configuration. Required if style != plain.
  final GridConfig? gridConfig;

  /// Perspective drawing configuration. Required if style == perspective.
  final PerspectiveConfig? perspectiveConfig;

  /// The event log. This is the page. Ordered, append-only.
  final List<String> strokeIds;

  /// Gallery image pins on this page.
  final List<ImageRef> attachments;

  /// Null = root page. Non-null = this is a branch.
  final String? parentPageId;

  /// Last shared stroke with parent. Must exist in strokeIds.
  final String? branchPointStrokeId;

  /// Child branches from this page.
  final List<String> branchPageIds;

  /// Page layers. Default: ["default"]. Length >= 1.
  final List<String> layerIds;

  const SketchPage({
    required this.id,
    required this.chapterId,
    required this.pageNumber,
    this.style = PageStyle.plain,
    this.gridConfig,
    this.perspectiveConfig,
    this.strokeIds = const [],
    this.attachments = const [],
    this.parentPageId,
    this.branchPointStrokeId,
    this.branchPageIds = const [],
    this.layerIds = const ['default'],
  });

  /// Create a copy with updated fields.
  SketchPage copyWith({
    int? pageNumber,
    PageStyle? style,
    GridConfig? gridConfig,
    PerspectiveConfig? perspectiveConfig,
    List<String>? strokeIds,
    List<ImageRef>? attachments,
    List<String>? branchPageIds,
    List<String>? layerIds,
  }) {
    return SketchPage(
      id: id,
      chapterId: chapterId,
      pageNumber: pageNumber ?? this.pageNumber,
      style: style ?? this.style,
      gridConfig: gridConfig ?? this.gridConfig,
      perspectiveConfig: perspectiveConfig ?? this.perspectiveConfig,
      strokeIds: strokeIds ?? this.strokeIds,
      attachments: attachments ?? this.attachments,
      parentPageId: parentPageId,
      branchPointStrokeId: branchPointStrokeId,
      branchPageIds: branchPageIds ?? this.branchPageIds,
      layerIds: layerIds ?? this.layerIds,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'chapterId': chapterId,
        'pageNumber': pageNumber,
        'style': style.toJson(),
        'gridConfig': gridConfig?.toJson(),
        'perspectiveConfig': perspectiveConfig?.toJson(),
        'strokeIds': strokeIds,
        'attachments': attachments.map((a) => a.toJson()).toList(),
        'parentPageId': parentPageId,
        'branchPointStrokeId': branchPointStrokeId,
        'branchPageIds': branchPageIds,
        'layerIds': layerIds,
      };

  factory SketchPage.fromJson(Map<String, dynamic> json) => SketchPage(
        id: json['id'] as String,
        chapterId: json['chapterId'] as String,
        pageNumber: json['pageNumber'] as int,
        style: PageStyle.fromJson(json['style'] as String),
        gridConfig: json['gridConfig'] != null
            ? GridConfig.fromJson(json['gridConfig'] as Map<String, dynamic>)
            : null,
        perspectiveConfig: json['perspectiveConfig'] != null
            ? PerspectiveConfig.fromJson(
                json['perspectiveConfig'] as Map<String, dynamic>)
            : null,
        strokeIds: (json['strokeIds'] as List?)?.cast<String>() ?? [],
        attachments: (json['attachments'] as List?)
                ?.map((a) => ImageRef.fromJson(a as Map<String, dynamic>))
                .toList() ??
            [],
        parentPageId: json['parentPageId'] as String?,
        branchPointStrokeId: json['branchPointStrokeId'] as String?,
        branchPageIds:
            (json['branchPageIds'] as List?)?.cast<String>() ?? [],
        layerIds: (json['layerIds'] as List?)?.cast<String>() ?? ['default'],
      );

  /// Convert to SQLite row map.
  Map<String, dynamic> toDbMap() => {
        'id': id,
        'chapter_id': chapterId,
        'page_number': pageNumber,
        'style': style.toJson(),
        'grid_config_json':
            gridConfig != null ? jsonEncode(gridConfig!.toJson()) : null,
        'perspective_config_json': perspectiveConfig != null
            ? jsonEncode(perspectiveConfig!.toJson())
            : null,
        'parent_page_id': parentPageId,
        'branch_point_stroke_id': branchPointStrokeId,
        'branch_page_ids_json': jsonEncode(branchPageIds),
        'layer_ids_json': jsonEncode(layerIds),
      };

  /// Reconstruct from a SQLite row map.
  factory SketchPage.fromDbMap(Map<String, dynamic> map) => SketchPage(
        id: map['id'] as String,
        chapterId: map['chapter_id'] as String,
        pageNumber: map['page_number'] as int,
        style: PageStyle.fromJson(map['style'] as String),
        gridConfig: map['grid_config_json'] != null
            ? GridConfig.fromJson(
                jsonDecode(map['grid_config_json'] as String)
                    as Map<String, dynamic>)
            : null,
        perspectiveConfig: map['perspective_config_json'] != null
            ? PerspectiveConfig.fromJson(
                jsonDecode(map['perspective_config_json'] as String)
                    as Map<String, dynamic>)
            : null,
        parentPageId: map['parent_page_id'] as String?,
        branchPointStrokeId: map['branch_point_stroke_id'] as String?,
        branchPageIds: map['branch_page_ids_json'] != null
            ? (jsonDecode(map['branch_page_ids_json'] as String) as List)
                .cast<String>()
            : [],
        layerIds: map['layer_ids_json'] != null
            ? (jsonDecode(map['layer_ids_json'] as String) as List)
                .cast<String>()
            : ['default'],
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SketchPage && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
