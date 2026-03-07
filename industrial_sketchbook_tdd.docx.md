**INDUSTRIAL SKETCHBOOK**

Technical Design & Test Foundation

Version 0.1  |  Status: **Foundation Draft**  |  Platform: OnePlus Tablet / Android / Flutter

| *This document is the single source of truth for what the app is, how it is architected, and how every system will be validated. Code is written to satisfy this document — not the other way around. If a decision is not recorded here, it has not been made.* |
| :---- |

# **0\.  How to Use This Document**

This is a living Technical Design Document (TDD). It serves four functions simultaneously:

* Design reference — every architectural decision is captured here with its rationale.

* Contract — the test matrix defines exactly what "done" means for each system.

* Onboarding guide — a new contributor can understand the entire system from this document.

* Change log target — when decisions change, this document is updated first.

**READING PRIORITY**

| Section | Purpose | Read First If... |
| :---- | :---- | :---- |
| §1 — Vision | What the app is and is not | You are new to the project |
| §2 — Core Principle | The one rule that governs everything | Always |
| §3 — Data Model | The formal entity definitions | You are touching data or storage |
| §4 — Pipelines | The three runtime subsystems | You are building any service layer |
| §5 — Test Matrix | Acceptance criteria per system | You are writing or reviewing code |
| §6 — Build Order | What to build in what sequence | You are planning a sprint |
| §7 — Open Questions | Decisions not yet made | You are in a design discussion |

| 1\.  Vision & Scope |
| :---- |

## **1.1  What This App Is**

Industrial Sketchbook is a native Android tablet application for professional industrial designers. It is built for a OnePlus tablet with a paired stylus as the primary input device.

Its defining characteristics — the features that make it different from Procreate, Concepts, or GoodNotes — are:

* The canvas is infinite and organised into user-defined chapters, not fixed page sizes.

* Handwriting is continuously indexed into a full-text search database in the background.

* Every page maintains a complete version history and can be branched like source code.

* Images live in a parallel gallery index — they are referenced by pages, never embedded.

* Perspective drawing tools with live vanishing-point snapping are a first-class feature.

* The entire stroke log syncs to the cloud. Rendered images and OCR caches do not.

## **1.2  What This App Is Not**

* Not a photo editor or illustration tool — it is a design thinking environment.

* Not a cloud-rendered app — everything runs on-device; cloud is sync only.

* Not a bitmap tool — pixels are never the source of truth.

* Not a real-time collaboration app in v1 — sync is personal, single-user first.

## **1.3  Target Hardware**

| Attribute | Target | Notes |
| :---- | :---- | :---- |
| Device | OnePlus Pad (1st gen / Pro) | Primary test device |
| Stylus | OPPO / OnePlus Stylo | Must detect pressure, tilt, tool type |
| OS | Android 13+ | Min SDK 33 |
| Framework | Flutter 3.x (Dart) | Single codebase, native Android compile |
| Screen | 11.6" / 144Hz | Canvas must target 120fps touch response |
| RAM | 8–12 GB | Isolates for OCR must not pressure main process |

| 2\.  Core Architectural Principle |
| :---- |

| THE STROKE LOG IS THE SOURCE OF TRUTH. *Everything else is a cache.* |
| :---: |

This principle is borrowed from game engine replay systems. A game replay never records pixels — it records inputs with timestamps. The renderer is deterministic, so any frame can be reconstructed from the input log.

This app applies the same model to a sketchbook canvas. Strokes are inputs. The rendered canvas, the OCR text, and the search index are all frames derived from those inputs. They are disposable and rebuildable.

## **2.1  What This Means in Practice**

| Layer | Stored Where | Synced to Cloud | Rebuilable From |
| :---- | :---- | :---- | :---- |
| Stroke event log | SQLite (strokes table) | YES — primary sync target | — (this is the root) |
| Rendered canvas tiles | GPU / memory cache only | NO | Stroke log replay |
| OCR text regions | SQLite (ocr\_snapshots) | NO | Stroke log \+ ML Kit |
| FTS5 search index | SQLite (search\_index) | NO | OCR snapshot union |
| Gallery image files | Local storage \+ Supabase | YES — separate pipeline | — (binary assets) |
| Gallery metadata | SQLite (gallery\_images) | YES | Cloud metadata record |
| Rendered thumbnails | Local cache only | NO | Stroke log replay |

