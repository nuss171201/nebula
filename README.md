# Nebula

A native macOS media centre: browse catalogs from add-ons you install, keep a library, and play
anything in a player built on libmpv.

"Nebula" is the app's name. It is set in one file (see [Renaming the app](#renaming-the-app)).

- macOS 14 or later, Apple Silicon and Intel (universal binary).
- Swift 6 and SwiftUI, with AppKit where it is faster. No web views except the trailer player.
- Distributed outside the App Store: hardened runtime, not sandboxed.

## What it does

**Browsing.** Home, Discover, Search, title pages with seasons and episodes, a Library with history and
Continue Watching, and a Calendar of upcoming episodes for the series you saved. Home opens with a
banner of featured titles, taken from the top of your first two catalogs, with Play, Add to Library
and More Info on each (Settings → General hides it).

**Add-ons.** Catalogs, metadata, streams and subtitles come from add-ons that speak the Stremio add-on
protocol. The app ships with two: Cinemeta (metadata) and OpenSubtitles (subtitles). It ships with no
source of streams and suggests none. You add an add-on by pasting its address in Add-ons; what an add-on
provides is your choice and your responsibility.

**Playing.** Local files, folders, web addresses, and streams from add-ons, including torrents (fetched
piece by piece in playing order and served to the player from this Mac only).

**One Play button.** A title's page shows Play, not a list of forty releases. The app picks the best
picture that should play without stopping: in your languages, shared by enough people, within the limits
you set, and needing no more than your connection has been seen to manage. If it does not start, the
next one is tried. The full list is one click away, or the default if you prefer (Settings → Streaming).

- Hardware decoding; HDR shown as HDR on an HDR display, converted otherwise.
- Audio and subtitle track selection by language, remembered per file and per series.
- Subtitle style, delay and online subtitle search; audio delay, 10-band equaliser, loudness levelling.
- Speed, frame stepping, A-B loop, chapters, a queue, screenshots, seek-bar previews.
- Picture in picture, a mini player, media keys and Now Playing.
- Resume where you left off; the next episode starts after a countdown.

**Watching together.** A watch party keeps the players of up to eight people, wherever they are, on the
same frame: play, pause, jumps and speed are shared, a party waits when someone's video stalls, and there
is a text chat and a voice chat. Everyone plays their own copy or stream; no video travels between people.

## Building

