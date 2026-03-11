# Performance Overhaul: Infinite Sketchbook Architecture

## Context

Heavy drawings (6MB+ SQLite, hundreds of strokes) take 10-30+ seconds to load on the tablet. The root cause is threefold: (1) each StrokePoint is 32 bytes with sensor fields unused by the renderer, (2) Catmull-Rom spline subdivision runs synchronously on every full rebuild, and (3) page switching requires a complete stroke rebuild with no intermediate display. Additionally, sync payloads are bloated (~20KB/stroke JSON) and cross-device coordinate scaling adds runtime cost.

**User approved wiping all existing data** — no migration needed. Tilt/twist/velocity dropped from the render tier for v1 (only pressure affects visuals). New branch `feat/perf-overhaul` from `main`.

---

## Phase 1: New Data Foundation

**Goal**: 12-byte normalized render points replace 32-byte raw sensor points as the primary storage and rendering format.

### New file: `lib/models/render_point.dart`
- `RenderPoint(x, y, pressure)` — all Float32, x/y normalized 0.0-1.0
- `packedSize = 12` (vs StrokePoint's 32)
- `packAll/unpackAll`, `toJson/fromJson`, `toBytes/fromBytes`
- `fromStrokePoint(sp, canvasWidth, canvasHeight)` — normalizes device coords
- `toCanvas(canvasWidth, canvasHeight)` — denormalizes for rendering

### Modify: `lib/models/stroke.dart`
- Replace `final List<StrokePoint>? fittedPoints` with `final List<RenderPoint>? renderData`
- Remove `renderPoints` getter (all callers use `renderData` explicitly)
- `toDbMap()`: write `renderData` as `render_points_blob`, raw points as `raw_points_blob`
- `fromDbMap()`: read both blobs
- `toJson()` / `fromJson()`: serialize `renderData` as `renderPoints` array
- Keep `boundingRect` computed from raw `points` (device coords, used for hit testing)

### Modify: `lib/services/database_service.dart`
- Bump to `version: 4`, delete `_onUpgrade` (clean slate)
- `strokes` table: `points_blob` → `raw_points_blob`, `fitted_points_blob` → `render_points_blob`
- New `page_snapshots` table: `page_id PK, png_blob BLOB, stroke_version INT, width INT, height INT, updated_at TEXT`
- New methods: `savePageSnapshot`, `getPageSnapshot`, `deletePageSnapshot`

### Tests
- **New**: `test/models/render_point_test.dart` — binary round-trip, JSON round-trip, normalization, Float32 precision
- **Update**: `test/models/stroke_test.dart` — renderData serialization round-trips
- **Update**: `test/services/database_service_test.dart` — v4 schema, page_snapshots CRUD, render_points_blob verification

---

## Phase 2: Fitting Pipeline + Rendering Update

**Goal**: Pen-up produces compact normalized RenderPoints. Renderer consumes them directly. Pencil simplified (no tilt/velocity).

### Modify: `lib/utils/curve_fitter.dart`
- New `simplifyToRenderPoints(points, canvasWidth, canvasHeight)` — RDP + normalize → `List<RenderPoint>`
- New `chaikinSmoothRenderPoints(List<RenderPoint>)` — Chaikin on (x, y, pressure) only
- Existing methods remain for backward compat

### Modify: `lib/services/drawing_service.dart`
- Add `setCanvasDimensions(width, height)` — called from CanvasWidget
- Pen-up pipeline: `simplifyToRenderPoints → chaikinSmoothRenderPoints → store as renderData`
- Raw `StrokePoint` list archived in `raw_points_blob`

### Modify: `lib/widgets/stroke_rendering.dart`
- `renderStroke()` gains `canvasWidth/canvasHeight` params
- When stroke has `renderData`: denormalize coords → existing Catmull-Rom → ribbon (but with ~5x fewer input points)
- **Drop from pencil**: `tiltWidthMultiplier`, `tiltOpacityFade`, `velocityFactor`
- New pencil alpha: `baseAlpha * 0.7 * max(pressure^exp, 0.1) * grain`
- Functions remain in file but removed from hot path

### Modify: `lib/widgets/committed_strokes_painter.dart`
- Pass `canvasWidth/canvasHeight` through to `rendering.renderStroke()`

### Modify: `lib/widgets/active_stroke_painter.dart`
- Live drawing continues using raw `StrokePoint` in device coords (no normalization during drawing)
- Separate render path for raw points (no denormalization needed)

### Modify: `lib/widgets/canvas_widget.dart`
- Call `drawingService.setCanvasDimensions()` in build
- Pass canvas dims to painters
- After eraser split: re-fit split segments into RenderPoints

### Tests
- **Update**: `test/utils/curve_fitter_test.dart` — `simplifyToRenderPoints` output in 0.0-1.0, reduction ratio
- **Update**: `test/services/drawing_service_test.dart` — pen-up produces non-null renderData in normalized range
- **Update**: `test/widgets/committed_strokes_painter_test.dart` — canvas dims parameter

---

## Phase 3: Page Raster Snapshots

**Goal**: Sub-100ms perceived page switch via PNG snapshots with background stroke loading.

### New file: `lib/models/page_snapshot.dart`
- `PageSnapshot(pageId, pngBlob, strokeVersion, width, height, updatedAt)`

### New file: `lib/services/snapshot_service.dart`
- LRU in-memory cache (5 entries) backed by `page_snapshots` DB table
- `captureSnapshot(pageId, ui.Image, strokeVersion)` — PNG encode + cache + persist
- `getSnapshot(pageId)` — cache-first, then DB fallback
- `invalidate(pageId)` — remove from cache and DB

### Modify: `lib/widgets/canvas_widget.dart`
- **Page switch flow**: display snapshot immediately → async stroke load → crossfade (200ms AnimatedOpacity) → remove snapshot layer
- **Pen-up**: debounced 500ms timer → capture raster cache image as snapshot
- New state: `_displayedSnapshot`, `_showingSnapshot`, `_snapshotDebounce`

### Modify: `lib/providers/` (database_provider or new snapshot_provider)
- Add `SnapshotService` Riverpod provider

### Tests
- **New**: `test/services/snapshot_service_test.dart` — LRU eviction, cache hit, invalidation, DB round-trip

---

## Phase 4: Compact Sync

**Goal**: ~90% smaller sync payloads. No cross-device scaling. Gzip compression.

### Modify: `lib/models/stroke.dart`
- New `toSyncJson()` — excludes raw points, includes only `renderPoints`
- New `Stroke.fromSyncJson()` — creates stroke with `renderData` populated, `points` empty

### Modify: `lib/models/sync_journal.dart`
- Add `version` field (2 for new format)
- Remove `canvasWidth` field
- Backward compat: version 1 journals still accepted on pull (with canvasWidth scaling)

### Modify: `lib/services/sync_service.dart`
- Push: use `toSyncJson()`, gzip before upload (`.json.gz` extension)
- Pull: detect `.json.gz`, decompress, version check for format
- Tombstone compaction: if stroke + its tombstone both in push batch, omit both
- Remove `_localCanvasWidth` and all scaling code for v2 journals

### Tests
- **Update**: `test/models/stroke_test.dart` — `toSyncJson` excludes raw points, round-trip
- **New/Update**: sync tests — gzip round-trip, tombstone compaction, v1 backward compat, v2 normalized coords

---

## Expected Impact

| Metric | Current | After |
|--------|---------|-------|
| RAM per 100-stroke page | ~640KB | ~20-30KB |
| Full rebuild (tablet) | 10-30s | 2-5s (hidden by snapshot) |
| Page switch perceived | 10-30s | <100ms |
| Sync journal (500 strokes) | ~10MB | ~50-100KB |
| Per-stroke render data | 6.4KB | ~300B |

## Verification Strategy

After each phase:
1. `flutter test` — all tests pass
2. Build: `flutter build apk --debug` (never `flutter install`)
3. Deploy: `adb install -r build/app/outputs/flutter-apk/app-debug.apk`
4. Tablet test: draw strokes, switch pages, verify visual quality
5. Phase 4: sync between tablet and phone, verify identical visuals

## Phase Dependencies

```
Phase 1 (foundation) → Phase 2 (rendering) → Phase 3 (snapshots)
                                             → Phase 4 (sync)
```
Phases 3 and 4 are independent of each other after Phase 2.
