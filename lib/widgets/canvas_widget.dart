import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/eraser_mode.dart';
import '../models/grid_config.dart';
import '../models/grid_style.dart';
import '../models/page_style.dart';
import '../models/sketch_page.dart';
import '../models/stroke.dart';
import '../models/stroke_point.dart';
import '../models/tool_type.dart';
import '../models/undo_action.dart';
import '../providers/database_provider.dart';
import '../providers/drawing_provider.dart';
import '../providers/notebook_provider.dart';
import '../services/drawing_service.dart';
import '../utils/stroke_splitter.dart';
import 'active_stroke_painter.dart';
import 'background_painter.dart';
import 'committed_strokes_painter.dart';
import 'developer_overlay.dart';
import 'floating_palette.dart';
import 'page_strip.dart';

const _uuid = Uuid();

/// The main drawing canvas (TDD §4.1, Phase 2.8).
///
/// Uses a three-layer [RepaintBoundary] architecture for performance:
/// - Layer 1: Background (paper + grid) — repaints only on settings change
/// - Layer 2: Committed strokes — repaints only on commit/undo/erase/clear
/// - Layer 3: Active stroke + eraser cursor — repaints every pointer move
///
/// Also implements stroke stitching (Phase 2.8): when a new stroke starts
/// near where the previous stroke ended (< 150ms, < 20px, same style),
/// a bridge point is prepended to eliminate gaps between strokes.
class CanvasWidget extends ConsumerStatefulWidget {
  const CanvasWidget({super.key});

  @override
  ConsumerState<CanvasWidget> createState() => _CanvasWidgetState();
}

class _CanvasWidgetState extends ConsumerState<CanvasWidget> {
  /// Whether a stylus/pen is currently active (for palm rejection).
  bool _penActive = false;

  /// Whether strokes have been loaded from the database for the current page.
  /// Prevents re-loading on every widget rebuild. Reset on page switch.
  bool _strokesLoaded = false;

  /// The current page ID, read from the Riverpod provider.
  String get _pageId => ref.read(currentPageIdProvider);

  /// Grid spacing in logical pixels.
  double _gridSpacing = 25.0;

  /// Current grid overlay style.
  GridStyle _gridStyle = GridStyle.dots;

  /// Current paper background color.
  Color _paperColor = BackgroundPainter.defaultPaperColor;

  /// Current eraser cursor position (null when eraser is not active or
  /// when the pointer is not over the canvas).
  Offset? _eraserCursorPosition;

  // ---------------------------------------------------------------------------
  // Stroke stitching state (Phase 2.8)
  // ---------------------------------------------------------------------------

  /// End point of the most recently committed stroke.
  StrokePoint? _lastCommittedEndPoint;

  /// Timestamp (microseconds) when the last stroke was committed.
  int _lastCommittedTimestamp = 0;

  /// Tool of the last committed stroke (for style matching).
  ToolType? _lastCommittedTool;

  /// Color of the last committed stroke (for style matching).
  int? _lastCommittedColor;

  /// Weight of the last committed stroke (for style matching).
  double? _lastCommittedWeight;

  /// Whether the current inflight stroke has a stitch point prepended.
  bool _hasStitchPoint = false;

