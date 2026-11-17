# Orbit

Native macOS media center with a libmpv-based player. "Orbit" is a placeholder name.
The full product spec is the original brief; this file is the working reference.

## Ground rules

- **Stage gate:** a stage is done only when `Scripts/ci.sh` passes (zero warnings, all tests), the app
  has been run and its acceptance criteria checked, and the work is committed.
- **Branding in one place:** name and bundle id live in `Config/Branding.xcconfig`; the icon in
  `App/Assets.xcassets/AppIcon.appiconset`. Swift code reads them through `App/Branding.swift`
  (`AppBranding` is injected into packages). Never hard-code the app name anywhere else. The Xcode
  project, target, scheme and module are deliberately called `MediaCenter`, and packages have
  brand-neutral names.
- **No third-party branding:** never use Stremio's or IINA's names, logos or artwork in UI or assets.
  (The add-on protocol's `stremio://` install scheme and add-on host names are protocol facts, not branding.)
- **Licensing:** do not copy or adapt code from Stremio, IINA or any other repo without checking its
  licence and telling the user first. IINA is GPL-3.0; reusing its code would make the whole app GPL-3.0.
  Write our own code on top of libmpv.
- **Add-ons are neutral:** the only pre-installed add-ons are in `Config/DefaultAddons.json`
  (Cinemeta for metadata, OpenSubtitles for subtitles). Never pre-install, hard-code, suggest or link a
  streaming source or piracy add-on. Users install add-ons by URL.
- **Ask the user before:** adding a paid dependency, changing the minimum macOS version (14.0), or any
  architectural decision that is hard to reverse.
- **Test media:** generate with ffmpeg only. Never download copyrighted content.

## Commands

```bash
xcodegen generate                 # regenerate MediaCenter.xcodeproj (not committed)
Scripts/ci.sh                     # format check + lint + Debug build (warnings = errors) + all tests
Scripts/ci.sh --release           # the above + universal Release build (arm64 + x86_64)
swiftformat .                     # apply formatting
Scripts/measure-launch.sh 5       # launch time + idle memory of the Release build
swift Scripts/generate-icon.swift App/Assets.xcassets/AppIcon.appiconset   # redraw placeholder icon

# One package, fast (no Xcode project needed):
cd Packages/MediaCore && swift test

# Manual xcodebuild (what ci.sh runs):
xcodebuild -project MediaCenter.xcodeproj -scheme MediaCenter -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build   # or: test
```

Built app: `build/DerivedData/Build/Products/{Debug,Release}/Orbit.app`. Logs: `build/logs/`.

### Running the app for verification

Launch it in the **background** so it does not steal focus from the user, and capture the window by id:

```bash
open -g build/DerivedData/Build/Products/Debug/Orbit.app
# find the window id with CGWindowListCopyWindowInfo (owner name = app name), then:
screencapture -x -o -l <windowID> /path/to/shot.png
pkill -f "Orbit.app/Contents/MacOS"
```

`open` without `-g` brings the window to the front; the user was working and quit it (⌘Q) both times
during Stage 1. Quit any instance you start.

## Architecture

```
App/ (target MediaCenter)   entry point + composition root + Branding. No feature logic.
  └─ AppUI                  SwiftUI screens, @Observable view models, image pipeline
       ├─ PlayerKit         libmpv wrapper, render view, track selection, controls, config parsing
       ├─ StreamEngine      torrent bridge (Obj-C++), piece prioritiser, local HTTP Range server, cache
       ├─ MediaLibrary      GRDB/SQLite: settings, library, history, resume, installed add-ons
       └─ MediaCore         models, add-on protocol client, HTTP client (timeout/retry/cancel), branding
```

- Five local Swift packages under `Packages/`. Dependencies point one way, down to `MediaCore`.
  `PlayerKit` and `StreamEngine` do not know about each other or about `MediaLibrary`; they are joined
  through protocols defined in `MediaCore` and wired in the app target.
- **MVVM with `@Observable`.** View models are `@MainActor final class`es; views hold no business logic
  and are not unit-tested, view models are.
- **Persistence: GRDB** (MIT). Chosen over SwiftData for explicit append-only migrations, Sendable
  value-type records under strict concurrency, in-memory databases in tests, and a schema that can be
  made sync-ready (`updatedAt` on synced rows). Migrations live in `LibraryDatabase.migrator`; never edit
  one that has shipped.
- **Distribution:** outside the App Store. Hardened runtime on, App Sandbox off (mpv.conf access, local
  HTTP server, torrent engine). Local builds are ad-hoc signed; Developer ID signing arrives in Stage 9.
- **Networking rule:** every call has a timeout, supports cancellation, retries with `RetryPolicy`
  backoff, and surfaces a clear error state in the UI.
- **Dependencies are pinned exactly** in each `Package.swift` because the generated Xcode project (and
  its `Package.resolved`) is not committed.

### Decisions still to be made (with the stage that decides them)

| Stage | Decision | Current recommendation |
|---|---|---|
| 3 | Render path | `vo=gpu-next` over MoltenVK into a `CAMetalLayer`; fallback libmpv render API + OpenGL layer. Decide by spike. |
| 3 | libmpv source | MPVKit LGPL build, dynamically linked. Verify variant and licence files before adding. |
| 4 | Audio transcode fallback | Bundled ffmpeg helper as the last step of a fallback chain; size/licence to be approved. |
| 4 | Picture-in-Picture | Floating always-on-top window with public APIs (no private PIP.framework). |
| 2 | Trailers | Embedded YouTube player (no stream extraction). |
| 9 | Notarisation | Needs a paid Developer ID certificate; ask first. |

Known limits to state honestly in the UI/docs: mpv tone-maps Dolby Vision to HDR10/SDR but cannot emit a
true Dolby Vision signal; libmpv decodes AC3/E-AC3/DTS itself, so the AAC transcode path will rarely run.

## Conventions

- Swift 6 language mode, strict concurrency, `ExistentialAny` on. Packages use swift-tools-version 6.2
  with `.treatAllWarnings(as: .error)`; the app target uses `SWIFT_TREAT_WARNINGS_AS_ERRORS`.
- Formatting is owned by SwiftFormat (`.swiftformat`), linting by SwiftLint in strict mode
  (`.swiftlint.yml`). Run `swiftformat .` before committing. No force unwraps in app or package code.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), with parameterised cases for parsers.
  Pure logic (parsing, selection, prioritisation, scheduling) is written as value types or static
  functions with injected inputs (time, randomness) so tests are deterministic.
