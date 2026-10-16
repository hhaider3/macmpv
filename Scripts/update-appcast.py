#!/usr/bin/env python3
"""Write a Sparkle appcast for one build variant.

Usage: update-appcast.py <output.xml> <title> <short-version> <build-number>
                         <download-url> <notes-url> <sign_update output>

The last argument is what Sparkle's sign_update prints for the dmg:
    sparkle:edSignature="..." length="..."
Each feed lists only the newest release; Sparkle needs nothing older.
"""
import re
import sys
from datetime import datetime, timezone
from xml.sax.saxutils import escape, quoteattr

output, title, short_version, build, url, notes, signed = sys.argv[1:8]

match = re.fullmatch(r'\s*sparkle:edSignature="([A-Za-z0-9+/=]+)"\s+length="(\d+)"\s*', signed)
if not match:
    sys.exit(f'error: unexpected sign_update output: {signed!r}')
signature, length = match.groups()
if not re.fullmatch(r'\d+', build):
    sys.exit(f'error: build number must be numeric, got {build!r}')

published = datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
feed = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>{escape(title)}</title>
    <link>https://macmpv.pages.dev/</link>
    <item>
      <title>Version {escape(short_version)}</title>
      <pubDate>{published}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{escape(short_version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{escape(notes)}</sparkle:releaseNotesLink>
      <enclosure url={quoteattr(url)} length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>
'''
with open(output, 'w') as handle:
    handle.write(feed)
