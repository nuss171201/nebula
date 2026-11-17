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

# One package, fast (no Xcode project needed):
cd Packages/MediaCore && swift test
LIVE_ADDON_TESTS=1 swift test --filter LiveAddonTests   # opt-in: hits the real default add-ons
cd Packages/AppUI && LIVE_ADDON_TESTS=1 swift test --filter LiveSubtitleServiceTests   # opt-in: lists, never downloads

# Prerequisites that ci.sh runs for you (both skip work that is already done):
Scripts/build-mpv-framework.sh    # Packages/PlayerKit/Vendor/Libmpv.xcframework from Config/mpv-libraries.lock
Scripts/build-torrent-framework.sh  # Packages/StreamEngine/Vendor/Libtorrent.xcframework from Config/torrent-libraries.lock (needs cmake, ninja)
Scripts/make-test-media.sh        # TestMedia/: 1080p H.264, 4K HDR10 HEVC, multi-track MKV, external subs

# Looking at the running app without taking focus (Debug build):
Scripts/screenshot.sh /path/shot.png 6                          # Home
Scripts/screenshot.sh /path/shot.png 6 -section discover        # also: library, calendar, addons
Scripts/screenshot.sh /path/shot.png 7 -search "the office"
Scripts/screenshot.sh /path/shot.png 7 -open series:tt0386676   # a detail page
Scripts/screenshot.sh /path/shot.png 6 -silent YES -play "$PWD/TestMedia/sdr-h264-1080p.mp4"   # player
Scripts/stage-media.sh TestMedia/multi-track.mkv   # prints a copy's path outside ~/Documents, for -play

# Playback over HTTP (Range-capable; python's http.server is not):
Scripts/serve-test-media.py 8765 &          # then -play http://127.0.0.1:8765/<file>; add --throttle-kbps N

# Measuring (Release build; run Scripts/ci.sh --release first):
Scripts/measure-launch.sh 5                       # first-screen and home-content times, idle memory
CLEAR_IMAGE_CACHE=1 Scripts/profile-launch.sh 8   # Time Profiler around a launch, summarised
Scripts/measure-playback.sh TestMedia/hdr10-hevc-4k60.mkv 10            # first frame, CPU, memory, leaks
Scripts/measure-playback.sh TestMedia/hdr10-hevc-4k60.mkv 10 "profile=fast"   # with extra engine options

