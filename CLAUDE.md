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
Scripts/package.sh                # ci.sh --release, then build/dist/<name>-<version>.dmg (signed .app inside); --skip-ci to reuse the build
SIGN_IDENTITY="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=<keychain profile> Scripts/package.sh   # for other people's Macs
swiftformat .                     # apply formatting

# One package, fast (no Xcode project needed):
cd Packages/MediaCore && swift test
LIVE_ADDON_TESTS=1 swift test --filter LiveAddonTests   # opt-in: hits the real default add-ons
cd Packages/AppUI && LIVE_ADDON_TESTS=1 swift test --filter LiveSubtitleServiceTests   # opt-in: lists, never downloads

# Prerequisites that ci.sh runs for you (both skip work that is already done):
Scripts/build-mpv-framework.sh    # Packages/PlayerKit/Vendor/Libmpv.xcframework from Config/mpv-libraries.lock
Scripts/build-torrent-framework.sh  # Packages/StreamEngine/Vendor/Libtorrent.xcframework from Config/torrent-libraries.lock (needs cmake, ninja)
Scripts/build-ffmpeg-helper.sh    # Vendor/Helpers/ffmpeg from Config/ffmpeg-helper.lock: audio-only, LGPL, universal (about 2 minutes)
Scripts/collect-licenses.sh       # Vendor/Licenses/ from Config/licenses.lock (hash-verified); bundled as Resources/Licenses
Scripts/make-test-media.sh        # TestMedia/: 1080p H.264, 4K HDR10 HEVC, multi-track MKV, external subs

# Looking at the running app without taking focus (Debug build):
Scripts/screenshot.sh /path/shot.png 6                          # Home
Scripts/screenshot.sh /path/shot.png 6 -section discover        # also: library, calendar, addons
Scripts/screenshot.sh /path/shot.png 7 -search "the office"
Scripts/screenshot.sh /path/shot.png 7 -open series:tt0386676   # a detail page
Scripts/screenshot.sh /path/shot.png 6 -silent YES -play "$PWD/TestMedia/sdr-h264-1080p.mp4"   # player
Scripts/screenshot.sh /path/shot.png 5 -settings shortcuts      # Settings is saved as shot-2.png
Scripts/stage-media.sh TestMedia/multi-track.mkv   # prints a copy's path outside ~/Documents, for -play

# A watch party between two copies of the Debug app, on this machine only (needs deno):
Scripts/party-check.sh /path/folder 14       # host.png, guest.png (+ -2 for the main windows), and where each player was at the same moment
cd Packages/WatchParty && swift test          # sync logic, real WebRTC connections on loopback, and Server/signal.ts itself if deno is installed
HOST=127.0.0.1 PORT=8787 ICE_SERVERS='[]' deno run --allow-net --allow-env Server/signal.ts   # the signalling server, by hand

# Playback over HTTP (Range-capable; python's http.server is not):
Scripts/serve-test-media.py 8765 &          # then -play http://127.0.0.1:8765/<file>; add --throttle-kbps N

# Measuring launch (Release build; run Scripts/ci.sh --release first):
Scripts/measure-launch.sh 5                       # first-screen and home-content times, idle memory
CLEAR_IMAGE_CACHE=1 Scripts/profile-launch.sh 8   # Time Profiler around a launch, summarised

