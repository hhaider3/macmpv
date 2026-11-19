#!/usr/bin/env python3
"""Update the website from the exact release artifact size and checksum."""
import os, re, sys

path, version, sha, dmg = sys.argv[1:5]
size_mb = round(os.path.getsize(dmg) / 1e6)

html = open(path).read()
html, n_url = re.subn(
    r'/releases/download/v[\w.]+/macmpv-[\d.]+-arm64(?:-torrents)?\.dmg',
    f'/releases/download/v{version}/macmpv-{version}-arm64.dmg', html)
html, n_sha = re.subn(
    r'(SHA-256</span>\s*<code>)[0-9a-f]{64}',
    r'\g<1>' + sha, html)
html, n_version = re.subn(
    r'(<span data-version>)[\d.]+(</span>)',
    rf'\g<1>{version}\g<2>', html)
html, n_size = re.subn(
    r'(<span data-dmg-size>)\d+ MB(</span>)',
    rf'\g<1>{size_mb} MB\g<2>', html)

for label, count in (('download url', n_url),
                     ('checksum', n_sha),
                     ('version', n_version),
                     ('size', n_size)):
    if count == 0:
        sys.exit(f'error: no {label} matches in site/index.html — layout changed?')
open(path, 'w').write(html)
