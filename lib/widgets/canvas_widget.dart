import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/camera.dart';
import '../models/chapter.dart';
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
import '../providers/auth_provider.dart';
import '../providers/drawing_provider.dart';
import '../providers/notebook_provider.dart';
import '../providers/snapshot_provider.dart';
import '../services/drawing_service.dart';
import '../utils/stroke_splitter.dart';
import 'stroke_rendering.dart' show computeSpinePoints;
import 'active_stroke_painter.dart';
import 'background_painter.dart';
import 'committed_strokes_painter.dart';
import 'developer_overlay.dart';
import 'floating_palette.dart';
import 'organize_panel.dart';
import 'page_strip.dart';
import 'tile_cache.dart';
import 'dev_menu_page.dart';
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
  /// Per-tile raster cache for tiled rendering.
  final _tileCache = TileCache(maxTiles: 64);

  /// Whether a stylus/pen is currently active (for palm rejection).
  bool _penActive = false;

  /// Whether the last-viewed page has been restored from SharedPreferences.
  /// Blocks stroke loading until the correct page ID is set.
  bool _pageRestored = false;

  /// Whether stroke loading has been kicked off for the current page.
  /// Prevents re-loading on every widget rebuild. Reset on page switch.
  bool _strokesLoaded = false;

  /// Whether the page is fully ready (strokes loaded + settings applied).
  /// Controls the loading UI (grey veil, progress bar). Reset on page switch.
  bool _pageReady = false;

  /// Whether the organize panel (Layer 4c) is currently visible.
  bool _showOrganizePanel = false;

  /// Whether the developer info overlay is visible.
  bool _devOverlayVisible = true;

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
  // Camera state (infinite canvas)
  // ---------------------------------------------------------------------------

  /// Camera: defines which part of the infinite world is visible.
  final Camera _camera = Camera();

  /// Camera state used for tile/background rendering. Matches [_camera]
  /// except during a pinch gesture, where it stays frozen at the pre-pinch
  /// state. A compensating Transform handles the visual scaling/panning
  /// so tiles are NOT re-rendered every frame during pinch.
  Camera _renderCamera = Camera();

  /// Snapshot of camera at pinch start (for focal-point-stable zoom).
  Camera? _baseCameraSnapshot;

  /// Whether a pinch gesture is in progress (for frozen tile rendering).
  bool _isPinching = false;

  /// Focal point (screen coords) at pinch start.
  Offset _baseFocal = Offset.zero;

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

  /// True when pen-down was rejected due to pressure below deadzone.
  /// Reset on pen-up. If pressure rises above threshold during a move,
  /// the stroke starts then.
  bool _belowDeadzone = false;

  // ---------------------------------------------------------------------------
  // Page snapshot state (Phase 3: instant page switching)
  // ---------------------------------------------------------------------------

  /// Decoded snapshot image displayed during page switch while strokes load.
  ui.Image? _snapshotImage;

  /// Whether the snapshot overlay is currently showing (crossfade control).
  bool _showingSnapshot = false;

  /// Debounce timer for capturing snapshots after pen-up.
  Timer? _snapshotDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreLastViewedPage();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _snapshotDebounce?.cancel();
    _snapshotImage?.dispose();
    _tileCache.dispose();
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
            // Clear tile cache so empty tiles from pre-load paint are
            // discarded and tiles re-render with the loaded strokes.
            _tileCache.clear();
            // Async backfill spine data for pre-v5 strokes (fire-and-forget)
            drawingService.backfillSpines(db);
          }

          // Load page settings (grid style, spacing, paper color)
          final page = await db.getPage(_pageId);
          if (!mounted || gen != _loadGeneration) return;
          setState(() {
            if (page != null) {
              _gridStyle = GridStyle.fromPageStyle(page.style);
              _gridSpacing = page.gridConfig?.spacing ?? 25.0;
              _paperColor = Color(page.paperColor);
            }
            _pageReady = true;
          });

          // Phase 3: dismiss snapshot overlay after page is fully ready.
          // Schedule after paint frame so the committed strokes painter
          // has a chance to render before we fade out the snapshot.
          if (_showingSnapshot && mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || gen != _loadGeneration) return;
              setState(() {
                _showingSnapshot = false;
              });
            });
          }
        });
      });
    }

    final screenSize = MediaQuery.of(context).size;

    // During pinch, _renderCamera stays frozen at the pre-pinch state.
    // A compensating Transform handles the visual scaling/panning so
    // tiles are NOT re-rendered on every frame during a pinch gesture.
    final renderViewport = _renderCamera.viewportRect(screenSize);
    final renderZoom = _renderCamera.zoom;

    // Compensating transform: maps from _renderCamera screen space to
    // _camera screen space. Identity when not pinching.
    final Matrix4 compensatingTransform;
    if (_isPinching) {
      final relZoom = _camera.zoom / _renderCamera.zoom;
      final tx = (_renderCamera.topLeft.dx - _camera.topLeft.dx) * _camera.zoom;
      final ty = (_renderCamera.topLeft.dy - _camera.topLeft.dy) * _camera.zoom;
      compensatingTransform = Matrix4.identity()
        ..translate(tx, ty)
        ..scale(relZoom, relZoom);
    } else {
      compensatingTransform = Matrix4.identity();
    }

    return Scaffold(
      backgroundColor: _paperColor,
      body: Stack(
        children: [
          // Layers 1+2: Background + Committed strokes — wrapped in
          // compensating Transform during pinch for smooth zoom/pan
          // without re-rendering tiles every frame.
          Positioned.fill(
            child: Transform(
              transform: compensatingTransform,
              child: Stack(
                children: [
                  // Layer 1: Background — OUTSIDE main Transform (handles own
                  // world→screen mapping for infinite grid rendering)
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: BackgroundPainter(
                          paperColor: _paperColor,
                          gridStyle: _gridStyle,
                          gridSpacing: _gridSpacing,
                          viewportRect: renderViewport,
                          zoom: renderZoom,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),

                  // Layer 2: Committed strokes — OUTSIDE main Transform
                  // (handles own world→screen mapping via tiled rendering)
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: CommittedStrokesPainter(
                          committedStrokes: drawingService.committedStrokes,
                          erasedStrokeIds: drawingService.erasedStrokeIds,
                          strokeVersion: drawingService.strokeVersion,
                          pressureMode: drawingService.pressureMode,
                          grainIntensity:
                              drawingService.effectiveGrainIntensity,
                          pressureExponent:
                              drawingService.effectivePressureExponent,
                          replayArcLength: drawingService.replayArcLength,
                          tileCache: _tileCache,
                          spatialGrid: drawingService.spatialGrid,
                          devicePixelRatio:
                              MediaQuery.of(context).devicePixelRatio,
                          viewportRect: renderViewport,
                          zoom: renderZoom,
                          lastMutationInfo: drawingService.lastMutationInfo,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Phase 3: Snapshot overlay — instant display during page switch.
          // Crossfades out (200ms) when live strokes finish loading.
          if (_snapshotImage != null)
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: _showingSnapshot ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                onEnd: () {
                  if (!_showingSnapshot && _snapshotImage != null) {
                    setState(() {
                      _snapshotImage!.dispose();
                      _snapshotImage = null;
                    });
                  }
                },
                child: CustomPaint(
                  painter: _SnapshotPainter(_snapshotImage!),
                  size: Size.infinite,
                ),
              ),
            ),

          // Layer 3: Active stroke + eraser cursor
          // Listener is OUTSIDE Transform so it receives touches across the
          // full screen (important when zoomed out — the world extends beyond
          // the original canvas bounds). Coordinates are converted from screen
          // to world space manually via _camera.screenToWorld().
          Positioned.fill(
            child: Listener(
              onPointerDown: (event) => _handlePointerDown(event),
              onPointerMove: (event) => _handlePointerMove(event),
              onPointerUp: (event) => _handlePointerUp(event),
              onPointerCancel: (event) => _handlePointerCancel(event),
              behavior: HitTestBehavior.opaque,
              child: ClipRect(
                child: Transform(
                  transform: _camera.matrix,
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
                            drawingService.effectiveGrainIntensity,
                        pressureExponent:
                            drawingService.effectivePressureExponent,
                        liveArcLength: drawingService.liveArcLength,
                        suppressSinglePoint: !_hasStitchPoint,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Page loading overlay — grey veil while strokes load.
          // Blocks interaction by absorbing all pointer events.
          if (!_pageReady)
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: _pageReady ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 150),
                child: AbsorbPointer(
                  child: Container(
                    color: const Color.fromRGBO(0, 0, 0, 0.15),
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
            onDevTap: () async {
              final result = await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DevMenuPage(
                    devOverlayVisible: _devOverlayVisible,
                    onDevOverlayToggled: (v) =>
                        setState(() => _devOverlayVisible = v),
                  ),
                ),
              );
              if (!mounted) return;
              if (result == 'purged') {
                // Reset to default page after purge
                ref.read(currentPageIdProvider.notifier).state = defaultPageId;
                ref.invalidate(chaptersProvider);
                ref.invalidate(globalPageListProvider);
                ref.invalidate(pagesForChapterProvider);
                // Reload strokes (now empty)
                final ds = ref.read(drawingServiceProvider);
                ds.loadStrokes([]);
                _tileCache.clear();
                setState(() {
                  _strokesLoaded = false;
                });
              }
            },
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
                  // Async backfill spine data for pre-v5 strokes
                  ds.backfillSpines(db);
                  _tileCache.clear();
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
                  return _devOverlayVisible
                      ? DeveloperOverlay(drawingService: drawingService)
                      : const SizedBox.shrink();
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
                    if (_devOverlayVisible)
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
                      isLoading: !_pageReady,
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
              loading: () => _devOverlayVisible
                  ? DeveloperOverlay(drawingService: drawingService)
                  : const SizedBox.shrink(),
              error: (_, __) => _devOverlayVisible
                  ? DeveloperOverlay(drawingService: drawingService)
                  : const SizedBox.shrink(),
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
      final worldPos = _camera.screenToWorld(event.localPosition);
      _lastErasePosition = null; // reset throttle so first touch always erases
      setState(() => _eraserCursorPosition = worldPos);
      if (drawingService.eraserMode == EraserMode.history) {
        _historyEraseAt(worldPos, drawingService);
      } else {
        _standardEraseAt(worldPos, drawingService);
      }
      return;
    }

    // --- Pressure deadzone ---
    // Reject pen-down if pressure is below threshold to prevent
    // accidental strokes from light stylus contact.
    if (event.pressure < drawingService.pressureDeadzone) {
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
      final worldPos = _camera.screenToWorld(event.localPosition);
      setState(() => _eraserCursorPosition = worldPos);
      if (drawingService.eraserMode == EraserMode.history) {
        _historyEraseAt(worldPos, drawingService);
      } else {
        _standardEraseAt(worldPos, drawingService);
      }
      return;
    }

    // Pressure deadzone: if pen-down was rejected, check if pressure
    // has risen above threshold. If so, start the stroke now.
    if (_belowDeadzone) {
      if (event.pressure < drawingService.pressureDeadzone) return;
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

      // Invalidate only tiles overlapping the new stroke; surviving tiles
      // keep their cached images (revalidateRemaining re-stamps their version).
      if (committed.points.isNotEmpty) {
        _tileCache.invalidateRect(committed.boundingRect);
        _tileCache.bumpVersion();
        _tileCache.revalidateRemaining();
      }

      // Push undo action for the drawn stroke
      drawingService.pushUndoAction(
        UndoAction(strokesAdded: [committed]),
      );
      _persistStroke(committed);

      // Phase 3: debounced snapshot capture — waits 500ms after last
      // pen-up before capturing, to avoid encoding during rapid drawing.
      _snapshotDebounce?.cancel();
      _snapshotDebounce = Timer(const Duration(milliseconds: 500), () {
        _capturePageSnapshot(drawingService);
      });
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

    // Spatial grid query: O(1) lookup instead of scanning all strokes.
    final candidateIds = drawingService.queryStrokesInRect(hitRect);

    for (final stroke in drawingService.committedStrokes) {
      if (!candidateIds.contains(stroke.id)) continue;
      if (erasedIds.contains(stroke.id)) continue;
      if (newlyErasedIds.contains(stroke.id)) continue;

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
        // Pre-bake spine points for the split segment.
        final spineData = segment.length >= 2
            ? computeSpinePoints(segment)
            : null;
        strokesToAdd.add(Stroke(
          id: _uuid.v4(),
          pageId: _pageId,
          layerId: stroke.layerId,
          tool: stroke.tool,
          color: stroke.color,
          weight: stroke.weight,
          opacity: stroke.opacity,
          points: segment,
          spineData: spineData,
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

      // Incremental grid update: remove erased strokes, insert new splits.
      // This is O(K) where K = changed strokes, vs O(N) full rebuild.
      drawingService.updateGridForErase(newlyErasedIds, strokesToAdd);
      drawingService.addCommittedStrokesForErase(
          strokesToAdd, newlyErasedIds);
      if (dirtyRect != Rect.zero) {
        _tileCache.invalidateRect(dirtyRect);
        _tileCache.bumpVersion();
        _tileCache.revalidateRemaining();
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

    // Spatial grid query: O(1) lookup instead of scanning all strokes.
    final hitRect = Rect.fromCenter(
      center: position,
      width: hitRadius * 2,
      height: hitRadius * 2,
    );
    final candidateIds = drawingService.queryStrokesInRect(hitRect);

    final candidates = <Stroke>[];
    for (final stroke in drawingService.committedStrokes) {
      if (!candidateIds.contains(stroke.id)) continue;
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
    _tileCache.invalidateRect(newest.boundingRect);
    _tileCache.bumpVersion();
    _tileCache.revalidateRemaining();
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

    // Invalidate tiles + set dirty-region mutation info
    if (dirtyRect != Rect.zero) {
      _tileCache.invalidateRect(dirtyRect);
      _tileCache.bumpVersion();
      _tileCache.revalidateRemaining();
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

    // Invalidate tiles + set dirty-region mutation info
    if (dirtyRect != Rect.zero) {
      _tileCache.invalidateRect(dirtyRect);
      _tileCache.bumpVersion();
      _tileCache.revalidateRemaining();
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
    _snapshotDebounce?.cancel();

    // TODO: snapshot capture deferred — tile cache doesn't produce a single
    // full-page image. Revisit if page snapshots are still needed.

    // Persist current page + tool settings before leaving
    _persistPageSettings();
    drawingService.saveToolState();

    // Clear drawing state and tile cache
    drawingService.clear();
    drawingService.clearUndoHistory();
    _resetStitchState();
    _tileCache.clear();

    // Update the provider to the new page
    ref.read(currentPageIdProvider.notifier).state = newPageId;

    // Persist last-viewed page for next app launch
    _saveLastViewedPage(newPageId, ref.read(currentChapterIdProvider));

    // Phase 3: try to load snapshot for the new page.
    // Display it immediately while strokes load in the background.
    _snapshotImage?.dispose();
    _snapshotImage = null;
    _showingSnapshot = false;
    final snapshotService = ref.read(snapshotServiceProvider);
    if (snapshotService != null) {
      snapshotService.getSnapshot(newPageId).then((image) {
        if (!mounted) {
          image?.dispose();
          return;
        }
        if (image != null) {
          setState(() {
            _snapshotImage = image;
            _showingSnapshot = true;
          });
        }
      });
    }

    // Reset load flags so the next build loads the new page's data
    setState(() {
      _strokesLoaded = false;
      _pageReady = false;
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
    _baseCameraSnapshot = _camera.copy();
    _baseFocal = (positions[0] + positions[1]) / 2.0;
    _isPinching = true;
    // Freeze renderCamera — tiles won't be re-rendered during pinch.
    // A compensating Transform handles the visual scaling/panning.
    _renderCamera = _camera.copy();
  }

  /// Update zoom/pan during an active pinch gesture.
  ///
  /// Keeps the world point under the pinch focal stationary on screen.
  void _updatePinch() {
    if (_touchPointers.length < 2 ||
        _basePinchDistance == null ||
        _baseCameraSnapshot == null) return;
    if (_basePinchDistance! < 1.0) return;

    final positions = _touchPointers.values.toList();
    final currentDistance = (positions[0] - positions[1]).distance;
    final currentFocal = (positions[0] + positions[1]) / 2.0;

    final baseZoom = _baseCameraSnapshot!.zoom;
    final rawZoom = baseZoom * (currentDistance / _basePinchDistance!);
    final newZoom = rawZoom.clamp(Camera.minZoom, Camera.maxZoom);

    // The world point under the original focal must stay under the current focal.
    final focalWorld = _baseCameraSnapshot!.screenToWorld(_baseFocal);

    setState(() {
      _camera.zoom = newZoom;
      _camera.topLeft = Offset(
        focalWorld.dx - currentFocal.dx / newZoom,
        focalWorld.dy - currentFocal.dy / newZoom,
      );
    });
  }

  /// End the pinch gesture. No clamping — infinite pan.
  void _endPinch() {
    _basePinchDistance = null;
    _baseCameraSnapshot = null;
    if (_isPinching) {
      _isPinching = false;
      // Sync renderCamera to current camera. This triggers tile re-render
      // at the new zoom resolution on the next paint.
      _renderCamera = _camera.copy();
      _tileCache.clear(); // Force full re-render at new resolution
    }
  }

  /// Reset zoom to 1.0x and pan to origin.
  void _resetZoom() {
    setState(() {
      _camera.zoom = 1.0;
      _camera.topLeft = Offset.zero;
      _renderCamera = _camera.copy();
      _tileCache.clear();
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
  ///
  /// The Listener is outside the camera Transform, so localPosition is in
  /// screen coordinates. Convert to world coordinates via the camera.
  StrokePoint _eventToPoint(PointerEvent event) {
    final world = _camera.screenToWorld(event.localPosition);
    return StrokePoint(
      x: world.dx,
      y: world.dy,
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

  /// Phase 3: capture the current page's raster cache as a snapshot.
  ///
  /// Called on a debounced timer after pen-up. The snapshot is stored in
  /// the SnapshotService's LRU cache and persisted to SQLite for recovery
  /// after app restart.
  void _capturePageSnapshot(DrawingService drawingService) {
    // TODO: tile cache doesn't produce a single full-page image.
    // Snapshot capture deferred until a composite image approach is added.
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

/// Simple painter that draws a decoded snapshot [ui.Image] to fill the canvas.
///
/// Used as the instant-display layer during page switches. The snapshot
/// provides immediate visual feedback while the full stroke rebuild
/// loads in the background.
class _SnapshotPainter extends CustomPainter {
  _SnapshotPainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
          0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint(),
    );
  }

  @override
  bool shouldRepaint(covariant _SnapshotPainter oldDelegate) {
    return image != oldDelegate.image;
  }
}