Tools, from [Homebrew](https://brew.sh):

```bash
brew install xcodegen swiftformat swiftlint ffmpeg cmake ninja
```

It is built with Xcode 27.2; the packages need Swift 6.2 or later. Then:

```bash
Scripts/ci.sh
```

The first run takes a while. It downloads and verifies the prebuilt playback libraries, builds
libtorrent and a small audio-only ffmpeg from source, collects the licence texts, generates small test videos with ffmpeg, generates
the Xcode project, checks formatting and lint, builds with warnings as errors, and runs every test.

The app is then at `build/DerivedData/Build/Products/Debug/Nebula.app`. To work in Xcode:

```bash
xcodegen generate
```

```bash
open MediaCenter.xcodeproj
```

`CLAUDE.md` is the working reference for the code: architecture, conventions, every measuring script,
and what has and has not been verified.

## Using it

### Keyboard shortcuts in the player

All of these can be changed in Settings → Shortcuts.

| Key | Action | Key | Action |
|---|---|---|---|
| Space, K | Play / pause | F, Return | Full screen |
| ← → | Back / forward 5 seconds | Esc | Leave full screen |
| ⇧← ⇧→ | Back / forward 30 seconds | ⌃⌘P | Picture in picture |
| ↑ ↓ | Volume | ⌃⌘M | Mini player |
| M | Mute | ⌃⌘T | Always on top |
| , . | Previous / next frame | ⌘S | Screenshot |
| [ ] | Slower / faster | ⌥⌘S | Screenshot without subtitles |
| 0 | Normal speed | ⇧⌘V ⇧⌘A ⇧⌘S | Video, audio, subtitle settings |
| ⌘← ⌘→ | Previous / next chapter | A | Next audio track |
| ⇧⌘← ⇧⌘→ | Previous / next in queue | S | Next subtitle track |
| L | Set A-B loop points | V | Show or hide subtitles |
| Z X | Subtitles earlier / later | ⇧Z ⇧X | Sound earlier / later |

### mpv.conf and input.conf

For settings the app has no control for, put an `mpv.conf` in the app's own folder; an `input.conf`
there adds shortcuts. Settings → Advanced → Show Folder opens it. The app reads these files itself and
leaves out what it must control (the window, the output, track selection) and anything that would run
scripts or write files; Settings → Advanced lists every line it left out and why. Files in
`~/.config/mpv` are not read.

### Watch parties

Start one from File → Start or Join Watch Party… or from the people button in the player. You get an
invitation link (it is copied for you); friends paste it in the same place. Then play something: whoever
has the same title open is brought to where the party is, and anyone who has not is told what is on and,
for a title from a catalog, taken to its page to choose their own stream. A file counts as a copy of
whatever the party is watching, since two people's copies rarely have the same name.

- **What is shared:** which title, the position, play and pause, and the speed. Sound and subtitle
  tracks, volume and picture settings stay each person's own.
- **Who controls:** everyone, unless the person who started the party keeps the controls to themselves
  (a switch in the party panel).
- **Voice:** Join Voice in the party panel; macOS asks for the microphone the first time. Use headphones:
  the microphone hears the film from your speakers, and your friends would hear it twice.
- **Privacy:** the apps connect directly to each other (WebRTC) and what they say is encrypted between
  them. The link holds a secret that never reaches the party server; the server only sees that some
  apps want to meet in a room it cannot name, and passes sealed messages between them while they connect.
  People in a party do see each other's internet address, as in any direct call.

**The party server.** Apps in different places cannot find each other without help, so a party needs a
small meeting point. It is one file with no dependencies, `Server/signal.ts`, for whoever builds the app
to run somewhere that is reachable over https:

```bash
deno run --allow-net --allow-env Server/signal.ts     # PORT, HOST, ROOM_LIMIT, ICE_SERVERS, TURN_URLS, TURN_SECRET
```

Run a single instance (rooms are kept in memory), behind anything that gives it https. Its address goes
in `PARTY_SERVER_URL` in `Config/Branding.xcconfig` for a build, or in Settings → General on one Mac;
with neither, the app can still join a party from a link, which names its own server. The server tells
the apps which helper servers to use for finding a path to each other (two public STUN servers unless you
say otherwise). On some networks, mobile and company ones especially, no direct path exists, and two
people then connect only if you also run a relay (a TURN server such as coturn) and name it in
`TURN_URLS` and `TURN_SECRET`.

### Where things are kept

| What | Where |
|---|---|
| Library, history, settings, add-ons | `~/Library/Application Support/<bundle id>/library.sqlite` |
| `mpv.conf`, `input.conf` | `~/Library/Application Support/<bundle id>/` |
| Artwork, subtitles, streamed data | `~/Library/Caches/<bundle id>/` |
| Screenshots | `~/Pictures/<app name>/` |

The stream cache is trimmed to the size set in Settings → Streaming (10 GB unless changed).

## Packaging

```bash
Scripts/package.sh
```

This runs the full checks, then copies the Release app, strips local symbols, signs every piece of code
from the inside out with the hardened runtime, checks the result, and builds `build/dist/Nebula-<version>.dmg`.

**Signing.** Without anything set, the app is ad-hoc signed. That runs on the Mac that built it; on any
other Mac, macOS refuses to open it until its owner allows it in System Settings → Privacy & Security.
To make an app other people can simply open, you need a Developer ID certificate from the Apple
Developer Program (paid) and notarisation:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE="your-profile" Scripts/package.sh
```

`NOTARY_PROFILE` is the name of a keychain profile you save once with
`xcrun notarytool store-credentials`. The script makes and stores no credentials itself.

**Updates.** The app includes [Sparkle](https://sparkle-project.org) but has no updater until you give
it somewhere to look and a way to check what it finds. In `Config/Branding.xcconfig`:

- `UPDATE_FEED_URL`: the https address of your appcast.
- `UPDATE_PUBLIC_KEY`: the public half of an Ed25519 key pair, made with Sparkle's `generate_keys`
  (after a build it is in `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`). The
  private half stays in your keychain and signs each release (`sign_update`).

With both set, "Check for Updates…" appears in the app menu. With either missing or malformed, the app
contains no update check at all.

**Version.** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Config/Base.xcconfig`.

## Renaming the app

Change `BRAND_NAME` and `BRAND_BUNDLE_ID` in `Config/Branding.xcconfig`, and replace the icon in
`App/Assets.xcassets/AppIcon.appiconset`. Nothing else names the app: the Xcode project, target and
Swift module are called `MediaCenter` on purpose.

## Layout

```
App/        entry point, composition root, branding, debug launch arguments
Packages/
  MediaCore      models, add-on protocol client, HTTP client
  MediaLibrary   SQLite (GRDB): settings, library, history, installed add-ons
  StreamEngine   torrent engine (libtorrent), piece ordering, local HTTP server, cache
  PlayerKit      libmpv wrapper, player model and views, key bindings, config file parsing
  WatchParty     watch parties: sync logic, invitations, signalling client, WebRTC connections
  AppUI          every screen and its view model
Server/     the watch party's signalling server (one file, runs with Deno)
Config/     build settings, default add-ons, pinned third-party versions and hashes
Scripts/    CI, framework builds, packaging, measuring
```

## Known limits

- Dolby Vision is tone-mapped or shown as HDR10; a true Dolby Vision signal cannot be produced.
- The picture is always rendered at the screen's resolution, whatever the window's size.
- An audio track the player cannot decode is converted to AAC by a small `ffmpeg` inside the app. It is
  the same FFmpeg version as the player's own, so it rescues little that the player could not play
  anyway; it is there so that the conversion does not depend on what is installed on the Mac.
- The first time a torrent plays, macOS may ask whether to allow incoming connections and access to the
  local network.
- A file in Documents, Desktop or Downloads makes macOS ask for permission the first time.
- Watch parties need a party server that someone runs (see above), and a relay as well for people whose
  networks allow no direct connection. Everyone is connected to everyone, so a party holds eight people.
- In a watch party, the voice chat removes the echo of your friends' voices, not the sound of the film:
  without headphones the others hear your speakers. An A-B loop is not shared and does not hold in a party.
- No localisation yet: the interface is in English.

What was measured, and what was never tried by hand, is listed stage by stage in `CLAUDE.md`.

## Licences

**This app's own code has no licence yet.** Until one is chosen and added here, all rights are reserved
by its author.

**Third-party code** is listed, with its licence texts, in the app under Nebula → Acknowledgements and in
`Config/ThirdParty.json`. The versions and hashes of everything prebuilt are pinned in
`Config/mpv-libraries.lock`, `Config/torrent-libraries.lock`, `Config/ffmpeg-helper.lock` and
`Config/licenses.lock`.

WebRTC (BSD) is a separate dynamic library too, `WebRTC.framework`, used as published by the
stasel/WebRTC project and pinned by checksum in `Packages/WatchParty/Package.swift`. The open-source code
it contains in turn (BoringSSL, Opus, libvpx, libaom, dav1d, libsrtp, Abseil and more) is listed with it,
each with its notice taken from Google's repositories at the revision WebRTC's source pins.

The playback engine (mpv, FFmpeg, libplacebo and their dependencies) is under the LGPL. It is built as a
separate dynamic library, `Libmpv.framework`, so that it can be replaced with a build of your own; after
replacing it, sign the app again (`codesign --force --deep --sign - Nebula.app`). GPL-only parts of those
libraries are deliberately left out.

The app also carries a small `ffmpeg` program for converting audio (`Contents/MacOS/ffmpeg`), built from
FFmpeg's release archive under the LGPL 2.1 or later with the configuration in
`Scripts/build-ffmpeg-helper.sh`; the archive's address and hash are in `Config/ffmpeg-helper.lock`.

**If you distribute this app**, the LGPL also asks you to make the source of those libraries and of
that program available to the people you give it to, or to offer it in writing. The binaries here come from the
[MPVKit](https://github.com/mpvkit) project's releases, which name the upstream source each was built
from; pointing at someone else's download is not a substitute for providing the source yourself. Take
advice if you are unsure: this file is not legal advice.
