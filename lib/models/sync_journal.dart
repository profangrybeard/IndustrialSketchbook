import 'stroke.dart';

/// A batch of strokes uploaded by a single device (Phase 3.2).
///
/// Journals are the unit of incremental sync. Each push creates one or more
/// journal files in Google Drive's appDataFolder. Other devices download
/// and merge journals using UUID dedup.
class SyncJournal {
  const SyncJournal({
    required this.deviceId,
    required this.createdAt,
    required this.strokes,
    this.canvasWidth,
  });

  /// Device that created this journal.
  final String deviceId;

  /// ISO 8601 UTC timestamp when this journal was created.
  final String createdAt;

  /// Strokes in this batch (including tombstones).
  final List<Stroke> strokes;

  /// Logical canvas width of the source device (for cross-device scaling).
  /// Null for journals created before this field was added.
  final double? canvasWidth;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'createdAt': createdAt,
        'strokes': strokes.map((s) => s.toJson()).toList(),
        if (canvasWidth != null) 'canvasWidth': canvasWidth,
      };

  factory SyncJournal.fromJson(Map<String, dynamic> json) => SyncJournal(
        deviceId: json['deviceId'] as String,
        createdAt: json['createdAt'] as String,
        strokes: (json['strokes'] as List)
            .map((s) => Stroke.fromJson(s as Map<String, dynamic>))
            .toList(),
        canvasWidth: (json['canvasWidth'] as num?)?.toDouble(),
      );
}
