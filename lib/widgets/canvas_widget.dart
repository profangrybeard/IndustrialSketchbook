import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/stroke.dart';
import '../models/stroke_point.dart';
import '../models/tool_type.dart';
import '../providers/database_provider.dart';
import '../providers/drawing_provider.dart';
import '../utils/stroke_splitter.dart';
import 'floating_palette.dart';
import 'sketch_painter.dart';

const _uuid = Uuid();

/// The main drawing canvas (TDD §4.1, Phase 2.5).
///
/// Full-screen canvas with a floating dockable palette. Captures stylus
/// input via [Listener], feeds it to [DrawingService], and renders strokes
/// via [SketchPainter]. Persists committed strokes to SQLite asynchronously.
class CanvasWidget extends ConsumerStatefulWidget {
  const CanvasWidget({super.key});

  @override
  ConsumerState<CanvasWidget> createState() => _CanvasWidgetState();
}

class _CanvasWidgetState extends ConsumerState<CanvasWidget> {
  /// Whether a stylus/pen is currently active (for palm rejection).
  bool _penActive = false;

  /// The page ID for strokes. Using a fixed default page for Phase 2.
  final String _pageId = 'default-page';

  /// Dot grid spacing in logical pixels.
  double _gridSpacing = 25.0;

  /// Whether the dot grid is enabled.
  bool _gridEnabled = true;

  @override
  Widget build(BuildContext context) {
    final drawingService = ref.watch(drawingServiceProvider);

    return Scaffold(
      body: Stack(
        children: [
          // Canvas layer (full screen)
          Positioned.fill(
            child: Listener(
              onPointerDown: (event) => _handlePointerDown(event),
              onPointerMove: (event) => _handlePointerMove(event),
              onPointerUp: (event) => _handlePointerUp(event),
              onPointerCancel: (event) => _handlePointerCancel(event),
              behavior: HitTestBehavior.opaque,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: SketchPainter(
                    committedStrokes: drawingService.committedStrokes,
                    inflightStroke: drawingService.inflightStroke,
                    gridSpacing: _gridEnabled ? _gridSpacing : 0,
                    erasedStrokeIds:
                        _collectErasedIds(drawingService.committedStrokes),
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ),

          // Floating palette layer (on top)
          FloatingPalette(
            currentTool: drawingService.currentTool,
            currentColor: drawingService.currentColor,
            currentWeight: drawingService.currentWeight,
            currentLead: drawingService.currentLead,
            eraserToggleActive: drawingService.eraserToggleActive,
            gridEnabled: _gridEnabled,
            gridSpacing: _gridSpacing,
            onToolChanged: (tool) => drawingService.currentTool = tool,
            onColorChanged: (color) => drawingService.currentColor = color,
            onWeightChanged: (weight) => drawingService.currentWeight = weight,
            onLeadChanged: (lead) => drawingService.applyPencilLead(lead),
            onEraserToggle: () => drawingService.toggleEraser(),
            onGridToggle: () => setState(() => _gridEnabled = !_gridEnabled),
            onGridSpacingChanged: (v) => setState(() => _gridSpacing = v),
            onClear: () => drawingService.clear(),
          ),
        ],
      ),
    );
  }

  /// Collect all stroke IDs that have been erased by tombstone strokes.
  Set<String> _collectErasedIds(List<Stroke> strokes) {
    final erased = <String>{};
    for (final s in strokes) {
      if (s.isTombstone && s.erasesStrokeId != null) {
        erased.add(s.erasesStrokeId!);
      }
    }
    return erased;
  }

  // ---------------------------------------------------------------------------
  // Pointer event handlers
  // ---------------------------------------------------------------------------

  void _handlePointerDown(PointerDownEvent event) {
    // Palm rejection (DRW-006): Only accept stylus and mouse for drawing.
    if (!_isDrawingInput(event.kind)) return;

    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _penActive = true;
    }

    final drawingService = ref.read(drawingServiceProvider);

    // Eraser: find and subdivide strokes near the point
    if (drawingService.currentTool == ToolType.eraser) {
      _eraseAt(event.localPosition, drawingService);
      return;
    }

    drawingService.onPointerDown(
      strokeId: _uuid.v4(),
      pageId: _pageId,
      point: _eventToPoint(event),
    );
  }

  void _handlePointerMove(PointerMoveEvent event) {
    // Palm rejection: only accept stylus/mouse input for drawing
    if (!_isDrawingInput(event.kind)) return;

    final drawingService = ref.read(drawingServiceProvider);

    // Eraser: continuously check for strokes to erase
    if (drawingService.currentTool == ToolType.eraser) {
      _eraseAt(event.localPosition, drawingService);
      return;
    }

    drawingService.onPointerMove(_eventToPoint(event));
  }

  void _handlePointerUp(PointerUpEvent event) {
    // Palm rejection: only accept stylus/mouse input
    if (!_isDrawingInput(event.kind)) return;

    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _penActive = false;
    }

    final drawingService = ref.read(drawingServiceProvider);

    // Eraser doesn't commit a stroke
    if (drawingService.currentTool == ToolType.eraser) return;

    final committed = drawingService.onPointerUp();

    // Persist to SQLite asynchronously — does NOT block the UI thread
    if (committed != null) {
      _persistStroke(committed);
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _penActive = false;
    }

    // Discard the in-flight stroke on cancel
    final drawingService = ref.read(drawingServiceProvider);
    if (drawingService.isDrawing) {
      drawingService.onPointerUp();
    }
  }

