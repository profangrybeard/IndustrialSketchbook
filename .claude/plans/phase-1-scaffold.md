# Industrial Sketchbook: Dev Pipeline & Project Scaffold Plan

## Context

You have a comprehensive TDD for an infinite-canvas sketchbook app targeting your OnePlus Pad with Flutter/Android. This plan scaffolds the project structure so you can start building Phase 1 immediately.

**TDD note**: The TDD says StrokePoint is 28 bytes but specifies "6 x Float32 + 1 x Int64" which is actually 32 bytes (24 + 8). The implementation will use the correct 32-byte layout and we should update the TDD.

## Completed ✅
- Part 1: Flutter SDK installed at `C:\dev\flutter`, Android Studio + SDK installed, env vars set, `flutter doctor` green
- Part 3.0: `flutter create` done — project scaffolded at `C:\SCAD\Projects\IndustrialSketchbook`
- Verified: `build.gradle.kts` uses Kotlin DSL, namespace `com.profangrybeard.industrial_sketchbook`
- Verified: SDK uses `flutter.minSdkVersion` / `flutter.targetSdkVersion` (needs override to 33/34)

## Remaining Work (Claude Code implements now)
- Part 2: Wireless ADB (user does when ready to deploy to tablet)
- Part 3.1: Edit `build.gradle.kts` — set minSdk=33, targetSdk=34
- Part 3.2: Edit `pubspec.yaml` — add all TDD dependencies
- Part 3.3: Edit `AndroidManifest.xml` — add permissions
- Part 3.3-3.4: Create all model, service, provider, widget, and test files
- Part 4: Verify with `flutter pub get` + `flutter test`

---

## Part 1: Toolchain Installation (You Do Manually)

These steps require GUI installers and persistent environment variable changes — Claude Code can't do them.

### 1.1 Install Flutter SDK
- Download from https://docs.flutter.dev/get-started/install/windows/mobile
- Extract to `C:\dev\flutter` (avoid paths with spaces)
- Add `C:\dev\flutter\bin` to your system PATH

### 1.2 Install Android Studio
- Download from https://developer.android.com/studio
- Run installer, accept defaults (bundles Android SDK + JDK)
- SDK installs to `C:\Users\rinds\AppData\Local\Android\Sdk`

### 1.3 Set Environment Variables
| Variable | Value |
|---|---|
| `ANDROID_HOME` | `C:\Users\rinds\AppData\Local\Android\Sdk` |
| Add to `Path` | `%ANDROID_HOME%\platform-tools` |
| Add to `Path` | `%ANDROID_HOME%\cmdline-tools\latest\bin` |

### 1.4 Verify
```
flutter doctor --android-licenses   # accept all
flutter doctor -v                    # should show Flutter + Android toolchain OK
```

---

## Part 2: Wireless ADB to OnePlus Tablet (You Do Manually)

### 2.1 On Tablet
1. Settings > About Tablet > tap Build Number 7x to enable Developer Options
2. Settings > System > Developer Options > enable **Wireless debugging**
3. Tap into Wireless debugging > **Pair device with pairing code** — note IP, port, code

### 2.2 On PC
```
adb pair <ip>:<pairing-port>          # enter pairing code
adb connect <ip>:<connection-port>    # different port shown on main wireless debugging screen
flutter devices                       # should list OnePlus Pad
```

Note: Connection port changes on tablet reboot — you'll need to re-run `adb connect` each time.

---

## Part 3: Flutter Project Scaffold (Claude Code Does)

### 3.0 You Run Once
```
cd C:\SCAD\Projects\IndustrialSketchbook
flutter create --project-name industrial_sketchbook --org com.profangrybeard --platforms android .
```

### 3.1 Android Config — Claude Code Edits
- `android/app/build.gradle.kts`: set `minSdk = 33`, `targetSdk = 34`, version `0.1.0`
- `AndroidManifest.xml`: add INTERNET, CAMERA, READ_MEDIA_IMAGES permissions; declare touchscreen feature

