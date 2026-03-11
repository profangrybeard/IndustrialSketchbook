import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/snapshot_service.dart';
import 'database_provider.dart';

/// Provides a [SnapshotService] for page raster snapshot management.
///
/// Depends on [databaseServiceProvider] for DB-backed persistence.
/// Returns null while the database is still initializing.
final snapshotServiceProvider = Provider<SnapshotService?>((ref) {
  final dbAsync = ref.watch(databaseServiceProvider);
  return dbAsync.whenOrNull(
    data: (db) => SnapshotService(db),
  );
});