## **2.2  Why This Architecture Was Chosen**

| Decision | Alternative Considered | Why Rejected |
| :---- | :---- | :---- |
| Stroke vectors as source of truth | Bitmap layers (like Procreate) | Bitmaps cannot be searched, branched, or replayed. Sync would require transferring MB per page. |
| Append-only stroke log | Mutable stroke records | Mutability requires locking, merge complexity, and makes undo/redo harder. Append-only \= free undo. |
| FTS5 search (SQLite) | Cloud-hosted search (Algolia, etc.) | On-device search is instant, works offline, and requires no external dependency or cost. |
| ML Kit Digital Ink (vector) | Bitmap OCR (Tesseract, Google Vision) | Vector ink recognition uses pressure \+ timing data. It is more accurate and requires no rasterize step. |
| Supabase for cloud sync | Firebase / custom backend | Supabase is Postgres-based (familiar SQL), open-source, self-hostable, and has built-in object storage. |
| Gallery as parallel index | Images embedded in stroke log | Embedding blobs in the stroke log would break the sync model. Reference-by-UUID keeps payloads tiny. |

| 3\.  Formal Data Model |
| :---- |

The following entities form the complete data model. Each entity definition includes its fields, constraints, and the testable invariants that must hold at all times.

## **3.1  StrokePoint**

The atomic unit. A single sample from the stylus sensor pipeline. Immutable once captured.

| Field | Type | Range / Constraint | Notes |
| :---- | :---- | :---- | :---- |
| x | Float64 | Unbounded (canvas coords) | Horizontal position in infinite canvas space |
| y | Float64 | Unbounded (canvas coords) | Vertical position in infinite canvas space |
| pressure | Float32 | 0.0 – 1.0 | 0 \= no contact, 1 \= maximum pressure |
| tiltX | Float32 | \-90 – 90 degrees | Side tilt of stylus |
| tiltY | Float32 | \-90 – 90 degrees | Forward/back tilt of stylus |
| twist | Float32 | 0 – 360 degrees | Barrel rotation (hardware-dependent) |
| timestamp | Int64 | Microseconds since epoch | Required for ML Kit ink recognition ordering |

**STORAGE FORMAT**

Points are stored as packed binary blobs in SQLite. Each point occupies exactly 28 bytes: 6 × Float32 (x, y, pressure, tiltX, tiltY, twist) \+ 1 × Int64 (timestamp). A 50-point stroke ≈ 1.4 KB.

## **3.2  Stroke**

A single pen-down → pen-up sequence. The primary entry in the stroke event log. Immutable once committed.

| Field | Type | Constraint | Notes |
| :---- | :---- | :---- | :---- |
| id | UUID v4 | Globally unique | Primary key. Used for deduplication in sync merge. |
| pageId | UUID | FK → SketchPage.id | Owning page |
| layerId | String | Must exist in page.layerIds | Default: "default" |
| tool | Enum | pen|pencil|marker|brush|eraser|highlighter | Controls renderer behaviour |
| color | Int32 | ARGB packed | Alpha channel used for opacity blending |
| weight | Float32 | 0.5 – 50.0 canvas units | Base stroke width before pressure scaling |
| opacity | Float32 | 0.01 – 1.0 | Global opacity (separate from color alpha) |
| points | StrokePoint\[\] | Length \>= 1 | Minimum one point (tap \= single point stroke) |
| createdAt | DateTime | ISO 8601 UTC | Set at pen-up. Not modified thereafter. |
| isTombstone | Bool | Default: false | True \= this stroke is logically erased |
| erasesStrokeId | UUID? | FK → Stroke.id if tombstone | The stroke this tombstone erases |
| synced | Bool | Default: false | Set to true after cloud acknowledgement |

| *INVARIANT: Strokes are never deleted. Erasure is represented as a new Stroke record with isTombstone \= true and erasesStrokeId pointing to the target. This preserves the append-only log and enables full history replay.* |
| :---- |

## **3.3  SketchPage**

The canvas entity. A page does not store stroke data directly — it stores an ordered list of stroke IDs. Strokes are looked up by ID for rendering.

