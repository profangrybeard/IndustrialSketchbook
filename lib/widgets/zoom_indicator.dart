import 'package:flutter/material.dart';

/// Floating pill that shows the current zoom level and resets on tap.
///
/// Appears at bottom-center of the canvas when zoomed away from 1.0x
/// or during an active pinch gesture. Matches the floating palette's
/// dark semi-transparent aesthetic.
class ZoomIndicator extends StatelessWidget {
  const ZoomIndicator({
    required this.zoom,
    required this.onResetTap,
    super.key,
  });

  /// Current zoom factor (1.0 = 100%).
  final double zoom;

  /// Called when the user taps to reset zoom.
  final VoidCallback onResetTap;

  @override
  Widget build(BuildContext context) {
    final pct = (zoom * 100).round();

    return GestureDetector(
      onTap: onResetTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xBF1A1A1A),
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Color(0x4D000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$pct%',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
              ),
            ),
            if (zoom != 1.0) ...[
              const SizedBox(width: 6),
              const Icon(
                Icons.filter_center_focus,
                color: Colors.white54,
                size: 15,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
