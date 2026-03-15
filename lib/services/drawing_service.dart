import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/eraser_mode.dart';
import '../models/pencil_lead.dart';
import '../models/pressure_curve.dart';
import '../models/pressure_mode.dart';
import '../models/spine_point.dart';
import '../models/stroke.dart';
import '../models/stroke_point.dart';
import '../models/tool_type.dart';
import '../models/undo_action.dart';
import '../utils/spatial_grid.dart';
import '../widgets/stroke_rendering.dart' show computeSpinePoints;
import 'database_service.dart';

// ---------------------------------------------------------------------------
// Raster cache mutation metadata
// ---------------------------------------------------------------------------

/// Describes the type of the most recent committed-stroke mutation.
/// Used by [CommittedStrokesPainter] to select the optimal cache update path.
enum MutationType {
  /// A single stroke was appended (pen-up). Cache updates incrementally.
  append,

  /// Strokes were added/removed with a computable dirty region.
  /// Only the affected area needs re-rendering.
  dirtyRegion,

  /// Full cache rebuild required (clear, load, or unknown mutation).
  fullRebuild,
}

/// Metadata about the most recent committed-stroke mutation.
///
/// Replaces the previous `lastMutationWasAppend` + `lastAppendedStroke` pair
/// with a richer descriptor that enables dirty-region cache updates.
class MutationInfo {
  const MutationInfo.append(this.appendedStroke)
      : type = MutationType.append,
        dirtyRect = null;

  const MutationInfo.dirtyRegion(this.dirtyRect)
      : type = MutationType.dirtyRegion,
        appendedStroke = null;

  const MutationInfo.fullRebuild()
      : type = MutationType.fullRebuild,
        dirtyRect = null,
        appendedStroke = null;

  final MutationType type;

  /// The dirty rectangle for [MutationType.dirtyRegion] mutations.
  final Rect? dirtyRect;

  /// The newly appended stroke for [MutationType.append] mutations.
  final Stroke? appendedStroke;
}

/// Drawing Pipeline (TDD §4.1, Phase 2.8).
///
/// Runs on the UI thread. Latency critical.
/// Extends [ChangeNotifier] to drive [CustomPainter] repaints via Riverpod.
///
/// ## Latency Requirements
///
/// | Operation                    | Target          |
/// |------------------------------|-----------------|
/// | Stroke point → screen pixel  | < 20ms e2e      |
/// | Full page redraw (pan/zoom)  | < 16ms (60fps)  |
/// | Stroke commit to SQLite      | < 5ms           |
/// | OCR trigger after pen-up     | 900ms idle      |
///
/// ## Pipeline Flow (TDD §4.1)
///
/// ```
/// ACTION_DOWN  → onPointerDown() → Create in-flight Stroke
/// ACTION_MOVE  → onPointerMove() → Append StrokePoint, emit partial render
/// ACTION_UP    → onPointerUp()   → Commit stroke, persist, enqueue sync
/// ```
class DrawingService extends ChangeNotifier {
  /// The stroke currently being drawn (pen is down).
  Stroke? _inflightStroke;

  /// Growable points list for the in-flight stroke.
  /// Shared by reference with [_inflightStroke] — `.add()` is O(1) amortized
  /// instead of rebuilding the entire Stroke + list on every pointer move.
  List<StrokePoint> _inflightPoints = [];

  /// All committed strokes for the current page.
  final List<Stroke> committedStrokes = [];

  // ---------------------------------------------------------------------------
  // Stroke version & erased IDs cache (Phase 2.8)
  // ---------------------------------------------------------------------------

  /// Monotonically increasing counter for committed stroke mutations.
  /// Used by [CommittedStrokesPainter.shouldRepaint()] for cache invalidation.
  int _strokeVersion = 0;
  int get strokeVersion => _strokeVersion;