| Field | Type | Constraint | Notes |
| :---- | :---- | :---- | :---- |
| id | UUID v4 | Globally unique | Primary key |
| chapterId | UUID | FK → Chapter.id | Owning chapter |
| pageNumber | Int | \>= 0 | Display order within chapter |
| style | Enum | plain|grid|dot|isometric|perspective | Background overlay type |
| gridConfig | GridConfig? | Required if style \!= plain | Spacing, color, line weight |
| perspectiveConfig | PerspConfig? | Required if style \= perspective | Vanishing points, horizon |
| strokeIds | UUID\[\] | Ordered, append-only | The event log. This is the page. |
| attachments | ImageRef\[\] | May be empty | Gallery image pins on this page |
| parentPageId | UUID? | Null \= root page | Non-null \= this is a branch |
| branchPointStrokeId | UUID? | Must exist in strokeIds | Last shared stroke with parent |
| branchPageIds | UUID\[\] | May be empty | Child branches from this page |
| layerIds | String\[\] | Length \>= 1 | Default: \["default"\] |

| *BRANCH INVARIANT: All strokes up to and including branchPointStrokeId are shared with the parent. They are not duplicated in storage. The branch page's strokeIds array includes the full ordered history (shared \+ own). Rendering resolves shared strokes by following parentPageId.* |
| :---- |

## **3.4  Chapter & Notebook**

| Entity | Key Fields | Notes |
| :---- | :---- | :---- |
| Notebook | id, title, ownerId, chapterIds\[\] | Top-level container. One per user in v1. |
| Chapter | id, notebookId, title, order, color, pageIds\[\] | User-named grouping. Reorderable. |

## **3.5  Gallery Entities**

| Entity | Key Fields | Notes |
| :---- | :---- | :---- |
| GalleryImage | id, notebookId, source, localPath, cloudStorageRef, tags\[\], pageRefs\[\] | The canonical image record. pageRefs is bidirectional — the gallery knows every page that references this image. |
| ImageRef | imageId, anchorX, anchorY, annotationStrokeIds\[\], pinnedAt | A pin on a specific page. Stored in SketchPage.attachments\[\]. Points back to GalleryImage by id. |

| 4\.  Runtime Pipelines |
| :---- |

Three independent pipelines run concurrently. They are isolated so that OCR and sync work never blocks drawing.

## **4.1  Drawing Pipeline  (UI thread — latency critical)**

| Stylus PointerEvent (ACTION\_DOWN)   └─► DrawingService.onPointerDown()         └─► Create in-flight Stroke object Stylus PointerEvent (ACTION\_MOVE)  \[fires at 120–240 Hz on OnePlus Pad\]   └─► DrawingService.onPointerMove()         └─► Append StrokePoint to in-flight Stroke         └─► CustomPainter.\_emit()  \[renders ONLY in-flight stroke — no full redraw\] Stylus PointerEvent (ACTION\_UP)   └─► DrawingService.onPointerUp()         ├─► Commit Stroke to committedStrokes\[\]         ├─► Persist Stroke to SQLite  \[async, does not block emit\]         ├─► Enqueue SyncEvent(strokeAdded)  \[async, does not block emit\]         ├─► DirtyRegion.expandToInclude(stroke.boundingRect)         └─► Reset OCR debounce timer (900ms) OCR debounce fires (900ms after last pen-up with no new pen-down)   └─► DirtyRegion.flush()  →  DirtySnapshot   └─► Send DirtySnapshot to OCR Isolate  \[fire-and-forget\]   └─► DirtyRegion.clear() |
| :---- |

**LATENCY REQUIREMENTS**

| Operation | Target Latency | Method |
| :---- | :---- | :---- |
| Stroke point → screen pixel | \< 20ms end-to-end | Dedicated CustomPainter, no layout recompute |
| Full page redraw (pan/zoom) | \< 16ms (60fps min) | Tile-based rendering, off-screen cache |
| Stroke commit to SQLite | \< 5ms | WAL mode, async isolate write |
| OCR trigger after pen-up | 900ms idle timeout | Debounce timer, not blocking |

## **4.2  OCR Pipeline  (Dart Isolate — fire-and-forget)**

