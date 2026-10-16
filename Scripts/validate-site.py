#!/usr/bin/env python3
"""Validate the static site without browser or network dependencies."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit
import json

ROOT = Path(__file__).resolve().parent.parent / 'site'
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}

class SiteParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.ids = set()
        self.links = []
        self.assets = []
        self.headings = 0
        self.structured_data = ''
        self.in_json = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag not in VOID:
            self.stack.append(tag)
        if 'id' in attrs:
            assert attrs['id'] not in self.ids, f"Duplicate id: {attrs['id']}"
            self.ids.add(attrs['id'])
        if tag == 'h1': self.headings += 1
        if tag == 'a': self.links.append(attrs.get('href', ''))
        if tag in {'img', 'script'} and attrs.get('src'): self.assets.append(attrs['src'])
        if tag == 'link' and attrs.get('rel') in {'stylesheet', 'icon'}: self.assets.append(attrs['href'])
        if tag == 'img': assert 'alt' in attrs, 'Image is missing alt text'
        if tag == 'script' and attrs.get('type') == 'application/ld+json': self.in_json = True

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID: self.handle_endtag(tag)

    def handle_endtag(self, tag):
        assert self.stack and self.stack[-1] == tag, f"Unexpected </{tag}> after {self.stack[-3:]}"
        self.stack.pop()
        if tag == 'script': self.in_json = False

    def handle_data(self, data):
        if self.in_json: self.structured_data += data

parser = SiteParser()
parser.feed((ROOT / 'index.html').read_text())
assert not parser.stack, f'Unclosed elements: {parser.stack}'
assert parser.headings == 1, 'Expected one main heading'
json.loads(parser.structured_data)
for link in parser.links:
    assert link, 'Empty link'
    if link.startswith('#'): assert link[1:] in parser.ids, f'Missing anchor {link}'
for asset in parser.assets:
    parsed = urlsplit(asset)
    if not parsed.scheme: assert (ROOT / parsed.path).is_file(), f'Missing asset {asset}'
assert sum('/releases/download/' in link for link in parser.links) == 4
# Update feeds (written by release.sh) must offer the same signed dmgs the
# download buttons link to, so updating and downloading agree.
import xml.etree.ElementTree as ET
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
feeds = 0
for name, suffix in (('appcast.xml', '.dmg'), ('appcast-torrents.xml', '-torrents.dmg')):
    path = ROOT / name
    if not path.exists():
        continue
    enclosure = ET.parse(path).getroot().find('channel/item/enclosure')
    assert enclosure is not None, f'{name} has no enclosure'
    url = enclosure.get('url', '')
    assert url.endswith(suffix) and (suffix != '.dmg' or not url.endswith('-torrents.dmg')), f'{name} offers {url}'
    assert url in parser.links, f'{name} offers {url}, which no download button links to'
    assert enclosure.get(SPARKLE + 'edSignature'), f'{name} enclosure is unsigned'
    feeds += 1
print(f'Site valid: {len(parser.ids)} unique anchors, {len(parser.assets)} assets, four download links, {feeds} update feeds.')
