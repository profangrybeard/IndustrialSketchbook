import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/pencil_lead.dart';
import 'package:industrial_sketchbook/models/pressure_mode.dart';
import 'package:industrial_sketchbook/models/stroke.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/models/tool_type.dart';
import 'package:industrial_sketchbook/services/drawing_service.dart';

void main() {
  /// Helper to create a StrokePoint at a given position.
  StrokePoint makePoint(double x, double y, {double pressure = 0.5, int timestamp = 0}) {
    return StrokePoint(
      x: x,
      y: y,
      pressure: pressure,
      tiltX: 0.0,
      tiltY: 0.0,
      twist: 0.0,
      timestamp: timestamp,
    );
  }

  group('DrawingService', () {
    late DrawingService service;

    setUp(() {
      service = DrawingService();
    });

    // -----------------------------------------------------------------------
    // Basic pointer lifecycle
    // -----------------------------------------------------------------------
    group('pointer lifecycle', () {
      test('onPointerDown creates in-flight stroke', () {
        expect(service.isDrawing, isFalse);

        service.onPointerDown(
          strokeId: 'stroke-1',
          pageId: 'page-1',
          point: makePoint(10.0, 20.0),
        );

        expect(service.isDrawing, isTrue);
        expect(service.inflightStroke, isNotNull);
        expect(service.inflightStroke!.id, equals('stroke-1'));
        expect(service.inflightStroke!.points.length, equals(1));
      });

      test('onPointerMove appends points to in-flight stroke', () {
        service.onPointerDown(
          strokeId: 'stroke-1',
          pageId: 'page-1',
          point: makePoint(10.0, 20.0, timestamp: 1000),
        );

        service.onPointerMove(makePoint(15.0, 25.0, timestamp: 2000));
        service.onPointerMove(makePoint(20.0, 30.0, timestamp: 3000));

        expect(service.inflightStroke!.points.length, equals(3));
      });

      test('onPointerMove with no in-flight stroke is a no-op', () {
        service.onPointerMove(makePoint(10.0, 20.0));
        expect(service.isDrawing, isFalse);
        expect(service.committedStrokes, isEmpty);
      });

      test('onPointerUp commits stroke and clears in-flight', () {
        service.onPointerDown(
          strokeId: 'stroke-1',
          pageId: 'page-1',
          point: makePoint(10.0, 20.0),
        );
        service.onPointerMove(makePoint(20.0, 30.0));

        final committed = service.onPointerUp();

        expect(committed, isNotNull);
        expect(committed!.id, equals('stroke-1'));
        expect(committed.points.length, equals(2));
        expect(service.isDrawing, isFalse);
        expect(service.inflightStroke, isNull);
        expect(service.committedStrokes.length, equals(1));
        expect(service.committedStrokes.first.id, equals('stroke-1'));
      });

      test('onPointerUp with no in-flight stroke returns null', () {
        final result = service.onPointerUp();
        expect(result, isNull);
        expect(service.committedStrokes, isEmpty);
      });
    });

    // -----------------------------------------------------------------------
    // DRW-008: Single-point tap creates valid stroke
    //
    // Simulate ACTION_DOWN immediately followed by ACTION_UP;
    // assert stroke created with exactly 1 point.
    // Priority: P0
    // -----------------------------------------------------------------------
    group('DRW-008: single-point tap via service', () {
      test('pointer down then immediately up creates 1-point stroke', () {
        service.onPointerDown(
          strokeId: 'tap-stroke',
          pageId: 'page-1',
          point: makePoint(100.0, 200.0, pressure: 0.8),
        );

        final committed = service.onPointerUp();

        expect(committed, isNotNull);
        expect(committed!.points.length, equals(1));
        expect(committed.points.first.x, closeTo(100.0, 0.01));
        expect(committed.points.first.y, closeTo(200.0, 0.01));
        expect(committed.points.first.pressure, closeTo(0.8, 0.001));
      });
    });

    // -----------------------------------------------------------------------
    // Tool and property settings
    // -----------------------------------------------------------------------
    group('tool settings', () {
      test('stroke inherits current tool and color', () {
        service.currentTool = ToolType.marker;
        service.currentColor = 0xFFFF0000;
        service.currentWeight = 8.0;
        service.currentOpacity = 0.5;

        service.onPointerDown(
          strokeId: 's1',
          pageId: 'p1',
          point: makePoint(0.0, 0.0),
        );
        final stroke = service.onPointerUp()!;

        expect(stroke.tool, equals(ToolType.marker));
        expect(stroke.color, equals(0xFFFF0000));
        expect(stroke.weight, equals(8.0));
        expect(stroke.opacity, equals(0.5));
      });
    });

    // -----------------------------------------------------------------------
    // Multiple strokes
    // -----------------------------------------------------------------------
    group('multiple strokes', () {
      test('committed strokes accumulate in order', () {
        for (int i = 0; i < 5; i++) {
          service.onPointerDown(
            strokeId: 'stroke-$i',
            pageId: 'page-1',
            point: makePoint(i * 10.0, i * 10.0),
          );
          service.onPointerUp();
        }

        expect(service.committedStrokes.length, equals(5));
        for (int i = 0; i < 5; i++) {
          expect(service.committedStrokes[i].id, equals('stroke-$i'));
        }
      });
    });

    // -----------------------------------------------------------------------
    // Clear and loadStrokes
    // -----------------------------------------------------------------------
    group('clear and loadStrokes', () {
      test('clear removes all strokes', () {
        service.onPointerDown(
          strokeId: 's1', pageId: 'p1', point: makePoint(0, 0),
        );
        service.onPointerUp();
        expect(service.committedStrokes, isNotEmpty);

        service.clear();
        expect(service.committedStrokes, isEmpty);
        expect(service.isDrawing, isFalse);
      });

      test('loadStrokes replaces committed strokes', () {
        service.onPointerDown(
          strokeId: 's1', pageId: 'p1', point: makePoint(0, 0),
        );
        service.onPointerUp();

        // Create some strokes to load
        final loadedStrokes = List.generate(3, (i) {
          return _makeStroke('loaded-$i', 'p1');
        });

        service.loadStrokes(loadedStrokes);

        expect(service.committedStrokes.length, equals(3));
        expect(service.committedStrokes[0].id, equals('loaded-0'));
        expect(service.isDrawing, isFalse);
      });
    });

    // -----------------------------------------------------------------------
    // ChangeNotifier behavior
    // -----------------------------------------------------------------------
    group('ChangeNotifier', () {
      test('notifies on pointer down', () {
        int notifyCount = 0;
        service.addListener(() => notifyCount++);

        service.onPointerDown(
          strokeId: 's1', pageId: 'p1', point: makePoint(0, 0),
        );

        expect(notifyCount, equals(1));
      });

      test('notifies on pointer move', () {
        service.onPointerDown(
          strokeId: 's1', pageId: 'p1', point: makePoint(0, 0),
        );

        int notifyCount = 0;
        service.addListener(() => notifyCount++);

        service.onPointerMove(makePoint(10, 10));
        service.onPointerMove(makePoint(20, 20));

        expect(notifyCount, equals(2));
      });

      test('notifies on pointer up', () {
        service.onPointerDown(
          strokeId: 's1', pageId: 'p1', point: makePoint(0, 0),
        );

        int notifyCount = 0;
        service.addListener(() => notifyCount++);

        service.onPointerUp();
        expect(notifyCount, equals(1));
      });

      test('notifies on clear', () {
        int notifyCount = 0;
        service.addListener(() => notifyCount++);

        service.clear();
        expect(notifyCount, equals(1));
      });
    });

    // -----------------------------------------------------------------------
    // Pencil lead presets (Phase 2.5)
    // -----------------------------------------------------------------------
    group('pencil leads', () {
      test('applyPencilLead sets weight, opacity, and tool', () {
        service.applyPencilLead(PencilLead.fine);

        expect(service.currentTool, equals(ToolType.pencil));
        expect(service.currentWeight,
            closeTo(DrawingService.pencilBaseWeight * 0.5, 0.01));
        expect(service.currentOpacity, closeTo(0.8, 0.01));
        expect(service.currentLead, equals(PencilLead.fine));
      });

      test('each lead applies correct multiplier and opacity', () {
        for (final lead in PencilLead.values) {
          service.applyPencilLead(lead);
          expect(service.currentWeight,
              closeTo(DrawingService.pencilBaseWeight * lead.weightMultiplier, 0.01),
              reason: '${lead.label} weight');
          expect(service.currentOpacity, closeTo(lead.opacity, 0.01),
              reason: '${lead.label} opacity');
        }
      });

      test('manual weight change clears current lead', () {
        service.applyPencilLead(PencilLead.bold);
        expect(service.currentLead, equals(PencilLead.bold));

        service.currentWeight = 5.0;
        expect(service.currentLead, isNull);
      });

      test('manual opacity change clears current lead', () {
        service.applyPencilLead(PencilLead.medium);
        expect(service.currentLead, equals(PencilLead.medium));

        service.currentOpacity = 0.3;
        expect(service.currentLead, isNull);
      });

      test('applyPencilLead notifies listeners', () {
        int notifyCount = 0;
        service.addListener(() => notifyCount++);

        service.applyPencilLead(PencilLead.soft);
        expect(notifyCount, equals(1));
      });

      test('stroke inherits pencil lead weight and opacity', () {
        service.applyPencilLead(PencilLead.bold);

        service.onPointerDown(
          strokeId: 'lead-stroke',
          pageId: 'p1',
          point: makePoint(0, 0),
        );
        final stroke = service.onPointerUp()!;

        expect(stroke.tool, equals(ToolType.pencil));
        expect(stroke.weight,
            closeTo(DrawingService.pencilBaseWeight * PencilLead.bold.weightMultiplier, 0.01));
        expect(stroke.opacity, closeTo(PencilLead.bold.opacity, 0.01));
      });

      test('applyPencilLead deactivates eraser toggle', () {
        service.toggleEraser();
        expect(service.eraserToggleActive, isTrue);

        service.applyPencilLead(PencilLead.fine);
        expect(service.eraserToggleActive, isFalse);
        expect(service.currentTool, equals(ToolType.pencil));
      });
    });

    // -----------------------------------------------------------------------
    // Quick eraser toggle (Phase 2.5)
    // -----------------------------------------------------------------------
    group('eraser toggle', () {
      test('toggleEraser activates eraser and saves previous tool', () {
        service.currentTool = ToolType.marker;
        expect(service.eraserToggleActive, isFalse);

        service.toggleEraser();

        expect(service.eraserToggleActive, isTrue);
        expect(service.currentTool, equals(ToolType.eraser));
      });

      test('toggleEraser again restores previous tool', () {
        service.currentTool = ToolType.marker;
        service.toggleEraser();
        service.toggleEraser();

        expect(service.eraserToggleActive, isFalse);
        expect(service.currentTool, equals(ToolType.marker));
      });

      test('toggleEraser defaults to pencil if no previous tool', () {
        // Default tool is pencil
        service.toggleEraser();
        service.toggleEraser();

        expect(service.currentTool, equals(ToolType.pencil));
      });

      test('manual tool change deactivates eraser toggle', () {
        service.toggleEraser();
        expect(service.eraserToggleActive, isTrue);

        service.currentTool = ToolType.pen;
        expect(service.eraserToggleActive, isFalse);
        expect(service.currentTool, equals(ToolType.pen));
      });

      test('eraser toggle notifies listeners on each toggle', () {
        int notifyCount = 0;
        service.addListener(() => notifyCount++);

        service.toggleEraser();
        expect(notifyCount, equals(1));

        service.toggleEraser();
        expect(notifyCount, equals(2));
      });

      test('stroke drawn while eraser active uses eraser tool', () {
        service.toggleEraser();

        service.onPointerDown(
          strokeId: 'e-stroke',
          pageId: 'p1',
          point: makePoint(0, 0),
        );
        final stroke = service.onPointerUp()!;

        expect(stroke.tool, equals(ToolType.eraser));
      });
    });

    // -----------------------------------------------------------------------
    // Pressure mode (Phase 2.6)
    // -----------------------------------------------------------------------
    group('pressure mode', () {
      test('defaults to PressureMode.width', () {
        expect(service.pressureMode, equals(PressureMode.width));
      });

      test('setter changes pressure mode', () {
        service.pressureMode = PressureMode.opacity;
        expect(service.pressureMode, equals(PressureMode.opacity));

        service.pressureMode = PressureMode.both;
        expect(service.pressureMode, equals(PressureMode.both));
      });

      test('setting same value does not notify', () {
        int notifyCount = 0;
        service.addListener(() => notifyCount++);

        service.pressureMode = PressureMode.width; // same as default
        expect(notifyCount, equals(0));
      });

      test('changing pressure mode notifies listeners', () {
        int notifyCount = 0;
        service.addListener(() => notifyCount++);

        service.pressureMode = PressureMode.opacity;
        expect(notifyCount, equals(1));

        service.pressureMode = PressureMode.both;
        expect(notifyCount, equals(2));
      });
    });

    // -----------------------------------------------------------------------
    // PencilLead grainIntensity (Phase 2.6)
    // -----------------------------------------------------------------------
    group('pencil lead grain intensity', () {
      test('each lead has a grain intensity value', () {
        for (final lead in PencilLead.values) {
          expect(lead.grainIntensity, greaterThan(0.0),
              reason: '${lead.label} should have positive grain');
          expect(lead.grainIntensity, lessThanOrEqualTo(1.0),
              reason: '${lead.label} grain should be <= 1.0');
        }
      });

      test('soft leads have higher grain than hard leads', () {
        expect(PencilLead.soft.grainIntensity,
            greaterThan(PencilLead.fine.grainIntensity));
      });

      test('grain intensity ordering: fine < medium < bold < soft', () {
        expect(PencilLead.fine.grainIntensity,
            lessThan(PencilLead.medium.grainIntensity));
        expect(PencilLead.medium.grainIntensity,
            lessThan(PencilLead.bold.grainIntensity));
        expect(PencilLead.bold.grainIntensity,
            lessThan(PencilLead.soft.grainIntensity));
      });
    });
  });
}

/// Helper to create a Stroke for loadStrokes testing.
Stroke _makeStroke(String id, String pageId) {
  return Stroke(
    id: id,
    pageId: pageId,
    tool: ToolType.pen,
    color: 0xFF000000,
    weight: 2.0,
    opacity: 1.0,
    points: [
      StrokePoint(
        x: 10, y: 20, pressure: 0.5,
        tiltX: 0, tiltY: 0, twist: 0, timestamp: 0,
      ),
    ],
    createdAt: DateTime.utc(2024, 1, 1),
  );
}