| DrawingService sends DirtySnapshot to OcrIsolate via SendPort OcrIsolate receives (DirtySnapshot, List\<Stroke\>)   └─► Build ML Kit Ink object from raw StrokePoint vectors         \[NO rasterize step — vector mode is more accurate than bitmap OCR\]   └─► DigitalInkRecognizer.recognize(ink)  →  List\<RecognitionCandidate\>   └─► Map bounding boxes back to canvas coordinates   └─► Build OCRSnapshot { pageId, strokeCount, regions\[\] }   └─► Write OCRSnapshot to SQLite   └─► Upsert affected regions into search\_index (FTS5)   └─► Notify DrawingService via ReceivePort (optional — for UI indicators) |
| :---- |

**OCR CHECKPOINT EVENTS (WHEN PIPELINE IS TRIGGERED)**

| Trigger | Priority | Notes |
| :---- | :---- | :---- |
| Pen-up \+ 900ms idle (no new strokes) | Primary | Best signal quality — user finished a thought |
| Page navigation (user leaves page) | High | Flush immediately, no debounce wait |
| App backgrounded (onPause lifecycle) | High | Aggressive flush before process may be killed |
| Every 50 strokes (safety net) | Medium | Catches continuous writers who never pause |
| Undo / redo action | Low | Canvas state changed, re-OCR affected dirty region |

## **4.3  Sync Pipeline  (background worker — offline-first)**

| Any mutation (stroke, page, chapter, image)   └─► SyncEvent written to sync\_queue table  \[status: pending\]   └─► SyncQueue.enqueue()  →  if online: schedule immediate flush SyncQueue.flush() (runs in background, triggered by enqueue or reconnect)   └─► SELECT \* FROM sync\_queue WHERE status \= "pending" ORDER BY timestamp ASC   └─► For each event:         ├─► POST to Supabase REST API         ├─► On success:  UPDATE sync\_queue SET status \= "synced"         └─► On failure:  increment retry\_count; exponential backoff               \[max 5 retries; after 5: status \= "failed", alert user\] On reconnect after offline period:   └─► Full flush of all pending events in timestamp order   └─► Pull remote events newer than local watermark   └─► Apply conflict resolution (see §4.3.1) |
| :---- |

### **4.3.1  Conflict Resolution Matrix**

| Event Type | Conflict Scenario | Resolution Strategy |
| :---- | :---- | :---- |
| strokeAdded | Same stroke UUID received from two devices | Idempotent — accept once, ignore duplicate (UUID dedup) |
| strokeTombstoned | Tombstone received for stroke that is already tombstoned locally | Idempotent — no-op |
| pageMetadataUpdated | Two devices update same page style simultaneously | Last timestamp wins |
| chapterReordered | Two devices reorder chapters simultaneously | Last timestamp wins |
| imageTagged | Two devices add different tags to same image | Merge tag arrays, deduplicate |
| pageBranched | Branch created on both devices from same parent | Accept both — branching is additive |

| 5\.  Test Matrix |
| :---- |

Every row is a testable requirement. Tests are written to satisfy these criteria before the feature is considered complete. Priority P0 \= must pass before any release. P1 \= required for feature-complete milestone. P2/P3 \= regression and edge cases.

**TEST TYPE KEY**

| Type | Meaning | Runs Where |
| :---- | :---- | :---- |
| UNIT | Tests a single class or function in isolation, no I/O | flutter test (CI) |
| INT | Tests two or more components working together, may use SQLite | flutter test (CI) |
| E2E | Full device test — stylus input to rendered output or synced data | On-device / emulator |

## **5.1  Stroke Model & Drawing Pipeline**

