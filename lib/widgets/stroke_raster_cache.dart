import 'dart:ui' as ui;

/// Caches committed strokes as a raster [ui.Image] to avoid re-rendering
/// all strokes on every [strokeVersion] change.
///
/// Supports two update modes:
/// - **Incremental**: when the version is exactly 1 behind, the caller
///   can composite the old image with just the newly appended stroke.
/// - **Full rebuild**: for undo/erase/clear/load, the caller re-renders
///   all strokes from scratch.
///
/// Owned by [_CanvasWidgetState] and passed to [CommittedStrokesPainter].
class StrokeRasterCache {
  ui.Image? _image;
  int _version = -1;
  ui.Size _size = ui.Size.zero;
  int _paramHash = 0;

  /// The cached raster image, or null if no cache exists.
  ui.Image? get image => _image;

  /// The stroke version this cache was built for.
  int get version => _version;

  /// Whether the cache is valid for the given version, size, and params.
  bool isValid(int version, ui.Size size, int paramHash) =>
      _image != null &&
      _version == version &&
      _size == size &&
      _paramHash == paramHash;

  /// Whether the cache can be incrementally updated (exactly 1 version behind).
  bool canIncrement(int version, ui.Size size, int paramHash) =>
      _image != null &&
      _version == version - 1 &&
      _size == size &&
      _paramHash == paramHash;

  /// Replace the cached image. Disposes the old image if present.
  void update(ui.Image newImage, int version, ui.Size size, int paramHash) {
    _image?.dispose();
    _image = newImage;
    _version = version;
    _size = size;
    _paramHash = paramHash;
  }

  /// Invalidate the cache (e.g. on page switch). Disposes the image.
  void invalidate() {
    _image?.dispose();
    _image = null;
    _version = -1;
  }

  /// Dispose the cache and free GPU memory.
  void dispose() {
    _image?.dispose();
    _image = null;
  }
}