  /// Cached set of erased stroke IDs. Recomputed on version bump.
  /// Eliminates per-frame [_collectErasedIds] computation from CanvasWidget.
  Set<String> _erasedStrokeIds = {};
  Set<String> get erasedStrokeIds => _erasedStrokeIds;

  // ---------------------------------------------------------------------------
  // Spatial grid index (Option D Phase 1)
  // ---------------------------------------------------------------------------

  /// Uniform grid hash for O(1) spatial queries on committed strokes.
  /// Built on [loadStrokes], marked dirty on undo/redo, rebuilt lazily.
  SpatialGrid? _spatialGrid;
  bool _spatialGridDirty = true;

  /// Expose the spatial grid for tiled rendering (CommittedStrokesPainter
  /// needs it to find strokes per tile). May be null before first query.
  SpatialGrid? get spatialGrid {
    if (_spatialGridDirty) _rebuildSpatialGrid();
    return _spatialGrid;
  }

  /// Query strokes whose bounding rects overlap [rect].
  /// Lazily rebuilds the grid if marked dirty. Falls back to linear scan
  /// if canvas dimensions aren't set yet.
  Set<String> queryStrokesInRect(Rect rect) {
    if (_spatialGridDirty) _rebuildSpatialGrid();
    if (_spatialGrid != null) return _spatialGrid!.queryRect(rect);
    // Fallback: linear scan
    return {
      for (final s in committedStrokes)
        if (!s.isTombstone &&
            !_erasedStrokeIds.contains(s.id) &&
            s.points.isNotEmpty &&
            s.boundingRect.overlaps(rect))
          s.id,
    };
  }

  /// Rebuild the spatial grid from current committed strokes.
  void _rebuildSpatialGrid() {
    _spatialGrid ??= SpatialGrid(128.0);
    _spatialGrid!.rebuild(committedStrokes, _erasedStrokeIds);
    _spatialGridDirty = false;
  }