swift Scripts/generate-icon.swift App/Assets.xcassets/AppIcon.appiconset   # redraw placeholder icon
```

Built app: `build/DerivedData/Build/Products/{Debug,Release}/Orbit.app`. Logs: `build/logs/`.
Traces: `build/traces/` (open in Instruments).

### Running the app for verification

Always launch it in the **background** (`open -g`, which the scripts above do) and quit it afterwards.
`open` without `-g` brings the window to the front; the user was working and quit it (⌘Q) both times
during Stage 1. Debug builds accept launch arguments that open a given state
(`App/DebugLaunchOptions.swift`): `-section`, `-search`, `-open <type>:<id>`, `-install <address>`,
`-play <path or URL>`, `-silent YES`, `-engine "name=value,…"`, `-panel video|audio|subtitles|queue` (a
player side panel), `-seekPreview <0…1>` (the seek bar's hover preview at that fraction), `-enqueue <path>`
(a second file for the queue), `-keys "]]l"` (plain key presses sent through the player's key bindings
two seconds after launch: the only way to check a binding and its on-screen notice without the keyboard).
`-subtitleSearch "<name>"` looks a title up in the player's subtitle panel (real catalog add-ons; metadata only).
`-window pictureInPicture|mini` puts the player window in that mode.
`-profile <folder>` keeps the database and caches in a scratch folder and keeps the stream engine to
this machine; with it, `-installNow <address>` installs an add-on without the confirmation click,
`-episode <video id>` shows an episode's streams and `-stream <n>` plays the nth listed stream.

**Debug arguments that touch the player are applied one main-queue turn after launch**, not in
`makeModel()`: that runs while SwiftUI is creating the app's `@State`, and resizing a window from there
re-enters SwiftUI's update and aborts (this crashed the app twice in Stage 4, with a crash dialog on the
user's screen each time). For the same reason the player window is resized through the animator, never
with the blocking `setFrame(_:display:animate:)`. Before trying a new launch argument in the app, check
`ls ~/Library/Logs/DiagnosticReports | grep Orbit` afterwards.

**Never make macOS ask the user for permission during a check.** Do not point the app at files in
`~/Documents`, `~/Desktop` or `~/Downloads` (this repository is in Documents): macOS shows a
permission dialog and the app waits on it. `screenshot.sh` and `measure-playback.sh` swap a `-play`
path for a copy made by `Scripts/stage-media.sh`; do the same in anything new. Tests are not
affected: they run under the terminal's own permission.

**Never let a check reach the network with the torrent engine.** A real torrent listens on all
interfaces and talks to the router, and macOS then asks the user to allow incoming connections (if the
firewall is on) and local-network access. Tests use `TorrentEngineSettings.loopback()`; in the app,
`-profile` does the same. Never play a torrent stream in the app without `-profile`.

**Never make a sound the user did not ask for:** every `-play` used for a check must come with
`-silent YES` (the scripts do this), and tests create players with `playsAudio: false` or volume 0.

A crash at launch puts a system dialog on the user's screen. `ci.sh --release` therefore runs the
Release binary directly first (a loader failure shows up in the log, not as a dialog).

Limits of background verification: nothing can be clicked or scrolled, and a window with a sheet
attached cannot be captured. Anything that needs interaction is covered by view-model tests, not by eye.

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

### How the browse side fits together (Stage 2)

- `AddonClient` (MediaCore) is the only code that speaks the add-on protocol. Decoding is lenient by
  design (`LenientDecoding.swift`): loose JSON types are accepted and malformed list entries are skipped,
  never fatal. Image and subtitle URLs must be http(s) so an add-on cannot point the app at local files.
- `AddonRegistry` (AppUI) is the single source of truth for installed add-ons; it persists through
  `AddonStore` (MediaLibrary). `AppModel` observes `registry.addons` and pushes changes to
  `HomeModel`, `DiscoverModel` and `SearchModel`.
- **Anything a view branches on must be an observed stored property.** A computed property over
  `@ObservationIgnored` state does not invalidate the view (this broke Discover and Search once;
  `ObservationTests` guards it).
- `ImagePipeline` (AppUI) downloads once, stores originals on disk (SHA-256 file names, LRU trim),
  decodes and downsamples off the main thread, and dedupes concurrent requests.
- Tests run against `MockAddonServer` (AddonTestSupport, in the MediaCore package): a real loopback
  HTTP server, so request URLs are verified byte for byte.

### How the player fits together (Stage 3)

- **Libmpv.framework is dynamic, on purpose.** MPVKit's LGPL build ships static archives; linking
  them into the app would statically link LGPL code. `Scripts/build-mpv-framework.sh` links the 29
  pinned libraries (SHA-256 verified, GPL variants and Samba excluded) into one dynamic framework that
  exports only libmpv's 54 public functions. PlayerKit sees just that framework, so the libraries can
  later come from a from-source build without touching player code. MPVKit's README calls itself
  "only suitable for learning" and lightly maintained; treat it as a dependency to replace, not to trust.
- **Local signing needs an entitlement.** An ad-hoc signature has no Team ID, so the hardened runtime
  refuses to load the embedded framework. `Config/LocalSigning.entitlements` disables library validation
  for local builds only; a Developer ID build (Stage 9) must not carry it.
- `MPVClient` wraps one engine: commands and property writes are asynchronous; a dedicated thread
  translates engine events to `PlayerEvent` values; the playhead is forwarded about 15 times a second
  without ever dropping the newest value. `PlaybackState` is a pure reduction of those events.
  `PlayerModel` (@MainActor) owns client, state and surface, and exposes intents.
- **The app is in sole control of the engine:** its config files, scripts, key bindings, on-screen
  controller and window are switched off (`PlayerConfiguration.engineOptions`). `PlayableSource` only
  admits `file`, `http` and `https`, because addresses will come from add-ons and the engine
  understands schemes that read local files or run filters.
- **Render path: `vo=gpu-next` through MoltenVK into a `CAMetalLayer`** (passed as `wid`), with
  VideoToolbox decoding. No OpenGL fallback is built.
- **The surface is a fixed-size canvas, scaled by Core Animation** (`PlayerSurfaceView`,
  `CanvasGeometry`). This engine build cannot be told its surface was resized: mpv raises the
  external-resize control only for Android and Direct3D, and MPVKit's Metal context implements no
  events, so after a resize the picture stayed laid out for the old size. The canvas is created once at
  the screen's pixel size (capped at 3840 on the long edge); the engine letterboxes the video inside
  it; the view shows the video's rectangle scaled to fit. Costs: rendering is always at screen
  resolution, and windows smaller than the screen see a Core Animation downscale. The proper fix is a
  resize event in the engine's Metal context, which needs a patched from-source build.
- **Render quality defaults to `efficient`** (`profile=fast` plus ordered dithering) because the
  engine's default pipeline misses the CPU and memory targets at 4K (see the performance log).
  `RenderQuality.high` keeps the engine defaults for a future Settings choice.
- This FFmpeg build has no image encoders, so mpv's own screenshot-to-file fails; screenshots use
  `screenshot-raw` and are encoded with ImageIO (`FrameImage`, `ScreenshotFile`).
- The system audio output this build picks is `avfoundation`, not `coreaudio`.

### How streaming fits together (Stage 5)

```
detail page ─ StreamListModel ─ AddonClient.streams (every add-on with a stream resource, in parallel)
     │ choice
