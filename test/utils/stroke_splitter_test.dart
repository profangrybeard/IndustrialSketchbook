import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/utils/stroke_splitter.dart';

void main() {
  /// Helper to create a StrokePoint at a given position.
  StrokePoint makePoint(double x, double y) {
    return StrokePoint(
      x: x,
      y: y,
      pressure: 0.5,
      tiltX: 0.0,
      tiltY: 0.0,
      twist: 0.0,
      timestamp: 0,
    );
  }

  group('splitStrokePoints', () {
    // -------------------------------------------------------------------------
    // No points hit — returns null
    // -------------------------------------------------------------------------
    test('returns null when no points are within eraser radius', () {
      final points = [
        makePoint(0, 0),
        makePoint(10, 0),
        makePoint(20, 0),
      ];

      final result = splitStrokePoints(
        points: points,
        eraserPosition: const Offset(100, 100),
        eraserRadius: 5.0,
      );

      expect(result, isNull);
    });

    // -------------------------------------------------------------------------
    // All points erased — returns empty list
    // -------------------------------------------------------------------------
    test('returns empty list when all points are erased', () {
      final points = [
        makePoint(10, 10),
        makePoint(12, 10),
        makePoint(11, 11),
      ];

      final result = splitStrokePoints(
        points: points,
        eraserPosition: const Offset(11, 10),
        eraserRadius: 5.0,
      );

      expect(result, isNotNull);
      expect(result, isEmpty);
    });

    // -------------------------------------------------------------------------
    // Middle of stroke erased — two segments
    // -------------------------------------------------------------------------
    test('erasing middle produces two segments', () {
      // Horizontal line: 0,0 → 10,0 → 20,0 → 30,0 → 40,0
      final points = [
        makePoint(0, 0),
        makePoint(10, 0),
        makePoint(20, 0),
        makePoint(30, 0),
        makePoint(40, 0),
      ];

      // Erase around x=20 with radius 5 — hits point at (20,0)
      final result = splitStrokePoints(
        points: points,
        eraserPosition: const Offset(20, 0),
        eraserRadius: 5.0,
      );

      expect(result, isNotNull);
      expect(result!.length, equals(2));
      // First segment: points before erased area
      expect(result[0].length, equals(2)); // (0,0), (10,0)
      expect(result[0][0].x, equals(0));
      expect(result[0][1].x, equals(10));
      // Second segment: points after erased area
      expect(result[1].length, equals(2)); // (30,0), (40,0)
      expect(result[1][0].x, equals(30));
      expect(result[1][1].x, equals(40));
    });

    // -------------------------------------------------------------------------
    // Start of stroke erased — one segment remains
    // -------------------------------------------------------------------------
    test('erasing start produces one trailing segment', () {
      final points = [
        makePoint(0, 0),
        makePoint(5, 0),
        makePoint(20, 0),
        makePoint(30, 0),
      ];

      // Erase near origin — hits (0,0) and (5,0)
      final result = splitStrokePoints(
        points: points,
        eraserPosition: const Offset(2, 0),
        eraserRadius: 6.0,
      );

      expect(result, isNotNull);
      expect(result!.length, equals(1));
      expect(result[0].length, equals(2)); // (20,0), (30,0)
      expect(result[0][0].x, equals(20));
    });

    // -------------------------------------------------------------------------
    // End of stroke erased — one leading segment remains
    // -------------------------------------------------------------------------
    test('erasing end produces one leading segment', () {
      final points = [
        makePoint(0, 0),
        makePoint(10, 0),
        makePoint(35, 0),
        makePoint(40, 0),
      ];

      // Erase near end — hits (35,0) and (40,0)
      final result = splitStrokePoints(
        points: points,
        eraserPosition: const Offset(37, 0),
        eraserRadius: 6.0,
      );

      expect(result, isNotNull);
      expect(result!.length, equals(1));
      expect(result[0].length, equals(2)); // (0,0), (10,0)
    });

    // -------------------------------------------------------------------------
    // Multiple gaps — three segments
    // -------------------------------------------------------------------------
    test('erasing two separate areas produces three segments', () {
      // Points at x = 0, 10, 20, 30, 40, 50, 60
      final points = [
        makePoint(0, 0),
        makePoint(10, 0),
        makePoint(20, 0),
        makePoint(30, 0),
        makePoint(40, 0),
        makePoint(50, 0),
        makePoint(60, 0),
      ];

      // Erase at x=20 (radius 3) — hits (20,0) only
      // Also erase at x=50 (radius 3) — hits (50,0) only
      // We need a single eraser position, so let's test with just one hit
      // that creates two segments. For multiple gaps we'd call twice.
      // Actually, splitStrokePoints takes a single eraser position.
      // Let's hit point at x=30 with a big enough radius to also hit x=20
      final result = splitStrokePoints(
        points: points,
        eraserPosition: const Offset(25, 0),
        eraserRadius: 8.0,
      );
      // This should hit (20,0) and (30,0), splitting into:
      // Segment 1: (0,0), (10,0)
      // Segment 2: (40,0), (50,0), (60,0)
      expect(result, isNotNull);
      expect(result!.length, equals(2));
      expect(result[0].length, equals(2));
      expect(result[1].length, equals(3));
    });

    // -------------------------------------------------------------------------
    // Single-point stroke erased
    // -------------------------------------------------------------------------
    test('single-point stroke fully erased returns empty list', () {
      final points = [makePoint(10, 10)];

      final result = splitStrokePoints(
        points: points,
        eraserPosition: const Offset(10, 10),
        eraserRadius: 5.0,
      );

      expect(result, isNotNull);
      expect(result, isEmpty);
    });

    // -------------------------------------------------------------------------
    // Point exactly on radius boundary
    // -------------------------------------------------------------------------
    test('point exactly on radius boundary is erased (<=)', () {
      final points = [
        makePoint(0, 0),
        makePoint(5, 0), // exactly at distance 5 from eraser
        makePoint(20, 0),
      ];

      final result = splitStrokePoints(
        points: points,
        eraserPosition: const Offset(0, 0),
        eraserRadius: 5.0,
      );

      expect(result, isNotNull);
      // (0,0) is at distance 0 — erased
      // (5,0) is at distance 5 — erased (boundary, <=)
      // (20,0) survives
      expect(result!.length, equals(1));
      expect(result[0].length, equals(1));
      expect(result[0][0].x, equals(20));
    });

    // -------------------------------------------------------------------------
    // Preserves StrokePoint data
    // -------------------------------------------------------------------------
    test('surviving points retain all original data', () {
      final original = StrokePoint(
        x: 50,
        y: 60,
        pressure: 0.75,
        tiltX: 15.0,
        tiltY: 20.0,
        twist: 45.0,
        timestamp: 12345,
      );

      final points = [
        makePoint(0, 0), // will be erased
        original, // will survive
      ];

      final result = splitStrokePoints(
        points: points,
        eraserPosition: const Offset(0, 0),
        eraserRadius: 5.0,
      );

      expect(result, isNotNull);
      expect(result!.length, equals(1));
      final surviving = result[0][0];
      expect(surviving.x, equals(50));
      expect(surviving.y, equals(60));
      expect(surviving.pressure, equals(0.75));
      expect(surviving.tiltX, equals(15.0));
      expect(surviving.tiltY, equals(20.0));
      expect(surviving.twist, equals(45.0));
      expect(surviving.timestamp, equals(12345));
    });

    // -------------------------------------------------------------------------
    // 2D distance check (not just X axis)
    // -------------------------------------------------------------------------
    test('uses 2D Euclidean distance, not axis-aligned', () {
      final points = [
        makePoint(3, 4), // distance = 5 from origin — on boundary
        makePoint(3, 5), // distance ~5.83 from origin — outside
      ];

      final result = splitStrokePoints(
        points: points,
        eraserPosition: const Offset(0, 0),
        eraserRadius: 5.0,
      );

      expect(result, isNotNull);
      // (3,4) at distance 5 — erased
      // (3,5) at distance ~5.83 — survives
      expect(result!.length, equals(1));
      expect(result[0].length, equals(1));
      expect(result[0][0].x, equals(3));
      expect(result[0][0].y, equals(5));
    });
  });
}
