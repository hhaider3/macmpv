# Bundled mpv backport

`mpv-coreaudio-init-cleanup.patch` is the unmodified combined diff from
[mpv PR #18383](https://github.com/mpv-player/mpv/pull/18383), by Dudemanguy,
applied to the official mpv 0.41.0 source archive. It fixes
[mpv #18274](https://github.com/mpv-player/mpv/issues/18274): a failed CoreAudio
initialization left hotplug listeners referring to a freed audio output, which
could crash the process when Bluetooth headphones connected or disconnected.

The patch registers listeners after AudioUnit initialization succeeds and cleans
up partially initialized audio outputs. Upstream commits from the PR are
`e8414d910311ea5663d5a230e85d48a415e6119a` and
`3371b9007754c3aefe719c97ab08325f23e14e88`.
The patched source retains mpv's original license terms.

`Scripts/build-libmpv.sh` verifies the official archive's SHA-256 and builds the
patched library in `.build/patched-mpv/build`. The app's existing Homebrew runtime
dependencies are reused; the standalone mpv CLI and optional VapourSynth filter
bridge are omitted. Packaging uses this library instead of the unpatched
Homebrew library. Homebrew itself is not modified.

Remove the backport when the bundled stable mpv release includes both fixes.
