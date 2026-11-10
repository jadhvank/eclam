#!/usr/bin/env python3
"""Fail before publishing if the feed points at the wrong release or archive."""
import base64
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def validate(feed, archive, version, build, repo):
    archive = Path(archive)
    items = ET.parse(feed).getroot().findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one release item')
    item = items[0]
    enclosure = item.find('enclosure')
    if enclosure is None:
        raise ValueError('Missing archive enclosure')
    expected_url = f'https://github.com/{repo}/releases/download/v{version}/{archive.name}'
    if enclosure.get('url') != expected_url:
        raise ValueError('Archive URL does not match the release')
    if int(enclosure.get('length', '0')) != archive.stat().st_size:
        raise ValueError('Archive size mismatch')
    if item.findtext(SPARKLE + 'version') != build:
        raise ValueError('Build version mismatch')
    if item.findtext(SPARKLE + 'shortVersionString') != version:
        raise ValueError('Display version mismatch')
    if len(base64.b64decode(enclosure.get(SPARKLE + 'edSignature', ''), validate=True)) != 64:
        raise ValueError('Missing/invalid Ed25519 signature')


if __name__ == '__main__':
    validate(*sys.argv[1:])
    print('OK: appcast version, archive URL, length and signature shape')
