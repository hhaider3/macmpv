# macmpv

macmpv is a native macOS video player built with SwiftUI. It embeds mpv for
playback and uses ffprobe (from FFmpeg) to read media metadata.

**Website:** <https://macmpv.pages.dev> — download the latest release.

![macmpv playing a 4K video with playback controls visible](docs/macmpv-player.png)

## Features

- Embedded, hardware-accelerated mpv playback
- Local video/audio files and HTTP, HTTPS, RTMP, or RTSP streams
- `.magnet`, `.torrent`, and magnet links through WebTorrent CLI, including multi-file torrents
- Drag-and-drop, reorderable queue with next/previous and repeat modes
- Seeking, mute/volume, playback speed, audio tracks, and subtitles
- Per-file playback resume and saved intro/outro markers
- External subtitle loading and selectable audio/subtitle track menus
- Configurable subtitle appearance: size, outline, text color, background, bold, and sync delay
- Subtitles that move clear of the controls bar based on the measured overlap, in windowed and full-screen playback
- PNG screenshots through the player controls or keyboard
- ffprobe metadata for duration, resolution, frame rate, codecs, and format
- Full-screen playback and native macOS keyboard commands

## Requirements

- macOS 26
- Xcode 26 or newer (including Command Line Tools)
- Homebrew `mpv` and `ffmpeg` with `pkg-config`
- Node.js/npm and WebTorrent CLI for torrent playback only (`npm install -g webtorrent-cli`)

Verify your toolchain:

```sh
xcode-select -p
swift --version
pkg-config --modversion mpv  # should print 2.x
```

## Quick Start

```sh
brew install mpv ffmpeg pkg-config node
npm install -g webtorrent-cli
make app && open dist/macmpv.app
```

## Install dependencies

```sh
brew install mpv ffmpeg pkg-config node
npm install -g webtorrent-cli
```

If `pkg-config --modversion mpv` fails, ensure Homebrew's pkg-config is on your PATH:

```sh
brew --prefix
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig:$PKG_CONFIG_PATH"
```

## Supported Formats

