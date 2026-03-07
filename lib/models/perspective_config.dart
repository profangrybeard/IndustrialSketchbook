import 'dart:ui';

/// Vanishing point definition for perspective drawing (TDD §5.6).
class VanishingPoint {
  final double x;
  final double y;

  const VanishingPoint({required this.x, required this.y});

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  factory VanishingPoint.fromJson(Map<String, dynamic> json) => VanishingPoint(
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VanishingPoint && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'VanishingPoint($x, $y)';
}

/// Perspective drawing configuration (TDD §3.3, §5.6).
///
/// Stored per page when [PageStyle] is perspective.
/// Test PER-001 requires JSON serialization round-trip fidelity.
class PerspectiveConfig {
  /// 1-point or 2-point perspective vanishing points.
  final List<VanishingPoint> vanishingPoints;

  /// Horizon line Y coordinate in canvas space.
  final double horizonY;

  const PerspectiveConfig({
    required this.vanishingPoints,
    required this.horizonY,
  });

  /// Number of vanishing points (1 or 2 for v1).
  int get pointCount => vanishingPoints.length;

  Map<String, dynamic> toJson() => {
        'vanishingPoints': vanishingPoints.map((vp) => vp.toJson()).toList(),
        'horizonY': horizonY,
      };

  factory PerspectiveConfig.fromJson(Map<String, dynamic> json) {
    final vpList = (json['vanishingPoints'] as List)
        .map((vp) => VanishingPoint.fromJson(vp as Map<String, dynamic>))
        .toList();
    return PerspectiveConfig(
      vanishingPoints: vpList,
      horizonY: (json['horizonY'] as num).toDouble(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! PerspectiveConfig) return false;
    if (horizonY != other.horizonY) return false;
    if (vanishingPoints.length != other.vanishingPoints.length) return false;
    for (int i = 0; i < vanishingPoints.length; i++) {
      if (vanishingPoints[i] != other.vanishingPoints[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(vanishingPoints),
        horizonY,
      );

  @override
  String toString() =>
      'PerspectiveConfig(${pointCount}-point, horizonY: $horizonY)';
}
