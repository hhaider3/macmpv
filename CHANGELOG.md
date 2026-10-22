# Changelog

## 1.9 — 2026-10-21

- Torrents stop sharing once every queued video is downloaded. Playback continues from the saved files, and macmpv leaves the swarm instead of uploading until you close the torrent.
- The queue shows how much of each torrent video is downloaded, or **LOCAL** once it is saved, and Now Playing says whether it is streaming or playing from local storage. Downloads from earlier versions are estimated from the files on disk.
- Downloaded torrent videos play straight from disk, so switching to another torrent collection is as quick as opening a local file instead of waiting for the whole torrent to be re-checked. Torrents downloaded before 1.9 are checked once, the first time you open them.

Both downloads require macOS 26 or newer on Apple Silicon. The Standard build bundles playback dependencies; the + Torrents build also includes Node and WebTorrent. Public builds remain ad-hoc signed unless a Developer ID identity is configured.

## 1.8 — 2026-10-15

- Automatic updates: macmpv checks for a new release at launch and daily, downloads it from GitHub Releases in the background, and installs it when you quit. Every update is verified with an EdDSA signature before it is installed. **Check for Updates…** and **Install Updates Automatically** are in the macmpv menu, and Standard and + Torrents builds each update to their own variant.
- Earlier versions have no updater, so install 1.8 manually once; later versions arrive automatically.

Both downloads require macOS 26 or newer on Apple Silicon. The Standard build bundles playback dependencies; the + Torrents build also includes Node and WebTorrent. Public builds remain ad-hoc signed unless a Developer ID identity is configured.

## 1.7.1 — 2026-10-15

- Fixed **Save Screenshot** (⇧⌘S), which failed in 1.6 and 1.7 because VideoToolbox frames stay on the GPU where mpv's screenshot code cannot read them. macmpv now switches to copy-back decoding for a moment to capture the frame, then goes back to full hardware decoding.

Both downloads require macOS 26 or newer on Apple Silicon. The Standard build bundles playback dependencies; the + Torrents build also includes Node and WebTorrent. Public builds remain ad-hoc signed unless a Developer ID identity is configured.

## 1.7 — 2026-10-15

- Right-click a queue item or collection to move its files to the Trash, including downloaded torrent episodes; removing a whole torrent also trashes its cached metadata and local source. Remote streams and missing files simply leave the queue, and anything that cannot be trashed stays queued with an error. **Clear Queue** still never touches files.
- Show in Finder is available on queue items and from the player title.
- Torrent episodes you remove from the queue are no longer downloaded in the background.
- Website: a version and release-notes link under the download button, a macOS 27 FAQ entry, a note about moving finished items to the Trash, and much lighter pages (the icon shrank from 1.3 MB to 6 KB, and screenshots are served as WebP at about a seventh of their former size).

Both downloads require macOS 26 or newer on Apple Silicon. The Standard build bundles playback dependencies; the + Torrents build also includes Node and WebTorrent. Public builds remain ad-hoc signed unless a Developer ID identity is configured.

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
