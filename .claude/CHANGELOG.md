# Industrial Sketchbook — Changelog & Lecture Notes

> **Course:** AI 201 — Advanced AI-Assisted Development
> **Project:** Pressure-sensitive infinite-canvas sketchbook for OnePlus Pad
> **Stack:** Flutter/Dart, Android (arm64), SQLite, Riverpod
> **Hardware:** OnePlus Pad 2 (11.6", 144Hz, stylus w/ 4096 pressure levels)
> **AI Pair:** Claude Code (Opus) — full implementation partner from scaffold to deploy

---

## Option D Phase 2 — Tiled Rendering + Infinite Canvas
**Date:** 2026-03-13 | **Tests:** 405 pass | **Branch:** `claude/stoic-leavitt`

### Problem
The canvas was fixed-size with zoom capped at 1.5x and pan clamped to canvas bounds. Deep zoom for fine detail work was impossible. The single full-page raster cache didn't scale — at high zoom, the entire canvas would need to be rasterized at absurd resolutions. And the spatial grid was bounded to canvas dimensions, preventing strokes at negative or very large coordinates.

### Solution
Four-phase infinite canvas overhaul: Camera system → Unbounded spatial grid → Tiled rendering → Viewport-aware background.

### What changed

**1. Camera model (`lib/models/camera.dart` — NEW)**
- `topLeft` (Offset) + `zoom` (double) replaces `_canvasScale` / `_canvasOffset`
- `screenToWorld()` / `worldToScreen()` / `viewportRect()` / `matrix` for Transform widget
- Zoom range: 0.05x–20.0x. Pan: infinite (no clamping)
- Focal-point-stable pinch: the world point under your pinch stays stationary during zoom

**2. Tiled rendering (`lib/widgets/tile_cache.dart` — NEW)**
- 512×512 world-unit tiles, rasterized to GPU images at resolution matching current zoom
- LRU eviction (max 64 tiles), physical pixel cap of 2048px per tile (prevents GPU memory blowout)
- `invalidateRect(worldRect)` for fine-grained per-mutation invalidation
- Version tracking synced with `strokeVersion` — stale tiles from pre-load paints are automatically purged

**3. Committed strokes painter — complete rewrite**
- Computes visible tile range from camera viewport
- For each tile: check cache → if miss, query spatial grid → render strokes → `toImageSync()` → cache
- World→screen positioning: `screenRect = (tileWorld.left - viewport.left) * zoom`

**4. Frozen pinch rendering — zero tile re-renders during zoom gesture**
- `_renderCamera` freezes at pinch start; tiles stay cached throughout the gesture
- Compensating Transform wraps background + committed layers: `scale(currentZoom/frozenZoom)` + translate
- On pinch end: `_tileCache.clear()` → tiles re-render at new resolution (one-time cost)

**5. Listener moved outside Transform**
- When zoomed out, visible world extends beyond original screen bounds
- Old: Listener inside Transform → hit area limited to screen-sized rect in world space
- New: Listener outside Transform → captures full screen → `_camera.screenToWorld()` for all coordinates

**6. Background LOD (`lib/widgets/background_painter.dart`)**
- Renders only grid dots/lines within camera viewport (not infinite canvas)
- At >4x zoom: grid subdivides (spacing/2). At <0.5x: grid coarsens (spacing×2)
- Dot radius and line width scale with zoom (clamped)

### Critical bugs found and fixed during device testing

| Bug | Root cause | Fix |
|-----|-----------|-----|
| Strokes disappear after load | Empty tiles cached at version=0 before strokes load, returned as cache hits after | `_tileCache.clear()` after `loadStrokes()` + version sync safety net in painter |
| Pinch-to-zoom crawls | Every frame: new zoom → new pixelSize → all tiles miss → synchronous `toImageSync()` | Freeze `_renderCamera` during pinch, compensating Transform for visual zoom |
| Can't draw at zoomed-out edges | Listener inside Transform → hit area bounded to original screen rect in world coords | Move Listener outside Transform, explicit `screenToWorld()` conversion |

### Files
| File | Change |
|------|--------|
| `lib/models/camera.dart` | **NEW** — Camera model |
| `lib/models/tile_key.dart` | **NEW** — Tile grid identifier |
| `lib/widgets/tile_cache.dart` | **NEW** — Per-tile LRU raster cache |
| `lib/utils/spatial_grid.dart` | Unbounded hash-based cell keys (Cantor pairing) |
| `lib/services/drawing_service.dart` | Lazy spatial grid getter |
| `lib/widgets/canvas_widget.dart` | Camera, tiled rendering, frozen pinch, Listener refactor |
| `lib/widgets/committed_strokes_painter.dart` | Tiled rendering with version-synced cache |
| `lib/widgets/background_painter.dart` | Viewport-aware grid with LOD |
| `test/utils/spatial_grid_test.dart` | Updated for unbounded grid |
| `test/widgets/background_painter_test.dart` | Added viewport/zoom params |
| `test/widgets/committed_strokes_painter_test.dart` | Updated for TileCache |

---

## Performance Option A — Pre-Baked Spine Points
**Date:** 2026-03-13 | **Tests:** 383 pass | **Base:** rebased on `main`

### Problem
Heavy drawings (100+ strokes per page) took 10-30+ seconds to load on the Samsung Tab S9 Ultra. The bottleneck: `CommittedStrokesPainter.paint()` ran Catmull-Rom spline subdivision for every committed stroke on the UI thread during each full rebuild. A 200-point stroke generates ~600 spine points via subdivision — pure geometry that never changes once committed.

### Solution
Compute spine subdivision **once at pen-up**, store the result in SQLite as a binary blob, skip subdivision entirely on page load. Cuts ~60-70% of the recording-phase CPU time.

### What changed

**1. New model: `SpinePoint` (x, y, pressure) — 12 bytes packed**
- Stores interpolated pressure (not halfWidth) so spine blobs remain valid when users change pressureMode, weight, or grainIntensity after drawing.
- Binary pack/unpack follows same pattern as StrokePoint and RenderPoint.

**2. `computeSpinePoints()` extracted from rendering loop**
- Public function in `stroke_rendering.dart` consolidates the Catmull-Rom subdivision logic that previously existed inline in both `_renderStandardStroke` and `_renderPencilStroke`.
- Uses `replayTargetArcLength = 3.0` (coarser than live drawing's 0.5px).

**3. Dual rendering path — fast path + fallback**
- When `stroke.spineData` exists: builds ribbon geometry directly from stored (x, y, pressure), computing halfWidth/alpha from current rendering params. Skips the entire Catmull-Rom loop.
- When `stroke.spineData` is null: falls back to on-the-fly subdivision (backward compat for pre-v5 strokes).

**4. DB schema v4 -> v5**
- New `spine_blob BLOB` column on `strokes` table.
- `_onUpgrade` adds column for existing installs. No data migration needed — null triggers fallback.

**5. Pen-up computation + lazy backfill**
- `DrawingService.onPointerUp()` computes spine data and attaches to the committed Stroke.
- `backfillSpines(db)` runs async after `loadStrokes()` — computes and persists spine data for old strokes without blocking page display.

### Files
| File | Change |
|------|--------|
| `lib/models/spine_point.dart` | NEW — 12-byte binary model |
| `lib/models/stroke.dart` | Added `spineData` field, updated toDbMap/fromDbMap |
| `lib/widgets/stroke_rendering.dart` | Extracted `computeSpinePoints()`, dual render path |
| `lib/services/database_service.dart` | Schema v5, spine_blob column, backfill helpers |
| `lib/services/drawing_service.dart` | Compute at pen-up, `backfillSpines()` |
| `lib/widgets/canvas_widget.dart` | Wired backfill calls at both load sites |
| `test/models/spine_point_test.dart` | NEW — pack/unpack round-trip tests |
| `test/widgets/spine_computation_test.dart` | NEW — subdivision regression tests |

---

## Phase 2.6 — Inline Color Picker, Pressure Modes & Realistic Pencil
**Commit:** `5fb92d6` | **Date:** 2025-03-07 | **Tests:** 102 pass

### What changed
Three UX problems solved in a single session:

**1. Color picker moved from dialog to inline sub-panel**
- **Problem:** Tapping the color swatch opened a `showDialog()` in the center of the screen while the palette floated at the edge. Terrible flow for a drawing app.
- **Solution:** Added `_SubPanel.color` to the palette's sub-panel enum. Built a compact HSV picker (hue/saturation/brightness sliders + 8 quick presets) that fits within the existing 200px maxWidth constraint. Live preview — no cancel/select buttons. Color updates as you drag.
- **Key decision:** Kept `color_wheel_dialog.dart` in the repo (unused) rather than deleting it. No breaking changes, easy to revert.

**2. Pressure mode selector (Width / Opacity / Both)**
- **Problem:** Stylus pressure only controlled stroke width. Real pencil pressure also affects how dark the mark is.
- **Solution:** New `PressureMode` enum. Three chips appear in the tool panel when pencil is selected. The renderer branches per-segment based on mode:
  - `width`: classic behavior — pressure varies thickness
  - `opacity`: consistent width, pressure varies transparency
  - `both`: pressure controls both simultaneously
- **Architecture note:** Pressure mode is a rendering-time concern, NOT a data concern. Raw pressure is always captured in `StrokePoint` regardless of mode. This means you can change modes and re-render old strokes differently.

**3. Realistic pencil rendering (4 techniques combined)**

This is the big one. The OnePlus Pad stylus reports pressure (4096 levels), tilt (X and Y in degrees), twist (barrel rotation), and timestamps (microsecond precision). We were capturing ALL of this data in `StrokePoint` since Phase 1 but only using `pressure → width` with a flat 30% opacity reduction. Phase 2.6 activates all the unused sensor data:

- **Non-linear pressure curve** — `pow(pressure, 1.8)` replaces linear mapping. At 0.5 raw pressure, effective is only 0.29. At 0.9 raw, effective is 0.82. This creates the "resistance" feel of real graphite — you have to press deliberately to get bold marks.
- **Tilt-based shading** — `tiltX` (side-to-side stylus angle) widens the stroke up to 3× and reduces opacity by up to 30%. Simulates flat-shading with the side of the pencil lead. At 0° (upright) = normal line. At 60°+ (flat) = wide, light shading stroke.
- **Grain texture** — Deterministic position-based pseudo-random per-segment opacity variation. Creates the look of graphite catching paper texture. Key property: `grainFactor(x, y, intensity)` uses `(x * 73.0 + y * 179.0) % 1.0` — stable across repaints (no shimmer). Each pencil lead has its own grain intensity: Fine HB = 0.15 (smooth), Soft 6B = 0.40 (textured).
- **Velocity sensitivity** — Timestamp deltas between consecutive points give drawing speed. Fast strokes lighten to 60% (pencil skipping over paper). Slow strokes stay at full opacity (graphite depositing).

### AI collaboration notes

**What the human brought:**
- "The color picker pulling up in the middle of the screen is a strange user flow"
- "The pencil pressure should control width and/or opacity optionally"
- "How else can we make the pencil feel more like a pencil? I want resistance, texture, excellent pressure control. I want the paper to have drag even though it's a screen."

**What Claude researched & proposed:**
- Explored the existing sub-panel system to understand the 200px constraint and toggle pattern
- Discovered that tiltX, tiltY, twist, and timestamps were captured but completely unused
- Proposed the 4-technique pencil rendering pipeline (pressure curve + tilt + grain + velocity)
- Designed grain intensity as a per-lead property (hard leads = smooth, soft leads = textured)
- Suggested `PressureMode` as a rendering-time concern separate from stroke data (future-proofs replay)

**The iterative loop:**
1. Plan written → user approved
2. 8 files created/modified in dependency order (enum → service → painter → palette → widget)
3. 33 new tests (26 rendering helpers + 7 service tests)
4. First test run: 1 failure (grain hash collision at adjacent positions) — fixed test positions
5. Second run: 102/102 pass
6. Build → deploy → launch on tablet
7. User: "this rev feels fucking awesome"

### Files changed (9 files, +1164 / -101 lines)

| File | What |
|------|------|
| `lib/models/pressure_mode.dart` | **New** — PressureMode enum (width/opacity/both) |
| `lib/models/grid_style.dart` | **New** — GridStyle enum (none/dots/lines) — was implemented in 2.5 but uncommitted |
| `lib/models/pencil_lead.dart` | Added `grainIntensity` field per lead |
| `lib/services/drawing_service.dart` | Added `pressureMode` property with getter/setter |
| `lib/widgets/sketch_painter.dart` | Full pencil rendering pipeline — `pencilPressure()`, `tiltWidthMultiplier()`, `tiltOpacityFade()`, `grainFactor()`, `velocityFactor()`, `_drawPencilStroke()` |
| `lib/widgets/floating_palette.dart` | Inline HSV color picker sub-panel, pressure mode chips, removed dialog |
| `lib/widgets/canvas_widget.dart` | Wired pressureMode + grainIntensity through Stack |
| `test/widgets/sketch_painter_test.dart` | **New** — 26 tests for rendering helpers |
| `test/services/drawing_service_test.dart` | Added 7 tests for pressure mode + grain intensity |

---

## Phase 2.5 — Canvas UX Improvements
**Commit:** `fe283ea` (bundled with Phase 2) | **Date:** 2025-03-07 | **Tests:** 69 pass

### What changed

Five UX problems identified after deploying Phase 2 to the tablet:

**1. Grid dots invisible** — The original dot grid used alpha-blended colors at 0.8px radius. On the warm-white paper background, dots were effectively invisible. Fixed with `gridColorForBackground()` — computes a contrasting color by lerping 35% toward mid-gray (light paper) or light-gray (dark paper). Fully opaque, no alpha tricks. Dot radius bumped to 1.2px. This took TWO iterations — the first attempt (25% lerp toward #9E9E9E) was still too subtle. The user reported "dots still not visible on light paper" and we increased the contrast factor.

**2. Floating dockable palette** — The fixed toolbar was consuming screen real estate. Replaced with a compact 48px-wide vertical strip that snaps to screen edges. Sub-panels expand outward from the strip. Draggable with edge-snapping on release.

**3. Pencil lead presets** — PencilLead enum with 4 presets (Fine HB, Medium 2B, Bold 4B, Soft 6B). Each defines a weight multiplier and opacity. Applied through `DrawingService.applyPencilLead()`.

**4. Quick eraser toggle** — `toggleEraser()` saves current tool, switches to eraser, and restores the previous tool on second toggle. Manual tool selection deactivates the toggle.

**5. Partial stroke erasing** — Instead of tombstoning entire strokes, `splitStrokePoints()` identifies points within the eraser radius and splits the stroke into surviving segments. Preserves the append-only log invariant.

**6. Grid style + paper color** — Added choice between dots, lines, and no grid. Added 6 paper color presets (white, cream, tan, gray, dark, navy).

### AI collaboration notes
- Grid visibility required two rounds of iteration based on real-device feedback
- The grid contrast computation was redesigned from scratch after the first approach failed on actual hardware (what looks visible in a simulator can be invisible on a real display)
- Partial erasing required careful append-only log design — can't delete strokes, so we tombstone the original and create new strokes for surviving segments

---

## Phase 2 — Drawing Canvas
**Commit:** `fe283ea` | **Date:** 2025-03-07 | **Tests:** 46 pass

### What changed

Full stylus-input drawing canvas with:
- `DrawingService` (ChangeNotifier) managing pointer lifecycle: down → move → up
- `SketchPainter` (CustomPainter) rendering pressure-sensitive strokes
- Palm rejection (stylus and mouse only, no touch)
- Async SQLite persistence (fire-and-forget, <5ms)
- Tombstone-based erasure (append-only log, never delete)

### Architecture decisions
- **ChangeNotifier + Riverpod** instead of pure Riverpod StateNotifier — CustomPainter needs direct notifier binding for 120-240Hz stylus input without rebuild overhead
- **Binary blob storage** for StrokePoints (32 bytes each) — 50-point stroke is 1.6KB, efficient for SQLite
- **Append-only stroke log** — erasure creates a tombstone stroke pointing to the target. Enables full history replay and conflict-free sync (future Phase 11)

---

## Phase 1 — Project Scaffold
**Commit:** `fe283ea` | **Date:** 2025-03-07 | **Tests:** 21 pass

### What changed

Complete project scaffold from TDD specification:
- Flutter project targeting Android arm64 (minSdk 33, targetSdk 34)
- All data models: StrokePoint (binary pack/unpack), Stroke (boundingRect, tombstone), Page, Chapter, Notebook
- SQLite schema with 10 tables including FTS5 full-text search
- Provider layer (Riverpod) for dependency injection
- Wireless ADB deployment pipeline to OnePlus Pad

### AI collaboration notes
- The TDD specified StrokePoint as 28 bytes but the field layout (6×Float32 + 1×Int64) is actually 32 bytes. Claude caught this discrepancy and implemented the correct 32-byte layout.
- The `flutter create` and toolchain installation (Flutter SDK, Android Studio, ADB pairing) were done by the human. Everything after `flutter create` was Claude.

---

## Build & Deploy Pipeline

```
# Run tests
C:/dev/flutter/bin/flutter test

# Build release APK
export JAVA_HOME="C:/Program Files/Android/Android Studio/jbr"
C:/dev/flutter/bin/flutter build apk --release

# Deploy to OnePlus Pad (wireless ADB)
C:/dev/flutter/bin/flutter install --release -d 192.168.50.164:36599

# Launch
adb -s 192.168.50.164:36599 shell monkey -p com.profangrybeard.industrial_sketchbook -c android.intent.category.LAUNCHER 1
```

**Known issues:**
- Gradle daemon sometimes holds locks on `build/` directory. Fix: `rm -rf build` before building.
- `JAVA_HOME` must be set per-session (not in system env). Points to Android Studio's bundled JBR.
- Tablet connection port changes on reboot — re-run `adb connect <ip>:<port>`.
- `flutter install` doesn't auto-launch. Use `adb shell monkey` to start the app.