# Measuring playback and scrolling: these need a launch argument, which Release does not have, so
# they use the "profile" build: Debug configuration compiled with optimisation, in build/DerivedData-Profile.
Scripts/build-profile.sh                          # rebuild it after changing code
PROFILE_BUILD=1 Scripts/measure-playback.sh TestMedia/hdr10-hevc-4k60.mkv 14   # first frame, CPU, memory, dropped frames, leaks
PROFILE_BUILD=1 Scripts/measure-playback.sh TestMedia/hdr10-hevc-4k60.mkv 14 "swapchain-depth=1"   # with extra engine options
PROFILE_BUILD=1 Scripts/measure-playback.sh http://127.0.0.1:8765/hdr10-hevc-4k24-long.mkv 40      # a stream (serve-test-media.py), long enough for the cache to fill
Scripts/memory-detail.sh TestMedia/sdr-h264-1080p.mp4 8          # what playback memory is made of (NO_LOOP=1: after the file has ended)
Scripts/measure-scroll.sh discover 8              # scrolls the screen by itself; how late the main thread was per tick
CLEAR_IMAGE_CACHE=1 Scripts/measure-scroll.sh home 6 2500        # with artwork to fetch; third argument is points per second
PROFILE_BUILD=1 DETAIL=60 DETAIL_FROM_MS=3500 Scripts/profile-launch.sh 13 -section discover -autoscroll 8   # what the main thread did meanwhile
#   DETAIL_THREAD=vo (or core, …) breaks down another thread; THREADS=16 lists more threads.

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
two seconds after launch, or `-keysAfter <seconds>` after it: the only way to check a binding and its
on-screen notice without the keyboard).
`-subtitleSearch "<name>"` looks a title up in the player's subtitle panel (real catalog add-ons; metadata only).
`-window pictureInPicture|mini` puts the player window in that mode.
`-settings general|playback|streaming|shortcuts|advanced` opens the Settings window on that tab.
`-acknowledgements YES` opens the Acknowledgements window.
`-autoscroll <seconds>` scrolls the screen's list by itself (`App/DebugAutoscroll.swift`), `-scrollSpeed <pt/s>`;
`-stats <seconds>` logs dropped and late frames and the buffered duration that long after launch.
`-profile <folder>` keeps the database and caches in a scratch folder and keeps the stream engine to
this machine; with it, `-installNow <address>` installs an add-on without the confirmation click,
`-episode <video id>` shows an episode's streams, `-stream <n>` plays the nth listed stream,
`-addToLibrary YES` saves the shown title and `-markWatched <video id>` marks a video watched.
A scratch profile is also the only way a silent check records watch history and resumes.
`-partyHost <link>` / `-partyJoin <link>` put the app in a watch party as its host or a guest (only with
`-profile`, and only with an invitation to a server on this machine, such as `http://127.0.0.1:8787/#<code>`
where the code is 16 random bytes in URL-safe base64); `-partyName <name>`, `-partySay "<text>"` (a chat
message six seconds in), `-panel party` (the party panel in the player), `-partyReportAt <unix time>` (logs
the player's position at that moment). `Scripts/party-check.sh` uses them all; two copies need `open -g -n`.

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

**Never open the microphone, and never let a party check reach the network.** A silent run
(`-silent YES`) has no voice chat at all: `PartyEnvironment.allowsVoice` is false, so nothing asks for
the microphone and nobody's voice is played. Tests use `allowsVoice: false` or a transport without a
network. A party's connections stay on the loopback interface when the app has a scratch profile, and
also whenever the invitation names a server on this machine (`WebRTCTransport.Configuration
.staysOnThisMachine`): WebRTC is then told to ignore every network interface but the loopback one and
is given no helper servers. Without that, WebRTC looks at the local network and macOS asks the user
about it. Never join a party in the app for a check without `-profile` and a `127.0.0.1` invitation.

A crash at launch puts a system dialog on the user's screen. `ci.sh --release` therefore runs the
Release binary directly first (a loader failure shows up in the log, not as a dialog).

Limits of background verification: nothing can be clicked or scrolled, and a window with a sheet
attached cannot be captured. Anything that needs interaction is covered by view-model tests, not by eye.

## Architecture

```
App/ (target MediaCenter)   entry point + composition root + Branding. No feature logic.
  └─ AppUI                  SwiftUI screens, @Observable view models, image pipeline
       ├─ WatchParty        watch parties: sync logic, invitations, signalling client, WebRTC mesh (stands alone)
       ├─ PlayerKit         libmpv wrapper, render view, track selection, controls, config parsing
       ├─ StreamEngine      torrent bridge (Obj-C++), piece prioritiser, local HTTP Range server, cache
       ├─ MediaLibrary      GRDB/SQLite: settings, library, history, resume, installed add-ons
       └─ MediaCore         models, add-on protocol client, HTTP client (timeout/retry/cancel), branding
```

- Six local Swift packages under `Packages/`. Dependencies point one way, down to `MediaCore`.
  `PlayerKit` and `StreamEngine` do not know about each other or about `MediaLibrary`; they are joined
  through protocols defined in `MediaCore` and wired in the app target. `WatchParty` depends on none of
  the others (only on WebRTC) and knows the player through a protocol of its own, `PartyPlayback`,
  which AppUI implements; PlayerKit in turn knows nothing of parties.
- **MVVM with `@Observable`.** View models are `@MainActor final class`es; views hold no business logic
  and are not unit-tested, view models are.
- **Persistence: GRDB** (MIT). Chosen over SwiftData for explicit append-only migrations, Sendable
  value-type records under strict concurrency, in-memory databases in tests, and a schema that can be
  made sync-ready (`updatedAt` on synced rows). Migrations live in `LibraryDatabase.migrator`; never edit
  one that has shipped.
- **Distribution:** outside the App Store. Hardened runtime on, App Sandbox off (mpv.conf access, local
  HTTP server, torrent engine). Builds are ad-hoc signed unless `Scripts/package.sh` is given an identity.
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
  resize event in the engine's Metal context, which needs a patched from-source build. Tried in
  Stage 8: with the layer's size changed, none of panscan, zoom, aspect override, rotation,
  deinterlacing, switching hardware decoding, `video-reload`, a filter change or a seek makes the engine
  read it again; only re-creating the video output does (`vid=no` then `vid=auto`), which interrupts
  playback. What the canvas costs is its three swapchain images (98 MB at 3600×2338; 43 MB at 2560×1440).
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
  closes; what is playing is never removed. The budget is a setting (Settings → Streaming).
- **Neutrality**: with no stream add-on installed the detail page says so and suggests nothing.

### How the library fits together (Stage 6)

- **Two tables, both sync-ready** (migration `v4-library-and-history`): `libraryItem` (saved titles;
  removing sets `removedAt` instead of deleting) and `watchEntry` (one row per video: position, length,
  watched, last watched, and the title's name and poster so that lists need no network).
- **`LibraryCenter` is what the screens talk to.** Every write bumps `revision`; a screen that shows
  library or history data reloads in a `.task(id: library.revision)`. The player writes through
  `LibraryPlayerMemory`, which calls `noteChange()`.
- **One source of truth for where a video was left.** Videos played from a detail page are remembered
  under `video:<type>:<id>` (`WatchKey`); for those keys `LibraryPlayerMemory` reads and writes the watch
  history. Local files and plain addresses stay in `playbackMemory`. The player reports a `ResumePoint`:
  not started (first 10 s), a position, or finished (last 10 s or last twentieth, at most six minutes).
- **Continue Watching** (`ContinueWatching`, pure): per title, its most recently watched video; resume it
  if unfinished, else offer the next *aired* episode (needs the series' episode list, fetched once).
  A card opens the title's page on that episode with its streams showing; it does not start playback.
- **Next-episode autoplay** (`NextEpisodeController`): when an episode played from a stream ends, the
  next aired episode is offered in the player with a countdown, but only if one of its streams is like
  the one being watched (`LastStreamChoice.bestMatch`). The player only shows the offer (`UpNextOffer`);
  the app counts down and acts on Play Now / Cancel.
- **Calendar** (`CalendarBuilder`, pure): saved series' episodes from a week back to 90 days ahead, by
  day in the user's time zone. Fetched through an add-on's calendar catalog where there is one (one
  request for up to 100 series, answer under `metasDetailed`), else series by series.

### How settings fit together (Stage 7)

- **Two stored values, both JSON in the settings table**: `app.settings` (`AppSettings`: everything in the
  Settings window) and `player.defaults` (`PlayerDefaults`: what the user leaves the player's own panels
  at, such as subtitle style, equaliser and HDR choice). Both decode leniently, field by field, so a value
  written by another version is read as far as it goes. Key bindings are a third value (`player.keyBindings`).
- **`SettingsModel` is the one place settings turn into behaviour.** Every change is applied at once and
  saved a moment later: it rebuilds `PlayerCoordinator.configuration` from the configuration the app was
  started with (so what is not a setting, like a silent check's `playsAudio: false`, survives), switches
  autoplay, and hands limits to `StreamManager`. Player options apply to the next video opened.
- **A setting can narrow what the app was started with, never widen it.** A stream engine started for
  this machine only (`-profile`, tests) stays that way whatever is stored
  (`AppSettings.engineSettings(basedOn:)`); a player started not to resume does not resume; and
  `ao=null` is appended after every other engine option so nothing can make a silent player heard.
- **Key bindings have three layers** (`ShortcutsModel`): the standard table, an `input.conf` if there is
  one, and the user's changes from the editor. Only the last is stored, as the difference from the first
  two. A chord the app's menus use is refused. A change reaches the open player at once.
- **`mpv.conf` and `input.conf` live in the app's own Application Support folder**, not `~/.config/mpv`,
  and are parsed by the app (`EngineConfigFile`, `InputConfigFile`); the engine's own config loading stays
  off. From `mpv.conf` only options are read, minus the ones the app controls and the ones that reach
  beyond playback (scripts, includes, anything that writes files); profiles are not supported.
  `input.conf` commands are translated to `PlayerCommand`s; nothing is passed to the engine as text, so a
  bindings file cannot do more than the app's own shortcuts. What was left out is listed in Settings →
  Advanced with the reason. The option deny-list is hygiene, not a security boundary: the file is the user's.
- **Subtitles that come with a stream** are handed to `AddonSubtitleService` when the stream starts and
  listed first ("This stream") when the player's subtitle panel looks that video up. They are not loaded
  by themselves.

### What keeps it fast (Stage 8)

- **The playhead is observed apart from the rest of the player's state** (`PlayerModel+State.swift`).
  `state` is one struct, so a read of any part of it used to be invalidated fifteen times a second by the
  position, and the whole player view was evaluated and laid out at that rate: the main thread's largest
  cost during playback (268 ms in nine seconds, now 16 ms). A change to position or buffer alone is
  announced as `playhead`; a write that changes nothing is not announced. **A view that follows the
  playhead must read `playhead` or `displayPosition`, never `state.position`.**
- **The Mac is kept awake by the app** (`Wakefulness`): display on while a picture plays, system awake
  for sound alone, nothing when paused or ended. The engine would do this for a window of its own; it
  draws into ours. Before Stage 8 nothing did, so the display would have slept during a film.
- **The engine's stream cache is capped** at 48 MiB ahead and 8 MiB behind (`PlayerConfiguration`). Its
  own defaults (150 + 50 MiB, lending between the two) put a 4K HDR stream at 740 to 850 MB.
- **Grids and strips of posters are AppKit underneath** (`PosterGrid`, `PosterRow`, `PosterCellView`).
  SwiftUI's lazy grid builds each card as it scrolls in, which cost 10 to 20 ms a row whatever the card
  contained (measured with bare cards and with no artwork). The grid is an `NSCollectionView` whose cells
  are three layers each and are reused; a horizontal strip keeps SwiftUI's scroll view (so trackpad
  handling is SwiftUI's) around one view that holds cells only for what is in sight. Opening a title goes
  through `EnvironmentValues.openTitle`, an `Equatable` action: a bare closure in the environment
  invalidates every reader on every update. The Library's Saved grid and Continue Watching are still SwiftUI.
- **Screens are split so that a view is evaluated only for what it reads.** Discover's pickers and its
  results are separate views: a page arriving used to rebuild the pickers (9 to 10 ms, mid-scroll).

### How packaging fits together (Stage 9)

- **`Scripts/package.sh` is the only way a build leaves this machine.** It copies the Release app,
  strips local symbols (132 MB to 102 MB; the dSYMs are kept beside the image), signs from the inside
  out with the hardened runtime (Sparkle's two XPC services, its `Autoupdate` and `Updater.app`, the
  Sparkle framework, `Libmpv.framework`, then the app), checks signature, entitlements, both
  architectures and that the binary starts, builds a compressed disk image with an Applications
  shortcut, and checks the image by mounting it out of Finder's sight. With a Developer ID identity it
  also signs the image, and with a `notarytool` keychain profile it notarises and staples it.
- **The library-validation exception is for ad-hoc signatures only.** `package.sh` adds
  `Config/LocalSigning.entitlements` only when there is no identity, and refuses to finish if a build
  signed with an identity carries it.
- **The script makes no credentials.** The signing identity and the notarisation profile come from the
  keychain; the Sparkle key pair is made by the user with Sparkle's `generate_keys`.
- **Sparkle is linked but inert until configured.** `UPDATE_FEED_URL` and `UPDATE_PUBLIC_KEY` in
  `Config/Branding.xcconfig` reach Info.plist as `SUFeedURL` and `SUPublicEDKey`; `UpdateConfiguration`
  accepts only an https address with a host and a 32-byte base64 key. Otherwise `AppUpdater` creates no
  updater and there is no menu item. Debug builds never create one. Sparkle is a dependency of the app
  target (pinned in `project.yml`), not of a package.
- **Licence texts are pinned like the libraries.** `Config/licenses.lock` names each text's address at
  the library's version (or at a fixed commit where the prebuilt library does not say which version of a
  dependency it holds) with its hash; `collect-licenses.sh` fetches them into `Vendor/Licenses`, adds
  libtorrent's and Boost's from their source archives, and fails if the files and
  `Config/ThirdParty.json` disagree in either direction (a test checks the same). The app shows them in
  its Acknowledgements window (`AcknowledgementsModel`), under the app menu.
- **The audio conversion helper** is an `ffmpeg` of our own build in `Contents/MacOS`, where
  `AudioTranscoder.locate` looks first (`Bundle.url(forAuxiliaryExecutable:)`).
  `Scripts/build-ffmpeg-helper.sh` compiles FFmpeg's release archive (pinned by hash in
  `Config/ffmpeg-helper.lock`) for both architectures with `--disable-everything` plus what the one
  job needs: all demuxers, parsers and bitstream filters, the audio decoders (read from the source's
  own list, so the build does not depend on an installed ffmpeg), the AAC encoder, the Matroska muxer,
  seven audio filters, and file/http/https input through the system's Secure Transport. The script
  refuses a configuration that FFmpeg itself calls GPL, version 3 or non-free, a binary that links
  anything outside the system, or one that does not report itself as LGPL 2.1 or later. It is the same
  FFmpeg version as the engine's, so it decodes what the engine decodes: its use is that conversion no
  longer depends on what the user has installed. `nasm` is not installed, so the Intel half has no
  hand-written assembly. **Downloading that archive needed the user's explicit go-ahead** (the
  permission system refused it until then): ask before fetching anything new from a new place.
  Go-aheads given so far: FFmpeg's release archive; github.com/stasel/WebRTC; Google's source servers
  (`*.googlesource.com`), for licence texts.
- **Disk image by `hdiutil`**, not `create-dmg`: nothing to install, and no Finder scripting (which
  would open windows on the user's screen). The image has no background picture or icon layout.

### How watch parties fit together (Stage 10)

```
PartyCenter (AppUI) ─ PartySession ─┬─ PartyCore            pure: what to send, when to pause, seek or nudge
     │ start / join / leave         ├─ PartyTransport ─ WebRTCTransport ─┬─ SignalingConnection ─ wss ─ Server/signal.ts
     │ panel, status bar, menu      │                                    └─ PeerLink × everyone else: data channel (+ audio)
     └─ PlayerPartyBridge ──────────┴─ PartyPlayback        the player, as the party sees and steers it
```

- **Nobody sends video.** Everyone plays their own copy or stream. What is shared is which title
  (`PartyContent`: a catalog id or a file name, never an address), the position, paused or not, and
  the speed. An add-on's stream address never leaves the Mac it was chosen on.
- **`PartyCore` is a value with no clock and no network.** It is told what happens with the time it
  happens at (a message, an intent, a tick four times a second) and answers with effects: send this,
  pause, seek, play 3 % faster. All of the behaviour below is decided there and tested with
  `SimulatedParty` (made-up clocks, network delay and players).
- **Shared values are last-writer-wins registers** with a version of (counter, author): where the
  party is (`SharedPlayback`), what it watches (`SharedContent`), who may control (`RoomSettings`, the
  host's alone). No app is in charge; the highest version wins everywhere.
- **Clocks are compared pairwise**, NTP-fashion, over the data channel (`ClockSync`: the quickest of the
  last eight exchanges). A position travels as "position P at my time T"; the receiver places it on its
  own clock. A position that arrives before the first exchange has completed waits for it.
- **Following** (`PartyCore+Sync`): within 0.12 s nothing is done; up to 1.5 s the engine plays up to 8 %
  faster or slower (`PlayerModel.speedAdjustment`, on top of the speed the person sees); beyond that it
  jumps, aiming ahead by how long jumps were seen to take here, with one better-aimed retry. Paused
  players are put within 0.1 s of each other: people pause to look at the same frame.
- **Waiting**: a player that was in step and stalls for 1.5 s pauses the party (`holder`); whoever paused
  it lets it go on once nobody reports a stall. If they leave, the member with the lowest id takes over.
- **What the person did, as opposed to what was done to their player.** `PlayerModel` reports
  `PlaybackIntent`s (pause, a jump once it has landed, speed) and takes outside changes inside
  `followingExternal { }`, which are not reported. A jump is only known when its picture is back, so
  between asking and landing `hasPendingUserSeek` is true and the party leaves the player alone;
  without that, a tick in between pulled the player back to where the party still was.
- **Who decides what is watched**: someone who controls the party, knows how it stands (`isInformed`:
  the host, or anyone who has received `caughtUp` from a member) and either finds the party with nothing
  on, or was watching with it and moves on to another video. A newcomer's own resume point, pauses and
  jumps mean nothing until their player has been in step once (`hasSynced`).
- **Connections** (`WebRTCTransport`, on one serial queue): a full mesh, so a party holds eight. The one
  who arrives proposes to everyone there. One negotiated data channel (id 0) carries JSON messages.
  Changes are negotiated by hand (`needsNegotiation`), not by WebRTC's callback, with the usual
  polite/impolite rule for when both sides propose at once (the polite side is the one with the higher id).
- **The invitation is a secret** (16 random bytes in the link's fragment). The room's name at the server
  and the key that seals signalling (ChaCha20-Poly1305, bound to sender and recipient) are derived from
  it, so the server can neither read what it relays nor put itself between two people. The data channel
  and the audio are encrypted by WebRTC between the two apps.
- **The signalling server** (`Server/signal.ts`, Deno, no dependencies) keeps rooms in memory, relays
  sealed frames, hands out the STUN/TURN list, and limits room size, frame size and rate. A connection
  that is up does not need it: if it restarts, people stay connected and rejoin the room when it is back.
  Tests use an in-process stand-in (`LoopbackSignalServer`) and, where deno is installed, the real file.
- **Voice** is an audio transceiver on the same connections: send and receive for someone in the voice
  chat, inactive for someone who is not, so sound flows only between two people who both joined. WebRTC
  opens the microphone only while something is being sent. Echo cancellation, noise suppression and gain
  are WebRTC's own.
- **In the player**, the party is an "accessory": a side panel and a button that PlayerKit shows without
  knowing what they are (`PlayerAccessory`, set through `PlayerCoordinator.accessory`).
- **The server's address**: `PARTY_SERVER_URL` in `Config/Branding.xcconfig` (Info.plist `PartyServerURL`),
  or the user's in Settings → General; an invitation link always carries its own. With neither, starting
  a party is off and joining from a link still works.

### Decisions still to be made (with the stage that decides them)

| Stage | Decision | Current recommendation |
|---|---|---|
| later | Shortcuts in the menus | The Playback menu shows no key equivalents, because the keys are the user's to change and live in `KeyBindings`. Showing the current key next to each menu item needs the menu to read the bindings. Not done in Stage 8. |
| later | Subtitles in black bars | With the fixed canvas, subtitles are kept inside the picture (`sub-use-margins=no`). Goes with the engine build. |
| later | Engine build | Building libmpv from source (meson, with MPVKit's patches plus a resize event) is **the user's call and was not started**: every target is met without it. It would buy a surface that follows the window (about 55 MB less in a 1280×720 window, nothing in full screen), subtitles in the black bars, and a chance to find the fixed 190 MB of GPU memory described in the performance log. It costs a long from-source build as a prerequisite and a patch to maintain. Adapting MPVKit's patches means checking their licence and telling the user first. |
| done | Bundling ffmpeg for the audio fallback | Bundled, on the user's decision (and their go-ahead for downloading FFmpeg's source and building it here): see "The audio conversion helper" below. |
| user | Developer ID and notarisation | `package.sh` is ready for both but neither has run: the keychain holds an Apple Development identity only. A Developer ID needs the paid Apple Developer Program; the user decides. Until then a disk image from here opens on another Mac only after its owner allows it by hand. |
| user | Update feed | Where the appcast is hosted, and making the Sparkle key pair (it lives in the user's keychain), are the user's to do; see the README. |
| user | The app's own licence | None chosen; the README says all rights are reserved until one is. |
| user | Party server | Someone has to run `Server/signal.ts` where it can be reached over https, and put its address in `PARTY_SERVER_URL` or Settings. Not deployed anywhere: creating an account at a host is the user's to do. One instance only (rooms are in memory); a host that runs several copies of a program would split rooms. |
| user | Relay for people who cannot connect directly | With STUN alone, some pairs of networks (carrier-grade NAT on mobile and many home connections in India, company networks) will not connect. A TURN relay fixes that and costs money or a server: coturn on a small machine (`TURN_URLS`, `TURN_SECRET`), or a hosted one. Not set up; nothing has been tried between two real networks. |
| user | Public STUN servers | The server's default list names Cloudflare's and Google's public STUN servers, which learn the address of everyone who joins a party. Change `ICE_SERVERS` to use others or your own. |
| done | Notices for what WebRTC contains | Collected, on the user's go-ahead to fetch from Google's repositories (`*.googlesource.com`): see "Stage 10 contents". |
| later | WebRTC from source | The framework is stasel/WebRTC's build of Google's source (one maintainer, like MPVKit), pinned by checksum. Building it here means Google's tools, about 20 GB of source and hours; the user chose the prebuilt one. |
| user | Source for the LGPL libraries | Whoever distributes the app must make the source of the LGPL libraries available (or offer it in writing). The binaries are MPVKit's; pointing at MPVKit is not the same as providing the source. Not arranged. |

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
- Tools (Homebrew): xcodegen 2.46, swiftformat 0.64, swiftlint 0.65, ffmpeg 9.0, cmake 4.5, ninja 1.13,
  deno 2.9 (runs the watch party's signalling server; its tests and `party-check.sh` are skipped or fail without it).
  The disk image is made with the system's `hdiutil` (create-dmg was not needed).
- Signing identities in the keychain: one Apple Development identity; no Developer ID.

## Stage checklist

- [x] **1. Skeleton** — XcodeGen project, five packages, CLAUDE.md, branding, placeholder icon, CI script
- [x] **2. Add-on client + browsing** — protocol client, Cinemeta, Home, Discover, Search, Detail, Add-ons
- [x] **3. Player core** — libmpv embedding, Metal view, basic controls, file + HTTP playback
- [x] **4. Player features** — everything in spec section 3B (the shortcut editor and mpv.conf/input.conf are Stage 7)
- [x] **5. Streams + torrent engine** — stream list, libtorrent bridge, local HTTP server, cache
- [x] **6. Library** — Continue Watching, resume, next-episode autoplay, calendar
- [x] **7. Settings + polish** — settings window, shortcut editor, mpv.conf/input.conf, saved player choices
- [x] **8. Performance pass** — every target in spec section 4 measured; playback, memory and scrolling fixes
- [x] **9. Packaging** — `package.sh` (signed .app in a .dmg), Sparkle (off until configured), licences and Acknowledgements, README
- [x] **10. Watch party** — synchronised playback between people's own players over WebRTC, text chat, voice chat, signalling server

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
- **The audio fallback needs an ffmpeg program.** `AudioTranscoder.locate()` looks for a helper in the app
  bundle (there is one since Stage 9), then Homebrew's. Without one the chain is: same-language track,
  any track.

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
- The player panel's settings (subtitle style, equaliser, HDR choice) lasted for the session only in
  this stage; they are saved since Stage 7.
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
  settings since Stage 7. Subtitles that come attached to a stream are listed in the player since Stage 7, not loaded by themselves.
- The cache's trimming was tested with small files only.

### Stage 6 contents

| Where | Added | Tests |
|---|---|---|
| MediaLibrary | migration `v4-library-and-history`, `LibraryStore`, `WatchHistoryStore` | 19 |
| MediaCore | `AddonClient.detailedCatalog`, `ProcessLimits` | 61 |
| PlayerKit | `ResumePoint`, `UpNextOffer` and its card, accept/decline commands, `eventTrace`; fixes below | 163 |
| StreamEngine | `StreamServer.recentRequests` (a request log for diagnosing) | 41 |
| AppUI, App | `LibraryCenter`, `LibraryModel` + view, `ContinueWatching` + model + row, detail-page library and watched controls, `NextEpisodeController`, `CalendarBuilder` + model + view | 96 |

Three bugs found while testing this stage, each now covered by a test:

- **A file that followed one of the same size had no size.** The engine only reports a value when it
  changes, and the app forgets a file's values when the next one starts; two episodes of the same
  resolution left the second without a size (shown inset with black borders, no hover previews).
  `MPVClient` now states the per-file values again after a file loads and after its first frame.
- **A seek not yet confirmed was repeated in the next file**, which could throw it to its last seconds.
  `open` now drops it, and a restart that arrives while the next file is loading no longer counts as
  that file's first frame.
- **A position could be saved after the player had shut down**, with the engine's empty state,
  overwriting where the file was left. Saving stops at shutdown.

A lesson from the same investigation: a test that polls for a state must not rely on a state that
something else ends within milliseconds. `NextEpisodeTests` once waited for "ended" while an instant
countdown replaced the file; when the poll missed it, the test waited for the *next* file's end and
failed in ways that looked like engine bugs. `PlayerModel.eventTrace` (engine events with timestamps)
is what showed it; turn it on before theorising.

Carried over or not verified in Stage 6:

- Seen in the running app with a scratch profile and a stand-in add-on, driven by debug arguments:
  watched marks, In Library, Continue Watching (a resume card and a next-episode card), the Library's
  Saved tab, the calendar, the up-next card with its countdown, and the next episode starting by itself.
  **Nothing was clicked**: the buttons, context menus, the History tab, Clear History and the season
  button are covered by view-model tests only.
- Continue Watching and the calendar ask the catalog add-on about each series; with many series this is
  one request per series for Continue Watching (the calendar batches). Not measured with a large library.
- Autoplay is on with a 10-second countdown; switching it off and changing the delay are settings since
  Stage 7. Local files in a folder do not get "next episode" (the queue already plays them in order).
- `ImagePipelineTests` ("a second request is served from memory") failed once in some twenty Xcode runs
  of the AppUI tests during this stage. Not reproduced, not investigated.
- The app raises its open-file limit to 4096 at launch (`ProcessLimits`); whether libtorrent ever needed
  more than the default 256 was not measured.

### Stage 7 contents

| Where | Added | Tests |
|---|---|---|
| PlayerKit | `PlayerDefaults`, `EngineConfigFile` and `InputConfigFile` (parsers), `ShortcutAction`, chord display and spoken text, bindings changeable while a player is open, panels fade under Reduce Motion | 174 |
| StreamEngine | `StreamManager.updateSettings`, `cachePolicy` | 41 |
| AppUI | `AppSettings`, `SettingsModel`, `ShortcutsModel`, `EngineConfigFolder`, `LanguageList`, the Settings window (General, Playback, Streaming, Shortcuts, Advanced), preferred stream quality, a stream's own subtitles in the player's subtitle panel | 118 |
| App | `-settings <tab>` debug argument | — |

Settings there are: appearance, opening section, Continue Watching on or off; sound and subtitle
languages and when subtitles show; resume; autoplay and its countdown; rendering preset; preferred stream
quality and stream sorting; cache size (with the size on disk and Clear); connections, download and upload
limits, DHT, local discovery, port mapping; reading the config files. Choices made in the player's panels
(subtitle style, equaliser, loudness, downmix, HDR, tone mapping, hardware decoding) are kept without a
setting of their own.

Carried over or not verified in Stage 7:

- **Seen in the running app** (background screenshots, scratch profile): all five Settings tabs, the
  config-file report with lines left out, the shortcut list with an `input.conf` applied, and a key bound
  by `input.conf` muting the player. **Nothing was clicked or typed**: every control in the window, recording
  a shortcut from a real key press (the `NSEvent` monitor in `KeyRecorder`), the confirmation dialogs,
  Show Folder, and the appearance switch are covered by view-model tests or not at all.
- The appearance setting is applied with `NSApplication.appearance`; light and dark were not looked at
  side by side. VoiceOver was not run; labels and values are set, how they read aloud is unchecked.
- `mpv.conf` options are handed to the engine as they are once they pass the deny-list. An option this
  build does not know is logged and skipped (never fatal), but an option that conflicts with how the app
  renders (the fixed canvas) could still spoil the picture; the list of controlled options is from
  reading the engine's manual, not from trying each one. An option the app also has a control for
  (`hwdec`, subtitle style) is overridden by that control.
- `input.conf` supports the keys the player has names for (letters, digits, signs, arrows, Space, Enter,
  Esc with modifiers). Function keys, Tab, mouse buttons and the wheel are listed as left out.
- A stream's own subtitles are listed, not loaded automatically, and only after the user looks the
  title up in the subtitle panel.
- Limits changed while a torrent is streaming are handed to the running engine; this was tested only as
  "the manager holds the new settings", not against a live transfer.
- Not done: the mini player's cover art; key equivalents shown in the Playback menu (see the decisions
  table); export or import of settings.

### Stage 8 contents

| Where | Added | Tests |
|---|---|---|
| Scripts | `build-profile.sh`, `measure-scroll.sh`, `memory-detail.sh`; `measure-playback.sh` reports dropped frames and settled memory; `analyze-trace.py` breaks any thread down; a 150-second 4K HDR sample at 24 frames a second | — |
| PlayerKit | `PlayerModel+State` (playhead observed apart), `Wakefulness`, stream cache options | 179 |
| AppUI | `PosterGrid`, `PosterCell`, `PosterRow` (+ `PosterRowLayout`, `PosterGridMetrics`, `OpenTitleAction`), Discover split in two views | 125 |
| App | `DebugAutoscroll`, `-autoscroll`, `-stats` | — |

Targets, as measured at the end of the stage (M4 Pro, display at 3600×2338; details in the log below):

| Target | Result | Met |
|---|---|---|
| Cold launch < 1.5 s | 193 ms warm, 206–580 ms on the first run after a build | yes, with the caveat below |
| Idle memory < 250 MB | 71 MB | yes |
| Playing 4K HDR < 600 MB | 480–520 MB from a file, 545 MB as a stream | yes |
| 4K HEVC 10-bit HDR < 30 % CPU on an M1 | 10.5 % at 24 frames a second, 20 % at 60, on an M4 Pro | on this machine; not verified on an M1 |
| HTTP time to first frame < 2 s | 265–290 ms on loopback | yes, on loopback only |
| No main-thread work > 8 ms while scrolling | Discover and Home: no tick later than 7.5 ms in any run | yes, as far as it can be measured without a hand on the trackpad |

Carried over or not verified in Stage 8:

- **Nothing was scrolled by hand.** `-autoscroll` moves the scroll position 120 times a second, which
  makes the views do what a scroll makes them do, but it is not a trackpad: momentum, rubber-banding and
  the horizontal strips under two fingers were not tried. The window was in the background throughout.
- **The new grid and strips were not clicked.** Opening a title by click, Return or Space, hover
  highlights, the focus ring on strip cards and VoiceOver's press are in code and (activation, reuse,
  paging, scroll position) in tests against an offscreen window; none was tried by hand.
- **A true cold launch** (after a restart) is still unmeasured: it needs `sudo purge` or a reboot.
- **An M1 was not available.** The M1 has roughly 60 % of this machine's single-core speed, which would
  put 4K HDR at 24 frames a second near 18 % and at 60 near 33 %; that is arithmetic, not a measurement.
- **About 190 MB of GPU memory is unexplained**: some 46 allocations of exactly 4 MB that exist while a
  file is open (playing or paused) and are gone once it has ended. They do not depend on the canvas size,
  the video's size, hardware decoding, dithering, subtitles, sound or the Vulkan queue options; the
  high-quality preset adds 18 more. Not libplacebo's slab allocator (its log shows one 260 KB slab) and
  not Metal's timestamp buffers (tested outside the app). Finding it needs the engine built from source.
- **Dropped frames in background runs vary** without any change to the app: the same stream dropped 0,
  33–37 and 82 frames in different 40-second runs before the final ones, which dropped none. The window
  is behind others during a check, and what the window server does for a hidden window is not ours to
  control; treat a drop count from a background run as an upper bound, not a finding.
- The stream cache cap leaves about 12 seconds in hand at 32 Mbit/s for a plain HTTP stream (torrents
  are on disk by then). Whether that is enough on a poor connection was not tried; an `mpv.conf` can raise it.
- Engine costs that only a from-source build could change: 4 decoder threads are requested even with
  hardware decoding (about 380 ms of software HEVC work at start-up), FFmpeg sets colour attachments
  on every decoded frame (1.75 % of a core at 60 frames a second), and the letterbox bars are cleared in
  a render pass of their own (0.8 %).
- `swapchain-depth=1` would save one 32 MB swapchain image and dropped no frames here, but it cannot be
  judged with the window in the background, so the engine's default (3) stays.
- `leaks` still reports 3 to 5 blocks of 80 bytes during playback.

### Stage 9 contents

| Where | Added | Tests |
|---|---|---|
| Scripts, Config | `package.sh`, `collect-licenses.sh`, `licenses.lock`, `ThirdParty.json`, update settings in `Branding.xcconfig`, Sparkle 2.10.1 in `project.yml` | — |
| AppUI | `ThirdPartyCatalog`, `AcknowledgementsModel` + view + menu command, `UpdateConfiguration` | 133 |
| App | `AppUpdater` + "Check for Updates…", the Acknowledgements window, licence resources, `-acknowledgements`, the bundled `ffmpeg` helper | — |
| Scripts, Config | `build-ffmpeg-helper.sh`, `ffmpeg-helper.lock` | — |
| PlayerKit | the fallback converts once only; its engine test runs with the built helper and with an installed ffmpeg | 180 |
| Repository | `README.md` | — |

What was produced and checked: `build/dist/Orbit-0.1.0.dmg`, 52 MB, holding a 116 MB universal app
(44 MB and 101 MB before the audio conversion helper was added),
ad-hoc signed with the hardened runtime. The script verified the signature (deep, strict), both
architectures of the app and of the engine, that the binary starts, the image's checksum, and the app
inside the mounted image. The app was also launched from the mounted image in the background and drew
its window (70 MB footprint). The Acknowledgements window was seen showing mpv's licence.

Carried over or not verified in Stage 9:

- **Developer ID signing, signing the image, notarisation and stapling have never run.** There is no
  Developer ID in the keychain. Those branches of `package.sh` follow Apple's and Sparkle's
  documentation and are untested, including Sparkle's signing order with a real identity.
- **The updater has never started.** No feed or key is configured, so Sparkle is linked and silent. A
  check for updates, an appcast, a download and an install were not tried; only the rule for when an
  updater exists is tested.
- **The disk image was not opened on another Mac**, and not by double-click on this one (it was mounted
  from the command line, hidden from Finder). What Gatekeeper says about an ad-hoc signed app elsewhere
  is from its documentation, not observed. The Intel half is built and checked with `lipo`, not run.
- **Licence versions**: for FreeType, FriBidi, HarfBuzz, libunibreak, GMP, Nettle, glslang, SPIRV-Tools,
  SPIRV-Cross, uavs3d, libdovi and LuaJIT the text is from a fixed recent commit, because MPVKit's
  binaries do not say which version they contain. The licences themselves are the same; a copyright
  year in a text may be newer than the code. Whether MPVKit's FFmpeg is built with its version-3 option
  (which makes it LGPL 3) is not known; both texts are shipped and the entry says so.
- Nothing in the Acknowledgements window was clicked; its list and texts are tested through the model.
- The icon is still the generated placeholder. The disk image has no background or layout.
- Left to the user (see the decisions table): Developer ID and notarisation, the update feed and key,
  the app's own licence, and providing source for the LGPL libraries and the helper when distributing.
- **The helper's Intel half has never run** (built, checked with `lipo`). Its source archive's PGP
  signature was not checked (no `gpg` here); the hash is of the archive as first downloaded.
- **A bug the helper's in-app check turned up, now fixed and tested**: if even the converted sound would
  not play, the player converted the same track again and again (seven times in seven seconds), and a
  file with no playable sound at all was announced as such on every pass. It now converts once, says
  there is no sound, and stops until the user picks a track.

### Stage 10 contents

| Where | Added | Tests |
|---|---|---|
| WatchParty (new package) | `PartyCore` (+Messages, +Sync), `ClockSync`, `SyncTuning`, `PartyMessage`, `PartyInvite` / `PartyServer` / `SignalSeal`, signalling frames and `SignalingConnection`, `WebRTCTransport` (+Links, +Voice) and `PeerLink`, `PartySession`; target `WatchPartyTestSupport` (`LoopbackSignalServer`, `InMemoryPartyNetwork`) | 47 (1 skipped here: see below) |
| Server | `signal.ts`: the signalling server | 2 of the above run it |
| PlayerKit | `PlaybackIntent` and `followingExternal` (`PlayerModel+Following`), `speedAdjustment`, `hasPendingUserSeek`, `PlayerAccessory` + its panel and button, `announce` made public; volume and stop moved to `PlayerModel+Volume` | 180 |
| AppUI | `PartyCenter`, `PlayerPartyBridge`, `PartyEnvironment`, `PartyPanel`, `PartySetupView`, `PartyStatusBar`, `PartyCommands`, name and server in Settings → General, `StreamPlayer.nowPlayingURL` | 143 |
| App, Config, Scripts | `-partyHost` / `-partyJoin` and friends, `PARTY_SERVER_URL`, microphone usage text and entitlement (`Config/App.entitlements` for signed builds), WebRTC in `package.sh`, `licenses.lock` and `ThirdParty.json`, `party-check.sh` | — |

Decided by the user: option B of the four that were laid out (peer to peer over WebRTC, with a
signalling server), and Google's WebRTC as the prebuilt stasel/WebRTC framework rather than
libdatachannel or a from-source build. Decided here, and easy to change: Deno for the server (it is
installed, needs no dependencies, and the protocol is a dozen JSON frames, so porting it is an hour);
everyone controls playback unless the host says otherwise; a party holds eight.

What was checked, and how:

- **The sync logic** in `SimulatedParty`: joining with clocks a day apart, pause, jump, speed, a stalled
  player, the holder leaving, a slow or sluggish player's jumps, a player running 1 % slow for two
  minutes (never more than 0.2 s out, no jumps), three people, host-only control, changes of video.
- **Real connections**: WebRTC peers in one process over the loopback interface, through the in-process
  server and through `Server/signal.ts` itself: two and three peers, leaving, the server going away and
  coming back, a wrong invitation, a full room, everyone renegotiating at once five times over.
- **Real players**: two engines in one process kept within 0.25 s while playing and 0.15 s paused,
  through a pause, a jump while paused, a resume and a change of speed; once over an in-memory network
  and once over real WebRTC connections.
- **Two copies of the app** (`party-check.sh`, background, silent, loopback): both windows show the
  panel with both people "Watching", the chat line sent by one arrives at the other, and at the same
  wall-clock moment the two players were 0.083 s apart playing (one frame of the 12-frames-a-second
  sample) and 0 to 0.083 s apart after a pause made in either copy; a speed change made by the guest
  showed in the host's control bar.

**The notices of what WebRTC contains** (added after the user's go-ahead to fetch from Google's
repositories): 26 texts in `Config/licenses.lock`, from `webrtc.googlesource.com`,
`chromium.googlesource.com`, `boringssl.googlesource.com` and `aomedia.googlesource.com`, each at the
revision that WebRTC's `DEPS` pins for commit `fb1c41a9` (branch-heads/8127, the commit stasel's
release notes for 158.0.0 name; the binary's own source stamp, 2026-10-26, agrees). Those servers
answer in base64 (`?format=TEXT`), which `collect-licenses.sh` now decodes before checking the hash.
Rust's texts come from Chromium's mirror of rust-lang/rust at the toolchain's revision. 60 licence
files in all go into the app.

Three bugs found by those checks, each now covered by a test:

- **A person's own jump could be undone.** The position changes before the player reports that a jump
  has landed; a sync tick in between saw the player far from the party and pulled it back. The party
  now leaves a player alone while `hasPendingUserSeek`.
- **A newcomer could take the party over.** Someone who opened a video in the first quarter-second
  after connecting, before the party's state had arrived, published theirs, and a coin toss between the
  two versions decided. Nobody decides what is watched until they know how the party stands
  (`isInformed`), and the host publishes what is playing at once rather than at the first tick.
- **Catching up took fifteen seconds.** If the player had not started a jump by the first look after it,
  the landing was never noticed and a gap of up to a second and a half was closed at 8 %. The landing
  is now waited for, a jump more than 0.3 s off is repeated once with what was learnt, and anything
  over a second is jumped rather than played off.

Carried over or not verified in Stage 10:

- **Nobody has spoken or heard a word.** Voice is built on WebRTC's defaults and has never carried
  sound: checks may not open the microphone or play audio. The one test that negotiates audio (one
  person in the voice chat, which sends nothing) is skipped on this Mac because the microphone question
  has never been answered for the test runner; it runs where it has. Two people in the voice chat, the
  microphone prompt, echo cancellation, muting as heard by the other side, and whether the film's own
  sound leaks into the microphone badly enough to need push-to-talk are all untried.
- **No two networks have been connected.** Everything ran on one Mac's loopback interface: no STUN, no
  TURN, no NAT, no real latency or packet loss, no second Mac, no Intel Mac. That connections form
  between Germany, Singapore and India rests on WebRTC and on a relay being available where needed
  (see the decisions table). Clock comparison was tested with simulated delay only.
- **The server has only run on this Mac**, over plain http on loopback. TLS in front of it, a real host,
  many rooms, the TURN credential it issues (written to coturn's documented scheme, never tried against
  coturn) and its rate limits under abuse are untested.
- **Nothing was clicked or typed.** The panel was seen through debug arguments. Typing in the chat field
  (and whether the player's key bindings stay out of the way while typing), the start/join sheet, the
  File menu items, the Settings fields, Copy Invitation and the clipboard, "Show It" and bringing the
  main window forward, the host's control switch, Join Voice and Mute, and the unread badge on the
  people button are covered by view-model tests or not at all.
- **Streams from add-ons in a party were not tried**: only local files. A catalog title's identity
  (`video:<type>:<id>`) and the stall rule for paused streams are unit-tested; a torrent that needs a
  minute to start, two people on different streams of different lengths or with different intros, and
  next-episode autoplay in a party are untried. Two cuts of a film stay "in sync" by position, which is
  not the same scene.
- **An A-B loop does not hold in a party** (the loop's jump back is corrected as drift), by reading the
  code; not tried. Frame stepping is shared as a pause and a jump.
- A party survives the signalling server restarting, but not a Mac sleeping: connections time out and
  the person has to join again with the link. There is no rejoin by itself, and no way to remove someone.
- The invitation's secret is in the link; anyone who is given the link can join. The people in a party
  learn each other's internet addresses, as in any direct call.
- **Which libraries WebRTC contains was worked out, not read off a manifest.** The framework ships no
  list. The 16 components in `Config/ThirdParty.json` are the ones WebRTC's own licence generator
  (`tools_webrtc/libs/generate_licenses.py` at the built commit) maps to a notice and of which the
  binary shows a trace (file paths and version strings), plus the ones every build includes but that
  leave no strings (CRC32C, PFFFT, RNNoise, the in-tree FFTs, G.711/G.722 and square root) and `cxx`,
  which WebRTC's one Rust module needs. Left out for want of any trace: zlib, libjpeg-turbo, jsoncpp,
  perfetto, the third-party SFrame library, and `foldhash` (whose licence asks nothing of a binary).
  LLVM's compiler-rt and libc are under the same text as libc++, which is included. The certain way
  to settle the list is WebRTC's generator run on a real checkout of the build, which was not done.
- The x86_64 half of `WebRTC.framework` is checked with `lipo` only.
- The user's own running copy of the app (an older build, open since 17 November) crashed twice during
  this stage, in libmpv's CoreAudio hot-plug callback (`hotplug_cb` → `mp_msg`, a null context) when the
  list of audio devices changed. Not this branch's code, and not reproduced. The test runs here are
  probably not what changed the list: a listener on the system's device list saw no change through the
  second half of the engine tests, all of the AppUI and WatchParty tests, a Release launch and packaging.
  Worth its own investigation: a device appearing or going away should not take the app down.

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

| 2026-11-17 | 6 | Release, universal | Launch to first screen / Home content, warm, median of 5 (Home now also reads the watch history) | 181 ms / 341 ms |
| 2026-11-17 | 6 | Release, universal | Idle memory, Home loaded; app bundle size | 68 MB; 126 MB |
| 2026-11-17 | 6 | Debug app | Next episode after the countdown: first frame of the following file | 78 ms |

| 2026-11-17 | 7 | Release, universal | Launch to first screen / Home content, warm, median of 5 (settings are read alongside the add-ons) | 180 ms / 354 ms |
| 2026-11-17 | 7 | Release, universal | Same, with settings read before the add-ons (first attempt, two runs of 5) | 191–222 ms / 405–432 ms |
| 2026-11-17 | 7 | Release, universal | Idle memory, Home loaded; app bundle size | 68 MB; 128 MB |

| 2026-11-17 | 8 | Profile build | 4K HEVC 10-bit HDR 60 fps from a file, start of stage / end: CPU | 22.8 % / 20.1 % of one core |
| 2026-11-17 | 8 | Profile build | Same: memory at most / settled; dropped frames | 520 MB / 497 MB; 0 |
| 2026-11-17 | 8 | Profile build | 4K HEVC 10-bit HDR 24 fps (150 s, 32 Mbit/s) from a file: CPU / memory | 10.5 % / 481 MB |
| 2026-11-17 | 8 | Profile build | Same file as a stream over loopback HTTP, engine's own cache sizes: memory | 740–850 MB (over the target) |
| 2026-11-17 | 8 | Profile build | Same, cache capped at 48 + 8 MiB (now the default): CPU / memory at most / settled; dropped | 10.4 % / 553 MB / 543 MB; 0 |
| 2026-11-17 | 8 | Profile build | 1080p H.264 30 fps from a file, start of stage / end: CPU; memory | 13.0 % / 11.1 %; 429 MB |
| 2026-11-17 | 8 | Profile build | Time to first frame: file / loopback HTTP / HTTP throttled to 10 Mbit/s | 269–290 ms / 267 ms / 264 ms |
| 2026-11-17 | 8 | Profile build | Main thread while 4K HDR plays, nine seconds, before / after the playhead split | 268 ms / 16 ms on CPU |
| 2026-11-17 | 8 | Profile build | Player after its file has ended (holding the last frame): memory | 248 MB |
| 2026-11-17 | 8 | Profile build | Discover scrolled 20 000 pt in 8 s, SwiftUI grid: ticks late by > 8 ms / > 16 ms; longest | 29–37 / 6–10 of 900; 19–27 ms |
| 2026-11-17 | 8 | Profile build | Same, collection view grid (3 runs, and 1 with an empty image cache) | 0 / 0 of 960; 5.0–7.5 ms |
| 2026-11-17 | 8 | Profile build | Same at 6000 pt/s (47 000 pt) | 3 / 0; 9 ms |
| 2026-11-17 | 8 | Profile build | Home scrolled, SwiftUI strips / layer-based strips: longest tick | 17–31 ms / 6.9 ms |
| 2026-11-17 | 8 | Release, universal | Launch to first screen / Home content, warm, median of 5; first run after the build | 193 ms / 377 ms; 206 ms / 392 ms |
| 2026-11-17 | 8 | Release, universal | Idle memory, Home loaded; app bundle size | 71 MB; 128 MB |

| 2026-11-17 | 9 | Release, universal | Launch to first screen / Home content, first run after the build (with Sparkle linked) | 179 ms / 344 ms |
| 2026-11-17 | 9 | Packaged app | App bundle as built / after stripping local symbols; disk image | 132 MB / 102 MB; 44 MB |
| 2026-11-17 | 9 | Packaged app | Idle memory, launched from the mounted disk image | 70 MB |
| 2026-11-17 | 9 | Packaged app | With the audio conversion helper (15 MB): app as built / stripped; disk image | 147 MB / 117 MB; 52 MB |

| 2026-11-21 | 10 | Release, universal | Launch to first screen / Home content, first run after the build (with WebRTC linked) | 191 ms / 372 ms |
| 2026-11-21 | 10 | Release, universal | Idle memory, Home loaded (nothing of WebRTC is started until a party is) | 69 MB |
| 2026-11-21 | 10 | Packaged app | App as built / stripped; disk image (WebRTC.framework is 28 MB of it, both architectures) | 178 MB / 146 MB; 65 MB |
| 2026-11-21 | 10 | Debug app, two copies | Watch party on loopback: how far apart the two players were at the same moment, playing / after a pause | 0.083 s (one frame at 12 fps) / 0–0.083 s |
| 2026-11-21 | 10 | In a test | Two engines in one process, over real WebRTC on loopback: from the guest opening the file to within 0.25 s of the host | under 3 s for the whole test |

**The Stage 3 memory rows above are wrong, and its CPU rows rest on three samples.** The samples are
10 seconds long and `measure-playback.sh` read memory after the file had ended (about 200 MB too low)
and, through a parsing slip, dropped CPU samples under 10 %, which hid the idle ones. The script now
loops the file and reads memory while it plays; the Stage 4 rows are the ones to trust. The canvas was
also larger for Stage 4 (3600×2338, the display was set to a higher resolution) than for Stage 3
(3024×1964), and both CPU and memory grow with it.

Reading the Stage 8 numbers. "Profile build" is the Debug configuration compiled with optimisation; on
the plain Debug build the same playback measured about two points of CPU higher. Scrolling is measured
by how late a 120 Hz timer on the main thread fires while the list is moved under it: a tick 8 ms late
is a missed frame at 120 Hz. It understates work that fits between two ticks and says nothing about the
window server. Where playback memory goes at 4K HDR (about 520 MB): the decoder's frames, eleven of
24 MB each (inherent to 10-bit 4K with HEVC's reference frames); the three swapchain images, 98 MB; a
fixed 190 MB of GPU memory that is not explained (see the Stage 8 notes); 120 to 170 MB of heap; and the
app itself, about 70 MB.

**The Stage 4 reading of where memory goes was wrong**: it put about 290 MB down to canvas-sized
textures. Only the swapchain depends on the canvas (measured by changing the canvas size); the "under
30 % on an M1" CPU target remains unverified for want of an M1.

Reading the Stage 3 numbers: all on an M4 Pro, so the "under 30 % on an M1" target is not verified, and
CPU is a share of one core with the window in the background. Playback memory is inside the 600 MB
target with the default preset and was not with the engine's defaults (765 MB peak seen). The loopback
and throttled HTTP results say nothing about a real, distant server.

Reading the Stage 2 numbers: launch and memory are well inside the targets. The 8 ms main-thread budget
is met most of the time while artwork streams in but not always (run 2); that is SwiftUI committing
many image updates at once, and it is the first thing to look at in Stage 8. Scrolling itself has not
been measured.

Not measured in Stage 10: CPU and memory while a party is on (a data channel, four ticks a second and,
with voice, WebRTC's audio pipeline), and anything about voice.

Not yet measured: a true cold launch (after reboot or `sudo purge`), anything on an M1, and the
Allocations instrument (footprint, `heap`, `vmmap` and `leaks` were used instead).