Anything [mpv](https://mpv.io/) / [FFmpeg](https://ffmpeg.org/) can play. Common local extensions:

`mp4`, `m4v`, `mov`, `mkv`, `mka`, `webm`, `avi`, `flv`, `ts`, `mts`, `m2ts`, `mpeg`, `mpg`, `vob`, `wmv`, `asf`, `divx`, `f4v`, `rm`, `rmvb`, `3gp`, `3g2`, `ogv`, `ogm`, `ogg`, `oga`, `opus`, `mp3`, `m4a`, `aac`, `ac3`, `dts`, `flac`, `alac`, `ape`, `aiff`, `caf`, `wav`, `wma` plus `m3u`/`m3u8` playlists.

Network streams: `http`, `https`, `rtmp`, `rtsp`, and `magnet`. A `.magnet` file must contain a valid `magnet:` URI; binary `.torrent` files can be opened directly. After torrent metadata resolves, every supported video or audio file is added to the queue in natural filename order while retaining its original WebTorrent index for playback. The first file starts automatically, and selecting any row streams that file to the embedded player over localhost; non-media extras are hidden. Torrent media is saved under `~/Movies/macmpv/Torrents/<info-hash>/`. Completed files and partial downloads survive app shutdown and are verified and reused when you reopen the same torrent. The currently selected video gets all available download capacity; once it finishes, the remaining supported media files download in natural filename order. Selecting another video immediately changes download priority within the same connection. Downloads stop when the app closes or you leave the torrent. Use **Show Torrent Downloads** in the queue menu to find the files; remove unwanted downloads manually to reclaim disk space. URL schemes and extension checks are defined in `Sources/Cinewave/MediaModels.swift`.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘ O` | Open media files |
| `Space` | Play / Pause |
| `←` / `→` | Back / Forward 10 seconds |
| `↑` / `↓` | Volume up / down |
| `⌘ ←` / `⌘ →` | Previous / Next item in queue |
| `M` | Mute / Unmute |
| `[` / `]` | Decrease / Increase playback speed |
| `\` | Reset playback speed to 1× |
| `⇧ ⌘ O` | Open external subtitle file |
| `⇧ ⌘ S` | Save screenshot |
| `⌘ ⌥ S` | Show / Hide queue sidebar |
| `Double-click` | Toggle full screen |
| `Click` | Play / Pause (when media loaded) |
| `Esc` | Exit full screen (system) |

Menu commands are defined in `Sources/Cinewave/CinewaveApp.swift`.

## Run from source

```sh
# debug build and run
swift run macmpv
make run   # same as above

# with media
swift run macmpv -- /path/to/video.mp4
```

## Build

| Command | What it does |
|---------|--------------|
| `make build` | `swift build` (debug) |
| `make app` | `swift build -c release` + assembles `dist/macmpv.app` |
| `make clean` | `swift package clean` |

Build the app bundle:

```sh
make app
open dist/macmpv.app
```

The local app bundle links to the Homebrew `libmpv` installation. Keep mpv and
FFmpeg installed while using macmpv.

You can also build directly:

```sh
swift build -c release
zsh Scripts/build-app.sh release
open dist/macmpv.app
```

## Distribute (dmg)

```sh
make dmg
```

`Scripts/package-dmg.sh` bundles `libmpv`, its full Homebrew dependency closure,
and `ffprobe` inside the app (`Contents/Frameworks` + `Contents/MacOS/ffprobe`),
rewrites all load commands to `@rpath`, re-signs, and packs
`dist/macmpv-<version>-<arch>.dmg`. The bundled app runs without Homebrew
installed, on the same architecture and macOS 26 or newer. WebTorrent CLI stays
optional and external — torrent playback still requires it on the target Mac.

A "+ Torrents" variant also bundles a node runtime and WebTorrent CLI. It is
larger than the standard build, but torrent playback works with nothing installed:

```sh
make dmg-torrents   # dist/macmpv-<version>-<arch>-torrents.dmg
```

The npm tree is pruned (docs, type definitions, foreign-platform native
prebuilds) and lives in `Contents/Resources`, where codesign seals it as data;
the node launcher sits in `Contents/Helpers`. The app prefers the bundled
runtime automatically when present, and falls back to an installed CLI.

The dmg is ad-hoc signed. On another Mac, Gatekeeper will challenge the first
launch because the download has no verified developer signature: open
**System Settings → Privacy & Security** and click **Open Anyway**, or clear the
quarantine attribute:

```sh
xattr -dr com.apple.quarantine /Applications/macmpv.app
```

For friction-free distribution, sign with a Developer ID certificate and
notarize before distributing:

```sh
export MACMPV_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
make dmg
xcrun notarytool submit dist/macmpv-*.dmg --keychain-profile <profile> --wait
xcrun stapler staple dist/macmpv-*.dmg
```

## Website

A static marketing/download site lives in `site/` (dark glass theme, no
dependencies, plain HTML/CSS/JS), deployed at <https://macmpv.pages.dev>.
It is ready for Cloudflare Pages:

- Framework preset: **None**
- Build command: *(empty)*
- Output directory: `site`

Download buttons point at GitHub Releases, each pinned to its exact tag
(`releases/download/vX.Y/...` and `releases/download/vX.Yt/...` for the
"+ Torrents" build). Both DMGs exceed Cloudflare Pages' 25 MB static asset
limit, so binaries must be hosted on GitHub Releases (or R2), not in the Pages
project.

Releases are automated: `make release` (or `make release VERSION=1.3` to bump
Info.plist first — the bump is committed so the tag points at the version
built) builds both dmgs, patches the site's download URLs, sizes, and SHA-256,
and publishes both GitHub releases (`vX.Y` and `vX.Yt`) via the `gh` CLI — see
`Scripts/release.sh`. It refuses a dirty working tree, pushes the exact source commit, and explicitly targets that commit for both tags
and leaves the site changes for you to commit and push, which deploys them via
Cloudflare Pages.

## Troubleshooting

**`sandbox-exec: sandbox_apply: Operation not permitted`**

You are in a restricted sandbox (Muse sandbox, some CI). Workaround:

```sh
swift build --disable-sandbox
swift build -c release --disable-sandbox
swift build -c release --disable-sandbox --show-bin-path
# or for the app bundle:
swift build -c release --disable-sandbox && zsh Scripts/build-app.sh release
# Scripts/build-app.sh will also use --disable-sandbox automatically if needed
```

Do not use `--disable-sandbox` for normal local builds outside a sandbox.

**`pkg-config` / `mpv` not found**

```sh
brew reinstall mpv pkg-config
pkg-config --modversion mpv
```

**App opens but video is black / no audio**

Ensure `mpv` still installed: `brew list mpv` and `otool -L dist/macmpv.app/Contents/MacOS/macmpv` should show `/opt/homebrew/opt/mpv/lib/libmpv.2.dylib`.

**No video in a VM or headless session**

macmpv prefers an accelerated OpenGL 3.2 context and falls back to a software
renderer when that is all the system offers. If no OpenGL surface can be created
at all, the player shows an in-app error instead of crashing; playback is not
possible in that configuration.

## Architecture

macmpv wraps `libmpv` via `Sources/CMPV` (pkg-config `mpv`) and renders with `MPVEngine` / `MPVGLView` (`Sources/Cinewave/MPVEngine.swift`, `Sources/Cinewave/VideoSurface.swift`). Metadata is probed out-of-process with `ffprobe` (`Sources/Cinewave/MediaProbe.swift`).

Playback uses mpv's copy-back hardware decoding mode. Scrubbing coalesces fast-seek previews (throttled to ~180 ms, `absolute+keyframes`) while dragging the slider, then performs an exact seek on release — see `PlayerModel.previewSeekInterval` and `MPVEngine`. Natural EOF is consumed once from mpv’s `eof-reached` property, including when the last frame stays visible. Queue operations and persistence live in `PlayerModel+Queue.swift` and `PlayerModel+Persistence.swift`; their stored data format is unchanged. Metadata probes run at most two child processes at once, with blocking pipe reads isolated from Swift concurrency workers. Torrent requests verify their identity after asynchronous reads so canceled work cannot stop a newer helper.

Teardown drains the dedicated mpv event queue before destroying the handle, and subtitle clearance is recomputed from the letterboxed video rect and the measured height of the controls bar.

## Credits

- [mpv](https://mpv.io/) — media playback engine (`libmpv`)
- [FFmpeg](https://ffmpeg.org/) — `ffprobe` for metadata probing (`ffmpeg` Homebrew package)

## Tests

Run `make test` for Swift regression tests and static website validation. The Swift
suite covers EOF and repeat modes, stop/error handling, queue persistence, stale
torrent callbacks, large stderr output, and concurrent metadata timeouts. Process
tests use local fake helpers and do not contact torrent peers or remote media.

The website preserves its static Cloudflare Pages deployment: pushing `main`
publishes `site/`. Its native download picker and FAQ remain usable without
JavaScript; the layout adapts to small screens and respects reduced motion.

Run `make test-torrents` with the bundled torrent app present to test real downloads against a local web seed, priority switching, and offline reuse after restart. These tests do not contact public peers. Set `MACMPV_WEBTORRENT_MODULE` to a WebTorrent `index.js` and `TORRENT_NODE` to a compatible Node executable to use external dependencies.
