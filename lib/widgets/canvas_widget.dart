import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/chapter.dart';
import '../models/eraser_mode.dart';
import '../models/render_point.dart';
import '../models/grid_config.dart';
import '../models/grid_style.dart';
import '../models/page_style.dart';
import '../models/sketch_page.dart';
import '../models/stroke.dart';
import '../models/stroke_point.dart';
import '../models/tool_type.dart';
import '../models/undo_action.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/drawing_provider.dart';
import '../providers/notebook_provider.dart';
import '../services/drawing_service.dart';
import '../utils/curve_fitter.dart';
import '../utils/stroke_splitter.dart';
import 'active_stroke_painter.dart';
import 'background_painter.dart';
import 'committed_strokes_painter.dart';
import 'developer_overlay.dart';
import 'floating_palette.dart';
import 'organize_panel.dart';
import 'page_strip.dart';
import 'raster_cache_pool.dart';
import 'stroke_raster_cache.dart';
import 'sync_settings_page.dart';

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

class _CanvasWidgetState extends ConsumerState<CanvasWidget>
    with WidgetsBindingObserver {
  /// LRU pool of raster caches for recently visited pages.
  final _rasterCachePool = RasterCachePool(maxEntries: 3);

  /// Active page's raster cache (from the pool).
  StrokeRasterCache get _strokeRasterCache =>
      _rasterCachePool.getOrCreate(_pageId);

  /// Whether a stylus/pen is currently active (for palm rejection).
  bool _penActive = false;

  /// Whether the last-viewed page has been restored from SharedPreferences.
  /// Blocks stroke loading until the correct page ID is set.
  bool _pageRestored = false;

  /// Whether strokes have been loaded from the database for the current page.
  /// Prevents re-loading on every widget rebuild. Reset on page switch.
  bool _strokesLoaded = false;

  /// Whether the organize panel (Layer 4c) is currently visible.
  bool _showOrganizePanel = false;

  /// Generation counter — cancels stale stroke-loading microtasks on page switch.
  int _loadGeneration = 0;

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

  /// Last position where an erase hit-test was performed (throttle).
  Offset? _lastErasePosition;

  // ---------------------------------------------------------------------------
  // Pinch-to-zoom state
  // ---------------------------------------------------------------------------

  /// Current canvas scale (1.0 = default, max 1.5).
  double _canvasScale = 1.0;

  /// Canvas pan offset (in screen coordinates).
  Offset _canvasOffset = Offset.zero;

  /// Scale at the start of the current pinch gesture.
  double _baseScale = 1.0;

  /// Offset at the start of the current pinch gesture.
  Offset _baseOffset = Offset.zero;

  /// Focal point at the start of the current pinch gesture.
  Offset _baseFocal = Offset.zero;

  /// Maximum allowed canvas scale.
  static const double _maxScale = 1.5;

  /// Active touch pointer positions (global/screen coordinates).
  /// Used for pinch-to-zoom gesture detection.
  final Map<int, Offset> _touchPointers = {};

  /// Distance between fingers at the start of the current pinch gesture.
  double? _basePinchDistance;

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

  // ---------------------------------------------------------------------------
  // Pressure deadzone (prevents accidental strokes from light touches)
  // ---------------------------------------------------------------------------

  /// Minimum pressure required to start a stroke. Touches below this
  /// threshold are ignored until pressure rises above it.
  static const double _pressureDeadzone = 0.12;

  /// True when pen-down was rejected due to pressure below deadzone.
  /// Reset on pen-up. If pressure rises above threshold during a move,
  /// the stroke starts then.
  bool _belowDeadzone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreLastViewedPage();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rasterCachePool.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      ref.read(drawingServiceProvider).saveToolState();
    }
  }

  /// Restore the last-viewed page and tool state from SharedPreferences.
  Future<void> _restoreLastViewedPage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPageId = prefs.getString('lastPageId');
      final savedChapterId = prefs.getString('lastChapterId');

      // Restore tool settings before first render
      await ref.read(drawingServiceProvider).restoreToolState();

      if (mounted) {
        if (savedPageId != null) {
          ref.read(currentPageIdProvider.notifier).state = savedPageId;
        }
        if (savedChapterId != null) {
          ref.read(currentChapterIdProvider.notifier).state = savedChapterId;
        }
        setState(() => _pageRestored = true);
      }
    } catch (e) {
      debugPrint('Failed to restore last viewed page: $e');
      if (mounted) {
        setState(() => _pageRestored = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final drawingService = ref.watch(drawingServiceProvider);
    final hitRadius = drawingService.currentWeight * 2.0;

    // --- Page recall: load persisted strokes + page settings on first build ---
    // The database provider is async (FutureProvider). When it resolves,
    // load all strokes and page settings for the current page.
    // This runs once per page — _strokesLoaded prevents re-loading.
    if (!_strokesLoaded && _pageRestored) {
      final dbAsync = ref.watch(databaseServiceProvider);
      dbAsync.whenData((db) {
        _strokesLoaded = true;
        final gen = _loadGeneration;
        // Schedule after this build frame to avoid setState-during-build
        // (loadStrokes calls notifyListeners which triggers rebuild)
        Future.microtask(() async {
          if (!mounted || gen != _loadGeneration) return;

          // Load strokes for the current page
          final strokes = await db.getStrokesByPageId(_pageId);
          if (!mounted || gen != _loadGeneration) return;
          if (strokes.isNotEmpty) {
            drawingService.loadStrokes(strokes);
          }

          // Load page settings (grid style, spacing, paper color)
          final page = await db.getPage(_pageId);
          if (!mounted || gen != _loadGeneration) return;
          if (page != null) {
            setState(() {
              _gridStyle = GridStyle.fromPageStyle(page.style);
              _gridSpacing = page.gridConfig?.spacing ?? 25.0;
              _paperColor = Color(page.paperColor);
            });
          }
        });
      });
    }

    // Phase 2: feed canvas dimensions to DrawingService for coordinate
    // normalization. The canvas fills the full Scaffold body, so
    // MediaQuery.size gives us the logical pixel dimensions.
    final screenSize = MediaQuery.of(context).size;
    drawingService.setCanvasDimensions(screenSize.width, screenSize.height);

    return Scaffold(
      body: Stack(
        children: [
          // Drawing canvas with pinch-to-zoom transform
          Positioned.fill(
            child: ClipRect(
              child: Transform(
                transform: Matrix4.identity()
                  ..translate(_canvasOffset.dx, _canvasOffset.dy)
                  ..scale(_canvasScale),
                child: Stack(
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
                      rasterCache: _strokeRasterCache,
                      devicePixelRatio:
                          MediaQuery.of(context).devicePixelRatio,
                      lastMutationInfo:
                          drawingService.lastMutationInfo,
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
                  ],
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
            isSignedIn: ref.watch(isSignedInProvider),
            onSyncTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SyncSettingsPage()),
              );
              // After returning from sync page, reload strokes and structure
              // in case a sync pulled new data from another device.
              if (!mounted) return;

              // Refresh notebook/chapter/page providers for structural changes
              ref.invalidate(chaptersProvider);
              ref.invalidate(globalPageListProvider);
              ref.invalidate(pagesForChapterProvider);

              final db = ref.read(databaseServiceProvider).value;
              if (db != null) {
                final pageId = _pageId;
                final strokes = await db.getStrokesByPageId(pageId);
                debugPrint('Post-sync reload: pageId=$pageId, '
                    'found ${strokes.length} strokes in DB');
                if (mounted) {
                  final ds = ref.read(drawingServiceProvider);
                  final oldCount = ds.committedStrokes.length;
                  ds.loadStrokes(strokes);
                  _strokeRasterCache.invalidate();
                  debugPrint('Post-sync reload: was $oldCount strokes, '
                      'now ${strokes.length}, version=${ds.strokeVersion}');
                  // Force full widget rebuild
                  setState(() {});
                }
              }
            },
          ),

          // Developer overlay + page navigation — global page list (Layer 4b)
          Builder(builder: (context) {
            final globalPagesAsync = ref.watch(globalPageListProvider);
            final currentPageId = ref.watch(currentPageIdProvider);
            return globalPagesAsync.when(
              data: (globalPages) {
                if (globalPages.isEmpty) {
                  return DeveloperOverlay(drawingService: drawingService);
                }

                final currentGlobalIndex = globalPages
                    .indexWhere((e) => e.page.id == currentPageId);
                final safeIndex =
                    currentGlobalIndex >= 0 ? currentGlobalIndex : 0;
                final currentEntry = globalPages[safeIndex];

                // Auto-sync currentChapterIdProvider when navigating
                // across chapter boundaries.
                final currentChapterId =
                    ref.read(currentChapterIdProvider);
                if (currentEntry.chapterId != currentChapterId) {
                  Future.microtask(() {
                    if (mounted) {
                      ref
                          .read(currentChapterIdProvider.notifier)
                          .state = currentEntry.chapterId;
                    }
                  });
                }

                return Stack(
                  children: [
                    // Developer overlay (Phase 2.8.1)
                    DeveloperOverlay(
                      drawingService: drawingService,
                      currentPageIndex: safeIndex,
                      totalPages: globalPages.length,
                      chapterIndex: currentEntry.chapterIndex,
                      totalChapters: currentEntry.totalChapters,
                    ),
                    // Page navigation strip (Layer 4b)
                    PageStrip(
                      currentPage: safeIndex,
                      totalPages: globalPages.length,
                      chapterTitle: currentEntry.chapterTitle,
                      chapterColor: currentEntry.chapterColor,
                      chapterIndex: currentEntry.chapterIndex,
                      totalChapters: currentEntry.totalChapters,
                      onPrevPage: safeIndex > 0
                          ? () => _switchToPage(
                                globalPages[safeIndex - 1].page.id,
                                drawingService)
                          : null,
                      onNextPage: safeIndex < globalPages.length - 1
                          ? () => _switchToPage(
                                globalPages[safeIndex + 1].page.id,
                                drawingService)
                          : null,
                      onNewPage: () => _createNewPage(drawingService),
                      onNewChapter: () =>
                          _createNewChapter(drawingService),
                      onOrganize: () =>
                          setState(() => _showOrganizePanel = true),
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

          // Organize panel overlay + scrim (Layer 4c)
          if (_showOrganizePanel) ...[
            // Scrim: semi-transparent backdrop that dismisses the panel
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _showOrganizePanel = false),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.3),
                ),
              ),
            ),
            // The organize panel itself
            OrganizePanel(
              onClose: () => setState(() => _showOrganizePanel = false),
              onNavigateToChapter: (chapterId) {
                _navigateToFirstPageOfChapter(chapterId, drawingService);
                setState(() => _showOrganizePanel = false);
              },
              onSwitchToPage: (pageId) =>
                  _switchToPage(pageId, drawingService),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Pointer event handlers
  // ---------------------------------------------------------------------------

  void _handlePointerDown(PointerDownEvent event) {
    // Pinch-to-zoom: track touch pointers (screen coordinates)
    if (event.kind == PointerDeviceKind.touch) {
      _touchPointers[event.pointer] = event.position;
      if (_touchPointers.length == 2) _startPinch();
      return;
    }

    // Palm rejection (DRW-006): Only accept stylus and mouse for drawing.
    if (!_isDrawingInput(event.kind)) return;

    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _penActive = true;
    }

    final drawingService = ref.read(drawingServiceProvider);

    // Eraser: find and remove strokes near the point
    if (drawingService.currentTool == ToolType.eraser) {
      _lastErasePosition = null; // reset throttle so first touch always erases
      setState(() => _eraserCursorPosition = event.localPosition);
      if (drawingService.eraserMode == EraserMode.history) {
        _historyEraseAt(event.localPosition, drawingService);
      } else {
        _standardEraseAt(event.localPosition, drawingService);
      }
      return;
    }

    // --- Pressure deadzone ---
    // Reject pen-down if pressure is below threshold to prevent
    // accidental strokes from light stylus contact.
    if (event.pressure < _pressureDeadzone) {
      _belowDeadzone = true;
      return;
    }
    _belowDeadzone = false;

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
    // Pinch-to-zoom: update touch pointer positions
    if (event.kind == PointerDeviceKind.touch) {
      _touchPointers[event.pointer] = event.position;
      if (_touchPointers.length >= 2) _updatePinch();
      return;
    }

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

    // Pressure deadzone: if pen-down was rejected, check if pressure
    // has risen above threshold. If so, start the stroke now.
    if (_belowDeadzone) {
      if (event.pressure < _pressureDeadzone) return;
      // Pressure crossed threshold — start stroke from this point
      _belowDeadzone = false;
      final point = _eventToPoint(event);
      drawingService.onPointerDown(
        strokeId: _uuid.v4(),
        pageId: _pageId,
        point: point,
      );
      return;
    }

    drawingService.onPointerMove(_eventToPoint(event));
  }

  void _handlePointerUp(PointerUpEvent event) {
    // Pinch-to-zoom: release touch pointer
    if (event.kind == PointerDeviceKind.touch) {
      _touchPointers.remove(event.pointer);
      if (_touchPointers.length < 2) _endPinch();
      return;
    }

    // Palm rejection: only accept stylus/mouse input
    if (!_isDrawingInput(event.kind)) return;

    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _penActive = false;
    }

    // Reset deadzone state — pen lifted without ever crossing threshold
    if (_belowDeadzone) {
      _belowDeadzone = false;
      return;
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
    // Pinch-to-zoom: clean up touch pointer on cancel
    if (event.kind == PointerDeviceKind.touch) {
      _touchPointers.remove(event.pointer);
      if (_touchPointers.length < 2) _endPinch();
      return;
    }

    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _penActive = false;
    }
    _belowDeadzone = false;

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
  /// Disabled: the stitching feature created visible "spider web" bridge
  /// lines between letters in cursive handwriting. The temporal and spatial
  /// thresholds were too generous, causing nearly every pen-lift between
  /// letters to trigger a connecting line.
  bool _shouldStitch(PointerDownEvent event, DrawingService drawingService) {
    return false;
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
  // Dirty rect helpers (dirty-region cache optimization)
  // ---------------------------------------------------------------------------

  /// Union two rects, treating [Rect.zero] as empty (identity element).
  static Rect _unionRect(Rect a, Rect b) {
    if (a == Rect.zero) return b;
    if (b == Rect.zero) return a;
    return a.expandToInclude(b);
  }

  /// Compute dirty rect for an undo/redo action.
  ///
  /// Includes bounding rects of strokes being removed AND strokes being
  /// restored. For tombstones, includes the bounding rect of the original
  /// stroke they erased (found via [erasesStrokeId] in committed strokes).
  Rect _dirtyRectForAction(
      UndoAction action, DrawingService drawingService) {
    Rect dirty = Rect.zero;

    for (final s in action.strokesAdded) {
      if (s.isTombstone && s.erasesStrokeId != null) {
        // Include the original stroke's rect (it will appear/disappear)
        for (final cs in drawingService.committedStrokes) {
          if (cs.id == s.erasesStrokeId) {
            dirty = _unionRect(dirty, cs.boundingRect);
            break;
          }
        }
      } else if (!s.isTombstone && s.points.isNotEmpty) {
        dirty = _unionRect(dirty, s.boundingRect);
      }
    }

    for (final s in action.strokesRemoved) {
      if (!s.isTombstone && s.points.isNotEmpty) {
        dirty = _unionRect(dirty, s.boundingRect);
      }
    }

    return dirty;
  }

  // ---------------------------------------------------------------------------
  // Standard erasing (stroke subdivision) — Phase 2.5
  // ---------------------------------------------------------------------------

  /// Erase portions of strokes near the given position.
  void _standardEraseAt(Offset position, DrawingService drawingService) {
    // Throttle: skip if cursor moved < 2px since last erase hit-test
    if (_lastErasePosition != null) {
      final dx = position.dx - _lastErasePosition!.dx;
      final dy = position.dy - _lastErasePosition!.dy;
      if (dx * dx + dy * dy < 4.0) return;
    }
    _lastErasePosition = position;

    final hitRadius = drawingService.currentWeight * 2.0;
    final hitRect = Rect.fromCenter(
      center: position,
      width: hitRadius * 2,
      height: hitRadius * 2,
    );

    // Read the cached set directly — no defensive copy needed since we
    // track newly-erased IDs separately and don’t modify the set here.
    final erasedIds = drawingService.erasedStrokeIds;
    final newlyErasedIds = <String>{};
    final strokesToAdd = <Stroke>[];

    // Iterate the committed list directly — no copy needed since we only
    // append (via addCommittedStrokesForErase) AFTER the loop completes.
    for (final stroke in drawingService.committedStrokes) {
      if (stroke.isTombstone) continue;
      if (erasedIds.contains(stroke.id)) continue;
      if (newlyErasedIds.contains(stroke.id)) continue;
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
      newlyErasedIds.add(stroke.id);

      for (final segment in segments) {
        // Phase 2: re-fit split segments into normalized RenderPoints.
        final cw = drawingService.canvasWidth;
        final ch = drawingService.canvasHeight;
        final hasCanvasDims = cw > 0 && ch > 0;
        final fitted = CurveFitter.chaikinSmooth(
          CurveFitter.simplify(segment),
        );
        strokesToAdd.add(Stroke(
          id: _uuid.v4(),
          pageId: _pageId,
          layerId: stroke.layerId,
          tool: stroke.tool,
          color: stroke.color,
          weight: stroke.weight,
          opacity: stroke.opacity,
          points: segment,
          renderData: fitted
              .map((sp) => hasCanvasDims
                  ? RenderPoint.fromStrokePoint(sp,
                      canvasWidth: cw, canvasHeight: ch)
                  : RenderPoint(
                      x: sp.x, y: sp.y, pressure: sp.pressure))
              .toList(),
          createdAt: DateTime.now().toUtc(),
        ));
      }
    }

    if (strokesToAdd.isNotEmpty) {
      // Compute dirty rect from erased originals' bounding rects
      Rect dirtyRect = Rect.zero;
      for (final s in strokesToAdd) {
        if (s.isTombstone && s.erasesStrokeId != null) {
          for (final cs in drawingService.committedStrokes) {
            if (cs.id == s.erasesStrokeId) {
              dirtyRect = _unionRect(dirtyRect, cs.boundingRect);
              break;
            }
          }
        }
      }

      drawingService.addCommittedStrokes(strokesToAdd);
      if (dirtyRect != Rect.zero) {
        drawingService.setMutationInfo(MutationInfo.dirtyRegion(dirtyRect));
      }
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
    // Throttle: skip if cursor moved < 2px since last erase hit-test
    if (_lastErasePosition != null) {
      final dx = position.dx - _lastErasePosition!.dx;
      final dy = position.dy - _lastErasePosition!.dy;
      if (dx * dx + dy * dy < 4.0) return;
    }
    _lastErasePosition = position;

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
    drawingService.setMutationInfo(
        MutationInfo.dirtyRegion(newest.boundingRect));
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

    // Compute dirty rect BEFORE mutations (need access to original strokes)
    final dirtyRect = _dirtyRectForAction(action, drawingService);

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

    // Override with dirty-region mutation info
    if (dirtyRect != Rect.zero) {
      drawingService.setMutationInfo(MutationInfo.dirtyRegion(dirtyRect));
    }

    _resetStitchState();
    drawingService.notifyListeners();
  }

  void _handleRedo(DrawingService drawingService) {
    final action = drawingService.popRedo();
    if (action == null) return;

    // Compute dirty rect BEFORE mutations
    final dirtyRect = _dirtyRectForAction(action, drawingService);

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

    // Override with dirty-region mutation info
    if (dirtyRect != Rect.zero) {
      drawingService.setMutationInfo(MutationInfo.dirtyRegion(dirtyRect));
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
    _loadGeneration++; // Cancel any in-flight stroke loads

    // Persist current page + tool settings before leaving
    _persistPageSettings();
    drawingService.saveToolState();

    // Clear drawing state and invalidate raster cache
    drawingService.clear();
    drawingService.clearUndoHistory();
    _resetStitchState();
    _strokeRasterCache.invalidate();

    // Update the provider to the new page
    ref.read(currentPageIdProvider.notifier).state = newPageId;

    // Persist last-viewed page for next app launch
    _saveLastViewedPage(newPageId, ref.read(currentChapterIdProvider));

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

      // Invalidate the pages lists so the strip updates
      ref.invalidate(pagesForChapterProvider);
      ref.invalidate(globalPageListProvider);

      if (mounted) {
        _switchToPage(newPageId, drawingService);
      }
    } catch (e) {
      debugPrint('Failed to create new page: $e');
    }
  }

  /// Create a new chapter at the end of the notebook with one blank page,
  /// then navigate to that page.
  Future<void> _createNewChapter(DrawingService drawingService) async {
    try {
      final dbAsync = ref.read(databaseServiceProvider);
      final db = dbAsync.valueOrNull;
      if (db == null) return;

      final chapterCount = await db.getChapterCount(defaultNotebookId);
      final newChapterId = _uuid.v4();
      final newPageId = _uuid.v4();

      // Insert chapter at the end
      await db.insertChapter(Chapter(
        id: newChapterId,
        notebookId: defaultNotebookId,
        title: 'Chapter ${chapterCount + 1}',
        order: chapterCount,
      ));

      // Insert one blank page in the new chapter
      await db.insertPage(SketchPage(
        id: newPageId,
        chapterId: newChapterId,
        pageNumber: 0,
      ));

      // Update current chapter
      ref.read(currentChapterIdProvider.notifier).state = newChapterId;

      // Invalidate providers so they reload
      ref.invalidate(globalPageListProvider);
      ref.invalidate(chaptersProvider);
      ref.invalidate(pagesForChapterProvider);

      if (mounted) {
        _switchToPage(newPageId, drawingService);
      }
    } catch (e) {
      debugPrint('Failed to create new chapter: $e');
    }
  }

  /// Navigate to the first page of a chapter (for organize panel jump-to).
  Future<void> _navigateToFirstPageOfChapter(
    String chapterId,
    DrawingService drawingService,
  ) async {
    try {
      final dbAsync = ref.read(databaseServiceProvider);
      final db = dbAsync.valueOrNull;
      if (db == null) return;

      final pages = await db.getPagesByChapter(chapterId);
      if (pages.isNotEmpty) {
        ref.read(currentChapterIdProvider.notifier).state = chapterId;
        if (mounted) {
          _switchToPage(pages.first.id, drawingService);
        }
      }
    } catch (e) {
      debugPrint('Failed to navigate to chapter: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Pinch-to-zoom gesture handling
  // ---------------------------------------------------------------------------

  /// Begin a pinch-to-zoom gesture when 2 touch pointers are active.
  void _startPinch() {
    final positions = _touchPointers.values.toList();
    if (positions.length < 2) return;
    _basePinchDistance = (positions[0] - positions[1]).distance;
    _baseScale = _canvasScale;
    _baseOffset = _canvasOffset;
    _baseFocal = (positions[0] + positions[1]) / 2.0;
  }

  /// Update zoom/pan during an active pinch gesture.
  void _updatePinch() {
    if (_touchPointers.length < 2 || _basePinchDistance == null) return;
    if (_basePinchDistance! < 1.0) return;

    final positions = _touchPointers.values.toList();
    final currentDistance = (positions[0] - positions[1]).distance;
    final currentFocal = (positions[0] + positions[1]) / 2.0;

    final rawScale = _baseScale * (currentDistance / _basePinchDistance!);
    final newScale = rawScale.clamp(1.0, _maxScale);

    // Adjust offset so the focal point stays visually stationary
    final focalDelta = currentFocal - _baseFocal;
    final scaleRatio = newScale / _baseScale;
    final newOffset = _baseOffset + focalDelta -
        (_baseFocal - _baseOffset) * (scaleRatio - 1.0);

    setState(() {
      _canvasScale = newScale;
      _canvasOffset = newOffset;
    });
  }

  /// End the pinch gesture and clamp the canvas offset.
  void _endPinch() {
    _basePinchDistance = null;
    _clampCanvasOffset();
  }

  /// Clamp canvas offset so the canvas stays within viewable bounds.
  void _clampCanvasOffset() {
    if (_canvasScale <= 1.0) {
      setState(() {
        _canvasScale = 1.0;
        _canvasOffset = Offset.zero;
      });
      return;
    }

    // At scale S, the canvas is S times larger than the viewport.
    // Maximum pan in each direction = (S - 1) * viewportSize.
    final size = MediaQuery.of(context).size;
    final maxDx = ((_canvasScale - 1.0) * size.width) / 2.0;
    final maxDy = ((_canvasScale - 1.0) * size.height) / 2.0;

    setState(() {
      _canvasOffset = Offset(
        _canvasOffset.dx.clamp(-maxDx, maxDx),
        _canvasOffset.dy.clamp(-maxDy, maxDy),
      );
    });
  }

  /// Reset zoom to 1.0x (double-tap to reset).
  void _resetZoom() {
    setState(() {
      _canvasScale = 1.0;
      _canvasOffset = Offset.zero;
    });
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

  /// Persist the last-viewed page/chapter to SharedPreferences so the app
  /// can resume there on next launch.
  Future<void> _saveLastViewedPage(String pageId, String chapterId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lastPageId', pageId);
      await prefs.setString('lastChapterId', chapterId);
    } catch (e) {
      debugPrint('Failed to save last viewed page: $e');
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
