import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/pressure_mode.dart';
import 'package:industrial_sketchbook/models/stroke.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/models/tool_type.dart';
import 'package:industrial_sketchbook/widgets/active_stroke_painter.dart';

void main() {
  group('ActiveStrokePainter', () {
    test('shouldRepaint always returns true', () {
      final old = ActiveStrokePainter(
        pressureMode: PressureMode.width,
        grainIntensity: 0.25,
        pressureExponent: 1.8,
        suppressSinglePoint: true,
      );
      final current = ActiveStrokePainter(
        pressureMode: PressureMode.width,
        grainIntensity: 0.25,
        pressureExponent: 1.8,
        suppressSinglePoint: true,
      );

      // Even with identical parameters, always repaint during drawing
      expect(current.shouldRepaint(old), isTrue);
    });

    test('suppressSinglePoint flag is stored correctly', () {
      final suppressed = ActiveStrokePainter(
        pressureMode: PressureMode.width,
        grainIntensity: 0.25,
        pressureExponent: 1.8,
        suppressSinglePoint: true,
      );
      expect(suppressed.suppressSinglePoint, isTrue);

      final notSuppressed = ActiveStrokePainter(
        pressureMode: PressureMode.width,
        grainIntensity: 0.25,
        pressureExponent: 1.8,
        suppressSinglePoint: false,
      );
      expect(notSuppressed.suppressSinglePoint, isFalse);
    });

    test('accepts inflight stroke parameter', () {
      final stroke = Stroke(
        id: 's1',
        pageId: 'p1',
        tool: ToolType.pencil,
        color: 0xFF000000,
        weight: 2.0,
        opacity: 1.0,
        points: [
          const StrokePoint(
            x: 10, y: 20, pressure: 0.5,
            tiltX: 0, tiltY: 0, twist: 0, timestamp: 0,
          ),
        ],
        createdAt: DateTime.utc(2024, 1, 1),
      );

      final painter = ActiveStrokePainter(
        inflightStroke: stroke,
        pressureMode: PressureMode.width,
        grainIntensity: 0.25,
        pressureExponent: 1.8,
        suppressSinglePoint: false,
      );
      expect(painter.inflightStroke, equals(stroke));
    });
  });
}
