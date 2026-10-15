# Changelog

## 1.6 — 2026-10-15

- Seek-bar hover thumbnails: a separate silent decoder shows previews without interrupting playback. Previews appear in about 15 ms (1080p) to 50 ms (4K) while the cursor moves, then sharpen to the exact frame once it rests.
- Smoother 4K playback: VideoToolbox now decodes straight into GPU textures, and frames no longer block the main thread while waiting for display. On a 4K HEVC test clip, main-thread rendering time fell from 99% to about 22% and CPU use from 35% to about 20%.
- Fixed crashes when Bluetooth headphones connect or disconnect on macOS 27 by bundling mpv 0.41.0 with the upstream CoreAudio fix (mpv#18274), and switched macOS 27 to interleaved float audio.
- The audio, subtitle, and speed menus now show a checkmark next to the active choice.
- The controls bar and queue sidebar no longer swell while one of their menus is open.
- Torrent helpers stop on their own if macmpv quits unexpectedly, instead of downloading in the background.
- Torrent downloads persist under ~/Movies/macmpv/Torrents, resume when the torrent is reopened, and give the playing video download priority.
- The player title shows torrent filenames instead of stream indices, and torrent filenames with unusual characters stream correctly.
- Clicking the video responds immediately.
- The player redraws its controls at most four times a second during playback instead of on every frame, and resume positions are capped to the 500 most recent files.
- Fixed the website's download menu overflowing on phones.

Both downloads require macOS 26 or newer on Apple Silicon. The Standard build bundles playback dependencies; the + Torrents build also includes Node and WebTorrent. Public builds remain ad-hoc signed unless a Developer ID identity is configured.

## 1.5 — 2026-09-04

- Fixed automatic queue advancement and Repeat One/All when playback reaches the end while mpv keeps the final frame visible.
- Prevented canceled torrent metadata and stream requests from stopping a newer helper.
- Limited metadata probing to two processes and moved blocking pipe reads off Swift concurrency workers.
- Made loading indicators and playback errors visible in fullscreen.
- Corrected stop/error handling and reset transient state when the queue is cleared.
- Separated queue operations and persistence from the main player model while preserving saved queues, positions, and settings.
- Added regression tests for playback completion, repeat modes, persistence, torrent cancellation, pipe draining, and timeouts.
- Fixed release tags to target the exact source commit and applied signing options consistently to the app and helpers.
- Improved packaging speed and removed the signing fallback that deleted resource directories.
- Refreshed the website with clearer typography, a prominent product showcase, responsive layouts, and a download picker that works without JavaScript.

Both downloads require macOS 26 or newer on Apple Silicon. The Standard build bundles playback dependencies; the + Torrents build also includes Node and WebTorrent. Public builds remain ad-hoc signed unless a Developer ID identity is configured.
