import 'dart:typed_data';
import 'dart:ui';

import 'render_point.dart';
import 'spine_point.dart';
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

  /// Pre-computed spine points from Catmull-Rom subdivision (Option A).
  ///
  /// Computed once at pen-up using [replayTargetArcLength] and stored in
  /// SQLite as a binary blob. When present, the renderer skips the expensive
  /// Catmull-Rom subdivision loop entirely, using stored (x, y, pressure)
  /// to build ribbon geometry directly. Null for tombstones or strokes
  /// created before the v5 schema.
  final List<SpinePoint>? spineData;

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

  /// Coordinate format: 0 = legacy world coordinates, 1 = reference units.
  ///
  /// Strokes in format 1 have their x,y positions and weight stored in
  /// device-independent reference units (1000.0 = one screen width).
  /// At DB load time, format-1 values are multiplied by [referenceScale]
  /// to recover world coordinates. At DB save time, world coordinates
  /// are divided by [referenceScale] to produce reference units.
  ///
  /// In-memory Stroke objects always hold world coordinates — coordFormat
  /// only affects serialization.
  final int coordFormat;

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
    this.spineData,
    required this.createdAt,
    this.isTombstone = false,
    this.erasesStrokeId,
    this.synced = false,
    this.coordFormat = 0,
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

  /// Compact sync serialization — excludes raw [points], ships only
  /// [renderData] (normalized 0.0–1.0). ~95% smaller than [toJson].
  ///
  /// Used by v2 sync journals. Tombstones omit renderData entirely
  /// since they carry no visual data.
  Map<String, dynamic> toSyncJson() => {
        'id': id,
        'pageId': pageId,
        'layerId': layerId,
        'tool': tool.toJson(),
        'color': color,
        'weight': weight,
        'opacity': opacity,
        if (renderData != null && !isTombstone)
          'renderData': renderData!.map((rp) => rp.toJson()).toList(),
        'createdAt': createdAt.toUtc().toIso8601String(),
        'isTombstone': isTombstone,
        'erasesStrokeId': erasesStrokeId,
      };

  /// Reconstruct a stroke from a v2 sync journal payload.
  ///
  /// Only [renderData] is present — [points] is empty. The rendering
  /// pipeline uses [renderPoints] (which falls back to raw points for
  /// local strokes). For synced strokes, the renderer will need to
  /// consume renderData directly in a future phase.
  factory Stroke.fromSyncJson(Map<String, dynamic> json) => Stroke(
        id: json['id'] as String,
        pageId: json['pageId'] as String,
        layerId: json['layerId'] as String? ?? 'default',
        tool: ToolType.fromJson(json['tool'] as String),
        color: json['color'] as int,
        weight: (json['weight'] as num).toDouble(),
        opacity: (json['opacity'] as num).toDouble(),
        points: const [], // No raw points in sync payloads
        renderData: json['renderData'] != null
            ? (json['renderData'] as List)
                .map((rp) => RenderPoint.fromJson(rp as Map<String, dynamic>))
                .toList()
            : null,
        createdAt: DateTime.parse(json['createdAt'] as String),
        isTombstone: json['isTombstone'] as bool? ?? false,
        erasesStrokeId: json['erasesStrokeId'] as String?,
        synced: true, // Synced strokes arrived via sync
      );

  /// Convert to a SQLite row map. Points are stored as binary blobs.
  ///
  /// When [referenceScale] is provided, coordinates and weight are divided
  /// by the scale to produce device-independent reference units (coord_format=1).
  /// When null, coordinates are stored as-is (legacy world coords, coord_format=0).
  Map<String, dynamic> toDbMap({double? referenceScale}) {
    // If stroke is already in reference units (e.g., from v3 sync pull),
    // store as-is without conversion.
    if (coordFormat == 1) {
      return {
        'id': id,
        'page_id': pageId,
        'layer_id': layerId,
        'tool': tool.toJson(),
        'color': color,
        'weight': weight,
        'opacity': opacity,
        'raw_points_blob': StrokePoint.packAll(points),
        'render_points_blob': null,
        'spine_blob':
            spineData != null ? SpinePoint.packAll(spineData!) : null,
        'coord_format': 1,
        'created_at': createdAt.toUtc().toIso8601String(),
        'is_tombstone': isTombstone ? 1 : 0,
        'erases_stroke_id': erasesStrokeId,
        'synced': synced ? 1 : 0,
      };
    }
    // Convert world coords → reference units if scale provided.
    if (referenceScale != null) {
      final invScale = 1.0 / referenceScale;
      return {
        'id': id,
        'page_id': pageId,
        'layer_id': layerId,
        'tool': tool.toJson(),
        'color': color,
        'weight': weight * invScale,
        'opacity': opacity,
        'raw_points_blob': _packScaledPoints(points, invScale),
        'render_points_blob': null,
        'spine_blob': spineData != null
            ? _packScaledSpines(spineData!, invScale)
            : null,
        'coord_format': 1,
        'created_at': createdAt.toUtc().toIso8601String(),
        'is_tombstone': isTombstone ? 1 : 0,
        'erases_stroke_id': erasesStrokeId,
        'synced': synced ? 1 : 0,
      };
    }
    // Legacy: store world coords as-is.
    return {
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
      'spine_blob':
          spineData != null ? SpinePoint.packAll(spineData!) : null,
      'coord_format': 0,
      'created_at': createdAt.toUtc().toIso8601String(),
      'is_tombstone': isTombstone ? 1 : 0,
      'erases_stroke_id': erasesStrokeId,
      'synced': synced ? 1 : 0,
    };
  }

  /// Pack points with x,y scaled by [invScale] (1/referenceScale).
  static Uint8List _packScaledPoints(List<StrokePoint> points, double invScale) {
    final scaled = points.map((p) => StrokePoint(
      x: p.x * invScale,
      y: p.y * invScale,
      pressure: p.pressure,
      tiltX: p.tiltX,
      tiltY: p.tiltY,
      twist: p.twist,
      timestamp: p.timestamp,
    )).toList();
    return StrokePoint.packAll(scaled);
  }

  /// Pack spine points with x,y scaled by [invScale] (1/referenceScale).
  static Uint8List _packScaledSpines(List<SpinePoint> spines, double invScale) {
    final scaled = spines.map((s) => SpinePoint(
      s.x * invScale,
      s.y * invScale,
      s.pressure,
    )).toList();
    return SpinePoint.packAll(scaled);
  }

  /// Reconstruct from a SQLite row map.
  ///
  /// When [referenceScale] is provided and the row has `coord_format = 1`,
  /// coordinates and weight are multiplied by [referenceScale] to recover
  /// world coordinates. Format-0 rows pass through unchanged.
  factory Stroke.fromDbMap(Map<String, dynamic> map, {double? referenceScale}) {
    final format = (map['coord_format'] as int?) ?? 0;
    final scale = (format == 1 && referenceScale != null) ? referenceScale : null;

    var rawPoints = StrokePoint.unpackAll(map['raw_points_blob'] as Uint8List);
    var weight = (map['weight'] as num).toDouble();
    List<SpinePoint>? spines;
    if (map['spine_blob'] != null) {
      spines = SpinePoint.unpackAll(map['spine_blob'] as Uint8List);
    }

    if (scale != null) {
      rawPoints = rawPoints.map((p) => StrokePoint(
        x: p.x * scale,
        y: p.y * scale,
        pressure: p.pressure,
        tiltX: p.tiltX,
        tiltY: p.tiltY,
        twist: p.twist,
        timestamp: p.timestamp,
      )).toList();
      weight *= scale;
      if (spines != null) {
        spines = spines.map((s) => SpinePoint(
          s.x * scale,
          s.y * scale,
          s.pressure,
        )).toList();
      }
    }

    return Stroke(
      id: map['id'] as String,
      pageId: map['page_id'] as String,
      layerId: map['layer_id'] as String? ?? 'default',
      tool: ToolType.fromJson(map['tool'] as String),
      color: map['color'] as int,
      weight: weight,
      opacity: (map['opacity'] as num).toDouble(),
      points: rawPoints,
      renderData: map['render_points_blob'] != null
          ? RenderPoint.unpackAll(map['render_points_blob'] as Uint8List)
          : null,
      spineData: spines,
      coordFormat: format,
      createdAt: DateTime.parse(map['created_at'] as String),
      isTombstone: (map['is_tombstone'] as int) == 1,
      erasesStrokeId: map['erases_stroke_id'] as String?,
      synced: (map['synced'] as int) == 1,
    );
  }

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