| Test ID | Requirement | Test Description | Type | Acceptance Criteria | Priority |
| :---- | :---- | :---- | ----- | :---- | ----- |
| **DRW-001** | StrokePoint captures all stylus fields | Construct StrokePoint from a mocked PointerEvent with known pressure/tilt; assert all fields equal. | **UNIT** | *All 7 fields match input values to float32 precision* | **P0** |
| **DRW-002** | Stroke.boundingRect is correct | Construct Stroke with known points; assert boundingRect inflated by weight/2 on all sides. | **UNIT** | *Rect matches expected within 0.001 tolerance* | **P0** |
| **DRW-003** | Stroke serialization round-trip | Serialize Stroke to JSON; deserialize; assert all fields equal original. | **UNIT** | *Full equality including nested StrokePoint list* | **P0** |
| **DRW-004** | Eraser creates tombstone, not deletion | Erase a stroke; assert original stroke still exists in DB with isTombstone=false; assert new tombstone stroke exists with erasesStrokeId set. | **INT** | *Two rows in strokes table — original \+ tombstone* | **P0** |
| **DRW-005** | Stroke commit does not block draw thread | Use Flutter driver to measure frame time during rapid stroke input; assert p95 frame time \< 16ms. | **E2E** | *p95 frame time \< 16ms over 500 stroke points* | **P0** |
| **DRW-006** | Palm rejection — tool type filter | Send PointerEvent with kind=touch while a pen event is active; assert touch event is ignored. | **INT** | *No new stroke created from touch event during pen session* | **P1** |
| **DRW-007** | Undo removes stroke from render, not from DB | Draw a stroke, undo; assert stroke is absent from rendered output; assert stroke row still exists in DB. | **INT** | *DB row present; canvas does not include stroke in replay* | **P1** |
| **DRW-008** | Single-point tap creates valid stroke | Simulate ACTION\_DOWN immediately followed by ACTION\_UP; assert stroke created with exactly 1 point. | **UNIT** | *Stroke.points.length \== 1; no crash* | **P1** |

## **5.2  OCR Pipeline**

| Test ID | Requirement | Test Description | Type | Acceptance Criteria | Priority |
| :---- | :---- | :---- | ----- | :---- | ----- |
| **OCR-001** | DirtyRegion expands correctly | Add two strokes with known bounding rects; assert DirtyRegion union equals expected outer rect. | **UNIT** | *DirtyRegion bounds \== union of both rects \+ weight padding* | **P0** |
| **OCR-002** | DirtyRegion flush is atomic | Expand DirtyRegion; call flush(); assert returned snapshot contains correct data; assert DirtyRegion is empty after flush. | **UNIT** | *Snapshot non-null with correct bounds; post-flush isEmpty==true* | **P0** |
| **OCR-003** | OCR does not trigger during active drawing | Simulate continuous stroke input at 10Hz for 5 seconds; assert no OcrIsolate messages sent during that period. | **INT** | *Zero OCR triggers while stroke events are continuous* | **P0** |
| **OCR-004** | OCR triggers after 900ms idle | Commit a stroke; wait 950ms with no input; assert OCR isolate received exactly one DirtySnapshot. | **INT** | *One snapshot received in 900–1100ms window* | **P0** |
| **OCR-005** | Page navigation triggers immediate OCR flush | Commit strokes; navigate to different page without waiting; assert OCR snapshot created before navigation completes. | **INT** | *OCRSnapshot written to DB within 200ms of navigation event* | **P1** |
| **OCR-006** | OCR snapshot written to SQLite correctly | Trigger OCR with known strokes; assert OCRSnapshot row exists with correct pageId, region count \>= 1\. | **INT** | *Row exists with matching pageId and captured\_at within 2s* | **P1** |
| **OCR-007** | FTS5 index updated after OCR | Write a known word via simulated strokes; trigger OCR; query search\_index; assert match found. | **E2E** | *SELECT from search\_index returns row with matching text* | **P1** |
| **OCR-008** | Only dirty region is re-OCRd (not full page) | Draw on two separate non-overlapping regions; trigger OCR for only one; assert only the dirty region strokes are in the snapshot. | **INT** | *DirtySnapshot.strokeIds contains only strokes from dirty region* | **P2** |

## **5.3  Version History & Branching**

