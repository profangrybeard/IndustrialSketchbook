import 'dart:ui';

/// Device-independent coordinate conversion using a fixed reference width.
///
/// All strokes are stored in "reference units" where 1000.0 = one device
/// logical screen width. This makes strokes portable across devices:
/// a stroke drawn on a 412px-wide phone and a 1200px-wide tablet produce
/// the same reference-unit values.
///
/// Conversion uses a single scale factor (device width / 1000) for both
/// axes, preserving aspect ratio.
///
/// ## Usage
///
/// Call [initialize] once at startup before any DB reads:
/// ```dart
/// CoordinateUtils.initialize(MediaQuery.of(context).size.width);
/// ```
class CoordinateUtils {
  CoordinateUtils._();

  /// The fixed reference width in logical units.
  ///
  /// 1000 is chosen because it's the same order of magnitude as real device
  /// widths (412 phone, 1200 tablet), keeping values human-readable.
  static const double referenceWidth = 1000.0;

  /// Scale factor: `deviceLogicalWidth / referenceWidth`.
  ///
  /// Multiply reference-unit values by this to get world coordinates.
  /// Divide world-coordinate values by this to get reference units.
  static double _referenceScale = 1.0;

  /// Whether [initialize] has been called.
  static bool _initialized = false;

  /// The current reference scale. Throws if not initialized.
  static double get referenceScale {
    assert(_initialized, 'CoordinateUtils.initialize() must be called first');
    return _referenceScale;
  }

  /// Whether the utility has been initialized.
  static bool get isInitialized => _initialized;

  /// Initialize with the device's logical screen width.
  ///
  /// Must be called once at app startup, before any DB reads.
  /// Uses the device's logical width to compute the reference scale.
  /// The same width should be used consistently (don't change on rotation).
  static void initialize(double deviceLogicalWidth) {
    assert(deviceLogicalWidth > 0, 'Device width must be positive');
    _referenceScale = deviceLogicalWidth / referenceWidth;
    _initialized = true;
  }

  /// Initialize from a [FlutterView] (typically `PlatformDispatcher.views.first`).
  ///
  /// Extracts the logical width from the view's physical size and DPR.
  static void initializeFromView(FlutterView view) {
    final logicalWidth = view.physicalSize.width / view.devicePixelRatio;
    initialize(logicalWidth);
  }

  /// Convert a world-coordinate value to reference units.
  static double worldToRef(double world) => world / _referenceScale;

  /// Convert a reference-unit value to world coordinates.
  static double refToWorld(double ref) => ref * _referenceScale;
}
