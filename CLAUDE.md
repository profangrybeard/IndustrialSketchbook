# Session Context — IndustrialSketchbook

## Branch: `claude/stoic-leavitt`

Working in git worktree at `.claude/worktrees/stoic-leavitt`. Merge to `main` via PR.

---

## What was done this session

### Option D Phase 1 — Spatial Grid Index (`5b4061b`, already on branch)
- Unbounded hash-based spatial grid (Cantor pairing + zigzag encoding)
- O(1) stroke lookup by region for eraser hit-testing and tiled rendering
- Replaced fixed `(canvasWidth, canvasHeight)` constructor with just `cellSize`
- 18 spatial grid tests including negative/large coordinate support

### Option D Phase 2 — Tiled Rendering + Infinite Canvas (uncommitted)
Full infinite canvas implementation in 4 phases:

**Phase 1: Camera System**
- `lib/models/camera.dart` — NEW: topLeft + zoom model, screen↔world conversion
- Replaced `_canvasScale`/`_canvasOffset` in canvas_widget with `Camera _camera`
- Focal-point-stable pinch zoom (world point under pinch stays stationary)
- Zoom range: 0.05x–20.0x, infinite pan (no clamping)

**Phase 2: Unbounded Spatial Grid**
- Already done in Phase 1 commit above

**Phase 3: Tiled Rendering**
- `lib/models/tile_key.dart` — NEW: identifies tiles by (col, row) in world space
- `lib/widgets/tile_cache.dart` — NEW: per-tile LRU raster cache (512×512 world units, max 64 tiles, dynamic pixel cap)
- `lib/widgets/committed_strokes_painter.dart` — REWRITTEN: tiled rendering with three-tier progressive upgrade
- Widget tree restructured: Background + Committed painters OUTSIDE Flutter Transform, Active stroke INSIDE Transform

**Phase 4: Infinite Background Grid**
- `lib/widgets/background_painter.dart` — REWRITTEN: viewport-aware grid with LOD (subdivide at >4x zoom, coarsen at <0.5x)

### Critical Bug Fixes (deployed, uncommitted)

1. **Strokes disappearing after load** — Tile cache rendered empty tiles before strokes loaded (version=0), then returned those stale tiles after loading. Fixed by:
   - `_tileCache.clear()` after `loadStrokes()`
   - Safety net in painter: sync `tileCache.version` with `strokeVersion`
   - `bumpVersion()` on every mutation (draw, erase, undo, redo)

2. **Pinch-to-zoom crawling** — Every frame during pinch → new pixelSize → all tiles miss cache → synchronous `toImageSync()` per frame. Fixed by:
   - `_renderCamera` freezes at pinch start
   - Compensating Transform wraps background+committed layers during pinch
   - Tiles stay cached, re-render at new resolution only on pinch end

3. **Can't draw at edges when zoomed out** — Listener was inside Transform, limiting hit area to original screen bounds in world space. Fixed by:
   - Moved Listener OUTSIDE Transform
   - All coordinates (drawing + eraser) now convert via `_camera.screenToWorld()`

### Performance Overhaul — Progressive Rendering + Zoom Quality

**Problem diagnosed via profiling**: Each tile `toImageSync()` costs 20–34ms. At low zoom with 36 visible tiles, total stall was 660ms+ blocking the UI thread. Original progressive rendering (render 1-2 tiles per frame, show nothing for uncached tiles) created a worse problem: blank tiles appearing and disappearing at different zoom levels.

**Solution — Three-tier rendering strategy (Google Maps style):**
1. **Exact cache hit** (version + resolution match) → instant blit, zero cost
2. **Old-resolution fallback** (post-zoom, `getAny()`) → show stretched placeholder immediately, upgrade 1+ per frame within 8ms budget. Blurry-then-sharpen, never blank.
3. **No fallback** (new area, first load) → render synchronously. Brief stall for those tiles only, but never blank.

Key difference from first progressive attempt: tiles with NO cached version are always rendered synchronously (never blank). Only tiles with stale-resolution cached versions get deferred upgrades. `upgradesThisFrame` tracks upgrade budget separately from new-tile renders.