### 3.2 pubspec.yaml — Claude Code Edits
All dependencies from TDD Appendix B at exact specified versions:
- sqflite, flutter_riverpod, uuid, google_mlkit_digital_ink_recognition
- supabase_flutter, image_picker, image, path_provider, collection

### 3.3 Project Structure — Claude Code Creates

```
lib/
  main.dart                          # ProviderScope + dark theme + placeholder canvas
  models/
    stroke_point.dart                # 7 fields, 32-byte binary packing
    stroke.dart                      # 12 fields, tombstone erasure, boundingRect
    sketch_page.dart                 # Canvas entity with stroke IDs, branching
    chapter.dart                     # Chapter entity
    notebook.dart                    # Top-level container
    gallery_image.dart               # Gallery entity
    image_ref.dart                   # Image pin on page
    grid_config.dart                 # Grid background config
    perspective_config.dart          # Vanishing point config
    tool_type.dart                   # pen|pencil|marker|brush|eraser|highlighter
    page_style.dart                  # plain|grid|dot|isometric|perspective
  services/
    database_service.dart            # Full SQLite schema (Appendix A), WAL mode, CRUD
    drawing_service.dart             # Phase 2 stub with pipeline structure from TDD §4.1
    ocr_service.dart                 # Phase 5 stub
    sync_service.dart                # Phase 11 stub
  providers/
    database_provider.dart           # FutureProvider<DatabaseService>
    notebook_provider.dart           # Notebook state stub
    drawing_provider.dart            # Drawing state stub
  widgets/
    canvas_widget.dart               # Placeholder for Phase 2
test/
  models/
    stroke_point_test.dart           # DRW-001: all 7 fields match input
    stroke_test.dart                 # DRW-002: boundingRect, DRW-003: JSON round-trip
    perspective_config_test.dart     # PER-001: serialize/deserialize VPs
  services/
    database_service_test.dart       # Schema init, CRUD, stroke ordering
integration_test/
  app_test.dart                      # E2E placeholder
```

### 3.4 Key Implementation Details
- **StrokePoint**: immutable, binary pack/unpack (6x Float32 + 1x Int64 = 32 bytes), JSON for tests
- **Stroke**: append-only, `boundingRect` computed from points inflated by `weight/2`, tombstone erasure pattern
- **DatabaseService**: creates all 10 tables from Appendix A including FTS5 virtual table, WAL mode, binary blob storage for stroke points
- **main.dart**: ProviderScope wrapping MaterialApp with dark theme, placeholder canvas screen

---

## Part 4: First Deploy Verification

### 4.1 Get deps + run tests (no device needed)
```
flutter pub get
flutter test
```
Tests DRW-001, DRW-002, DRW-003, PER-001 should pass.

### 4.2 Deploy to tablet (requires wireless ADB from Part 2)
```
flutter run
```
App should show dark-themed placeholder screen. Verify hot reload works by changing placeholder text and pressing `r`.

---

## Sequencing

```
You (parallel):
  Install Flutter + Android Studio (Part 1)  ─┐
  Set up wireless ADB on tablet (Part 2)     ─┤
  Run flutter create (Part 3.0)              ─┘
                                               │
Claude Code:                                   │
  Scaffold all project files (Part 3.1-3.4)  ──┤
                                               │
Together:                                      │
  flutter pub get + flutter test (Part 4.1)  ──┤
  flutter run to tablet (Part 4.2)           ──┘
```

Parts 1 and 2 can happen in parallel. Part 3.0 (`flutter create`) must happen after Flutter is installed. Claude Code's scaffolding (3.1-3.4) happens after `flutter create`. Everything converges at Part 4.

---

## Files Modified/Created
- `android/app/build.gradle.kts` — minSdk, targetSdk
- `android/app/src/main/AndroidManifest.xml` — permissions
- `pubspec.yaml` — all TDD dependencies
- `lib/**` — 16 new files (models, services, providers, widgets)
- `test/**` — 4 new test files
- `integration_test/app_test.dart` — 1 placeholder

## Verification
1. `flutter test` — all Phase 1 unit tests pass
2. `flutter run` — app launches on OnePlus Pad over wireless ADB
3. Hot reload — change text in main.dart, press `r`, see update on tablet