  // ---------------------------------------------------------------------------
  // Partial erasing (stroke subdivision)
  // ---------------------------------------------------------------------------

  /// Erase portions of strokes near the given position.
  ///
  /// Instead of tombstoning entire strokes, identifies specific points
  /// within the eraser radius and splits the stroke into surviving segments.
  /// Preserves the append-only log invariant (TDD §3.2).
  void _eraseAt(Offset position, drawingService) {
    final hitRadius = drawingService.currentWeight * 2.0;
    final hitRect = Rect.fromCenter(
      center: position,
      width: hitRadius * 2,
      height: hitRadius * 2,
    );

    final erasedIds = _collectErasedIds(drawingService.committedStrokes);
    final strokesToAdd = <Stroke>[];

    for (final stroke
        in List<Stroke>.from(drawingService.committedStrokes)) {
      if (stroke.isTombstone) continue;
      if (erasedIds.contains(stroke.id)) continue;
      if (!stroke.boundingRect.overlaps(hitRect)) continue;

      // Split the stroke's points, removing those within eraser radius
      final segments = splitStrokePoints(
        points: stroke.points,
        eraserPosition: position,
        eraserRadius: hitRadius,
      );

      // null = no points hit — stroke unaffected
      if (segments == null) continue;

      // Tombstone the original stroke
      final tombstone = Stroke.tombstone(
        id: _uuid.v4(),
        pageId: _pageId,
        targetStrokeId: stroke.id,
        createdAt: DateTime.now().toUtc(),
      );
      strokesToAdd.add(tombstone);
      erasedIds.add(stroke.id);

      // Create new strokes for each surviving segment
      for (final segment in segments) {
        strokesToAdd.add(Stroke(
          id: _uuid.v4(),
          pageId: _pageId,
          layerId: stroke.layerId,
          tool: stroke.tool,
          color: stroke.color,
          weight: stroke.weight,
          opacity: stroke.opacity,
          points: segment,
          createdAt: DateTime.now().toUtc(),
        ));
      }
    }

    if (strokesToAdd.isNotEmpty) {
      drawingService.committedStrokes.addAll(strokesToAdd);
      drawingService.notifyListeners();

      // Batch-persist all new strokes
      _persistStrokes(strokesToAdd);
    }
  }

  // ---------------------------------------------------------------------------
  // Utility methods
  // ---------------------------------------------------------------------------

  /// Whether this pointer device kind should be accepted for drawing.
  bool _isDrawingInput(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus ||
        kind == PointerDeviceKind.mouse;
  }

  /// Convert a Flutter [PointerEvent] to a [StrokePoint].
  StrokePoint _eventToPoint(PointerEvent event) {
    return StrokePoint(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      pressure: event.pressure,
      tiltX: event.tilt * 90.0,
      tiltY: 0.0,
      twist: event.orientation * (180.0 / 3.14159265),
      timestamp: event.timeStamp.inMicroseconds,
    );
  }

  /// Fire-and-forget persistence to SQLite (TDD §4.1: async, < 5ms).
  Future<void> _persistStroke(Stroke stroke) async {
    try {
      final dbAsync = ref.read(databaseServiceProvider);
      final db = dbAsync.valueOrNull;
      if (db != null) {
        await db.insertStroke(stroke);
      }
    } catch (e) {
      debugPrint('Failed to persist stroke: $e');
    }
  }

  /// Batch-persist multiple strokes in a single transaction.
  Future<void> _persistStrokes(List<Stroke> strokes) async {
    try {
      final dbAsync = ref.read(databaseServiceProvider);
      final db = dbAsync.valueOrNull;
      if (db != null) {
        await db.insertStrokes(strokes);
      }
    } catch (e) {
      debugPrint('Failed to persist strokes: $e');
    }
  }
}

/// Re-export the old name for backward compatibility with main.dart.
typedef CanvasPlaceholder = CanvasWidget;