StreamPlayer ─┬─ web address ───────────────────────────────► PlayerCoordinator.play
              ├─ torrent ─ StreamManager.open ─ TorrentEngine ─ TorrentBridge (Obj-C++) ─ libtorrent
              │                │                    │ pieces
              │                └─ StreamServer ◄────┘  http://127.0.0.1:<port>/<token>/<file> ─► player
              ├─ YouTube ─ TrailerView          └─ external page ─ the browser (http/https only)
```

- **libtorrent is built from source, static, into `Libtorrent.xcframework`** (2.0.15, BSD; Boost 1.92
  headers, BSL; the OpenSSL pinned for the player, Apache-2.0). Static is fine for these licences; their
  texts are in the framework's `Licenses/` and must ship with the app (Stage 9). The bridge must be
  compiled with the definitions in `public-defines.txt` (`Package.swift` repeats them): a missing one
  (`TORRENT_NO_DEPRECATE` selects the ABI namespace) shows up as undefined symbols at link time.
- **Swift never sees C++.** `TorrentBridge` is Objective-C on the outside; `TorrentEngine` is an actor
  that turns its callbacks into an ordered event stream and async calls with cancellable waiters.
- **`PiecePrioritizer` is pure.** From where each reader is: the next 8 MB are urgent (deadlines rising
  piece by piece), the next 48 MB are fetched ahead, the rest of the file is background; before the
  player asks for anything, both ends of the file are urgent (containers keep their index there).
  Only the difference between two plans is sent to libtorrent. A file larger than the cache budget is
  not fetched whole.
- **The player reads torrents over HTTP from `StreamServer`**: loopback only, a random 128-bit token in
  every address, and the Host header must be a loopback name (so a web page cannot be tricked into
  fetching a stream). One connection is one reader; when the player hangs up (every seek), the reader
  is closed at once and its pieces stop being urgent.
- **Streams are remembered by what they are, not where they are**: the loopback address changes every
  time, so tracks and position are stored under `video:<type>:<id>` and `title:<type>:<id>`
  (`StreamVideo.memoryKeys`). Hover thumbnails are off for torrents: a second reader far from the
  playhead would take pieces from what is about to be watched.
- **Cache**: one folder per info hash under `Caches/<bundle id>/Streams`, measured by allocated size
  (files are sparse), trimmed least-recently-watched first to 10 GB at launch and whenever a stream
  closes; what is playing is never removed. The budget becomes a setting in Stage 7.
- **Neutrality**: with no stream add-on installed the detail page says so and suggests nothing.

### Decisions still to be made (with the stage that decides them)

| Stage | Decision | Current recommendation |
|---|---|---|
| 8 | Subtitles in black bars | With the fixed canvas, subtitles are kept inside the picture (`sub-use-margins=no`). Revisit with the engine build. |
| 8 | Engine build | Build libmpv from source with a resize event in the Metal context, replacing the fixed canvas. |
| 9 | Bundling ffmpeg for the audio fallback | The fallback chain exists and uses an ffmpeg the user has installed. Shipping an LGPL ffmpeg helper inside the app (tens of MB) is the user's call; ask before doing it. |
| 9 | Notarisation | Needs a paid Developer ID certificate; ask first. |

Decided (Stage 4): **HDR output is on only while an HDR video is on an HDR-capable display**
(`PlayerModel.updateHDROutput`). `target-colorspace-hint=yes` makes the renderer switch the canvas layer
to PQ/HLG with extended range, and macOS maps that to the display. It is off for standard video on
purpose: with the hint on, SDR is tagged BT.709, which macOS shows with a different gamma (washed out).
The engine option to leave one decoder out (`ad=-name`) does nothing in this build; only an allow-list
ending in `-` works (`ad=eac3,dca,aac,-`), which is how the audio fallback is tested.

Decided: trailers play in YouTube's embedded player (`TrailerView`), never by extracting streams. The
page is loaded with `https://<bundle id>` as its origin because YouTube requires embedders to send a referrer.

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
- Tools (Homebrew): xcodegen 2.46, swiftformat 0.64, swiftlint 0.65, ffmpeg 9.0, cmake 4.5, ninja 1.13.
  Still to install: create-dmg (Stage 9).

