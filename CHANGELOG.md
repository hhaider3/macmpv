# Changelog

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
