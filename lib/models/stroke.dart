import 'dart:typed_data';
import 'dart:ui';

import 'render_point.dart';
import 'stroke_point.dart';
import 'tool_type.dart';

/// A single pen-down → pen-up sequence (TDD §3.2).
///
/// The primary entry in the stroke event log. Immutable once committed.
///
/// ## Invariant
///
/// Strokes are never deleted. Erasure is represented as a new Stroke record
/// with [isTombstone] = true and [erasesStrokeId] pointing to the target.
/// This preserves the append-only log and enables full history replay.
class Stroke {
  /// Globally unique identifier. Used for deduplication in sync merge.
  final String id;

  /// Owning page (FK → SketchPage.id).
  final String pageId;

  /// Layer within the page. Default: "default".
  final String layerId;

  /// Drawing tool — controls renderer behaviour.
  final ToolType tool;

  /// Stroke color as ARGB packed integer.
  final int color;

  /// Base stroke width in canvas units before pressure scaling (0.5–50.0).
  final double weight;

  /// Global opacity, separate from color alpha (0.01–1.0).
  final double opacity;

  /// The raw point samples (Level 0). Minimum one point (tap = single point stroke).
  final List<StrokePoint> points;

  /// Compact normalized render points produced by curve fitting on pen-up.
  ///
  /// This is the primary data for rendering and sync. Coordinates are
  /// normalized 0.0–1.0 relative to canvas dimensions. Null for tombstones
  /// or strokes created before the v4 overhaul.
  final List<RenderPoint>? renderData;

  /// Bridge getter for the rendering pipeline (Phase 1 compat).
  ///
  /// Always returns raw [points] for display — no visible smoothing.
  /// [renderData] is stored for sync and future Phase 2 rendering
  /// but never shown to the user until we can make the transition
  /// imperceptible.
  List<StrokePoint> get renderPoints => points;

  /// Set at pen-up. Not modified thereafter.
  final DateTime createdAt;

  /// True = this stroke is logically erased.
  final bool isTombstone;

  /// The stroke this tombstone erases (null if not a tombstone).
  final String? erasesStrokeId;

  /// Set to true after cloud acknowledgement.
  final bool synced;

  Stroke({
    required this.id,
    required this.pageId,
    this.layerId = 'default',
    required this.tool,
    required this.color,
    required this.weight,
    required this.opacity,
    required this.points,
    this.renderData,
    required this.createdAt,
    this.isTombstone = false,
    this.erasesStrokeId,
    this.synced = false,
  });

  /// The bounding rectangle of all points, inflated by weight/2 on all sides.
  ///
  /// Cached on first access. Only valid for committed strokes (where points
  /// are frozen). Used for dirty region tracking (TDD §4.1) and hit testing.
  /// Test DRW-002 validates this computation.
  Rect get boundingRect => _cachedBoundingRect ??= _computeBoundingRect();
  Rect? _cachedBoundingRect;

  Rect _computeBoundingRect() {
    if (points.isEmpty) return Rect.zero;

    double minX = points[0].x;
    double maxX = points[0].x;
    double minY = points[0].y;
    double maxY = points[0].y;

    for (int i = 1; i < points.length; i++) {
      final p = points[i];
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }

    final halfWeight = weight / 2.0;
    return Rect.fromLTRB(
      minX - halfWeight,
      minY - halfWeight,
      maxX + halfWeight,
      maxY + halfWeight,
    );
  }

  /// Create a tombstone stroke that erases [targetStrokeId].
  ///
  /// The tombstone has no visual points — it exists only in the log
  /// to mark the target as logically erased (TDD §3.2 invariant).
  factory Stroke.tombstone({
    required String id,
    required String pageId,
    required String targetStrokeId,
    required DateTime createdAt,
  }) {
    return Stroke(
      id: id,
      pageId: pageId,
      tool: ToolType.eraser,
      color: 0x00000000,
      weight: 0.5,
      opacity: 1.0,
      points: const [],
      createdAt: createdAt,
      isTombstone: true,
      erasesStrokeId: targetStrokeId,
    );
  }