| Test ID | Requirement | Test Description | Type | Acceptance Criteria | Priority |
| :---- | :---- | :---- | ----- | :---- | ----- |
| **VER-001** | Stroke log is ordered and append-only | Add 5 strokes; retrieve page\_stroke\_order; assert sort\_order is 0,1,2,3,4 with correct stroke IDs. | **INT** | *Ordered sequence, no gaps, no out-of-order entries* | **P0** |
| **VER-002** | Page replay produces identical canvas | Render page; capture snapshot. Clear render cache. Replay stroke log. Capture snapshot. Assert equal. | **E2E** | *Pixel-perfect or vector-identical render on replay* | **P0** |
| **VER-003** | Timeline scrub to midpoint is accurate | Page with 10 strokes. Scrub to stroke 5\. Assert canvas shows exactly 5 strokes, not 4 or 6\. | **E2E** | *Canvas stroke count equals scrub position exactly* | **P1** |
| **VER-004** | Branch shares strokes with parent | Create page with 5 strokes. Branch at stroke 3\. Assert branch.sharedStrokeIds \== strokes\[0..2\]; branch.ownStrokeIds \== \[\]. | **UNIT** | *Shared and own stroke ID lists correct at creation* | **P0** |
| **VER-005** | Branch strokes do not duplicate in DB | Create page with 5 strokes. Branch at stroke 3\. Add 2 strokes to branch. Assert DB strokes table has exactly 7 rows total (5 \+ 2, not 5 \+ 5 \+ 2). | **INT** | *strokes table row count \== 7; no duplication* | **P0** |
| **VER-006** | Parent page unaffected by branch mutations | Branch from parent. Add strokes to branch. Assert parent.strokeIds is unchanged. | **INT** | *Parent strokeIds length and content identical before and after branch mutation* | **P1** |
| **VER-007** | OCR checkpoint appears in timeline | Draw, trigger OCR, draw more. Assert OCR snapshot timestamp is present as a named marker in page timeline data. | **INT** | *OCRSnapshot.capturedAt maps to a valid timeline position* | **P2** |

## **5.4  Sync Pipeline**

| Test ID | Requirement | Test Description | Type | Acceptance Criteria | Priority |
| :---- | :---- | :---- | ----- | :---- | ----- |
| **SYN-001** | Every stroke commit creates a SyncEvent | Commit a stroke; assert exactly one SyncEvent with type=strokeAdded exists in sync\_queue with status=pending. | **INT** | *One pending row in sync\_queue per committed stroke* | **P0** |
| **SYN-002** | Sync queue persists across app restart | Create pending SyncEvents; kill app; relaunch; assert events still in sync\_queue with status=pending. | **INT** | *All pending events survive process death* | **P0** |
| **SYN-003** | Offline drawing queues correctly | Disable network; draw 10 strokes; assert 10 pending SyncEvents; re-enable; assert all become synced. | **E2E** | *10 pending → 0 pending after reconnect (within 30s)* | **P0** |
| **SYN-004** | Duplicate stroke UUID is idempotent | Send same SyncEvent(strokeAdded) twice; assert only one stroke row exists in DB. | **INT** | *strokes table has one row; no duplicate key error* | **P0** |
| **SYN-005** | Conflict: two devices update page metadata | Simulate two SyncEvents for same pageId with different styles and timestamps T1 \< T2. Apply both. Assert final style matches T2 event. | **UNIT** | *Last-write-wins: final value equals T2 payload* | **P1** |
| **SYN-006** | Gallery images never in stroke sync payload | Inspect all SyncEvents of type strokeAdded; assert no event payload contains image binary data or base64 strings. | **INT** | *All strokeAdded payloads contain only stroke field keys* | **P0** |
| **SYN-007** | Failed sync retries with backoff | Mock Supabase to return 503; trigger sync; assert retry\_count increments and events re-attempted up to 5 times. | **INT** | *retry\_count reaches 5; status becomes "failed" after 5th failure* | **P2** |

## **5.5  Gallery Pipeline**

