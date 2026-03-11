import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/render_point.dart';
import 'package:industrial_sketchbook/models/stroke.dart';
import 'package:industrial_sketchbook/models/stroke_point.dart';
import 'package:industrial_sketchbook/models/sync_journal.dart';
import 'package:industrial_sketchbook/models/tool_type.dart';

/// Helper to create a test stroke with some raw points and renderData.
Stroke _makeStroke({
  String id = 'stroke-1',
  String pageId = 'page-1',
  bool isTombstone = false,
  String? erasesStrokeId,
}) {
  return Stroke(
    id: id,
    pageId: pageId,
    layerId: 'default',
    tool: ToolType.pencil,
    color: 0xFF000000,
    weight: 2.0,
    opacity: 1.0,
    points: isTombstone
        ? const []
        : [
            const StrokePoint(
                x: 100, y: 200, pressure: 0.5,
                tiltX: 0.1, tiltY: 0.2, twist: 0.0, timestamp: 1000),
            const StrokePoint(
                x: 110, y: 210, pressure: 0.6,
                tiltX: 0.1, tiltY: 0.2, twist: 0.0, timestamp: 1001),
            const StrokePoint(
                x: 120, y: 220, pressure: 0.7,
                tiltX: 0.1, tiltY: 0.2, twist: 0.0, timestamp: 1002),
          ],
    renderData: isTombstone
        ? null
        : [
            const RenderPoint(x: 0.1, y: 0.2, pressure: 0.5),
            const RenderPoint(x: 0.11, y: 0.21, pressure: 0.6),
            const RenderPoint(x: 0.12, y: 0.22, pressure: 0.7),
          ],
    createdAt: DateTime.utc(2026, 3, 11),
    isTombstone: isTombstone,
    erasesStrokeId: erasesStrokeId,
  );
}