## Stage checklist

- [x] **1. Skeleton** — XcodeGen project, five packages, CLAUDE.md, branding, placeholder icon, CI script
- [x] **2. Add-on client + browsing** — protocol client, Cinemeta, Home, Discover, Search, Detail, Add-ons
- [x] **3. Player core** — libmpv embedding, Metal view, basic controls, file + HTTP playback
- [x] **4. Player features** — everything in spec section 3B (the shortcut editor and mpv.conf/input.conf are Stage 7)
- [x] **5. Streams + torrent engine** — stream list, libtorrent bridge, local HTTP server, cache
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

### Stage 2 contents

| Package | Added | Tests |
|---|---|---|
| MediaCore | Protocol models (manifest, meta, stream, subtitles), lenient decoding, resource paths, `HTTPClient` with retry, `AddonClient`, `InstalledAddon`; target `AddonTestSupport` (mock server, fixtures, stub client) | 54 (2 opt-in live) |
| MediaLibrary | `AddonStore`, migration `v2-addons` | 10 |
| AppUI | `ImagePipeline`, `AddonRegistry`, view models and views for Home, Discover, Search, Detail, Add-ons, trailer sheet | 45 |
| App | `DefaultAddons` (bundled JSON), `DebugLaunchOptions` | — |

Carried over to later stages:

- Detail page: "mark watched" and "add to library" belong with the library (Stage 6); episodes become
  playable with the player and stream list (Stages 3 and 5).
- Not verified by eye because they need a click or a scroll: trailer playback (the embed was checked
  offscreen and loads the right video), the install confirmation sheet, drag-to-reorder, and Discover's
  paging in the live app. Their logic is unit-tested.
- Scrolling smoothness (120 Hz, no main-thread work > 8 ms) is unmeasured for the same reason; measure
  it in Stage 8 with a UI test or by hand in Instruments.

### Stage 3 contents

| Where | Added | Tests |
|---|---|---|
| Scripts, Config | `build-mpv-framework.sh` + `mpv-libraries.lock`, `make-test-media.sh`, `serve-test-media.py`, `measure-playback.sh`, `LocalSigning.entitlements` | — |
| PlayerKit | `MPVClient`, `PlaybackState`, `PlayerModel`, `PlayerConfiguration`, `PlayableSource`, `PlayerCommand`/`KeyBindings`, `PlayerSurfaceView`/`CanvasGeometry`, `PlayerView`, `PlayerChromeModel`, `PlayerWindowController` | 45 |
| AppUI | `PlayerCoordinator`, Open Location sheet, File menu commands | 48 in total |

The engine tests play the generated samples through the real engine (audio discarded): open, pause,
exact seek, volume, end of file, failures, replacing a file, 4K HDR into the surface with hardware
decoding and a window resize, the real audio output at zero volume with AC-3 / E-AC-3 / DTS, shutdown.

Carried over or not verified:

- Not checked by eye or hand, because they need focus, a click or a key press: full screen, real key
  presses, dragging the seek bar, the Open panel, the Open Location sheet, and **audible sound**
  (the output device opens and decodes; nothing was ever played aloud).
- **"Slow first frame after a rebuild" was a macOS permission dialog, not the app.** The repository
  is in `~/Documents`; when the app opened a test file there, macOS asked the user "Orbit would like to
  access files in your Documents folder" and playback waited for the answer (2.7 to 10.9 s, or for
  ever). Ad-hoc signed builds get a new identity on every rebuild, so the question returned each time.
  Checks now play a copy from the temporary folder (`Scripts/stage-media.sh`); the first launch after
  a rebuild then starts in about 0.3 s. A user opening their own file in Documents will still be
  asked, once per build while the signature is ad-hoc.
