import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/eraser_mode.dart';
import '../models/grid_style.dart';
import '../models/stroke.dart';
import '../models/stroke_point.dart';
import '../models/tool_type.dart';
import '../models/undo_action.dart';
import '../providers/database_provider.dart';
import '../providers/drawing_provider.dart';
import '../services/drawing_service.dart';
import '../utils/stroke_splitter.dart';
import 'floating_palette.dart';
import 'sketch_painter.dart';

const _uuid = Uuid();

/// The main drawing canvas (TDD §4.1, Phase 2.7).
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

  /// Grid spacing in logical pixels.
  double _gridSpacing = 25.0;

  /// Current grid overlay style.
  GridStyle _gridStyle = GridStyle.dots;

  /// Current paper background color.
  Color _paperColor = SketchPainter.defaultPaperColor;

  /// Current eraser cursor position (null when eraser is not active or
  /// when the pointer is not over the canvas).
  Offset? _eraserCursorPosition;

  @override
  Widget build(BuildContext context) {
    final drawingService = ref.watch(drawingServiceProvider);
    final hitRadius = drawingService.currentWeight * 2.0;

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
                    gridSpacing: _gridSpacing,
                    gridStyle: _gridStyle,
                    paperColor: _paperColor,
                    erasedStrokeIds:
                        _collectErasedIds(drawingService.committedStrokes),
                    pressureMode: drawingService.pressureMode,
                    grainIntensity:
                        drawingService.currentLead?.grainIntensity ?? 0.25,
                    pressureExponent:
                        drawingService.pressureCurve.exponent,
                    eraserCursorPosition: _eraserCursorPosition,
                    eraserRadius: hitRadius,
                    showEraserCursor:
                        drawingService.currentTool == ToolType.eraser &&
                            _eraserCursorPosition != null,
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
            gridStyle: _gridStyle,
            gridSpacing: _gridSpacing,
            paperColor: _paperColor,
            pressureMode: drawingService.pressureMode,
            pressureCurve: drawingService.pressureCurve,
            eraserMode: drawingService.eraserMode,
            canUndo: drawingService.canUndo,
            canRedo: drawingService.canRedo,
            onToolChanged: (tool) => drawingService.currentTool = tool,
            onColorChanged: (color) => drawingService.currentColor = color,
            onWeightChanged: (weight) => drawingService.currentWeight = weight,
            onLeadChanged: (lead) => drawingService.applyPencilLead(lead),
            onEraserToggle: () {
              drawingService.toggleEraser();
              // Clear eraser cursor when toggling off
              if (!drawingService.eraserToggleActive) {
                setState(() => _eraserCursorPosition = null);
              }
            },
            onGridStyleChanged: (style) =>
                setState(() => _gridStyle = style),
            onGridSpacingChanged: (v) => setState(() => _gridSpacing = v),
            onPaperColorChanged: (color) =>
                setState(() => _paperColor = color),
            onPressureModeChanged: (mode) =>
                drawingService.pressureMode = mode,
            onPressureCurveChanged: (curve) =>
                drawingService.pressureCurve = curve,
            onEraserModeChanged: (mode) =>
                drawingService.eraserMode = mode,
            onUndo: () => _handleUndo(drawingService),
            onRedo: () => _handleRedo(drawingService),
            onClear: () => _handleClear(drawingService),
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

    // Eraser: find and remove strokes near the point
    if (drawingService.currentTool == ToolType.eraser) {
      setState(() => _eraserCursorPosition = event.localPosition);
      if (drawingService.eraserMode == EraserMode.history) {
        _historyEraseAt(event.localPosition, drawingService);
      } else {
        _standardEraseAt(event.localPosition, drawingService);
      }
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

    // Eraser: continuously check for strokes to erase + update cursor
    if (drawingService.currentTool == ToolType.eraser) {
      setState(() => _eraserCursorPosition = event.localPosition);
      if (drawingService.eraserMode == EraserMode.history) {
        _historyEraseAt(event.localPosition, drawingService);
      } else {
        _standardEraseAt(event.localPosition, drawingService);
      }
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

    // Eraser doesn't commit a stroke — just clear position tracking
    if (drawingService.currentTool == ToolType.eraser) {
      // Keep the cursor visible at last position (it follows pointer hover)
      return;
    }

    final committed = drawingService.onPointerUp();

    // Persist to SQLite asynchronously — does NOT block the UI thread
    if (committed != null) {
      // Push undo action for the drawn stroke
      drawingService.pushUndoAction(
        UndoAction(strokesAdded: [committed]),
      );
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
  // Standard erasing (stroke subdivision) — Phase 2.5
  // ---------------------------------------------------------------------------

  /// Erase portions of strokes near the given position.
  ///
  /// Instead of tombstoning entire strokes, identifies specific points
  /// within the eraser radius and splits the stroke into surviving segments.
  /// Preserves the append-only log invariant (TDD §3.2).
  void _standardEraseAt(Offset position, DrawingService drawingService) {
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

      // Push undo action for the erase operation
      drawingService.pushUndoAction(
        UndoAction(strokesAdded: strokesToAdd),
      );

      // Batch-persist all new strokes
      _persistStrokes(strokesToAdd);
    }
  }

  // ---------------------------------------------------------------------------
  // History erasing — Phase 2.7
  // ---------------------------------------------------------------------------

  /// Erase the newest whole stroke at the given position.
  ///
  /// Unlike standard erasing, does not split strokes. Instead,
  /// tombstones the most recently created stroke whose bounding rect
  /// contains the eraser position. Subsequent passes at the same
  /// position hit progressively older strokes.
  void _historyEraseAt(Offset position, DrawingService drawingService) {
    final hitRadius = drawingService.currentWeight * 2.0;

    final erasedIds = _collectErasedIds(drawingService.committedStrokes);

    // Find all visible, non-tombstoned strokes that the eraser overlaps
    final candidates = <Stroke>[];
    for (final stroke in drawingService.committedStrokes) {
      if (stroke.isTombstone) continue;
      if (erasedIds.contains(stroke.id)) continue;

      // Check if eraser position is within the stroke's bounding rect
      // (inflated by eraser radius for more forgiving hit detection)
      final inflatedRect = stroke.boundingRect.inflate(hitRadius);
      if (inflatedRect.contains(position)) {
        candidates.add(stroke);
      }
    }

    if (candidates.isEmpty) return;

    // Sort by creation time descending — newest first
    candidates.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final newest = candidates.first;

    // Tombstone the newest stroke
    final tombstone = Stroke.tombstone(
      id: _uuid.v4(),
      pageId: _pageId,
      targetStrokeId: newest.id,
      createdAt: DateTime.now().toUtc(),
    );

    drawingService.committedStrokes.add(tombstone);
    drawingService.notifyListeners();

    // Push undo action
    drawingService.pushUndoAction(
      UndoAction(strokesAdded: [tombstone]),
    );

    // Persist tombstone to DB
    _persistStroke(tombstone);
  }

  // ---------------------------------------------------------------------------
  // Undo / Redo — Phase 2.7
  // ---------------------------------------------------------------------------

  /// Undo the most recent action.
  ///
  /// Removes strokes that were added by the action and re-adds
  /// strokes that were removed. Syncs changes to DB.
  void _handleUndo(DrawingService drawingService) {
    final action = drawingService.popUndo();
    if (action == null) return;

    // Remove strokes that were added by this action
    if (action.strokesAdded.isNotEmpty) {
      final addedIds = action.strokesAdded.map((s) => s.id).toSet();
      drawingService.committedStrokes
          .removeWhere((s) => addedIds.contains(s.id));

      // Delete from DB
      _deleteStrokes(addedIds.toList());
    }

    // Re-add strokes that were removed by this action
    if (action.strokesRemoved.isNotEmpty) {
      drawingService.committedStrokes.addAll(action.strokesRemoved);

      // Re-persist to DB
      _persistStrokes(action.strokesRemoved);
    }

    drawingService.notifyListeners();
  }

  /// Redo a previously undone action.
  ///
  /// Re-adds the strokes that were originally added, and re-removes
  /// the strokes that were originally removed. Syncs changes to DB.
  void _handleRedo(DrawingService drawingService) {
    final action = drawingService.popRedo();
    if (action == null) return;

    // Re-add strokes that were originally added
    if (action.strokesAdded.isNotEmpty) {
      drawingService.committedStrokes.addAll(action.strokesAdded);

      // Re-persist to DB
      _persistStrokes(action.strokesAdded);
    }

    // Re-remove strokes that were originally removed
    if (action.strokesRemoved.isNotEmpty) {
      final removedIds = action.strokesRemoved.map((s) => s.id).toSet();
      drawingService.committedStrokes
          .removeWhere((s) => removedIds.contains(s.id));

      // Delete from DB
      _deleteStrokes(removedIds.toList());
    }

    drawingService.notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Clear canvas — Phase 2.7 (with undo support)
  // ---------------------------------------------------------------------------

  /// Clear the canvas with undo support.
  ///
  /// Creates tombstones for all visible strokes, pushes an undo action,
  /// then clears.
  void _handleClear(DrawingService drawingService) {
    final erasedIds = _collectErasedIds(drawingService.committedStrokes);

    // Find all visible (non-tombstone, non-erased) strokes
    final visibleStrokes = drawingService.committedStrokes
        .where((s) => !s.isTombstone && !erasedIds.contains(s.id))
        .toList();

    if (visibleStrokes.isEmpty) {
      drawingService.clear();
      return;
    }

    // Create tombstones for all visible strokes
    final tombstones = <Stroke>[];
    for (final stroke in visibleStrokes) {
      tombstones.add(Stroke.tombstone(
        id: _uuid.v4(),
        pageId: _pageId,
        targetStrokeId: stroke.id,
        createdAt: DateTime.now().toUtc(),
      ));
    }

    // Add tombstones to committed strokes before clearing
    drawingService.committedStrokes.addAll(tombstones);

    // Push undo action with all tombstones
    drawingService.pushUndoAction(
      UndoAction(strokesAdded: tombstones),
    );

    // Persist tombstones
    _persistStrokes(tombstones);

    // Now clear the visual state (but don't clear undo history)
    drawingService.clear();
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

  /// Delete strokes from the DB by their IDs (used by undo).
  Future<void> _deleteStrokes(List<String> strokeIds) async {
    try {
      final dbAsync = ref.read(databaseServiceProvider);
      final db = dbAsync.valueOrNull;
      if (db != null) {
        await db.deleteStrokes(_pageId, strokeIds);
      }
    } catch (e) {
      debugPrint('Failed to delete strokes: $e');
    }
  }
}

/// Re-export the old name for backward compatibility with main.dart.
typedef CanvasPlaceholder = CanvasWidget;
