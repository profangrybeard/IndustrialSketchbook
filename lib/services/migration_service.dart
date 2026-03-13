import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../models/spine_point.dart';
import '../models/stroke_point.dart';
import '../utils/coordinate_utils.dart';

/// Background migration service that converts legacy world-coordinate strokes
/// (coord_format=0) to reference-unit strokes (coord_format=1).
///
/// Runs in batches after app startup. Each batch is a single transaction,
/// making the migration interruptible and safe. Mixed format pages work
/// fine — [Stroke.fromDbMap] handles each row independently.
///
/// Typical migration speed: ~50 strokes in ~2ms.
class MigrationService {
  MigrationService(this._db);

  final Database _db;

  /// Number of strokes to migrate per batch.
  /// Larger batches = fewer SQLite transactions = less fsync overhead.
  static const int _batchSize = 500;

  /// Run the format-0 → format-1 migration to completion.
  ///
  /// Returns the total number of strokes migrated.
  Future<int> migrateToReferenceUnits() async {
    if (!CoordinateUtils.isInitialized) {
      debugPrint('[Migration] CoordinateUtils not initialized, skipping');
      return 0;
    }

    final scale = CoordinateUtils.referenceScale;
    final invScale = 1.0 / scale;
    int totalMigrated = 0;

    while (true) {
      final count = await _migrateBatch(invScale);
      totalMigrated += count;
      if (count < _batchSize) break; // No more rows to migrate
    }

    if (totalMigrated > 0) {
      debugPrint('[Migration] Migrated $totalMigrated strokes to reference units');
    }
    return totalMigrated;
  }

  /// Migrate a single batch of strokes. Returns the number migrated.
  Future<int> _migrateBatch(double invScale) async {
    final rows = await _db.query(
      'strokes',
      columns: ['id', 'raw_points_blob', 'spine_blob', 'weight'],
      where: 'coord_format = 0',
      limit: _batchSize,
    );

    if (rows.isEmpty) return 0;

    await _db.transaction((txn) async {
      for (final row in rows) {
        final id = row['id'] as String;
        final rawBlob = row['raw_points_blob'] as Uint8List;
        final weight = (row['weight'] as num).toDouble();

        // Scale raw points
        final points = StrokePoint.unpackAll(rawBlob);
        final scaledPoints = points.map((p) => StrokePoint(
          x: p.x * invScale,
          y: p.y * invScale,
          pressure: p.pressure,
          tiltX: p.tiltX,
          tiltY: p.tiltY,
          twist: p.twist,
          timestamp: p.timestamp,
        )).toList();

        final updates = <String, dynamic>{
          'raw_points_blob': StrokePoint.packAll(scaledPoints),
          'weight': weight * invScale,
          'render_points_blob': null, // Deprecated
          'coord_format': 1,
        };

        // Scale spine points if present
        final spineBlob = row['spine_blob'] as Uint8List?;
        if (spineBlob != null) {
          final spines = SpinePoint.unpackAll(spineBlob);
          final scaledSpines = spines.map((s) => SpinePoint(
            s.x * invScale,
            s.y * invScale,
            s.pressure,
          )).toList();
          updates['spine_blob'] = SpinePoint.packAll(scaledSpines);
        }

        await txn.update('strokes', updates, where: 'id = ?', whereArgs: [id]);
      }
    });

    return rows.length;
  }
}
