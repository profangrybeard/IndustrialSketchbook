import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../models/pencil_lead.dart';
import '../models/stroke.dart';
import '../models/stroke_point.dart';
import '../models/tool_type.dart';

/// Drawing Pipeline (TDD §4.1).
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

  /// All committed strokes for the current page.
  final List<Stroke> committedStrokes = [];

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
  void onPointerDown({
    required String strokeId,
    required String pageId,
    required StrokePoint point,
  }) {
    _inflightStroke = Stroke(
      id: strokeId,
      pageId: pageId,
      layerId: currentLayerId,
      tool: _currentTool,
      color: _currentColor,
      weight: _currentWeight,
      opacity: _currentOpacity,
      points: [point],
      createdAt: DateTime.now().toUtc(),
    );
    notifyListeners();
  }

  /// Called on stylus ACTION_MOVE (fires at 120–240 Hz on OnePlus Pad).
  ///
  /// Appends a point to the in-flight stroke.
  /// Triggers repaint for the new segment only.
  void onPointerMove(StrokePoint point) {
    final stroke = _inflightStroke;
    if (stroke == null) return;

    // Rebuild with new point appended (Stroke is immutable-ish for now)
    _inflightStroke = Stroke(
      id: stroke.id,
      pageId: stroke.pageId,
      layerId: stroke.layerId,
      tool: stroke.tool,
      color: stroke.color,
      weight: stroke.weight,
      opacity: stroke.opacity,
      points: [...stroke.points, point],
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

    // Finalize with creation timestamp
    final committed = Stroke(
      id: stroke.id,
      pageId: stroke.pageId,
      layerId: stroke.layerId,
      tool: stroke.tool,
      color: stroke.color,
      weight: stroke.weight,
      opacity: stroke.opacity,
      points: stroke.points,
      createdAt: DateTime.now().toUtc(),
    );

    committedStrokes.add(committed);
    _inflightStroke = null;
    notifyListeners();
    return committed;
  }

  /// Load persisted strokes (e.g. when navigating to a page).
  void loadStrokes(List<Stroke> strokes) {
    _inflightStroke = null;
    committedStrokes
      ..clear()
      ..addAll(strokes);
    notifyListeners();
  }

  /// Clear all strokes (for page navigation).
  void clear() {
    _inflightStroke = null;
    committedStrokes.clear();
    notifyListeners();
  }
}
