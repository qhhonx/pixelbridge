"""Reject a release that would reuse or decrease a published Sparkle build."""
import json, pathlib, plistlib, sys, urllib.request, xml.etree.ElementTree as ET
root=pathlib.Path(__file__).resolve().parents[1]
build=int(plistlib.loads((root/'macos/Info.plist').read_bytes())['CFBundleVersion'])
releases=json.load(open(sys.argv[1]))
for release in releases:
    if release['draft']: continue
    for asset in release['assets']:
        if asset['name'] != 'appcast.xml': continue
        with urllib.request.urlopen(asset['browser_download_url'],timeout=30) as response:
            feed=ET.fromstring(response.read())
        for version in feed.findall('.//{http://www.andymatuschak.org/xml-namespaces/sparkle}version'):
            assert version.text and version.text.isdigit(), 'Unexpected published build format'
            assert build > int(version.text), f'Increase CFBundleVersion above published build {version.text}'
print('Sparkle build number is greater than all published builds.')
