import 'stroke.dart';

/// A batch of strokes uploaded by a single device.
///
/// Journals are the unit of incremental sync. Each push creates one or more
/// journal files in Google Drive's appDataFolder. Other devices download
/// and merge journals using UUID dedup.
///
/// ## Versions
/// - **v1** (Phase 3.2): Full stroke JSON with raw points + canvasWidth
///   for cross-device coordinate scaling. Large payloads (~10MB / 500 strokes).
/// - **v2** (Phase 4): Compact sync — renderData only (normalized 0.0–1.0),
///   no canvasWidth, gzip compressed. ~95% smaller payloads.
/// - **v3** (Option B): Full stroke JSON in reference units (1000 = screen width).
///   Device-independent, no canvas width needed, preserves full sensor data.
class SyncJournal {
  const SyncJournal({
    required this.deviceId,
    required this.createdAt,
    required this.strokes,
    this.version = 3,
    this.canvasWidth,
  });

  /// Journal format version. 1 = legacy, 2 = compact renderData, 3 = reference units.
  final int version;

  /// Device that created this journal.
  final String deviceId;

  /// ISO 8601 UTC timestamp when this journal was created.
  final String createdAt;

  /// Strokes in this batch (including tombstones).
  final List<Stroke> strokes;

  /// Logical canvas width of the source device (v1 only, for scaling).
  /// Null for v2/v3 journals.
  final double? canvasWidth;

  /// Serialize — v3 uses full [Stroke.toJson] (strokes in reference units),
  /// v2 uses compact [Stroke.toSyncJson].
  Map<String, dynamic> toJson() => {
        'version': version,
        'deviceId': deviceId,
        'createdAt': createdAt,
        'strokes': version >= 3
            ? strokes.map((s) => s.toJson()).toList()
            : strokes.map((s) => s.toSyncJson()).toList(),
      };

  /// Deserialize from JSON, handling v1, v2, and v3 formats.
  factory SyncJournal.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? 1;

    List<Stroke> strokes;
    if (version >= 3) {
      // v3: full stroke JSON in reference units
      strokes = (json['strokes'] as List)
          .map((s) => Stroke.fromJson(s as Map<String, dynamic>))
          .map((s) => Stroke(
                id: s.id,
                pageId: s.pageId,
                layerId: s.layerId,
                tool: s.tool,
                color: s.color,
                weight: s.weight,
                opacity: s.opacity,
                points: s.points,
                renderData: s.renderData,
                spineData: s.spineData,
                createdAt: s.createdAt,
                isTombstone: s.isTombstone,
                erasesStrokeId: s.erasesStrokeId,
                synced: true,
                coordFormat: 1, // Mark as reference units
              ))
          .toList();
    } else if (version >= 2) {
      // v2: compact renderData (0.0–1.0)
      strokes = (json['strokes'] as List)
          .map((s) => Stroke.fromSyncJson(s as Map<String, dynamic>))
          .toList();
    } else {
      // v1: full JSON with world coordinates
      strokes = (json['strokes'] as List)
          .map((s) => Stroke.fromJson(s as Map<String, dynamic>))
          .toList();
    }

    return SyncJournal(
      version: version,
      deviceId: json['deviceId'] as String,
      createdAt: json['createdAt'] as String,
      strokes: strokes,
      canvasWidth: (json['canvasWidth'] as num?)?.toDouble(),
    );
  }
}
