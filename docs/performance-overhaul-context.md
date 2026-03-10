# Industrial Sketchbook — Performance Overhaul Design Discussion

I'm building a Flutter tablet/phone sketchbook app with stylus pressure/tilt sensitivity. It uses a ribbon polygon renderer for high-fidelity strokes. The app syncs drawings between a Samsung Galaxy Tab S9 Ultra and Galaxy S24 phone via Google Drive.

**The problem**: Heavy drawings (6MB+ SQLite, hundreds of strokes) take 30+ seconds to load on the tablet, or crash the app. The phone handles the same data better but still shows multi-second delays. I need to redesign the data/rendering architecture.

---

## Current Rendering Pipeline

Each stroke is rendered through this pipeline:
1. **Spine computation**: Catmull-Rom spline through raw StrokePoints with adaptive subdivision
2. **SpinePoint generation**: (x, y, halfWidth) at each subdivision sample
3. **Ribbon construction**: For each spine point, compute tangent, perpendicular normal, offset +/-halfWidth for left/right edges
4. **Edge smoothing**: Catmull-Rom cubic Bezier curves on edge vertex arrays
5. **End caps**: Semicircle arcTo() at stroke start and end
6. **Fill**: Single canvas.drawPath(path, fillPaint) with BlendMode.src inside saveLayer

Arc lengths: 0.5px for live drawing (maximum fidelity), 3.0px for committed stroke replay (~6x fewer spine points).

Pencil tool: same ribbon pipeline but rendered in overlapping chunks of ~8 spine points, each with locally-averaged opacity (grain x velocity x tilt x pressure). Each chunk calls saveLayer.

## Raster Cache System

- 3-layer RepaintBoundary: background, committed strokes (raster cached), active stroke
- **Incremental pen-up**: composites old cache + 1 new stroke via toImageSync() = O(1)
- **Full rebuild** (page load, undo, erase): async via picture.toImage(), draws Picture directly for immediate display
- Generation counter prevents stale async builds after page switch
- Full rebuild uses 3.0px replay arc length

## Data Model

Notebook -> Chapters -> Pages -> Strokes -> StrokePoints

**StrokePoint** (32 bytes packed binary in SQLite):
- x, y (Float32) — logical pixel coordinates
- pressure (Float32) — 0.0 to 1.0
- tiltX, tiltY (Float32) — degrees, -90 to 90
- twist (Float32) — barrel rotation 0-360
- timestamp (Int64) — microseconds since epoch

**Stroke**: id (UUID), pageId, tool, color, weight, opacity, points (binary blob), createdAt, isTombstone, erasesStrokeId, synced flag

Tombstone pattern for erasure (append-only log, no deletes).

## Sync Architecture

Journal-based incremental sync via Google Drive appDataFolder. Each device uploads journals (batches of <=500 strokes) with UUID dedup. Cross-device coordinate scaling via canvasWidth metadata in journals. Currently strokes are stored in raw logical pixel coordinates (phone ~412px wide, tablet ~1200px wide).

## The Root Cause

The bottleneck is the **recording phase** during CommittedStrokesPainter.paint():

1. For each committed stroke, iterate all raw StrokePoints
2. Catmull-Rom spline subdivision generates spine points at targetArcLength intervals
3. Ribbon construction (tangent, normal, offset, Bezier edges) for every spine point
4. Each stroke gets a saveLayer call (opacity isolation)
5. Pencil strokes add per-chunk saveLayer calls

This runs **synchronously on the UI thread** during paint(). Flutter's CustomPainter.paint() must complete in a single frame.

### Scale

| Metric | Phone (412px) | Tablet (1200px) |
|--------|--------------|----------------|
| Arc length (replay) | 3.0px | 3.0px |
| Spine amplification | ~3x raw | ~3x raw |
| 200-point stroke | ~600 spines | ~600 spines |
| 100 strokes/page | ~60K spines | ~60K spines |
| Full rebuild time | 2-5 sec | 10-30+ sec |

The tablet's larger raster image (2960x1848 logical at 2x DPR) means GPU fill rate also matters.

## Incremental Fixes Already Applied

1. Async raster cache (toImage instead of toImageSync)
2. Generation counter for page-switch race conditions
3. Dual arc length (0.5 live / 3.0 replay)
4. Impeller disabled (Samsung Vulkan driver SIGSEGV bug, using Skia)

These helped but didn't solve the fundamental O(total_spine_points) problem.

## Proposed Approaches

### A: Pre-Baked Spine Points
Store computed spine points in SQLite at pen-up time. On page load, skip Catmull-Rom subdivision entirely — just build ribbon from stored spines. Cuts recording time by ~60-70%. Raw points preserved for re-computation if params change. Migration: background job for existing strokes. DB cost: ~3x storage.

### B: Normalized Coordinates
Store strokes in 0.0-1.0 coordinate space. Solves cross-device scaling at source. Breaking change requiring migration. Doesn't directly help performance.

### C: Page-Level Raster Snapshots
Save PNG per page for instant display while strokes load in background. Crossfade to live canvas when ready. ~200KB per page. Zoom beyond snapshot resolution shows blur until catch-up.

### D: Tiled Rendering
Divide canvas into tiles, only render visible viewport. R-tree spatial index. Most complex but standard in pro apps (Procreate, Krita).

## My Initial Thinking

A + C seems like best ROI. A cuts the core bottleneck, C makes page-switch feel instant. B is orthogonal cleanup. D is the "right" long-term answer but huge effort.

**What I'd like to discuss**: Which approach(es) make sense given this codebase, what the implementation would look like, and whether there are approaches I'm missing.