  /// Incrementally update the grid for an erase operation.
  /// Removes erased strokes and inserts new split segments without
  /// rebuilding the entire grid. O(K) where K = strokes changed.
  void updateGridForErase(Set<String> erasedIds, List<Stroke> newStrokes) {
    if (_spatialGrid == null || _spatialGridDirty) return;
    for (final id in erasedIds) {
      _spatialGrid!.remove(id);
    }
    for (final s in newStrokes) {
      if (!s.isTombstone && s.points.isNotEmpty) {
        _spatialGrid!.insert(s.id, s.boundingRect);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Raster cache mutation tracking
  // ---------------------------------------------------------------------------

  /// Describes the most recent committed-stroke mutation for cache updates.
  MutationInfo _lastMutationInfo = const MutationInfo.fullRebuild();
  MutationInfo get lastMutationInfo => _lastMutationInfo;

  /// Override the mutation info without bumping version.
  ///
  /// Called by canvas widget after performing mutations to set the correct
  /// dirty rect for undo/redo/erase operations.
  void setMutationInfo(MutationInfo info) {
    _lastMutationInfo = info;
  }

  /// Increment version and recompute erased IDs.
  /// Marks the spatial grid dirty — it rebuilds lazily on next query.
  void _bumpVersion() {
    _strokeVersion++;
    _recomputeErasedIds();
    _spatialGridDirty = true;
  }

  void _recomputeErasedIds() {
    _erasedStrokeIds = {
      for (final s in committedStrokes)
        if (s.isTombstone && s.erasesStrokeId != null) s.erasesStrokeId!,
    };
  }

  /// Add strokes to committed list and bump version.
  ///
  /// Callers must still call [notifyListeners] separately if additional
  /// state changes are made in the same logical operation.
  void addCommittedStrokes(List<Stroke> strokes) {
    committedStrokes.addAll(strokes);
    _lastMutationInfo = const MutationInfo.fullRebuild();
    _bumpVersion();
  }

  /// Optimized erase path: add strokes and incrementally update erasedIds.
  ///
  /// Avoids the O(N) [_recomputeErasedIds] scan that [addCommittedStrokes]
  /// triggers. The caller provides the set of newly erased stroke IDs so
  /// we can just add them to the existing set.
  void addCommittedStrokesForErase(
      List<Stroke> strokes, Set<String> newlyErasedIds) {
    committedStrokes.addAll(strokes);
    _erasedStrokeIds.addAll(newlyErasedIds);
    _strokeVersion++;
    // Grid updated incrementally by caller via updateGridForErase().
    // Don't mark dirty — incremental update keeps it consistent.
    _lastMutationInfo = const MutationInfo.fullRebuild();
  }

  /// Remove committed strokes matching [test] and bump version.
  void removeCommittedStrokesWhere(bool Function(Stroke) test) {
    committedStrokes.removeWhere(test);
    _lastMutationInfo = const MutationInfo.fullRebuild();
    _bumpVersion();
  }

  // ---------------------------------------------------------------------------
  // Tool state
  // ---------------------------------------------------------------------------

  /// Current drawing tool.
  ToolType _currentTool = ToolType.pencil;
  ToolType get currentTool => _currentTool;
  set currentTool(ToolType value) {
    if (_currentTool != value) {
      _currentTool = value;
      // Manual tool change deactivates eraser toggle
      if (value != ToolType.eraser) {
        _eraserToggleActive = false;
        _toolBeforeEraser = null;
      }
      notifyListeners();
    }
  }

  /// Current stroke color (ARGB packed).
  int _currentColor = 0xFF000000; // black
  int get currentColor => _currentColor;
  set currentColor(int value) {
    if (_currentColor != value) {
      _currentColor = value;
      notifyListeners();
    }
  }

  /// Current stroke weight in canvas units.
  double _currentWeight = 2.0;
  double get currentWeight => _currentWeight;
  set currentWeight(double value) {
    if (_currentWeight != value) {
      _currentWeight = value;
      _currentLead = null; // manual override clears lead preset
      notifyListeners();
    }
  }

  /// Current stroke opacity.
  double _currentOpacity = 1.0;
  double get currentOpacity => _currentOpacity;
  set currentOpacity(double value) {
    if (_currentOpacity != value) {
      _currentOpacity = value;
      _currentLead = null; // manual override clears lead preset
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Pressure mode & curve
  // ---------------------------------------------------------------------------

  /// How stylus pressure affects pencil rendering.
  PressureMode _pressureMode = PressureMode.width;
  PressureMode get pressureMode => _pressureMode;
  set pressureMode(PressureMode value) {
    if (_pressureMode != value) {
      _pressureMode = value;
      notifyListeners();
    }
  }

  /// Pressure curve preset for pencil rendering.
  PressureCurve _pressureCurve = PressureCurve.natural;
  PressureCurve get pressureCurve => _pressureCurve;
  set pressureCurve(PressureCurve value) {
    if (_pressureCurve != value) {
      _pressureCurve = value;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Runtime quality overrides (dev menu)
  // ---------------------------------------------------------------------------

  /// Override grain intensity (null = use pencil lead preset).
  double? _grainIntensityOverride;
  double? get grainIntensityOverride => _grainIntensityOverride;
  set grainIntensityOverride(double? value) {
    if (_grainIntensityOverride != value) {
      _grainIntensityOverride = value;
      notifyListeners();
    }
  }

  /// Override pressure exponent (null = use pressure curve preset).
  double? _pressureExponentOverride;
  double? get pressureExponentOverride => _pressureExponentOverride;
  set pressureExponentOverride(double? value) {
    if (_pressureExponentOverride != value) {
      _pressureExponentOverride = value;
      notifyListeners();
    }
  }

  /// Override replay arc length (null = use default 1.5).
  double _replayArcLength = 1.5;
  double get replayArcLength => _replayArcLength;
  set replayArcLength(double value) {
    if (_replayArcLength != value) {
      _replayArcLength = value;
      notifyListeners();
    }
  }

  /// Override live drawing arc length (null = use default 0.5).
  double _liveArcLength = 0.5;
  double get liveArcLength => _liveArcLength;
  set liveArcLength(double value) {
    if (_liveArcLength != value) {
      _liveArcLength = value;
      notifyListeners();
    }
  }

  /// Override pressure deadzone (default 0.12).
  double _pressureDeadzone = 0.12;
  double get pressureDeadzone => _pressureDeadzone;
  set pressureDeadzone(double value) {
    if (_pressureDeadzone != value) {
      _pressureDeadzone = value;
      notifyListeners();
    }
  }

  /// Tilt effect strength (0.0 = off, 1.0 = full tilt shading).
  double _tiltStrength = 0.0;
  double get tiltStrength => _tiltStrength;
  set tiltStrength(double value) {
    if (_tiltStrength != value) {
      _tiltStrength = value;
      notifyListeners();
    }
  }

  /// Effective grain intensity: override if set, else lead preset, else 0.25.
  double get effectiveGrainIntensity =>
      _grainIntensityOverride ?? currentLead?.grainIntensity ?? 0.25;

  /// Effective pressure exponent: override if set, else curve preset.
  double get effectivePressureExponent =>
      _pressureExponentOverride ?? _pressureCurve.exponent;

  // ---------------------------------------------------------------------------
  // Eraser mode
  // ---------------------------------------------------------------------------

  /// How the eraser removes strokes (standard partial or history-based).
  EraserMode _eraserMode = EraserMode.standard;
  EraserMode get eraserMode => _eraserMode;
  set eraserMode(EraserMode value) {
    if (_eraserMode != value) {
      _eraserMode = value;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Undo / Redo
  // ---------------------------------------------------------------------------

  /// Maximum number of undo actions to retain.
  static const int maxUndoStack = 50;

  final List<UndoAction> _undoStack = [];
  final List<UndoAction> _redoStack = [];

  /// Whether an undo operation is available.
  bool get canUndo => _undoStack.isNotEmpty;

  /// Whether a redo operation is available.
  bool get canRedo => _redoStack.isNotEmpty;

  /// Record an undoable action. Clears the redo stack (new action
  /// invalidates any previously undone operations).
  void pushUndoAction(UndoAction action) {
    _undoStack.add(action);
    if (_undoStack.length > maxUndoStack) {
      _undoStack.removeAt(0); // drop oldest
    }
    _redoStack.clear();
    notifyListeners();
  }

  /// Pop the most recent undo action and move it to the redo stack.
  /// Returns the action so the caller can sync with the DB.
  /// Returns null if the undo stack is empty.
  UndoAction? popUndo() {
    if (_undoStack.isEmpty) return null;
    final action = _undoStack.removeLast();
    _redoStack.add(action);
    notifyListeners();
    return action;
  }

  /// Pop the most recent redo action and move it back to the undo stack.
  /// Returns the action so the caller can sync with the DB.
  /// Returns null if the redo stack is empty.
  UndoAction? popRedo() {
    if (_redoStack.isEmpty) return null;
    final action = _redoStack.removeLast();
    _undoStack.add(action);
    notifyListeners();
    return action;
  }

  /// Clear both undo and redo stacks (e.g. on page change).
  void clearUndoHistory() {
    _undoStack.clear();
    _redoStack.clear();
    // No notifyListeners — typically called alongside clear() or loadStrokes()
  }

  // ---------------------------------------------------------------------------
  // Pencil lead presets
  // ---------------------------------------------------------------------------

  /// Base weight that pencil lead multipliers are applied against.
  static const double pencilBaseWeight = 2.0;

  /// Currently selected pencil lead (null if using manual weight/opacity).
  PencilLead? _currentLead;
  PencilLead? get currentLead => _currentLead;

  /// Apply a pencil lead preset. Sets weight, opacity, and tool to pencil.
  void applyPencilLead(PencilLead lead) {
    _currentLead = lead;
    _currentWeight = pencilBaseWeight * lead.weightMultiplier;
    _currentOpacity = lead.opacity;
    _currentTool = ToolType.pencil;
    // Deactivate eraser toggle when switching to a pencil lead
    _eraserToggleActive = false;
    _toolBeforeEraser = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Quick eraser toggle
  // ---------------------------------------------------------------------------

  /// The tool that was active before the eraser toggle was engaged.
  ToolType? _toolBeforeEraser;

  /// Whether the quick-eraser toggle is active.
  bool _eraserToggleActive = false;
  bool get eraserToggleActive => _eraserToggleActive;

  /// Toggle eraser mode on/off. Saves/restores previous tool.
  void toggleEraser() {
    if (_eraserToggleActive) {
      // Restore previous tool
      _currentTool = _toolBeforeEraser ?? ToolType.pencil;
      _toolBeforeEraser = null;
      _eraserToggleActive = false;
    } else {
      // Save current tool and switch to eraser
      _toolBeforeEraser = _currentTool;
      _currentTool = ToolType.eraser;
      _eraserToggleActive = true;
    }
    notifyListeners();
  }

  /// Current active layer.
  String currentLayerId = 'default';

  /// Whether a stroke is currently in progress.
  bool get isDrawing => _inflightStroke != null;

  /// The in-flight stroke for rendering (read-only).
  Stroke? get inflightStroke => _inflightStroke;

  /// Called on stylus ACTION_DOWN.
  ///
  /// Creates a new in-flight stroke with the first point.
  /// If [stitchPoint] is provided (stroke stitching, Phase 2.8),
  /// it is prepended to create a bridge from the previous stroke.
  void onPointerDown({
    required String strokeId,
    required String pageId,
    required StrokePoint point,
    StrokePoint? stitchPoint,
  }) {
    _inflightPoints = stitchPoint != null ? [stitchPoint, point] : [point];

    _inflightStroke = Stroke(
      id: strokeId,
      pageId: pageId,
      layerId: currentLayerId,
      tool: _currentTool,
      color: _currentColor,
      weight: _currentWeight,
      opacity: _currentOpacity,
      points: _inflightPoints,
      createdAt: DateTime.now().toUtc(),
    );
    notifyListeners();
  }

  /// Called on stylus ACTION_MOVE (fires at 120–240 Hz on OnePlus Pad).
  ///
  /// Appends a point to the shared [_inflightPoints] list (O(1) amortized),
  /// then creates a new [Stroke] shell referencing the same list. The new
  /// object identity is needed for Flutter's change-detection to trigger
  /// a repaint — but the list itself is never copied.
  void onPointerMove(StrokePoint point) {
    final stroke = _inflightStroke;
    if (stroke == null) return;

    _inflightPoints.add(point);

    // New Stroke identity (cheap — 12 field assignments) sharing the
    // same growable points list (no copy). This satisfies Flutter's
    // identity-based repaint gating while keeping O(1) append cost.
    _inflightStroke = Stroke(
      id: stroke.id,
      pageId: stroke.pageId,
      layerId: stroke.layerId,
      tool: stroke.tool,
      color: stroke.color,
      weight: stroke.weight,
      opacity: stroke.opacity,
      points: _inflightPoints,
      createdAt: stroke.createdAt,
    );
    notifyListeners();
  }

  /// Called on stylus ACTION_UP.
  ///
  /// Commits the in-flight stroke and returns it for persistence.
  /// The caller is responsible for:
  /// - Persisting to SQLite (async, does not block emit)
  /// - Enqueuing SyncEvent(strokeAdded) (async)
  /// - Expanding DirtyRegion
  /// - Resetting OCR debounce timer (900ms)
  Stroke? onPointerUp() {
    final stroke = _inflightStroke;
    if (stroke == null) return null;

    // Finalize with frozen points list and creation timestamp.
    // List.of() creates an independent copy so the committed stroke
    // is not affected if _inflightPoints is reused.
    final frozenPoints = List<StrokePoint>.of(_inflightPoints);

    // Pre-bake spine points at replay arc length for fast page-load rendering.
    // This is the Option A performance fix — compute once, skip subdivision
    // on every subsequent page load.
    final spineData = frozenPoints.length >= 2
        ? computeSpinePoints(frozenPoints)
        : null;

    final committed = Stroke(
      id: stroke.id,
      pageId: stroke.pageId,
      layerId: stroke.layerId,
      tool: stroke.tool,
      color: stroke.color,
      weight: stroke.weight,
      opacity: stroke.opacity,
      points: frozenPoints,
      spineData: spineData,
      createdAt: DateTime.now().toUtc(),
    );

    committedStrokes.add(committed);
    _inflightStroke = null;
    _inflightPoints = [];
    _lastMutationInfo = MutationInfo.append(committed);
    _bumpVersion();
    // Incremental grid insert — O(1) instead of waiting for lazy O(N) rebuild.
    if (_spatialGrid != null && committed.points.isNotEmpty) {
      _spatialGrid!.insert(committed.id, committed.boundingRect);
      _spatialGridDirty = false;
    }
    notifyListeners();
    return committed;
  }

  /// Load persisted strokes (e.g. when navigating to a page).
  void loadStrokes(List<Stroke> strokes) {
    _inflightStroke = null;
    _inflightPoints = [];
    committedStrokes
      ..clear()
      ..addAll(strokes);
    _lastMutationInfo = const MutationInfo.fullRebuild();
    _bumpVersion();
    clearUndoHistory();
    notifyListeners();
  }

  /// Compute and persist spine data for committed strokes that lack it.
  ///
  /// Called after [loadStrokes] to backfill old strokes created before the
  /// v5 schema. Computes spine points, replaces the Stroke objects in
  /// [committedStrokes] with spine-enriched copies, and fire-and-forget
  /// persists the spine blobs to SQLite.
  ///
  /// The first load of old data still pays the Catmull-Rom cost, but
  /// subsequent loads of the same page are fast (spines already in DB).
  Future<void> backfillSpines(DatabaseService db) async {
    bool anyUpdated = false;
    for (int i = 0; i < committedStrokes.length; i++) {
      final stroke = committedStrokes[i];
      if (stroke.spineData != null || stroke.points.length < 2 || stroke.isTombstone) {
        continue;
      }

      final spines = computeSpinePoints(stroke.points);
      // Replace with spine-enriched copy
      committedStrokes[i] = Stroke(
        id: stroke.id,
        pageId: stroke.pageId,
        layerId: stroke.layerId,
        tool: stroke.tool,
        color: stroke.color,
        weight: stroke.weight,
        opacity: stroke.opacity,
        points: stroke.points,
        renderData: stroke.renderData,
        spineData: spines,
        createdAt: stroke.createdAt,
        isTombstone: stroke.isTombstone,
        erasesStrokeId: stroke.erasesStrokeId,
        synced: stroke.synced,
      );
      anyUpdated = true;

      // Fire-and-forget DB update
      db.updateSpineBlob(stroke.id, SpinePoint.packAll(spines));
    }

    if (anyUpdated) {
      _lastMutationInfo = const MutationInfo.fullRebuild();
      _bumpVersion();
      notifyListeners();
    }
  }

  /// Clear all strokes (for page navigation).
  /// Note: the caller (CanvasWidget) is responsible for pushing
  /// an UndoAction before calling this for user-initiated clears.
  void clear() {
    _inflightStroke = null;
    _inflightPoints = [];
    committedStrokes.clear();
    _spatialGrid?.clear();
    _lastMutationInfo = const MutationInfo.fullRebuild();
    _bumpVersion();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Tool state persistence
  // ---------------------------------------------------------------------------

  /// Persist current tool settings to SharedPreferences.
  Future<void> saveToolState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('tool_pressureMode', _pressureMode.name);
      await prefs.setString('tool_pressureCurve', _pressureCurve.name);
      await prefs.setString('tool_eraserMode', _eraserMode.name);
      await prefs.setDouble('tool_weight', _currentWeight);
      await prefs.setDouble('tool_opacity', _currentOpacity);
      await prefs.setInt('tool_color', _currentColor);
      if (_currentLead != null) {
        await prefs.setString('tool_pencilLead', _currentLead!.name);
      } else {
        await prefs.remove('tool_pencilLead');
      }
      // Dev menu quality overrides
      await prefs.setDouble('dev_replayArcLength', _replayArcLength);
      await prefs.setDouble('dev_liveArcLength', _liveArcLength);
      await prefs.setDouble('dev_pressureDeadzone', _pressureDeadzone);
      if (_grainIntensityOverride != null) {
        await prefs.setDouble('dev_grainIntensity', _grainIntensityOverride!);
      } else {
        await prefs.remove('dev_grainIntensity');
      }
      if (_pressureExponentOverride != null) {
        await prefs.setDouble('dev_pressureExponent', _pressureExponentOverride!);
      } else {
        await prefs.remove('dev_pressureExponent');
      }
      await prefs.setDouble('dev_tiltStrength', _tiltStrength);
    } catch (e) {
      debugPrint('Failed to save tool state: $e');
    }
  }

  /// Restore tool settings from SharedPreferences.
  ///
  /// Call once during startup, before the first render. Falls back to
  /// the default value for any missing or invalid key.
  Future<void> restoreToolState() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final modeStr = prefs.getString('tool_pressureMode');
      if (modeStr != null) {
        _pressureMode = PressureMode.values.firstWhere(
          (m) => m.name == modeStr,
          orElse: () => PressureMode.width,
        );
      }

      final curveStr = prefs.getString('tool_pressureCurve');
      if (curveStr != null) {
        _pressureCurve = PressureCurve.values.firstWhere(
          (c) => c.name == curveStr,
          orElse: () => PressureCurve.natural,
        );
      }

      final eraserStr = prefs.getString('tool_eraserMode');
      if (eraserStr != null) {
        _eraserMode = EraserMode.values.firstWhere(
          (e) => e.name == eraserStr,
          orElse: () => EraserMode.standard,
        );
      }

      final weight = prefs.getDouble('tool_weight');
      if (weight != null) _currentWeight = weight;

      final opacity = prefs.getDouble('tool_opacity');
      if (opacity != null) _currentOpacity = opacity;

      final color = prefs.getInt('tool_color');
      if (color != null) _currentColor = color;

      final leadStr = prefs.getString('tool_pencilLead');
      if (leadStr != null) {
        _currentLead = PencilLead.values.firstWhere(
          (l) => l.name == leadStr,
          orElse: () => PencilLead.medium,
        );
      }

      // Dev menu quality overrides
      final replayArc = prefs.getDouble('dev_replayArcLength');
      if (replayArc != null) _replayArcLength = replayArc;

      final liveArc = prefs.getDouble('dev_liveArcLength');
      if (liveArc != null) _liveArcLength = liveArc;

      final deadzone = prefs.getDouble('dev_pressureDeadzone');
      if (deadzone != null) _pressureDeadzone = deadzone;

      _grainIntensityOverride = prefs.getDouble('dev_grainIntensity');
      _pressureExponentOverride = prefs.getDouble('dev_pressureExponent');

      final tilt = prefs.getDouble('dev_tiltStrength');
      if (tilt != null) _tiltStrength = tilt;

      notifyListeners();
    } catch (e) {
      debugPrint('Failed to restore tool state: $e');
    }
  }
}
