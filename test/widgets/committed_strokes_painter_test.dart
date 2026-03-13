import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/pressure_mode.dart';
import 'package:industrial_sketchbook/services/drawing_service.dart'
    show MutationInfo;
import 'package:industrial_sketchbook/widgets/committed_strokes_painter.dart';
import 'package:industrial_sketchbook/widgets/tile_cache.dart';

void main() {
  group('CommittedStrokesPainter.shouldRepaint', () {
    late TileCache tileCache;

    setUp(() {
      tileCache = TileCache(maxTiles: 4);
    });

    tearDown(() {
      tileCache.dispose();
    });

    CommittedStrokesPainter makePainter({
      int strokeVersion = 0,
      PressureMode pressureMode = PressureMode.width,
      double grainIntensity = 0.25,
      double pressureExponent = 1.8,
      Rect viewportRect = const Rect.fromLTWH(0, 0, 1200, 800),
      double zoom = 1.0,
    }) {
      return CommittedStrokesPainter(
        committedStrokes: const [],
        erasedStrokeIds: const {},
        strokeVersion: strokeVersion,
        pressureMode: pressureMode,
        grainIntensity: grainIntensity,
        pressureExponent: pressureExponent,
        tileCache: tileCache,
        spatialGrid: null,
        devicePixelRatio: 1.0,
        viewportRect: viewportRect,
        zoom: zoom,
        lastMutationInfo: const MutationInfo.fullRebuild(),
      );
    }

    test('returns false when strokeVersion unchanged', () {
      final old = makePainter(strokeVersion: 5);
      final current = makePainter(strokeVersion: 5);
      expect(current.shouldRepaint(old), isFalse);
    });

    test('returns true when strokeVersion changes', () {
      final old = makePainter(strokeVersion: 5);
      final current = makePainter(strokeVersion: 6);
      expect(current.shouldRepaint(old), isTrue);
    });

    test('returns true when pressureMode changes', () {
      final old = makePainter(pressureMode: PressureMode.width);
      final current = makePainter(pressureMode: PressureMode.opacity);
      expect(current.shouldRepaint(old), isTrue);
    });

    test('returns true when grainIntensity changes', () {
      final old = makePainter(grainIntensity: 0.25);
      final current = makePainter(grainIntensity: 0.5);
      expect(current.shouldRepaint(old), isTrue);
    });

    test('returns true when pressureExponent changes', () {
      final old = makePainter(pressureExponent: 1.8);
      final current = makePainter(pressureExponent: 2.5);
      expect(current.shouldRepaint(old), isTrue);
    });

    test('returns true when viewportRect changes', () {
      final old = makePainter(
          viewportRect: const Rect.fromLTWH(0, 0, 1200, 800));
      final current = makePainter(
          viewportRect: const Rect.fromLTWH(100, 100, 1200, 800));
      expect(current.shouldRepaint(old), isTrue);
    });

    test('returns true when zoom changes', () {
      final old = makePainter(zoom: 1.0);
      final current = makePainter(zoom: 2.0);
      expect(current.shouldRepaint(old), isTrue);
    });
  });
}