| Test ID | Requirement | Test Description | Type | Acceptance Criteria | Priority |
| :---- | :---- | :---- | ----- | :---- | ----- |
| **GAL-001** | Image stored once, referenced many times | Import one image; pin to 3 pages. Assert gallery\_images table has 1 row; image\_pins has 3 rows. | **INT** | *One GalleryImage record; three ImageRef/pin records* | **P0** |
| **GAL-002** | GalleryImage.pageRefs is bidirectional | Pin image to page A and B. Assert GalleryImage.pageRefs \== \[pageA.id, pageB.id\]. | **INT** | *pageRefs contains both page IDs* | **P1** |
| **GAL-003** | Unpinning removes ImageRef but not GalleryImage | Pin image to page; unpin; assert image\_pins row deleted; gallery\_images row still exists. | **INT** | *Unpin: pin row gone; image row present* | **P1** |
| **GAL-004** | Image file syncs separately from stroke log | Import image; assert GalleryImage SyncEvent type=imageAdded exists; assert no stroke SyncEvents reference image data. | **INT** | *Image sync uses imageAdded event type; isolation confirmed* | **P1** |
| **GAL-005** | Gallery shows all pages referencing an image | Pin image to 5 pages; open gallery detail view; assert 5 page thumbnails visible. | **E2E** | *5 page references displayed in gallery detail view* | **P2** |

## **5.6  Perspective Drawing Tools**

| Test ID | Requirement | Test Description | Type | Acceptance Criteria | Priority |
| :---- | :---- | :---- | ----- | :---- | ----- |
| **PER-001** | PerspectiveConfig serializes and deserializes | Create config with 2 vanishing points; serialize to JSON; deserialize; assert all VP coordinates match. | **UNIT** | *Full field equality after round-trip* | **P0** |
| **PER-002** | 1-point perspective: strokes snap to single VP | Enable 1-point mode with VP at (500, 400); draw stroke; assert all stroke points lie on rays originating from VP within 5 canvas units. | **E2E** | *Stroke geometry snaps to perspective rays* | **P1** |
| **PER-003** | 2-point perspective: horizon line is configurable | Set horizon to Y=300; assert guide lines draw at Y=300 across full canvas width. | **E2E** | *Horizon line rendered at configured Y coordinate* | **P1** |
| **PER-004** | Vanishing point drag updates guides live | Drag VP handle; assert guide lines update position with \< 16ms render lag. | **E2E** | *Guide line position matches VP handle position in real-time* | **P2** |
| **PER-005** | Perspective config saved per page | Set 2-point perspective on page A; navigate to page B (plain); return to A; assert perspective config unchanged. | **INT** | *PerspectiveConfig persists across navigation* | **P1** |

| 6\.  Build Order & Milestones |
| :---- |

Features are built in dependency order. Each milestone has a clear definition of done tied to the test matrix. No milestone is considered complete until its P0 tests pass.

| Phase | Milestone | Deliverable | P0 Tests Required | Est. Effort |
| :---- | :---- | :---- | :---- | :---- |
| 1 | Data Foundation | SQLite schema initialized; DatabaseService CRUD for Stroke, SketchPage, Chapter; StrokePoint binary packing. | DRW-001, DRW-003, VER-001 | 1 week |
| 2 | Drawing Canvas | CustomPainter with stylus Listener; live stroke preview; pen-up commit; pressure-sensitive line width. | DRW-002, DRW-005, DRW-008 | 1.5 weeks |
| 3 | Page Backgrounds | Plain, grid, and dot overlay painters; GridConfig persisted per page; style selector UI. | PER-005 (config persistence pattern) | 0.5 weeks |
| 4 | Stroke Persistence & Sync Queue | Stroke → SQLite on pen-up; SyncEvent created per stroke; SyncQueue worker stub. | SYN-001, SYN-002, SYN-006 | 1 week |
| 5 | OCR Pipeline | DirtyRegion tracker; debounce timer; OcrIsolate; ML Kit integration; FTS5 upsert. | OCR-001, OCR-002, OCR-003, OCR-004 | 1.5 weeks |
| 6 | Search UI | Search bar; FTS5 query; result list with canvas scroll-to; match highlight. | OCR-006, OCR-007 | 0.5 weeks |
| 7 | Version History UI | Timeline scrubber widget; stroke-log replay; snapshot pin markers. | VER-002, VER-003, VER-007 | 1 week |
| 8 | Branching | Branch creation from any timeline point; branch page model; branch picker UI. | VER-004, VER-005, VER-006 | 1 week |
| 9 | Perspective Tools | VanishingPoint handle widget; guide line painter; 1- and 2-point perspective; stroke snapping. | PER-001, PER-002, PER-003, PER-005 | 1.5 weeks |
| 10 | Gallery | Image import (camera \+ files); GalleryImage index; ImageRef pin on canvas; bidirectional pageRefs. | GAL-001, GAL-002, GAL-003 | 1 week |
| 11 | Cloud Sync | Supabase project setup; SyncQueue worker connected; offline/online detection; conflict resolution. | SYN-003, SYN-004, SYN-005, SYN-007 | 2 weeks |
| 12 | Polish & Performance | Palm rejection tuning; timelapse export; performance profiling; P2/P3 test pass. | DRW-006, DRW-007, OCR-008, GAL-005 | 1 week |

