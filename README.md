# macmpv

macmpv is a native macOS video player built with SwiftUI. It embeds mpv for
playback and uses ffprobe (from FFmpeg) to read media metadata.

## Features

- Embedded, hardware-accelerated mpv playback
- Local video/audio files and HTTP, HTTPS, RTMP, or RTSP streams
- Drag-and-drop queue with next/previous and repeat modes
- Seeking, mute/volume, playback speed, audio tracks, and subtitles
- ffprobe metadata for duration, resolution, frame rate, codecs, and format
- Full-screen playback and native macOS keyboard commands

## Requirements

- macOS 26
- Xcode 26 or newer (including Command Line Tools)
- Homebrew `mpv` and `ffmpeg` with `pkg-config`

Verify your toolchain:

```sh
xcode-select -p
swift --version
pkg-config --modversion mpv  # should print 2.x
```

## Install dependencies

```sh
brew install mpv ffmpeg pkg-config
```

If `pkg-config --modversion mpv` fails, ensure Homebrew's pkg-config is on your PATH:

```sh
brew --prefix
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig:$PKG_CONFIG_PATH"
```

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

## Notes

macmpv uses mpv's copy-back hardware decoding mode and coalesced fast-seek
previews while scrubbing, followed by an exact seek when the slider is released.