- `leaks` reports 2 to 5 leaked 80-byte blocks in most playback runs and none in the run with
  allocation stacks recorded. Source not identified.
- HDR is tone-mapped to SDR for now; passthrough is a Stage 4 item.

### Stage 4 contents

| Where | Added | Tests |
|---|---|---|
| PlayerKit, engine | Track model and selection (`TrackSelector`, `LanguageMatcher`, `PlayerMemory`), `VideoSettings` / `AudioSettings` / `SubtitleSettings` written through to the engine, chapters, queue and repeat, A-B loop, frame step, screenshots, `ThumbnailGenerator`, HDR output, `AudioTranscoder` and the audio fallback chain, resume (`ResumeState`), on-screen notices | 159 in total |
| PlayerKit, views | Two-row control bar, `SeekBar` with chapter marks and hover preview, settings panel (Video / Audio / Subtitles), queue panel, picture in picture, mini player, online subtitle section | (view models tested) |
| PlayerKit, input | `KeyBindings` with text forms and overrides, scroll and pinch gestures, `NowPlayingSession` + `SystemNowPlayingCenter`, `MediaFiles` | |
| MediaCore | `MediaNameGuess`, `VideoFileHash`, `SubtitleItem.releaseName` | 58 (2 opt-in live) |
| MediaLibrary | `PlaybackMemoryStore`, migration `v3-playback-memory` | 13 |
| AppUI, App | `AddonSubtitleService`, `LibraryPlayerMemory`, `PlayerCoordinator.open(urls:)`, drag and drop, Playback menu, `AppDelegate` for files from Finder, document types in Info.plist | 57 (1 opt-in live) |

How the pieces relate:

- **The player is one `PlayerModel` in extensions** (`+Tracks`, `+Navigation`, `+Commands`, `+Thumbnails`,
  `+AudioFallback`, `+Resume`); stored state lives in the class. Everything a key, menu, gesture or media
  key can do is a `PlayerCommand`; `PlayerWindowController.perform` handles the window's own and passes
  the rest to `PlayerModel.perform`, which also raises the on-screen notice.
- **The player knows nothing about add-ons or the database.** It is given a `PlayerMemory` (tracks,
  volume, positions) and an `OnlineSubtitleService`; AppUI implements both.
- **Three window modes in one window** (`PlayerWindowMode`): normal, picture in picture (floating, all
  Spaces, public APIs), mini (no picture decoded). Sound without a picture gets the mini player by itself.
- **The audio fallback needs an ffmpeg program and none is shipped.** `AudioTranscoder.locate()` looks for
  a helper in the app bundle, then Homebrew's. Without one the chain is: same-language track, any track.

Carried over or not verified in Stage 4:

- **Nothing here was tried by hand.** Checked only through tests and background screenshots: every
  menu, the settings panel's controls, dragging the seek bar, the queue's drag-to-reorder, drag and drop
  of files, real key presses, the Open panel, full screen, and whether picture in picture really stays
  above other apps and full-screen Spaces.
- **Scroll and pinch directions are untested on a real trackpad.** The arithmetic is tested; whether
  "fingers up" is volume up with both system scroll settings is not.