| 7\.  Open Questions & Deferred Decisions |
| :---- |

These decisions have been intentionally deferred. They must be resolved before the relevant phase begins.

| ID | Question | Phase Needed By | Options Under Consideration |
| :---- | :---- | :---- | :---- |
| OQ-01 | How many active layers per page will v1 support? | Phase 2 | 1 layer only (simplest); 3 layers (sketch / lineart / notes); unlimited (most flexible but complex) |
| OQ-02 | What is the tile size for the infinite canvas render cache? | Phase 2 | 256x256 px (more tiles, less overdraw); 512x512 px (standard); 1024x1024 px (fewer tiles, more VRAM) |
| OQ-03 | Should timelapse export be in-app or share-only? | Phase 8 | Share only (simpler — uses MediaStore); in-app preview first, then share; save to Files app |
| OQ-04 | Is 3-point perspective in scope for v1? | Phase 9 | Yes (complete feature); No (1 and 2 point only); Later (deferred to v1.1) |
| OQ-05 | Multi-user notebook sharing model for v2? | Phase 11 | Owner-only sync (simplest); shared notebooks (requires ACL); real-time co-sketch (complex, deferred) |
| OQ-06 | What is the maximum notebook size before performance degrades? | Phase 1 | Needs profiling target: 10,000 strokes? 100,000? Per page limit or total? |

| Appendix A — SQLite Schema Summary |
| :---- |

| Table | Purpose | Key Columns |
| :---- | :---- | :---- |
| notebooks | Top-level container | id, title, owner\_id |
| chapters | Named page groups | id, notebook\_id, title, sort\_order |
| pages | Canvas metadata | id, chapter\_id, style, parent\_page\_id, branch\_point\_stroke\_id |
| strokes | The event log (source of truth) | id, page\_id, tool, points\_blob, is\_tombstone, erases\_stroke\_id, synced |
| page\_stroke\_order | Ordered log per page | page\_id, stroke\_id, sort\_order |
| gallery\_images | Parallel image index | id, notebook\_id, local\_path, cloud\_storage\_ref, page\_refs\_json |
| image\_pins | Image pinned to canvas location | page\_id, image\_id, anchor\_x, anchor\_y |
| ocr\_snapshots | Cached OCR results | id, page\_id, stroke\_count, regions\_json, captured\_at |
| search\_index | FTS5 full-text search | page\_id, chapter\_id, text, canvas\_x, canvas\_y |
| sync\_queue | Pending sync outbox | id, event\_type, entity\_id, payload\_json, status, retry\_count |

| Appendix B — Dependency Manifest |
| :---- |

| Package | Version | Purpose | License |
| :---- | :---- | :---- | :---- |
| sqflite | ^2.3.0 | Local SQLite — stroke log, sync queue, OCR cache, FTS5 search | BSD-3 |
| flutter\_riverpod | ^2.4.9 | State management across all services and UI | MIT |
| uuid | ^4.2.1 | UUID v4 generation for all entity IDs | MIT |
| google\_mlkit\_digital\_ink\_recognition | ^0.13.0 | On-device handwriting OCR — vector mode, no server needed | Apache-2.0 |
| supabase\_flutter | ^2.3.0 | Cloud sync, auth, object storage for gallery images | Apache-2.0 |
| image\_picker | ^1.0.5 | Camera and photo library access for gallery import | BSD-3 |
| image | ^4.1.3 | Thumbnail generation (runs in isolate, not UI thread) | MIT |
| path\_provider | ^2.1.1 | Resolves app document and cache directories | BSD-3 |
| collection | ^1.18.0 | Sorted lists and collection equality utilities | BSD-3 |

*Document maintained alongside the codebase. Update this document before changing any architectural decision.*