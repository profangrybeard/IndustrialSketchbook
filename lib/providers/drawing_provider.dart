import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/drawing_service.dart';

/// Provides the [DrawingService] for the active canvas.
///
/// The DrawingService manages the in-flight stroke and committed stroke
/// list for the current page. It runs on the UI thread and is latency
/// critical (TDD §4.1).
///
/// Uses [ChangeNotifierProvider] so that widgets watching this provider
/// automatically rebuild when strokes change (pointer down/move/up).
final drawingServiceProvider = ChangeNotifierProvider<DrawingService>((ref) {
  return DrawingService();
});
