# Phase 2.6: Inline Color Picker, Pressure Modes & Realistic Pencil

## Context

Phase 2.5 (floating palette, grid improvements, pencil leads, eraser toggle, partial erasing) is complete and deployed on the OnePlus Pad. Three UX issues remain:

1. **Color picker as dialog is awkward** — Opening a center-screen dialog while the palette floats at the edge breaks the workflow. Color selection should be inline in the palette bar like all other sub-panels.
2. **Pressure only controls width** — Pencil pressure should optionally control width, opacity, or both.
3. **Pencil doesn't feel like a pencil** — No texture, no tilt response, no grain. The stylus captures pressure, tiltX, tiltY, twist, and timestamps, but rendering only uses pressure→width with a flat 30% opacity reduction.

---

## Step 1: Inline Color Picker Sub-Panel

**Goal:** Move color selection from `showDialog()` into a palette sub-panel (click, choose, close — all from the bar).

### `lib/widgets/floating_palette.dart`
- Add `color` to `_SubPanel` enum: `enum _SubPanel { tool, color, weight, grid }`
- Add `_buildColorPanel()` method returning a compact HSV picker:
  - Color preview swatch (30px tall, full width)
  - Hue slider (0–360) — compact, no label (use colored track)
  - Saturation slider (0–1)
  - Brightness slider (0–1)
  - Quick presets row: 8 color circles (black, white, red, blue, green, yellow, orange, purple) — wrap to 2 rows of 4 to fit 200px
- Add HSV state to `_FloatingPaletteState`: `late HSVColor _hsv` initialized from `widget.currentColor`
- On any slider change: update `_hsv` state, immediately call `widget.onColorChanged(color.toARGB32())` (no cancel/select buttons needed — live preview)
- Sync `_hsv` when `widget.currentColor` changes externally (in `didUpdateWidget`)
- Change `_ColorSwatch.onTap` from `_showColorPicker()` to `_togglePanel(_SubPanel.color)`
- Remove `_showColorPicker()` method and the `import` of `color_wheel_dialog.dart`

### `lib/widgets/color_wheel_dialog.dart`
- Keep file for now (no breaking changes) but it will be unused

### Sub-panel width
- The current sub-panel `maxWidth: 200` is sufficient — the hue/sat/brightness sliders can use ~180px width (same as weight slider). Quick presets in 2x4 grid fit within 180px.

---

## Step 2: Pressure Mode (Width / Opacity / Both)

**Goal:** Let users choose whether stylus pressure affects stroke width, opacity, or both.

### New: `lib/models/pressure_mode.dart`
```dart
enum PressureMode {
  width(label: 'Width'),
  opacity(label: 'Opacity'),
  both(label: 'Both');
}
```

### `lib/services/drawing_service.dart`
- Add `PressureMode _pressureMode = PressureMode.width` with getter/setter
- Setter calls `notifyListeners()` on change
- No change to stroke data model — pressure mode is a rendering concern, not a data concern

### `lib/widgets/sketch_painter.dart` — `_drawStroke()` changes
- Accept `PressureMode pressureMode` as a constructor parameter
- In the multi-point rendering loop, apply pressure based on mode:
  - **Width mode** (current behavior): `strokeWidth = weight * max(avgPressure, 0.1)`, full opacity
  - **Opacity mode**: fixed `strokeWidth = weight`, `paint.color = color.withValues(alpha: baseAlpha * max(avgPressure, 0.1))`
  - **Both mode**: pressure affects both width AND opacity simultaneously
- Single-point strokes (taps): apply the same logic to radius and fill opacity

### `lib/widgets/floating_palette.dart`
- Add `pressureMode` and `onPressureModeChanged` props
- In `_buildToolPanel()`, when pencil is selected, add a "Pressure" section below leads:
  - Three small chips: "Width" / "Opacity" / "Both" (reuse `_GridStyleChip` pattern)

### `lib/widgets/canvas_widget.dart`
- Pass `pressureMode` from `drawingService.pressureMode` to both `SketchPainter` and `FloatingPalette`
- Wire `onPressureModeChanged` callback

---

## Step 3: Realistic Pencil Rendering

**Goal:** Make the pencil tool feel like graphite on paper — grain texture, tilt-based shading, non-linear pressure response, velocity sensitivity.

### 3a. Non-linear pressure curve (resistance feel)
**File:** `lib/widgets/sketch_painter.dart`

Replace linear pressure mapping with a power curve for pencil strokes:
```dart
double _pencilPressure(double rawPressure) {
  // Power curve: light touches stay very light, heavy pressure saturates
  return math.pow(rawPressure.clamp(0.0, 1.0), 1.8).toDouble();
}
```
- Only applied when `stroke.tool == ToolType.pencil`
- Other tools keep linear pressure
- The exponent 1.8 gives a natural graphite feel — light sketching is subtle, pressing hard gives bold marks

### 3b. Tilt-based width variation (shading)
**File:** `lib/widgets/sketch_painter.dart`

