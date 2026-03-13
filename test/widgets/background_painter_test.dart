import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/grid_style.dart';
import 'package:industrial_sketchbook/widgets/background_painter.dart';

/// Default viewport for tests (typical tablet screen at 1x zoom).
const _defaultViewport = Rect.fromLTWH(0, 0, 1200, 800);

void main() {
  group('BackgroundPainter.shouldRepaint', () {
    test('returns false when nothing changes', () {
      final painter = BackgroundPainter(
        paperColor: const Color(0xFFF5F5F0),
        gridStyle: GridStyle.dots,
        gridSpacing: 25.0,
        viewportRect: _defaultViewport,
        zoom: 1.0,
      );
      final same = BackgroundPainter(
        paperColor: const Color(0xFFF5F5F0),
        gridStyle: GridStyle.dots,
        gridSpacing: 25.0,
        viewportRect: _defaultViewport,
        zoom: 1.0,
      );

      expect(painter.shouldRepaint(same), isFalse);
    });

    test('returns true when paperColor changes', () {
      final old = BackgroundPainter(
        paperColor: const Color(0xFFF5F5F0),
        gridStyle: GridStyle.dots,
        gridSpacing: 25.0,
        viewportRect: _defaultViewport,
        zoom: 1.0,
      );
      final updated = BackgroundPainter(
        paperColor: const Color(0xFF2D2D2D),
        gridStyle: GridStyle.dots,
        gridSpacing: 25.0,
        viewportRect: _defaultViewport,
        zoom: 1.0,
      );

      expect(updated.shouldRepaint(old), isTrue);
    });

    test('returns true when gridStyle changes', () {
      final old = BackgroundPainter(
        paperColor: const Color(0xFFF5F5F0),
        gridStyle: GridStyle.dots,
        gridSpacing: 25.0,
        viewportRect: _defaultViewport,
        zoom: 1.0,
      );
      final updated = BackgroundPainter(
        paperColor: const Color(0xFFF5F5F0),
        gridStyle: GridStyle.lines,
        gridSpacing: 25.0,
        viewportRect: _defaultViewport,
        zoom: 1.0,
      );

      expect(updated.shouldRepaint(old), isTrue);
    });

    test('returns true when gridSpacing changes', () {
      final old = BackgroundPainter(
        paperColor: const Color(0xFFF5F5F0),
        gridStyle: GridStyle.dots,
        gridSpacing: 25.0,
        viewportRect: _defaultViewport,
        zoom: 1.0,
      );
      final updated = BackgroundPainter(
        paperColor: const Color(0xFFF5F5F0),
        gridStyle: GridStyle.dots,
        gridSpacing: 50.0,
        viewportRect: _defaultViewport,
        zoom: 1.0,
      );

      expect(updated.shouldRepaint(old), isTrue);
    });

    test('returns true when viewportRect changes', () {
      final old = BackgroundPainter(
        paperColor: const Color(0xFFF5F5F0),
        gridStyle: GridStyle.dots,
        gridSpacing: 25.0,
        viewportRect: _defaultViewport,
        zoom: 1.0,
      );
      final updated = BackgroundPainter(
        paperColor: const Color(0xFFF5F5F0),
        gridStyle: GridStyle.dots,
        gridSpacing: 25.0,
        viewportRect: const Rect.fromLTWH(100, 100, 1200, 800),
        zoom: 1.0,
      );

      expect(updated.shouldRepaint(old), isTrue);
    });

    test('returns true when zoom changes', () {
      final old = BackgroundPainter(
        paperColor: const Color(0xFFF5F5F0),
        gridStyle: GridStyle.dots,
        gridSpacing: 25.0,
        viewportRect: _defaultViewport,
        zoom: 1.0,
      );
      final updated = BackgroundPainter(
        paperColor: const Color(0xFFF5F5F0),
        gridStyle: GridStyle.dots,
        gridSpacing: 25.0,
        viewportRect: _defaultViewport,
        zoom: 5.0,
      );

      expect(updated.shouldRepaint(old), isTrue);
    });
  });
}
