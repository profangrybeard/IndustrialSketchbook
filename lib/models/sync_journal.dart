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
class SyncJournal {
  const SyncJournal({
    required this.deviceId,
    required this.createdAt,
    required this.strokes,
    this.version = 2,
    this.canvasWidth,
  });

  /// Journal format version. 1 = legacy full JSON, 2 = compact renderData.
  final int version;

  /// Device that created this journal.
  final String deviceId;

  /// ISO 8601 UTC timestamp when this journal was created.
  final String createdAt;

  /// Strokes in this batch (including tombstones).
  final List<Stroke> strokes;

  /// Logical canvas width of the source device (v1 only, for scaling).
  /// Null for v2 journals (strokes are pre-normalized).
  final double? canvasWidth;

  /// Serialize as v2 compact format — uses [Stroke.toSyncJson].
  Map<String, dynamic> toJson() => {
        'version': version,
        'deviceId': deviceId,
        'createdAt': createdAt,
        'strokes': strokes.map((s) => s.toSyncJson()).toList(),
      };

  /// Deserialize from JSON, handling both v1 and v2 formats.
  ///
  /// v1 journals (no version field or version=1) use [Stroke.fromJson]
  /// which expects raw points + canvasWidth for coordinate scaling.
  /// v2 journals use [Stroke.fromSyncJson] with normalized renderData.
  factory SyncJournal.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? 1;

    final strokes = version >= 2
        ? (json['strokes'] as List)
            .map((s) => Stroke.fromSyncJson(s as Map<String, dynamic>))
            .toList()
        : (json['strokes'] as List)
            .map((s) => Stroke.fromJson(s as Map<String, dynamic>))
            .toList();

    return SyncJournal(
      version: version,
      deviceId: json['deviceId'] as String,
      createdAt: json['createdAt'] as String,
      strokes: strokes,
      canvasWidth: (json['canvasWidth'] as num?)?.toDouble(),
    );
  }
}