Use `StrokePoint.tiltX` to widen the stroke when the pencil tilts to its side:
```dart
double _tiltWidthMultiplier(double tiltX) {
  // tiltX is in degrees. At 0° (upright), multiplier = 1.0
  // At ±45°+, multiplier grows up to 3.0 (flat shading)
  final tiltFraction = (tiltX.abs() / 60.0).clamp(0.0, 1.0);
  return 1.0 + tiltFraction * 2.0;
}
```
- Only for pencil tool
- Applied as: `effectiveWidth = baseWidth * tiltMultiplier`
- Combined with pressure: `width = weight * pencilPressure * tiltMultiplier`
- Tilt also reduces opacity slightly (flat pencil = lighter marks): `alpha *= (1.0 - tiltFraction * 0.3)`

### 3c. Pencil grain texture (paper drag)
**File:** `lib/widgets/sketch_painter.dart`

Add per-segment opacity variation to simulate graphite texture:
```dart
double _grainFactor(double x, double y) {
  // Deterministic pseudo-random based on position
  // Creates a stable grain pattern that doesn't shimmer on repaint
  final hash = ((x * 73.0 + y * 179.0) % 1.0).abs();
  return 0.7 + hash * 0.3; // 70%–100% opacity variation
}
```
- Applied as a multiplier on stroke alpha for each segment
- Position-based so grain is stable across repaints (no shimmer)
- Only for pencil tool — other tools render clean

### 3d. Velocity-based lightening (fast strokes skip)
**File:** `lib/widgets/sketch_painter.dart`

Use timestamp deltas between consecutive points to compute drawing speed:
```dart
double _velocityFactor(StrokePoint p0, StrokePoint p1) {
  final dt = (p1.timestamp - p0.timestamp).abs();
  if (dt <= 0) return 1.0;
  final dx = p1.x - p0.x;
  final dy = p1.y - p0.y;
  final dist = math.sqrt(dx * dx + dy * dy);
  final velocity = dist / (dt / 1000.0); // pixels per millisecond
  // Fast strokes (>2.0 px/ms) lighten; slow strokes stay full
  final factor = (1.0 - ((velocity - 1.0) / 3.0).clamp(0.0, 0.4));
  return factor.clamp(0.6, 1.0);
}
```
- Fast strokes = pencil skipping over paper = lighter, thinner
- Slow strokes = graphite depositing = darker, full width
- Only for pencil tool

### 3e. Combined pencil rendering in `_drawStroke()`

The pencil branch of `_drawStroke()` becomes:
```
For each segment (p0 → p1):
  1. avgPressure = (p0.pressure + p1.pressure) / 2
  2. pencilP = pow(avgPressure, 1.8)              // non-linear curve
  3. tiltMult = tiltWidthMultiplier(avg tiltX)     // tilt-based shading
  4. grain = grainFactor(avg x, avg y)             // texture
  5. velocity = velocityFactor(p0, p1)             // speed sensitivity

  Width  = weight * pencilP * tiltMult             // (or fixed if opacity-only mode)
  Alpha  = baseAlpha * 0.7 * pencilP * grain * velocity * (1 - tiltFade)
                                                   // (depending on pressure mode)
```

### `lib/models/pencil_lead.dart` — Add grain intensity
- Add `grainIntensity` field (0.0–1.0) to `PencilLead`:
  - Fine (HB): 0.15 (subtle grain — hard graphite)
  - Medium (2B): 0.25
  - Bold (4B): 0.30
  - Soft (6B): 0.40 (heavy grain — soft graphite catches paper texture)
- Grain intensity scales the range of `_grainFactor` variation

---

## Files Modified/Created

| File | Action |
|------|--------|
| `lib/widgets/floating_palette.dart` | Modify — add `_SubPanel.color`, `_buildColorPanel()`, inline HSV state, pressure mode chips |
| `lib/models/pressure_mode.dart` | **Create** — `PressureMode` enum |
| `lib/services/drawing_service.dart` | Modify — add `pressureMode` property |
| `lib/widgets/sketch_painter.dart` | Modify — pressure mode support, pencil rendering (grain, tilt, velocity, pressure curve) |
| `lib/models/pencil_lead.dart` | Modify — add `grainIntensity` field |
| `lib/widgets/canvas_widget.dart` | Modify — wire pressure mode through to painter and palette |
| `test/services/drawing_service_test.dart` | Modify — add pressure mode tests |
| `test/widgets/sketch_painter_test.dart` | **Create** — test pencil rendering helpers (pressure curve, tilt, grain, velocity) |

---

## Verification

1. `flutter test` — all 69 existing tests pass + new tests for pressure mode and pencil rendering helpers
2. Deploy to OnePlus Pad and verify:
   - **Color picker**: Tap color swatch → sub-panel opens inline with hue/sat/brightness sliders + presets. No dialog. Live preview while sliding.
   - **Pressure modes**: Switch between Width/Opacity/Both in tool panel. Width mode = current behavior. Opacity mode = consistent width, pressure varies transparency. Both = pressure varies both.
   - **Pencil grain**: Light strokes show subtle texture variation (not uniform color). Grain is stable across repaints (no shimmer).
   - **Tilt shading**: Tilting stylus sideways widens the stroke and lightens opacity (flat shading effect).
   - **Pressure curve**: Very light touches produce barely-visible marks. Medium pressure gives clean lines. Hard pressing gives bold, dark strokes. Non-linear ramp provides "resistance" feel.
   - **Velocity**: Fast sketching produces lighter marks than slow deliberate strokes.
   - **Lead presets**: Each lead type has distinct grain intensity (Fine = smooth, Soft = textured).
