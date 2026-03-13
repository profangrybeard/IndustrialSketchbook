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
- `lib/widgets/tile_cache.dart` — NEW: per-tile LRU raster cache (512×512 world units, max 64 tiles, capped at 2048px physical)
- `lib/widgets/committed_strokes_painter.dart` — REWRITTEN: tiled rendering instead of single full-page raster cache
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

---

## Files changed (uncommitted)

| File | Change |
|------|--------|
| `lib/models/camera.dart` | **NEW** — Camera model (topLeft + zoom) |
| `lib/models/tile_key.dart` | **NEW** — Tile grid identifier |
| `lib/widgets/tile_cache.dart` | **NEW** — Per-tile LRU raster cache |
| `lib/utils/spatial_grid.dart` | Unbounded hash-based cell keys |
| `lib/services/drawing_service.dart` | Lazy spatial grid getter, no canvas dim dependency |
| `lib/widgets/canvas_widget.dart` | Camera, tiled rendering, frozen pinch, Listener outside Transform |
| `lib/widgets/committed_strokes_painter.dart` | Tiled rendering with version-synced cache |
| `lib/widgets/background_painter.dart` | Viewport-aware grid with LOD |
| `lib/config/build_info.dart` | Updated revision + date |
| `test/utils/spatial_grid_test.dart` | Updated for unbounded grid |
| `test/widgets/background_painter_test.dart` | Added viewport/zoom params |
| `test/widgets/committed_strokes_painter_test.dart` | Updated for TileCache |

## Hard Rules
- **NEVER use `flutter install`** — destroys SQLite database. ALWAYS `adb install -r`.
- Phone: `R5CX21RW3EW` (USB), Tablet: `8DCAUCUKRG8XVKJF`
- Impeller DISABLED on Samsung Tab S9 Ultra (Vulkan SIGSEGV)

## All 405 tests pass
