import 'dart:typed_data';
import 'dart:ui';

import 'stroke_point.dart';

/// A compact render-tier point: (x, y, pressure) normalized to 0.0–1.0.
///
/// This is the primary data type for rendering and sync. Raw sensor data
/// (tilt, twist, timestamp) stays in [StrokePoint] for archival only.
///
/// ## Storage Format
///
/// 3 × Float32 = 12 bytes per point (vs 32 bytes for StrokePoint).
/// A 40-point fitted stroke ≈ 480 bytes (vs ~6.4 KB raw).
class RenderPoint {
  /// Horizontal position, normalized 0.0–1.0 relative to canvas width.
  final double x;

  /// Vertical position, normalized 0.0–1.0 relative to canvas height.
  final double y;

  /// Stylus pressure. 0.0 = no contact, 1.0 = maximum pressure.
  final double pressure;

  /// Size in bytes of one packed RenderPoint.
  static const int packedSize = 12; // 3 × Float32

  const RenderPoint({
    required this.x,
    required this.y,
    required this.pressure,
  });

  /// Create from a raw [StrokePoint] by normalizing device coordinates.
  factory RenderPoint.fromStrokePoint(
    StrokePoint sp, {
    required double canvasWidth,
    required double canvasHeight,
  }) {
    return RenderPoint(
      x: canvasWidth > 0 ? sp.x / canvasWidth : 0.0,
      y: canvasHeight > 0 ? sp.y / canvasHeight : 0.0,
      pressure: sp.pressure,
    );
  }

  /// Denormalize to device coordinates for rendering.
  Offset toCanvas(double canvasWidth, double canvasHeight) {
    return Offset(x * canvasWidth, y * canvasHeight);
  }

  // --- Binary serialization (12 bytes) ---

  /// Pack this point into [packedSize] bytes (little-endian Float32).
  ///
  /// Layout:
  /// - Bytes  0–3:  x        (Float32)
  /// - Bytes  4–7:  y        (Float32)
  /// - Bytes  8–11: pressure (Float32)
  Uint8List toBytes() {
    final data = ByteData(packedSize);
    data.setFloat32(0, x.toDouble(), Endian.little);
    data.setFloat32(4, y.toDouble(), Endian.little);
    data.setFloat32(8, pressure.toDouble(), Endian.little);
    return data.buffer.asUint8List();
  }

  /// Unpack a RenderPoint from [packedSize] bytes.
  factory RenderPoint.fromBytes(Uint8List bytes, [int offset = 0]) {
    final data = ByteData.sublistView(bytes, offset, offset + packedSize);
    return RenderPoint(
      x: data.getFloat32(0, Endian.little).toDouble(),
      y: data.getFloat32(4, Endian.little).toDouble(),
      pressure: data.getFloat32(8, Endian.little).toDouble(),
    );
  }

  /// Pack a list of RenderPoints into a single binary blob.
  static Uint8List packAll(List<RenderPoint> points) {
    final blob = Uint8List(points.length * packedSize);
    for (int i = 0; i < points.length; i++) {
      blob.setRange(
          i * packedSize, (i + 1) * packedSize, points[i].toBytes());
    }
    return blob;
  }

  /// Unpack a binary blob into a list of RenderPoints.
  static List<RenderPoint> unpackAll(Uint8List blob) {
    final count = blob.length ~/ packedSize;
    return List.generate(
        count, (i) => RenderPoint.fromBytes(blob, i * packedSize));
  }

  // --- JSON serialization ---

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'pressure': pressure,
      };

  factory RenderPoint.fromJson(Map<String, dynamic> json) => RenderPoint(
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        pressure: (json['pressure'] as num).toDouble(),
      );

  // --- Equality ---

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RenderPoint &&
          _f32Equal(x, other.x) &&
          _f32Equal(y, other.y) &&
          _f32Equal(pressure, other.pressure);

  @override
  int get hashCode => Object.hash(x.hashCode, y.hashCode, pressure.hashCode);

  @override
  String toString() =>
      'RenderPoint(x: ${x.toStringAsFixed(4)}, y: ${y.toStringAsFixed(4)}, p: ${pressure.toStringAsFixed(3)})';

  /// Compare two doubles at Float32 precision.
  static bool _f32Equal(double a, double b) {
    final f32 = Float32List(2);
    f32[0] = a;
    f32[1] = b;
    return f32[0] == f32[1];
  }
}
