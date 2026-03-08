import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/stroke.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/models/tool_type.dart';
import 'package:industrial_sketchbook/models/undo_action.dart';

void main() {
  Stroke makeStroke(String id) {
    return Stroke(
      id: id,
      pageId: 'page-1',
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

  group('UndoAction', () {
    test('default constructor has empty lists', () {
      const action = UndoAction();
      expect(action.strokesAdded, isEmpty);
      expect(action.strokesRemoved, isEmpty);
    });

    test('can store strokes in strokesAdded', () {
      final stroke = makeStroke('s1');
      final action = UndoAction(strokesAdded: [stroke]);
      expect(action.strokesAdded.length, equals(1));
      expect(action.strokesAdded.first.id, equals('s1'));
    });

    test('can store strokes in strokesRemoved', () {
      final stroke = makeStroke('s2');
      final action = UndoAction(strokesRemoved: [stroke]);
      expect(action.strokesRemoved.length, equals(1));
      expect(action.strokesRemoved.first.id, equals('s2'));
    });

    test('can store strokes in both lists', () {
      final added = makeStroke('added');
      final removed = makeStroke('removed');
      final action = UndoAction(
        strokesAdded: [added],
        strokesRemoved: [removed],
      );
      expect(action.strokesAdded.length, equals(1));
      expect(action.strokesRemoved.length, equals(1));
    });
  });
}
