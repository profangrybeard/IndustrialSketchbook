import 'dart:collection';

/// Lightweight performance metrics collector for profiling rendering.
///
/// Tracks timing and counts for key rendering operations. All data is
/// in-memory only — no I/O. Designed for zero-cost when not read.
class PerfMetrics {
  PerfMetrics._();
  static final instance = PerfMetrics._();

  // ---------------------------------------------------------------------------
  // Active stroke (Layer 3) — per-frame during drawing
  // ---------------------------------------------------------------------------

  /// Last active stroke paint time in microseconds.
  int activeStrokePaintUs = 0;

  /// Rolling window of recent active stroke paint times for averaging.
  final _activeStrokeTimes = Queue<int>();
  static const _windowSize = 60;

  /// Number of inflight points in the last active stroke paint.
  int inflightPointCount = 0;

  /// Number of spine points generated for the last inflight stroke.
  int inflightSpinePointCount = 0;

  /// Number of saveLayer calls in the last inflight stroke paint.
  int inflightSaveLayerCount = 0;

  void recordActiveStrokePaint(int microseconds) {
    activeStrokePaintUs = microseconds;
    _activeStrokeTimes.addLast(microseconds);
    while (_activeStrokeTimes.length > _windowSize) {
      _activeStrokeTimes.removeFirst();
    }
  }

  /// Average active stroke paint time over the rolling window.
  double get activeStrokePaintAvgUs {
    if (_activeStrokeTimes.isEmpty) return 0;
    int sum = 0;
    for (final t in _activeStrokeTimes) {
      sum += t;
    }
    return sum / _activeStrokeTimes.length;
  }

  /// Max active stroke paint time in the rolling window.
  int get activeStrokePaintMaxUs {
    if (_activeStrokeTimes.isEmpty) return 0;
    int max = 0;
    for (final t in _activeStrokeTimes) {
      if (t > max) max = t;
    }
    return max;
  }

  // ---------------------------------------------------------------------------
  // Committed strokes (Layer 2)
  // ---------------------------------------------------------------------------

  /// Last committed strokes paint time in microseconds.
  int committedPaintUs = 0;

  /// Type of last committed paint: 'hit', 'incr', 'full'.
  String committedPaintType = '-';

  /// Number of strokes rendered in the last full rebuild.
  int committedStrokeCount = 0;

  /// Total spine points across all strokes in the last full rebuild.
  int committedSpinePointTotal = 0;

  /// Total saveLayer calls in the last committed paint.
  int committedSaveLayerCount = 0;

  // ---------------------------------------------------------------------------
  // Per-stroke rendering stats (updated by renderStroke)
  // ---------------------------------------------------------------------------

  /// Spine points generated in the last renderStroke call.
  int lastStrokeSpinePoints = 0;

  /// Chunk count in the last pencil renderStroke call.
  int lastStrokeChunkCount = 0;

  // ---------------------------------------------------------------------------
  // Frame timing
  // ---------------------------------------------------------------------------

  /// Timestamp of the last active stroke paint start.
  int _lastFrameStartUs = 0;

  /// Inter-frame interval in microseconds.
  int frameDeltaUs = 0;

  void markFrameStart() {
    final now = DateTime.now().microsecondsSinceEpoch;
    if (_lastFrameStartUs > 0) {
      frameDeltaUs = now - _lastFrameStartUs;
    }
    _lastFrameStartUs = now;
  }

  /// Estimated FPS from frame delta.
  double get estimatedFps {
    if (frameDeltaUs <= 0) return 0;
    return 1000000.0 / frameDeltaUs;
  }

  // ---------------------------------------------------------------------------
  // Reset
  // ---------------------------------------------------------------------------

  void resetActiveStroke() {
    activeStrokePaintUs = 0;
    inflightPointCount = 0;
    inflightSpinePointCount = 0;
    inflightSaveLayerCount = 0;
    _activeStrokeTimes.clear();
    _lastFrameStartUs = 0;
    frameDeltaUs = 0;
  }
}