**Dynamic tile pixel cap** (`tile_cache.dart`):
- Zoom ≤1x: cap at 2048px per tile (many tiles visible)
- Zoom 4x+: cap at 4096px per tile (few tiles visible, more GPU budget each)
- Linear interpolation between

**Zoom-adaptive arc length** (`committed_strokes_painter.dart`):
- At zoom >1x: `replayArcLength / zoom` (clamped at 0.3 min)
- Maintains constant physical-pixel spacing in Catmull-Rom subdivision
- Curves stay smooth at high zoom instead of showing polygon edges

**Settings invalidation** (`canvas_widget.dart`):
- Hash of rendering settings (grain, pressure mode, arc length, tilt) checked in `build()`
- Tile cache cleared when settings change (tiles bake in rendering parameters)
- `_tileContinuation` ValueNotifier drives continuation paints via `super(repaint:)`

**Pinch-end cache preservation**:
- Removed `_tileCache.clear()` from `_endPinch()` — old tiles stay as stretch placeholders
- `get()` misses on resolution mismatch → triggers progressive upgrade
- `getAny()` returns old tile for placeholder display

---

## Files changed (uncommitted)

| File | Change |
|------|--------|
| `lib/models/camera.dart` | **NEW** — Camera model (topLeft + zoom) |
| `lib/models/tile_key.dart` | **NEW** — Tile grid identifier |
| `lib/widgets/tile_cache.dart` | **NEW** — Per-tile LRU raster cache, dynamic pixel cap (2048–4096) |
| `lib/utils/spatial_grid.dart` | Unbounded hash-based cell keys |
| `lib/services/drawing_service.dart` | Lazy spatial grid getter, no canvas dim dependency |
| `lib/widgets/canvas_widget.dart` | Camera, tiled rendering, frozen pinch, Listener outside Transform, settings hash invalidation, continuation notifier |
| `lib/widgets/committed_strokes_painter.dart` | Three-tier progressive rendering, zoom-adaptive arc length |
| `lib/widgets/background_painter.dart` | Viewport-aware grid with LOD |
| `lib/config/build_info.dart` | Updated revision + date |
| `test/utils/spatial_grid_test.dart` | Updated for unbounded grid |
| `test/widgets/background_painter_test.dart` | Added viewport/zoom params |
| `test/widgets/committed_strokes_painter_test.dart` | Updated for TileCache |

---

## Next Up — Zoom Quality Tuning

### What's deployed and needs testing
- Three-tier progressive rendering (no blank tiles, blurry-then-sharpen for zoom changes)
- Dynamic tile pixel cap (2048→4096 at high zoom)
- Zoom-adaptive arc length (finer subdivision at high zoom)

### Remaining task: Define max zoom clamp
User said: "Let's start with 2 [dynamic tile cap], then 3 [adaptive arc length], and then play with that to define 1 [max zoom clamp]."

Items 2 and 3 are done. Item 1 remains:
- Test on phone at various zoom levels (2x, 3x, 5x, 10x, 20x)
- Find the zoom level where rendering quality degrades unacceptably
- Clamp `Camera.maxZoom` there (currently 20x, likely should be 3–5x)
- Location: `lib/models/camera.dart`, field `static const double maxZoom`

### Possible further improvements (if zoom quality still unsatisfactory)
- **Larger tile size** (1024 instead of 512) — fewer tiles visible, fewer `toImageSync()` calls
- **Tile render cost reduction** — profile what's expensive inside `_renderTile()` (stroke iteration? Catmull-Rom subdivision? `toImageSync()` itself?)
- **Adaptive tile budget** — increase frame budget when fewer tiles are visible (deep zoom = 2-3 tiles, can afford 16ms each)
- **Pan stall mitigation** — at zoom 1x with many visible tiles, panning to new areas renders all edge tiles synchronously. Consider pre-fetching 1-tile border around viewport.

---

## Hard Rules
- **NEVER use `flutter install`** — destroys SQLite database. ALWAYS `adb install -r`.
- Phone: `R5CX21RW3EW` (USB), Tablet: `8DCAUCUKRG8XVKJF`
- Impeller DISABLED on Samsung Tab S9 Ultra (Vulkan SIGSEGV)

## All 403 tests pass
