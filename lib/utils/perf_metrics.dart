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

  /// Rolling window of recent committed paint times for averaging.
  final _committedPaintTimes = Queue<int>();

  void recordCommittedPaint(int microseconds) {
    committedPaintUs = microseconds;
    _committedPaintTimes.addLast(microseconds);
    while (_committedPaintTimes.length > _windowSize) {
      _committedPaintTimes.removeFirst();
    }
  }

  /// Average committed paint time over the rolling window.
  double get committedPaintAvgUs {
    if (_committedPaintTimes.isEmpty) return 0;
    int sum = 0;
    for (final t in _committedPaintTimes) {
      sum += t;
    }
    return sum / _committedPaintTimes.length;
  }

  /// Max committed paint time in the rolling window.
  int get committedPaintMaxUs {
    if (_committedPaintTimes.isEmpty) return 0;
    int max = 0;
    for (final t in _committedPaintTimes) {
      if (t > max) max = t;
    }
    return max;
  }

  // ---------------------------------------------------------------------------
  // Tile cache stats (per paint call)
  // ---------------------------------------------------------------------------

  /// Tiles served from cache this paint.
  int tileCacheHits = 0;

  /// Tiles that missed cache this paint.
  int tileCacheMisses = 0;

  /// Miss reason: tile not in cache at all.
  int tileMissAbsent = 0;

  /// Miss reason: stale version.
  int tileMissVersion = 0;

  /// Miss reason: wrong pixel resolution.
  int tileMissResolution = 0;

  /// Total time rendering all missed tiles this paint (µs).
  int tileRenderTotalUs = 0;

  /// Slowest single tile render this paint (µs).
  int tileRenderMaxUs = 0;

  /// Number of tiles rendered (not cached) this paint.
  int tileRenderCount = 0;

  /// Time spent blitting tiles to canvas this paint (µs).
  int tileBlitUs = 0;

  /// Total visible tiles in viewport this paint.
  int tileVisibleCount = 0;

  /// Reset per-paint tile stats (call at start of each paint).
  void resetTileStats() {
    tileCacheHits = 0;
    tileCacheMisses = 0;
    tileMissAbsent = 0;
    tileMissVersion = 0;
    tileMissResolution = 0;
    tileRenderTotalUs = 0;
    tileRenderMaxUs = 0;
    tileRenderCount = 0;
    tileBlitUs = 0;
    tileVisibleCount = 0;
  }

  // ---------------------------------------------------------------------------
  // Pinch gesture timing
  // ---------------------------------------------------------------------------

  /// Frames rendered during the current/last pinch gesture.
  int pinchFrameCount = 0;

  /// Total pinch gesture duration (ms).
  int pinchDurationMs = 0;

  /// Timestamp (µs) when current pinch started.
  int pinchStartUs = 0;

  /// Time of the first committed paint after pinch end (µs).
  int postPinchPaintUs = 0;

  /// Tiles rendered in the first paint after pinch end.
  int postPinchTilesRendered = 0;

  /// Flag: set true by _endPinch(), cleared after first committed paint.
  bool pinchEndPending = false;

  /// Whether zoom changed during the last pinch (vs pure pan).
  bool pinchZoomChanged = false;

  void resetPinchStats() {
    pinchFrameCount = 0;
    pinchDurationMs = 0;
    pinchStartUs = DateTime.now().microsecondsSinceEpoch;
    postPinchPaintUs = 0;
    postPinchTilesRendered = 0;
    pinchEndPending = false;
    pinchZoomChanged = false;
  }

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