  // --- Serialization ---

  Map<String, dynamic> toJson() => {
        'id': id,
        'pageId': pageId,
        'layerId': layerId,
        'tool': tool.toJson(),
        'color': color,
        'weight': weight,
        'opacity': opacity,
        'points': points.map((p) => p.toJson()).toList(),
        if (renderData != null)
          'renderData': renderData!.map((rp) => rp.toJson()).toList(),
        'createdAt': createdAt.toUtc().toIso8601String(),
        'isTombstone': isTombstone,
        'erasesStrokeId': erasesStrokeId,
        'synced': synced,
      };

  factory Stroke.fromJson(Map<String, dynamic> json) => Stroke(
        id: json['id'] as String,
        pageId: json['pageId'] as String,
        layerId: json['layerId'] as String? ?? 'default',
        tool: ToolType.fromJson(json['tool'] as String),
        color: json['color'] as int,
        weight: (json['weight'] as num).toDouble(),
        opacity: (json['opacity'] as num).toDouble(),
        points: (json['points'] as List)
            .map((p) => StrokePoint.fromJson(p as Map<String, dynamic>))
            .toList(),
        renderData: json['renderData'] != null
            ? (json['renderData'] as List)
                .map((rp) => RenderPoint.fromJson(rp as Map<String, dynamic>))
                .toList()
            : null,
        createdAt: DateTime.parse(json['createdAt'] as String),
        isTombstone: json['isTombstone'] as bool? ?? false,
        erasesStrokeId: json['erasesStrokeId'] as String?,
        synced: json['synced'] as bool? ?? false,
      );

  /// Convert to a SQLite row map. Points are stored as binary blobs.
  Map<String, dynamic> toDbMap() => {
        'id': id,
        'page_id': pageId,
        'layer_id': layerId,
        'tool': tool.toJson(),
        'color': color,
        'weight': weight,
        'opacity': opacity,
        'raw_points_blob': StrokePoint.packAll(points),
        'render_points_blob':
            renderData != null ? RenderPoint.packAll(renderData!) : null,
        'created_at': createdAt.toUtc().toIso8601String(),
        'is_tombstone': isTombstone ? 1 : 0,
        'erases_stroke_id': erasesStrokeId,
        'synced': synced ? 1 : 0,
      };

  /// Reconstruct from a SQLite row map.
  factory Stroke.fromDbMap(Map<String, dynamic> map) => Stroke(
        id: map['id'] as String,
        pageId: map['page_id'] as String,
        layerId: map['layer_id'] as String? ?? 'default',
        tool: ToolType.fromJson(map['tool'] as String),
        color: map['color'] as int,
        weight: (map['weight'] as num).toDouble(),
        opacity: (map['opacity'] as num).toDouble(),
        points: StrokePoint.unpackAll(map['raw_points_blob'] as Uint8List),
        renderData: map['render_points_blob'] != null
            ? RenderPoint.unpackAll(map['render_points_blob'] as Uint8List)
            : null,
        createdAt: DateTime.parse(map['created_at'] as String),
        isTombstone: (map['is_tombstone'] as int) == 1,
        erasesStrokeId: map['erases_stroke_id'] as String?,
        synced: (map['synced'] as int) == 1,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Stroke &&
          id == other.id &&
          pageId == other.pageId &&
          layerId == other.layerId &&
          tool == other.tool &&
          color == other.color &&
          weight == other.weight &&
          opacity == other.opacity &&
          points.length == other.points.length &&
          createdAt == other.createdAt &&
          isTombstone == other.isTombstone &&
          erasesStrokeId == other.erasesStrokeId &&
          synced == other.synced;

  @override
  int get hashCode => Object.hash(id, pageId, tool, createdAt);

  @override
  String toString() =>
      'Stroke(id: $id, tool: ${tool.name}, points: ${points.length}, tombstone: $isTombstone)';
}
