import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/widgets/stroke_raster_cache.dart';

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
  group('StrokeRasterCache', () {
    late StrokeRasterCache cache;
    final size = const ui.Size(800, 600);
    const paramHash = 42;

    setUp(() {
      cache = StrokeRasterCache();
    });

    tearDown(() {
      cache.dispose();
    });

    // RST-001
    test('RST-001: fresh cache isValid returns false', () {
      expect(cache.isValid(0, size, paramHash), isFalse);
      expect(cache.image, isNull);
    });

    // RST-002
    test('RST-002: after update, isValid returns true for matching version+size+params', () {
      final image = _makeTestImage(800, 600);
      cache.update(image, 5, size, paramHash);

      expect(cache.isValid(5, size, paramHash), isTrue);
      expect(cache.image, isNotNull);
      expect(cache.version, equals(5));
    });

    // RST-003
    test('RST-003: isValid returns false for version mismatch', () {
      final image = _makeTestImage(800, 600);
      cache.update(image, 5, size, paramHash);

      expect(cache.isValid(6, size, paramHash), isFalse);
      expect(cache.isValid(4, size, paramHash), isFalse);
    });

    // RST-004
    test('RST-004: isValid returns false for size mismatch', () {
      final image = _makeTestImage(800, 600);
      cache.update(image, 5, size, paramHash);

      const differentSize = ui.Size(1024, 768);
      expect(cache.isValid(5, differentSize, paramHash), isFalse);
    });

    // RST-005
    test('RST-005: isValid returns false for paramHash mismatch', () {
      final image = _makeTestImage(800, 600);
      cache.update(image, 5, size, paramHash);

      expect(cache.isValid(5, size, 99), isFalse);
    });

    // RST-006
    test('RST-006: canIncrement returns true when version is exactly 1 behind', () {
      final image = _makeTestImage(800, 600);
      cache.update(image, 5, size, paramHash);

      expect(cache.canIncrement(6, size, paramHash), isTrue);
    });

    // RST-007
    test('RST-007: canIncrement returns false when version gap > 1', () {
      final image = _makeTestImage(800, 600);
      cache.update(image, 5, size, paramHash);

      expect(cache.canIncrement(7, size, paramHash), isFalse);
      expect(cache.canIncrement(8, size, paramHash), isFalse);
    });

    // RST-008
    test('RST-008: invalidate clears cache and isValid returns false', () {
      final image = _makeTestImage(800, 600);
      cache.update(image, 5, size, paramHash);
      expect(cache.isValid(5, size, paramHash), isTrue);

      cache.invalidate();

      expect(cache.isValid(5, size, paramHash), isFalse);
      expect(cache.image, isNull);
      expect(cache.version, equals(-1));
    });

    // RST-009
    test('RST-009: update disposes old image before storing new', () {
      final image1 = _makeTestImage(800, 600);
      cache.update(image1, 1, size, paramHash);

      final image2 = _makeTestImage(800, 600);
      cache.update(image2, 2, size, paramHash);

      // Old image should be disposed — accessing it would throw.
      // The new image should be the current one.
      expect(cache.image, same(image2));
      expect(cache.version, equals(2));

      // image1 was disposed by update(). Calling clone() on a disposed
      // image throws, confirming disposal.
      expect(() => image1.clone(), throwsA(anything));
    });

    // RST-010
    test('RST-010: dispose clears image', () {
      final image = _makeTestImage(800, 600);
      cache.update(image, 1, size, paramHash);
      expect(cache.image, isNotNull);

      cache.dispose();
      expect(cache.image, isNull);
    });

    // Additional edge cases
    test('canIncrement returns false on fresh cache', () {
      expect(cache.canIncrement(1, size, paramHash), isFalse);
    });

    test('canIncrement returns false for size mismatch', () {
      final image = _makeTestImage(800, 600);
      cache.update(image, 5, size, paramHash);

      const differentSize = ui.Size(1024, 768);
      expect(cache.canIncrement(6, differentSize, paramHash), isFalse);
    });

    test('canIncrement returns false for paramHash mismatch', () {
      final image = _makeTestImage(800, 600);
      cache.update(image, 5, size, paramHash);

      expect(cache.canIncrement(6, size, 99), isFalse);
    });
  });
}
