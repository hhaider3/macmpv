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
- Xcode 26 or newer
- Homebrew `mpv` and `ffmpeg`

```sh
brew install mpv ffmpeg
```

## Run from source

```sh
swift run macmpv
```

You can also pass media when launching:

```sh
swift run macmpv -- /path/to/video.mp4
```

## Build the app bundle

```sh
make app
open dist/macmpv.app
```

The local app bundle links to the Homebrew `libmpv` installation. Keep mpv and
FFmpeg installed while using macmpv.

macmpv uses mpv's copy-back hardware decoding mode and coalesced fast-seek
previews while scrubbing, followed by an exact seek when the slider is released.
