import 'dart:ui';

import 'package:flutter/rendering.dart' show Matrix4;

/// Camera model for the infinite canvas.
///
/// Replaces the old `_canvasScale` / `_canvasOffset` pair with a proper
/// world-coordinate camera. The camera defines which portion of the infinite
/// world is visible on screen.
///
/// Coordinate system:
/// - **World space**: where strokes live. Origin (0,0) is the "home" position.
///   Strokes can exist at negative coordinates (infinite pan).
/// - **Screen space**: Flutter widget coordinates (0,0 = top-left of canvas).
class Camera {
  /// Top-left corner of the viewport in world coordinates.
  Offset topLeft;

  /// Zoom factor. 1.0 = 100%. Range: [minZoom, maxZoom].
  double zoom;

  static const double minZoom = 0.05;
  static const double maxZoom = 20.0;

  Camera({this.topLeft = Offset.zero, this.zoom = 1.0});

  /// Create a copy of this camera.
  Camera copy() => Camera(topLeft: topLeft, zoom: zoom);

  /// The world-space rectangle visible through the viewport.
  Rect viewportRect(Size screenSize) => Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy,
        screenSize.width / zoom,
        screenSize.height / zoom,
      );

  /// Convert a screen-space point to world-space.
  Offset screenToWorld(Offset screen) => Offset(
        screen.dx / zoom + topLeft.dx,
        screen.dy / zoom + topLeft.dy,
      );

  /// Convert a world-space point to screen-space.
  Offset worldToScreen(Offset world) => Offset(
        (world.dx - topLeft.dx) * zoom,
        (world.dy - topLeft.dy) * zoom,
      );

  /// The transform matrix for Flutter's [Transform] widget.
  ///
  /// Applies zoom then translates so that [topLeft] maps to screen origin.
  Matrix4 get matrix => Matrix4.identity()
    ..scale(zoom, zoom)
    ..translate(-topLeft.dx, -topLeft.dy);
}
