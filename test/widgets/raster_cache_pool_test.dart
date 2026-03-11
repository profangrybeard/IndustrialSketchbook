import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/widgets/raster_cache_pool.dart';

/// Create a minimal [ui.Image] for testing via PictureRecorder.
ui.Image _makeTestImage(int width, int height) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint(),
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(width, height);
  picture.dispose();
  return image;
}

void main() {
  group('RasterCachePool', () {
    late RasterCachePool pool;

    setUp(() {
      pool = RasterCachePool(maxEntries: 3);
    });

    tearDown(() {
      pool.dispose();
    });

    // POOL-001
    test('POOL-001: fresh pool has size 0', () {
      expect(pool.size, equals(0));
    });

    // POOL-002
    test('POOL-002: getOrCreate returns fresh cache for unknown pageId', () {
      final cache = pool.getOrCreate('page-1');
      expect(cache, isNotNull);
      expect(cache.image, isNull);
      expect(cache.version, equals(-1));
      expect(pool.size, equals(1));
    });

    // POOL-003
    test('POOL-003: getOrCreate returns same instance for same pageId', () {
      final cache1 = pool.getOrCreate('page-1');
      final cache2 = pool.getOrCreate('page-1');
      expect(cache1, same(cache2));
      expect(pool.size, equals(1));
    });

    // POOL-004
    test('POOL-004: pool evicts LRU when exceeding maxEntries', () {
      pool.getOrCreate('page-1');
      pool.getOrCreate('page-2');
      pool.getOrCreate('page-3');
      expect(pool.size, equals(3));

      // Adding a 4th should evict page-1 (LRU)
      pool.getOrCreate('page-4');
      expect(pool.size, equals(3));
      expect(pool.peek('page-1'), isNull);
      expect(pool.peek('page-2'), isNotNull);
      expect(pool.peek('page-3'), isNotNull);
      expect(pool.peek('page-4'), isNotNull);
    });

    // POOL-005
    test('POOL-005: evicted entry image is disposed', () {
      final cache1 = pool.getOrCreate('page-1');
      final image = _makeTestImage(100, 100);
      cache1.update(image, 1, const ui.Size(100, 100), 42);
      expect(cache1.image, isNotNull);

      pool.getOrCreate('page-2');
      pool.getOrCreate('page-3');

      // Evict page-1 by adding page-4
      pool.getOrCreate('page-4');

      // The image from the evicted cache should be disposed
      expect(() => image.clone(), throwsA(anything));
    });

    // POOL-006
    test('POOL-006: access promotes to MRU, protecting from eviction', () {
      pool.getOrCreate('page-1');
      pool.getOrCreate('page-2');
      pool.getOrCreate('page-3');

      // Access page-1 to promote it to MRU
      pool.getOrCreate('page-1');

      // Adding page-4 should now evict page-2 (LRU), not page-1
      pool.getOrCreate('page-4');
      expect(pool.peek('page-1'), isNotNull);
      expect(pool.peek('page-2'), isNull);
      expect(pool.peek('page-3'), isNotNull);
      expect(pool.peek('page-4'), isNotNull);
    });

    // POOL-007
    test('POOL-007: remove() disposes and removes entry', () {
      final cache = pool.getOrCreate('page-1');
      final image = _makeTestImage(100, 100);
      cache.update(image, 1, const ui.Size(100, 100), 42);

      pool.remove('page-1');
      expect(pool.size, equals(0));
      expect(pool.peek('page-1'), isNull);

      // Image should be disposed
      expect(() => image.clone(), throwsA(anything));
    });

    // POOL-008
    test('POOL-008: dispose() clears all entries', () {
      final images = <ui.Image>[];
      for (int i = 0; i < 3; i++) {
        final cache = pool.getOrCreate('page-$i');
        final image = _makeTestImage(100, 100);
        cache.update(image, i, const ui.Size(100, 100), 42);
        images.add(image);
      }

      pool.dispose();
      expect(pool.size, equals(0));

      // All images should be disposed
      for (final image in images) {
        expect(() => image.clone(), throwsA(anything));
      }
    });

    // POOL-009
    test('POOL-009: peek() returns without promoting', () {
      pool.getOrCreate('page-1');
      pool.getOrCreate('page-2');
      pool.getOrCreate('page-3');

      // Peek at page-1 (should NOT promote it)
      expect(pool.peek('page-1'), isNotNull);

      // Adding page-4 should still evict page-1 (LRU, not promoted by peek)
      pool.getOrCreate('page-4');
      expect(pool.peek('page-1'), isNull);
    });

    // Edge case: remove non-existent page
    test('remove() on non-existent page is a no-op', () {
      pool.remove('non-existent');
      expect(pool.size, equals(0));
    });

    // Edge case: peek non-existent page
    test('peek() returns null for non-existent page', () {
      expect(pool.peek('non-existent'), isNull);
    });

    // Edge case: pool with maxEntries = 1
    test('pool with maxEntries=1 keeps only most recent', () {
      final smallPool = RasterCachePool(maxEntries: 1);

      smallPool.getOrCreate('page-1');
      expect(smallPool.size, equals(1));

      smallPool.getOrCreate('page-2');
      expect(smallPool.size, equals(1));
      expect(smallPool.peek('page-1'), isNull);
      expect(smallPool.peek('page-2'), isNotNull);

      smallPool.dispose();
    });
  });
}
