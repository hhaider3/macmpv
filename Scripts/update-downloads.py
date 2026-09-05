#!/usr/bin/env python3
"""Update the website from the exact release artifact sizes and checksum."""
import os, re, sys

path, version, std_sha, std_dmg, tor_dmg = sys.argv[1:6]
std_mb = round(os.path.getsize(std_dmg) / 1e6)
tor_mb = round(os.path.getsize(tor_dmg) / 1e6)

html = open(path).read()
html, n_std_url = re.subn(
    r'/releases/download/v[\w.]+/macmpv-[\d.]+-arm64\.dmg',
    f'/releases/download/v{version}/macmpv-{version}-arm64.dmg', html)
html, n_tor_url = re.subn(
    r'/releases/download/v[\w.]+/macmpv-[\d.]+-arm64-torrents\.dmg',
    f'/releases/download/v{version}t/macmpv-{version}-arm64-torrents.dmg', html)
html, n_sha = re.subn(
    r'(SHA-256 \(standard\)</span>\s*<code>)[0-9a-f]{64}',
    r'\g<1>' + std_sha, html)
html = re.sub(r'\b\d+ MB · add torrents later',
              f'{std_mb} MB · add torrents later', html)
html = re.sub(r'\b\d+ MB · WebTorrent bundled',
              f'{tor_mb} MB · WebTorrent bundled', html)
html = re.sub(r'(<span class="button-sub">)\d+ MB(</span>)',
              rf'\g<1>{std_mb} MB\g<2>', html)

for label, count in (('standard url', n_std_url),
                     ('torrents url', n_tor_url),
                     ('checksum', n_sha)):
    if count == 0:
        sys.exit(f'error: no {label} matches in site/index.html — layout changed?')
open(path, 'w').write(html)