- **Now Playing and media keys have never run against the system** (they are off in silent checks so the
  user's media keys stay with their music). Tested against a fake centre only.
- **HDR output is verified by what the layer and engine report** (PQ colour space, extended range), and a
  screenshot shows sane colours. Nobody has looked at it on the display. The HDR sample is an SDR test
  pattern tagged as HDR10, not real HDR content; Dolby Vision and HDR10+ files were not available to test.
- **No sound has ever been played aloud**, as before.
- Online subtitles: listing is checked live against the default add-ons; downloading a real subtitle is
  not (the mock server covers it), to keep to "no copyrighted downloads".
- The player panel's settings (subtitle style, equaliser, HDR choice) last for the session only. Saving
  them, the shortcut editor and mpv.conf / input.conf are Stage 7.
- The mini player shows no cover art.
- Picture in picture uses a normal window, so clicking it activates the app.

### Stage 5 contents

| Where | Added | Tests |
|---|---|---|
| Scripts, Config | `build-torrent-framework.sh`, `torrent-libraries.lock` | — |
| StreamEngine | `TorrentBridge` (Obj-C++), `TorrentEngine`, `PiecePrioritizer` / `PieceMap` / `PiecePlan`, `StreamServer` + HTTP messages, `StreamCache`, `TorrentFileChooser`, `StreamManager` | 41 |
| PlayerKit | `PlaybackOptions` (memory keys, no thumbnails, HTTP headers, title) | 161 in total |
| MediaCore | `MediaFileExtensions`, character references decoded in titles and names | 60 |
| AppUI, App | `StreamChoice` / `StreamGroup` / `LastStreamChoice`, `StreamListModel`, `StreamPlayer`, `StreamListView`, status bar, streams on the detail page, scratch-profile debug arguments | 74 |

Carried over or not verified in Stage 5:

- **The engine has never talked to anyone but itself.** Every test is two engines on this machine's
  loopback interface: no tracker, no hash table (DHT), no router mapping, no peer from the internet,
  no HTTPS tracker. That real swarms work rests on libtorrent, not on anything checked here.
- **macOS will ask the user two things the first time a real torrent plays** (allow incoming
  connections, if the firewall is on; local-network access). Neither prompt has been seen.
- CPU and memory while a torrent streams were not measured in the app (only the test's loopback run).
- The stream list was looked at with a stand-in add-on serving generated media, driven by debug
  arguments; nothing was clicked. YouTube and external streams were not seen in the app.
- HTTP headers an add-on asks for are passed to the engine in the form its documentation gives; this
  was not tried against a server that requires them.
- Uploading to other peers is unlimited by default; limits, the cache size and connection count are
  settings for Stage 7. Subtitles that come attached to a stream are not loaded yet.
- The cache's trimming was tested with small files only.

## Performance log

Targets (spec section 4): cold launch < 1.5 s; idle memory < 250 MB; playing 4K HDR < 600 MB;
4K HEVC 10-bit HDR CPU < 30 % on M1; HTTP time-to-first-frame < 2 s; no main-thread work > 8 ms while scrolling.

| Date | Stage | Build | Measurement | Result |
|---|---|---|---|---|
| 2026-11-17 | 1 | Release, arm64 | Launch to first screen, warm cache, median of 5 (`measure-launch.sh`) | 173 ms (min 165) |
| 2026-11-17 | 1 | Release, arm64 | Launch to first screen, first run after build | 463 ms |
| 2026-11-17 | 1 | Debug, arm64 | Launch to first screen, first run after build | 622 ms |
| 2026-11-17 | 1 | Release, arm64 | Idle memory, empty shell: physical footprint / RSS | 30 MB / 97 MB |
| 2026-11-17 | 2 | Release, arm64 | Launch to first screen, warm, median of 5 | 196 ms |
| 2026-11-17 | 2 | Release, arm64 | Launch to Home content (first catalog row has data), warm, median of 5 | 378 ms |
| 2026-11-17 | 2 | Release, arm64 | First-ever launch (no database, no caches): first screen / Home content | 201 ms / 576 ms |
| 2026-11-17 | 2 | Release, arm64 | Idle memory, Home loaded with artwork: physical footprint / RSS | 62–67 MB / 134–148 MB |
| 2026-11-17 | 2 | Debug, arm64 | `leaks` on a series detail page | 0 leaks |
| 2026-11-17 | 2 | Release, arm64 | Time Profiler, launch with empty image cache (`profile-launch.sh`), run 1 | After launch: main thread never busy > 8 ms at a stretch |
| 2026-11-17 | 2 | Release, arm64 | Same, run 2 | After launch: 7 stretches > 8 ms, longest 16 ms, while ~60 posters arrive |
| 2026-11-17 | 2 | Release, arm64 | Same traces: where the work runs | Image decode (65–75 ms) and JSON decode on background threads; no app code hot on main |
| 2026-11-17 | 3 | Release, arm64 | Launch to first screen / Home content, warm, median of 5 | 176 ms / 357 ms |
| 2026-11-17 | 3 | Release, arm64 | Idle memory, Home loaded | 66 MB |
| 2026-11-17 | 3 | Release, universal | App bundle size (Libmpv.framework is 73 MB of it) | 90 MB |
| 2026-11-17 | 3 | Debug app | Time to first frame, local file: 1080p / 4K HDR / multi-track | 270–300 ms / 280–300 ms / 260–310 ms |
| 2026-11-17 | 3 | Debug app | Time to first frame, HTTP on loopback: 1080p / 4K HDR / multi-track | 298 ms / 513 ms / 277 ms |
| 2026-11-17 | 3 | Debug app | Time to first frame, HTTP throttled to 10 Mbit/s, 1080p | 285 ms |
| 2026-11-17 | 3 | Debug app | 4K HEVC 10-bit HDR 60 fps, `efficient` (default): CPU / memory, 3 runs | 23 % of one core / 276–310 MB |
| 2026-11-17 | 3 | Debug app | Same, engine defaults (`high`), median of 3 | 35 % / 533 MB |
| 2026-11-17 | 3 | Debug app | Same, engine defaults without HDR peak detection | 30 % / 515 MB |
| 2026-11-17 | 3 | Debug app | 1080p H.264 30 fps, `efficient`: CPU / memory | 12 % / 200–215 MB |
| 2026-11-17 | 3 | Debug app | Dropped frames, 4K HDR 60 fps (engine test) | fewer than 30 in the test's bound; 0 in the spike |

| 2026-11-17 | 4 | Release, universal | Launch to first screen / Home content, warm, median of 5 | 190 ms / 384 ms |
| 2026-11-17 | 4 | Release, universal | Idle memory, Home loaded; app bundle size | 67 MB; 94 MB |
| 2026-11-17 | 4 | Debug app | Time to first frame, local file: 1080p / 4K HDR | 236–250 ms / 275–279 ms |
| 2026-11-17 | 4 | Debug app | **1080p H.264 30 fps, looping: CPU / memory while playing** | 13 % of one core / 427 MB |
| 2026-11-17 | 4 | Debug app | **4K HEVC 10-bit HDR 60 fps, HDR output on, looping: CPU / memory while playing** | 26 % (peak 28 %) / 520 MB |
| 2026-11-17 | 4 | Debug app | Same 1080p file after it has ended (paused on the last frame) | 0 % / 210 MB |
| 2026-11-17 | 4 | Debug app | Seek bar hover preview, first request (it starts a second engine) | about 0.45 s |
| 2026-11-17 | 4 | Debug app | `leaks` during playback | 2 to 4 blocks of 80 bytes, as in Stage 3 |

| 2026-11-17 | 5 | Release, universal | Launch to first screen / Home content, warm, median of 5 | 183 ms / 351 ms |
| 2026-11-17 | 5 | Release, universal | Idle memory, Home loaded (the stream engine starts only when a torrent is played) | 67 MB |
| 2026-11-17 | 5 | Release, universal | App bundle size (libtorrent and OpenSSL add 30 MB across both architectures, unstripped) | 124 MB |
| 2026-11-17 | 5 | Debug, in a test | Torrent stream, from choosing it to the first frame, peer on this machine (engine, server and player all starting cold) | 1.7 s |

**The Stage 3 memory rows above are wrong, and its CPU rows rest on three samples.** The samples are
10 seconds long and `measure-playback.sh` read memory after the file had ended (about 200 MB too low)
and, through a parsing slip, dropped CPU samples under 10 %, which hid the idle ones. The script now
loops the file and reads memory while it plays; the Stage 4 rows are the ones to trust. The canvas was
also larger for Stage 4 (3600×2338, the display was set to a higher resolution) than for Stage 3
(3024×1964), and both CPU and memory grow with it.

Reading the Stage 4 numbers: about 290 MB of the playing footprint is canvas-sized textures (swapchain
images and the renderer's buffers at 34 MB each), the price of the fixed canvas. 4K HDR is inside the
600 MB target by 80 MB on this display and would not be on a larger one; the "under 30 % on an M1" CPU
target is not met with any confidence, since 26 % was measured on an M4 Pro. Both are for Stage 8, where
the from-source engine build lets the surface follow the window instead of the screen.

Reading the Stage 3 numbers: all on an M4 Pro, so the "under 30 % on an M1" target is not verified, and
CPU is a share of one core with the window in the background. Playback memory is inside the 600 MB
target with the default preset and was not with the engine's defaults (765 MB peak seen). The loopback
and throttled HTTP results say nothing about a real, distant server.

Reading the Stage 2 numbers: launch and memory are well inside the targets. The 8 ms main-thread budget
is met most of the time while artwork streams in but not always (run 2); that is SwiftUI committing
many image updates at once, and it is the first thing to look at in Stage 8. Scrolling itself has not
been measured.

Not yet measured: a true cold launch (after reboot or `sudo purge`), scrolling frame times, and the
Allocations instrument (footprint and `leaks` were used instead).