  @override
  Widget build(BuildContext context) {
    final drawingService = ref.watch(drawingServiceProvider);
    final hitRadius = drawingService.currentWeight * 2.0;

    // --- Page recall: load persisted strokes + page settings on first build ---
    // The database provider is async (FutureProvider). When it resolves,
    // load all strokes and page settings for the current page.
    // This runs once per page — _strokesLoaded prevents re-loading.
    if (!_strokesLoaded) {
      final dbAsync = ref.watch(databaseServiceProvider);
      dbAsync.whenData((db) {
        _strokesLoaded = true;
        // Schedule after this build frame to avoid setState-during-build
        // (loadStrokes calls notifyListeners which triggers rebuild)
        Future.microtask(() async {
          if (!mounted) return;

          // Load strokes
          final strokes = await db.getStrokesByPageId(_pageId);
          if (mounted && strokes.isNotEmpty) {
            drawingService.loadStrokes(strokes);
          }

          // Load page settings (grid style, spacing, paper color)
          final page = await db.getPage(_pageId);
          if (mounted && page != null) {
            setState(() {
              _gridStyle = GridStyle.fromPageStyle(page.style);
              _gridSpacing = page.gridConfig?.spacing ?? 25.0;
              _paperColor = Color(page.paperColor);
            });
          }
        });
      });
    }

    return Scaffold(
      body: Stack(
        children: [
          // Layer 1: Background (paper + grid) — cached by RepaintBoundary
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: BackgroundPainter(
                  paperColor: _paperColor,
                  gridStyle: _gridStyle,
                  gridSpacing: _gridSpacing,
                ),
                size: Size.infinite,
              ),
            ),
          ),

          // Layer 2: Committed strokes — cached by RepaintBoundary
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: CommittedStrokesPainter(
                  committedStrokes: drawingService.committedStrokes,
                  erasedStrokeIds: drawingService.erasedStrokeIds,
                  strokeVersion: drawingService.strokeVersion,
                  pressureMode: drawingService.pressureMode,
                  grainIntensity:
                      drawingService.currentLead?.grainIntensity ?? 0.25,
                  pressureExponent:
                      drawingService.pressureCurve.exponent,
                ),
                size: Size.infinite,
              ),
            ),
          ),

          // Layer 3: Active stroke + eraser cursor (with pointer input)
          Positioned.fill(
            child: Listener(
              onPointerDown: (event) => _handlePointerDown(event),
              onPointerMove: (event) => _handlePointerMove(event),
              onPointerUp: (event) => _handlePointerUp(event),
              onPointerCancel: (event) => _handlePointerCancel(event),
              behavior: HitTestBehavior.opaque,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: ActiveStrokePainter(
                    inflightStroke: drawingService.inflightStroke,
                    eraserCursorPosition: _eraserCursorPosition,
                    eraserRadius: hitRadius,
                    showEraserCursor:
                        drawingService.currentTool == ToolType.eraser &&
                            _eraserCursorPosition != null,
                    pressureMode: drawingService.pressureMode,
                    grainIntensity:
                        drawingService.currentLead?.grainIntensity ?? 0.25,
                    pressureExponent:
                        drawingService.pressureCurve.exponent,
                    suppressSinglePoint: !_hasStitchPoint,
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
            onGridStyleChanged: (style) {
              setState(() => _gridStyle = style);
              _persistPageSettings();
            },
            onGridSpacingChanged: (v) {
              setState(() => _gridSpacing = v);
              _persistPageSettings();
            },
            onPaperColorChanged: (color) {
              setState(() => _paperColor = color);
              _persistPageSettings();
            },
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

          // Developer overlay + page navigation — both need page list data
          Builder(builder: (context) {
            final pagesAsync = ref.watch(pagesForChapterProvider);
            final currentPageId = ref.watch(currentPageIdProvider);
            return pagesAsync.when(
              data: (pages) {
                final currentIndex =
                    pages.indexWhere((p) => p.id == currentPageId);
                final safeIndex = currentIndex >= 0 ? currentIndex : 0;
                return Stack(
                  children: [
                    // Developer overlay (Phase 2.8.1)
                    DeveloperOverlay(
                      drawingService: drawingService,
                      currentPageIndex: safeIndex,
                      totalPages: pages.length,
                    ),
                    // Page navigation strip (Layer 3)
                    PageStrip(
                      currentPage: safeIndex,
                      totalPages: pages.length,
                      onPrevPage: safeIndex > 0
                          ? () => _switchToPage(
                                pages[safeIndex - 1].id, drawingService)
                          : null,
                      onNextPage: safeIndex < pages.length - 1
                          ? () => _switchToPage(
                                pages[safeIndex + 1].id, drawingService)
                          : null,
                      onNewPage: () => _createNewPage(drawingService),
                    ),
                  ],
                );
              },
              loading: () =>
                  DeveloperOverlay(drawingService: drawingService),
              error: (_, __) =>
                  DeveloperOverlay(drawingService: drawingService),
            );
          }),
        ],
      ),
    );
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

    // --- Stroke stitching (Phase 2.8) ---
    final point = _eventToPoint(event);
    StrokePoint? stitchPoint;
    _hasStitchPoint = false;

    if (_shouldStitch(event, drawingService)) {
      stitchPoint = _lastCommittedEndPoint;
      _hasStitchPoint = true;
    }

    drawingService.onPointerDown(
      strokeId: _uuid.v4(),
      pageId: _pageId,
      point: point,
      stitchPoint: stitchPoint,
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
      return;
    }

    final committed = drawingService.onPointerUp();

    // Persist to SQLite asynchronously — does NOT block the UI thread
    if (committed != null) {
      // Track for stroke stitching (Phase 2.8)
      if (committed.points.isNotEmpty) {
        _lastCommittedEndPoint = committed.points.last;
        _lastCommittedTimestamp = committed.points.last.timestamp;
        _lastCommittedTool = committed.tool;
        _lastCommittedColor = committed.color;
        _lastCommittedWeight = committed.weight;
      }

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
  // Stroke stitching (Phase 2.8)
  // ---------------------------------------------------------------------------

  /// Whether a new stroke should be stitched to the previous one.
  ///
  /// Returns true if the previous stroke ended recently (< 150ms),
  /// spatially close (< 20px), and with the same drawing style.
  bool _shouldStitch(PointerDownEvent event, DrawingService drawingService) {
    if (_lastCommittedEndPoint == null) return false;

    // Only stitch drawing tools (not eraser)
    if (drawingService.currentTool == ToolType.eraser) return false;

    // Style must match
    if (drawingService.currentTool != _lastCommittedTool) return false;
    if (drawingService.currentColor != _lastCommittedColor) return false;
    if (drawingService.currentWeight != _lastCommittedWeight) return false;

    // Temporal proximity: within 500ms
    // Natural handwriting pen-lifts between letters are typically 150–400ms.
    // The original 150ms threshold was too tight and missed most transitions.
    final currentTimestamp = event.timeStamp.inMicroseconds;
    final timeDelta = currentTimestamp - _lastCommittedTimestamp;
    if (timeDelta > 500000) return false;

    // Spatial proximity: within 50 logical pixels
    // Generous threshold covers fast cursive strokes where the pen lands
    // further from the last lift point.
    final dx = event.localPosition.dx - _lastCommittedEndPoint!.x;
    final dy = event.localPosition.dy - _lastCommittedEndPoint!.y;
    if (dx * dx + dy * dy > 2500.0) return false;

    return true;
  }

  /// Reset stroke stitching state (on undo/redo/clear).
  void _resetStitchState() {
    _lastCommittedEndPoint = null;
    _lastCommittedTimestamp = 0;
    _lastCommittedTool = null;
    _lastCommittedColor = null;
    _lastCommittedWeight = null;
    _hasStitchPoint = false;
  }

  // ---------------------------------------------------------------------------
  // Standard erasing (stroke subdivision) — Phase 2.5
  // ---------------------------------------------------------------------------

  /// Erase portions of strokes near the given position.
  void _standardEraseAt(Offset position, DrawingService drawingService) {
    final hitRadius = drawingService.currentWeight * 2.0;
    final hitRect = Rect.fromCenter(
      center: position,
      width: hitRadius * 2,
      height: hitRadius * 2,
    );

    // Start from the cached set, but track local additions within this call
    final erasedIds = Set<String>.from(drawingService.erasedStrokeIds);
    final strokesToAdd = <Stroke>[];

    for (final stroke
        in List<Stroke>.from(drawingService.committedStrokes)) {
      if (stroke.isTombstone) continue;
      if (erasedIds.contains(stroke.id)) continue;
      if (!stroke.boundingRect.overlaps(hitRect)) continue;

      final segments = splitStrokePoints(
        points: stroke.points,
        eraserPosition: position,
        eraserRadius: hitRadius,
      );

      if (segments == null) continue;

      final tombstone = Stroke.tombstone(
        id: _uuid.v4(),
        pageId: _pageId,
        targetStrokeId: stroke.id,
        createdAt: DateTime.now().toUtc(),
      );
      strokesToAdd.add(tombstone);
      erasedIds.add(stroke.id);

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
      drawingService.addCommittedStrokes(strokesToAdd);
      drawingService.notifyListeners();

      drawingService.pushUndoAction(
        UndoAction(strokesAdded: strokesToAdd),
      );

      _persistStrokes(strokesToAdd);
    }
  }

  // ---------------------------------------------------------------------------
  // History erasing — Phase 2.7
  // ---------------------------------------------------------------------------

  /// Erase the newest whole stroke at the given position.
  void _historyEraseAt(Offset position, DrawingService drawingService) {
    final hitRadius = drawingService.currentWeight * 2.0;

    final erasedIds = drawingService.erasedStrokeIds;

    final candidates = <Stroke>[];
    for (final stroke in drawingService.committedStrokes) {
      if (stroke.isTombstone) continue;
      if (erasedIds.contains(stroke.id)) continue;

      final inflatedRect = stroke.boundingRect.inflate(hitRadius);
      if (inflatedRect.contains(position)) {
        candidates.add(stroke);
      }
    }

    if (candidates.isEmpty) return;

    candidates.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final newest = candidates.first;

    final tombstone = Stroke.tombstone(
      id: _uuid.v4(),
      pageId: _pageId,
      targetStrokeId: newest.id,
      createdAt: DateTime.now().toUtc(),
    );

    drawingService.addCommittedStrokes([tombstone]);
    drawingService.notifyListeners();

    drawingService.pushUndoAction(
      UndoAction(strokesAdded: [tombstone]),
    );

    _persistStroke(tombstone);
  }

  // ---------------------------------------------------------------------------
  // Undo / Redo — Phase 2.7
  // ---------------------------------------------------------------------------

  void _handleUndo(DrawingService drawingService) {
    final action = drawingService.popUndo();
    if (action == null) return;

    if (action.strokesAdded.isNotEmpty) {
      final addedIds = action.strokesAdded.map((s) => s.id).toSet();
      drawingService.removeCommittedStrokesWhere(
          (s) => addedIds.contains(s.id));
      _deleteStrokes(addedIds.toList());
    }

    if (action.strokesRemoved.isNotEmpty) {
      drawingService.addCommittedStrokes(action.strokesRemoved);
      _persistStrokes(action.strokesRemoved);
    }

    _resetStitchState();
    drawingService.notifyListeners();
  }

  void _handleRedo(DrawingService drawingService) {
    final action = drawingService.popRedo();
    if (action == null) return;

    if (action.strokesAdded.isNotEmpty) {
      drawingService.addCommittedStrokes(action.strokesAdded);
      _persistStrokes(action.strokesAdded);
    }

    if (action.strokesRemoved.isNotEmpty) {
      final removedIds = action.strokesRemoved.map((s) => s.id).toSet();
      drawingService.removeCommittedStrokesWhere(
          (s) => removedIds.contains(s.id));
      _deleteStrokes(removedIds.toList());
    }

    _resetStitchState();
    drawingService.notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Clear canvas — Phase 2.7 (with undo support)
  // ---------------------------------------------------------------------------

  void _handleClear(DrawingService drawingService) {
    final erasedIds = drawingService.erasedStrokeIds;

    final visibleStrokes = drawingService.committedStrokes
        .where((s) => !s.isTombstone && !erasedIds.contains(s.id))
        .toList();

    if (visibleStrokes.isEmpty) {
      drawingService.clear();
      _resetStitchState();
      return;
    }

    final tombstones = <Stroke>[];
    for (final stroke in visibleStrokes) {
      tombstones.add(Stroke.tombstone(
        id: _uuid.v4(),
        pageId: _pageId,
        targetStrokeId: stroke.id,
        createdAt: DateTime.now().toUtc(),
      ));
    }

    drawingService.addCommittedStrokes(tombstones);

    drawingService.pushUndoAction(
      UndoAction(strokesAdded: tombstones),
    );

    _persistStrokes(tombstones);

    _resetStitchState();
    drawingService.clear();
  }

  // ---------------------------------------------------------------------------
  // Page navigation (Layer 3)
  // ---------------------------------------------------------------------------

  /// Switch to a different page.
  ///
  /// Persists current page settings, clears the drawing service,
  /// resets all transient state, then triggers a reload for the new page.
  void _switchToPage(String newPageId, DrawingService drawingService) {
    if (newPageId == _pageId) return;

    // Persist current page settings before leaving
    _persistPageSettings();

    // Clear drawing state
    drawingService.clear();
    drawingService.clearUndoHistory();
    _resetStitchState();

    // Update the provider to the new page
    ref.read(currentPageIdProvider.notifier).state = newPageId;

    // Reset load flag so the next build loads the new page's data
    setState(() {
      _strokesLoaded = false;
      _gridStyle = GridStyle.none;
      _gridSpacing = 25.0;
      _paperColor = BackgroundPainter.defaultPaperColor;
    });
  }

  /// Create a new blank page at the end of the current chapter and switch to it.
  Future<void> _createNewPage(DrawingService drawingService) async {
    try {
      final dbAsync = ref.read(databaseServiceProvider);
      final db = dbAsync.valueOrNull;
      if (db == null) return;

      final chapterId = ref.read(currentChapterIdProvider);
      final pageCount = await db.getPageCount(chapterId);
      final newPageId = _uuid.v4();

      await db.insertPage(SketchPage(
        id: newPageId,
        chapterId: chapterId,
        pageNumber: pageCount,
      ));

      // Invalidate the pages list so the strip updates
      ref.invalidate(pagesForChapterProvider);

      if (mounted) {
        _switchToPage(newPageId, drawingService);
      }
    } catch (e) {
      debugPrint('Failed to create new page: $e');
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

  /// Persist current page settings (grid style, spacing, paper color) to SQLite.
  ///
  /// Fire-and-forget — called when the user changes any visual setting
  /// via the floating palette.
  Future<void> _persistPageSettings() async {
    try {
      final dbAsync = ref.read(databaseServiceProvider);
      final db = dbAsync.valueOrNull;
      if (db != null) {
        final page = SketchPage(
          id: _pageId,
          chapterId: ref.read(currentChapterIdProvider),
          pageNumber: 0,
          style: _gridStyle.toPageStyle(),
          gridConfig: GridConfig(spacing: _gridSpacing),
          paperColor: _paperColor.toARGB32(),
        );
        await db.updatePageSettings(page);
      }
    } catch (e) {
      debugPrint('Failed to persist page settings: $e');
    }
  }
}

/// Re-export the old name for backward compatibility with main.dart.
typedef CanvasPlaceholder = CanvasWidget;