- Typed throws for small closed error sets (`throws(AddonURLError)`); errors are `Sendable`.
- Comments explain why, not what. Doc comments on every public type and non-obvious public member.
- User-facing strings are plain English in view models / enums for now (no localisation yet).
- Logging: `os.Logger` with subsystem = bundle identifier. Never `print` in app code.
- Commit after every completed step with a clear message. Do not commit `build/`, `Vendor/` or the
  generated project.

## Environment

- Built with Xcode 27.2 / Swift 6.4.2 on macOS 27.2, Apple Silicon. Deployment target macOS 14.0.
- Runtime testing is only possible on this machine's OS and architecture. The x86_64 slice is built and
  checked with `lipo` but not executed; macOS 14–26 behaviour is not runtime-tested.
- Tools (Homebrew): xcodegen 2.46, swiftformat 0.64, swiftlint 0.65, ffmpeg 9.0. Still to install:
  cmake, ninja, pkg-config (Stage 5); create-dmg (Stage 9).

## Stage checklist

- [x] **1. Skeleton** — XcodeGen project, five packages, CLAUDE.md, branding, placeholder icon, CI script
- [ ] **2. Add-on client + browsing** — protocol client, Cinemeta, Home, Discover, Search, Detail
- [ ] **3. Player core** — libmpv embedding, Metal view, basic controls, file + HTTP playback
- [ ] **4. Player features** — everything in spec section 3B
- [ ] **5. Streams + torrent engine** — stream list, libtorrent bridge, local HTTP server, cache
- [ ] **6. Library** — Continue Watching, resume, next-episode autoplay, calendar
- [ ] **7. Settings + polish** — shortcuts, mpv.conf/input.conf, accessibility
- [ ] **8. Performance pass** — measure every target in spec section 4
- [ ] **9. Packaging** — signed .app + .dmg, Sparkle, README

### Stage 1 contents

| Package | Real code so far | Tests |
|---|---|---|
| MediaCore | `AppBranding`, `MediaType`, `AddonTransportURL` (install-URL normalisation), `RetryPolicy`, `LaunchMetrics` | 12 |
| MediaLibrary | `LibraryDatabase` (GRDB, migration `v1-settings`), `SettingsStore` | 5 |
| StreamEngine | `HTTPByteRange` (RFC 9110 single-range resolution) | 5 |
| PlayerKit | `PlaybackSpeed` (0.25×–16× clamp and preset ladder) | 5 |
| AppUI | `AppSection`, `AppModel`, `RootView` (sidebar shell with empty states), `SettingsView` | 4 |

## Performance log

Targets (spec section 4): cold launch < 1.5 s; idle memory < 250 MB; playing 4K HDR < 600 MB;
4K HEVC 10-bit HDR CPU < 30 % on M1; HTTP time-to-first-frame < 2 s; no main-thread work > 8 ms while scrolling.

| Date | Stage | Build | Measurement | Result |
|---|---|---|---|---|
| 2026-11-17 | 1 | Release, arm64 | Launch to first screen, warm cache, median of 5 (`measure-launch.sh`) | 173 ms (min 165) |
| 2026-11-17 | 1 | Release, arm64 | Launch to first screen, first run after build | 463 ms |
| 2026-11-17 | 1 | Debug, arm64 | Launch to first screen, first run after build | 622 ms |
| 2026-11-17 | 1 | Release, arm64 | Idle memory, empty shell: physical footprint / RSS | 30 MB / 97 MB |

Not yet measured: a true cold launch (after reboot or `sudo purge`), and Instruments traces (Time
Profiler, Allocations, Leaks). The shell has no workload worth profiling yet; Instruments runs start in
Stage 2 when there is real scrolling and networking.