void main() {
  group('Stroke.toSyncJson', () {
    test('excludes raw points', () {
      final stroke = _makeStroke();
      final json = stroke.toSyncJson();

      expect(json.containsKey('points'), isFalse);
      expect(json.containsKey('renderData'), isTrue);
    });

    test('excludes synced field', () {
      final stroke = _makeStroke();
      final json = stroke.toSyncJson();

      expect(json.containsKey('synced'), isFalse);
    });

    test('includes renderData with normalized coordinates', () {
      final stroke = _makeStroke();
      final json = stroke.toSyncJson();
      final renderData = json['renderData'] as List;

      expect(renderData.length, equals(3));
      expect((renderData[0] as Map)['x'], equals(0.1));
      expect((renderData[0] as Map)['pressure'], equals(0.5));
    });

    test('tombstone omits renderData', () {
      final stroke = _makeStroke(
        id: 'tombstone-1',
        isTombstone: true,
        erasesStrokeId: 'stroke-1',
      );
      final json = stroke.toSyncJson();

      expect(json.containsKey('renderData'), isFalse);
      expect(json['isTombstone'], isTrue);
      expect(json['erasesStrokeId'], equals('stroke-1'));
    });

    test('is significantly smaller than toJson', () {
      final stroke = _makeStroke();
      final fullJson = jsonEncode(stroke.toJson());
      final syncJson = jsonEncode(stroke.toSyncJson());

      // Sync JSON should be much smaller (no raw points with 7 fields each)
      expect(syncJson.length, lessThan(fullJson.length));
    });
  });

  group('Stroke.fromSyncJson', () {
    test('round-trips through toSyncJson', () {
      final stroke = _makeStroke();
      final json = stroke.toSyncJson();
      final restored = Stroke.fromSyncJson(json);

      expect(restored.id, equals(stroke.id));
      expect(restored.pageId, equals(stroke.pageId));
      expect(restored.tool, equals(stroke.tool));
      expect(restored.color, equals(stroke.color));
      expect(restored.weight, equals(stroke.weight));
      expect(restored.opacity, equals(stroke.opacity));
      expect(restored.isTombstone, equals(stroke.isTombstone));
    });

    test('has empty points list', () {
      final stroke = _makeStroke();
      final restored = Stroke.fromSyncJson(stroke.toSyncJson());

      expect(restored.points, isEmpty);
    });

    test('has renderData populated', () {
      final stroke = _makeStroke();
      final restored = Stroke.fromSyncJson(stroke.toSyncJson());

      expect(restored.renderData, isNotNull);
      expect(restored.renderData!.length, equals(3));
      expect(restored.renderData![0].x, closeTo(0.1, 0.001));
    });

    test('marks stroke as synced', () {
      final stroke = _makeStroke();
      final restored = Stroke.fromSyncJson(stroke.toSyncJson());

      expect(restored.synced, isTrue);
    });

    test('tombstone round-trips correctly', () {
      final stroke = _makeStroke(
        id: 'tombstone-1',
        isTombstone: true,
        erasesStrokeId: 'stroke-1',
      );
      final restored = Stroke.fromSyncJson(stroke.toSyncJson());

      expect(restored.isTombstone, isTrue);
      expect(restored.erasesStrokeId, equals('stroke-1'));
      expect(restored.renderData, isNull);
      expect(restored.points, isEmpty);
    });
  });

  group('SyncJournal v2', () {
    test('toJson includes version 2', () {
      final journal = SyncJournal(
        version: 2,
        deviceId: 'device-1',
        createdAt: '2026-03-11T00:00:00.000Z',
        strokes: [_makeStroke()],
      );
      final json = journal.toJson();

      expect(json['version'], equals(2));
      expect(json.containsKey('canvasWidth'), isFalse);
    });

    test('toJson uses toSyncJson for strokes', () {
      final journal = SyncJournal(
        version: 2,
        deviceId: 'device-1',
        createdAt: '2026-03-11T00:00:00.000Z',
        strokes: [_makeStroke()],
      );
      final json = journal.toJson();
      final strokeJson = (json['strokes'] as List).first as Map;

      // Sync format: no raw points
      expect(strokeJson.containsKey('points'), isFalse);
      expect(strokeJson.containsKey('renderData'), isTrue);
    });

    test('fromJson detects v2 and uses fromSyncJson', () {
      final journal = SyncJournal(
        version: 2,
        deviceId: 'device-1',
        createdAt: '2026-03-11T00:00:00.000Z',
        strokes: [_makeStroke()],
      );
      final json = journal.toJson();
      final restored = SyncJournal.fromJson(json);

      expect(restored.version, equals(2));
      expect(restored.strokes.first.points, isEmpty);
      expect(restored.strokes.first.renderData, isNotNull);
    });

    test('fromJson defaults to v1 when no version field', () {
      // Simulate v1 journal (no version field, has canvasWidth)
      final v1Json = {
        'deviceId': 'device-1',
        'createdAt': '2026-03-11T00:00:00.000Z',
        'strokes': [_makeStroke().toJson()],
        'canvasWidth': 1200.0,
      };
      final restored = SyncJournal.fromJson(v1Json);

      expect(restored.version, equals(1));
      expect(restored.canvasWidth, equals(1200.0));
      // v1 uses Stroke.fromJson — has raw points
      expect(restored.strokes.first.points, isNotEmpty);
    });

    test('v2 journal gzip round-trip produces valid JSON', () {
      final journal = SyncJournal(
        version: 2,
        deviceId: 'device-1',
        createdAt: '2026-03-11T00:00:00.000Z',
        strokes: [_makeStroke(), _makeStroke(id: 'stroke-2')],
      );
      final json = journal.toJson();
      final jsonStr = jsonEncode(json);

      // Simulate gzip round-trip
      final compressed = gzip.encode(utf8.encode(jsonStr));
      final decompressed = gzip.decode(compressed);
      final restoredJson =
          jsonDecode(utf8.decode(decompressed)) as Map<String, dynamic>;
      final restored = SyncJournal.fromJson(restoredJson);

      expect(restored.version, equals(2));
      expect(restored.strokes.length, equals(2));
      expect(restored.strokes.first.renderData, isNotNull);
    });

    test('v2 journal is significantly smaller than v1', () {
      // Create a stroke with many points to simulate real data
      final manyPoints = List.generate(
          100,
          (i) => StrokePoint(
              x: i * 1.0, y: i * 2.0, pressure: 0.5,
              tiltX: 0.1, tiltY: 0.2, twist: 0.0, timestamp: 1000 + i));
      final manyRenderData = List.generate(
          50,
          (i) => RenderPoint(
              x: i / 1000.0, y: i / 500.0, pressure: 0.5));

      final stroke = Stroke(
        id: 'stroke-big',
        pageId: 'page-1',
        layerId: 'default',
        tool: ToolType.pencil,
        color: 0xFF000000,
        weight: 2.0,
        opacity: 1.0,
        points: manyPoints,
        renderData: manyRenderData,
        createdAt: DateTime.utc(2026, 3, 11),
      );

      final v1Size = utf8.encode(jsonEncode(stroke.toJson())).length;
      final v2Size = utf8.encode(jsonEncode(stroke.toSyncJson())).length;
      final v2Gzip =
          gzip.encode(utf8.encode(jsonEncode(stroke.toSyncJson()))).length;

      // v2 JSON should be less than half of v1 (no raw points)
      expect(v2Size, lessThan(v1Size ~/ 2));
      // v2 gzip should be drastically smaller
      expect(v2Gzip, lessThan(v1Size ~/ 4));
    });
  });

  group('Tombstone compaction', () {
    // We can't directly call _compactTombstones (private), but we can
    // test the logic through the serialization path. The actual compaction
    // is tested in sync_service_test.dart. Here we test tombstone handling
    // in serialization.

    test('tombstone toSyncJson has minimal size', () {
      final tombstone = _makeStroke(
        id: 'tomb-1',
        isTombstone: true,
        erasesStrokeId: 'target-1',
      );
      final json = tombstone.toSyncJson();

      // Should only have: id, pageId, layerId, tool, color, weight,
      // opacity, createdAt, isTombstone, erasesStrokeId (no renderData)
      expect(json.containsKey('renderData'), isFalse);
      expect(json.containsKey('points'), isFalse);
    });
  });
}
