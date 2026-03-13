import 'dart:typed_data';

/// A pre-computed spine point from Catmull-Rom subdivision.
///
/// Stores the interpolated position and pressure at each subdivision sample.
/// Computed once at pen-up and stored in SQLite as a binary blob to skip
/// expensive Catmull-Rom subdivision on page load (Option A performance fix).
///
/// ## Storage Format
///
/// Points are stored as packed binary blobs in SQLite.
/// Layout: 3 × Float32 = 12 bytes per point.
class SpinePoint {
  /// X position in canvas coordinates.
  final double x;

  /// Y position in canvas coordinates.
  final double y;

  /// Interpolated pressure (0.0–1.0) at this spine position.
  ///
  /// We store pressure rather than halfWidth because halfWidth depends on
  /// global rendering params (pressureMode, stroke.weight) that can change.
  /// Storing pressure keeps spine blobs valid regardless of render settings.
  final double pressure;

  /// Size in bytes of one packed SpinePoint.
  static const int packedSize = 12; // 3 × Float32

  const SpinePoint(this.x, this.y, this.pressure);

  /// Pack this point into [packedSize] bytes.
  ///
  /// Binary layout (little-endian):
  /// - Bytes 0–3:  x        (Float32)
  /// - Bytes 4–7:  y        (Float32)
  /// - Bytes 8–11: pressure (Float32)
  Uint8List toBytes() {
    final data = ByteData(packedSize);
    data.setFloat32(0, x.toDouble(), Endian.little);
    data.setFloat32(4, y.toDouble(), Endian.little);
    data.setFloat32(8, pressure.toDouble(), Endian.little);
    return data.buffer.asUint8List();
  }

  /// Unpack a SpinePoint from [packedSize] bytes.
  factory SpinePoint.fromBytes(Uint8List bytes, [int offset = 0]) {
    final data = ByteData.sublistView(bytes, offset, offset + packedSize);
    return SpinePoint(
      data.getFloat32(0, Endian.little).toDouble(),
      data.getFloat32(4, Endian.little).toDouble(),
      data.getFloat32(8, Endian.little).toDouble(),
    );
  }

  /// Pack a list of SpinePoints into a single binary blob.
  static Uint8List packAll(List<SpinePoint> points) {
    final blob = Uint8List(points.length * packedSize);
    for (int i = 0; i < points.length; i++) {
      blob.setRange(
          i * packedSize, (i + 1) * packedSize, points[i].toBytes());
    }
    return blob;
  }

  /// Unpack a binary blob into a list of SpinePoints.
  static List<SpinePoint> unpackAll(Uint8List blob) {
    final count = blob.length ~/ packedSize;
    return List.generate(
        count, (i) => SpinePoint.fromBytes(blob, i * packedSize));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SpinePoint &&
          _f32Equal(x, other.x) &&
          _f32Equal(y, other.y) &&
          _f32Equal(pressure, other.pressure);

  @override
  int get hashCode => Object.hash(x, y, pressure);

  @override
  String toString() => 'SpinePoint(x: $x, y: $y, p: $pressure)';

  /// Compare two doubles at Float32 precision.
  static bool _f32Equal(double a, double b) {
    final f32 = Float32List(2);
    f32[0] = a;
    f32[1] = b;
    return f32[0] == f32[1];
  }
}
