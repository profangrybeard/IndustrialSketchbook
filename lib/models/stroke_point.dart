import 'dart:typed_data';

/// A single sample from the stylus sensor pipeline (TDD §3.1).
///
/// Immutable once captured. This is the atomic unit of the stroke log.
///
/// ## Storage Format
///
/// Points are stored as packed binary blobs in SQLite.
/// Layout: 6 x Float32 + 1 x Int64 = 32 bytes per point.
///
/// Note: The TDD states 28 bytes but the field layout (6 x Float32 + 1 x Int64)
/// yields 32 bytes (24 + 8). This implementation follows the field layout.
/// A 50-point stroke ≈ 1.6 KB.
class StrokePoint {
  /// Horizontal position in infinite canvas space.
  final double x;

  /// Vertical position in infinite canvas space.
  final double y;

  /// Stylus pressure. 0.0 = no contact, 1.0 = maximum pressure.
  final double pressure;

  /// Side tilt of stylus in degrees (-90 to 90).
  final double tiltX;

  /// Forward/back tilt of stylus in degrees (-90 to 90).
  final double tiltY;

  /// Barrel rotation in degrees (0 to 360). Hardware-dependent.
  final double twist;

  /// Microseconds since epoch. Required for ML Kit ink recognition ordering.
  final int timestamp;

  /// Size in bytes of one packed StrokePoint.
  static const int packedSize = 32; // 6 x Float32 (24) + 1 x Int64 (8)

  const StrokePoint({
    required this.x,
    required this.y,
    required this.pressure,
    required this.tiltX,
    required this.tiltY,
    required this.twist,
    required this.timestamp,
  });

  /// Pack this point into [packedSize] bytes.
  ///
  /// Binary layout (little-endian):
  /// - Bytes  0–3:  x        (Float32)
  /// - Bytes  4–7:  y        (Float32)
  /// - Bytes  8–11: pressure (Float32)
  /// - Bytes 12–15: tiltX    (Float32)
  /// - Bytes 16–19: tiltY    (Float32)
  /// - Bytes 20–23: twist    (Float32)
  /// - Bytes 24–31: timestamp (Int64)
  Uint8List toBytes() {
    final data = ByteData(packedSize);
    data.setFloat32(0, x.toDouble(), Endian.little);
    data.setFloat32(4, y.toDouble(), Endian.little);
    data.setFloat32(8, pressure.toDouble(), Endian.little);
    data.setFloat32(12, tiltX.toDouble(), Endian.little);
    data.setFloat32(16, tiltY.toDouble(), Endian.little);
    data.setFloat32(20, twist.toDouble(), Endian.little);
    data.setInt64(24, timestamp, Endian.little);
    return data.buffer.asUint8List();
  }

  /// Unpack a StrokePoint from [packedSize] bytes.
  factory StrokePoint.fromBytes(Uint8List bytes, [int offset = 0]) {
    final data = ByteData.sublistView(bytes, offset, offset + packedSize);
    return StrokePoint(
      x: data.getFloat32(0, Endian.little).toDouble(),
      y: data.getFloat32(4, Endian.little).toDouble(),
      pressure: data.getFloat32(8, Endian.little).toDouble(),
      tiltX: data.getFloat32(12, Endian.little).toDouble(),
      tiltY: data.getFloat32(16, Endian.little).toDouble(),
      twist: data.getFloat32(20, Endian.little).toDouble(),
      timestamp: data.getInt64(24, Endian.little),
    );
  }

  /// Pack a list of StrokePoints into a single binary blob.
  static Uint8List packAll(List<StrokePoint> points) {
    final blob = Uint8List(points.length * packedSize);
    for (int i = 0; i < points.length; i++) {
      blob.setRange(
          i * packedSize, (i + 1) * packedSize, points[i].toBytes());
    }
    return blob;
  }

  /// Unpack a binary blob into a list of StrokePoints.
  static List<StrokePoint> unpackAll(Uint8List blob) {
    final count = blob.length ~/ packedSize;
    return List.generate(count, (i) => StrokePoint.fromBytes(blob, i * packedSize));
  }

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'pressure': pressure,
        'tiltX': tiltX,
        'tiltY': tiltY,
        'twist': twist,
        'timestamp': timestamp,
      };

  factory StrokePoint.fromJson(Map<String, dynamic> json) => StrokePoint(
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        pressure: (json['pressure'] as num).toDouble(),
        tiltX: (json['tiltX'] as num).toDouble(),
        tiltY: (json['tiltY'] as num).toDouble(),
        twist: (json['twist'] as num).toDouble(),
        timestamp: json['timestamp'] as int,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StrokePoint &&
          // Compare at Float32 precision since binary packing uses Float32
          _f32Equal(x, other.x) &&
          _f32Equal(y, other.y) &&
          _f32Equal(pressure, other.pressure) &&
          _f32Equal(tiltX, other.tiltX) &&
          _f32Equal(tiltY, other.tiltY) &&
          _f32Equal(twist, other.twist) &&
          timestamp == other.timestamp;

  @override
  int get hashCode => Object.hash(
        x.hashCode,
        y.hashCode,
        pressure.hashCode,
        timestamp,
      );

  @override
  String toString() =>
      'StrokePoint(x: $x, y: $y, p: $pressure, t: $timestamp)';

  /// Compare two doubles at Float32 precision.
  static bool _f32Equal(double a, double b) {
    // Convert both to Float32 and back to normalize precision
    final f32 = Float32List(2);
    f32[0] = a;
    f32[1] = b;
    return f32[0] == f32[1];
  }
}
