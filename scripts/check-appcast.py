"""Validate release metadata and independent Ed25519 archive verification."""
import base64, pathlib, plistlib, subprocess, xml.etree.ElementTree as ET
root=pathlib.Path(__file__).resolve().parents[1]
ns={'sparkle':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
feed=root/'dist/release/appcast.xml'
item=ET.parse(feed).find('./channel/item');assert item is not None
info=plistlib.loads((root/'macos/Info.plist').read_bytes())
assert item.findtext('sparkle:version',namespaces=ns) == info['CFBundleVersion']
archive=item.find('enclosure');assert archive is not None
signature=archive.attrib['{'+ns['sparkle']+'}edSignature']
version=(root/'VERSION').read_text().strip()
path=root/f'dist/release/PixelBridge-{version}-arm64.zip'
assert archive.attrib['url'].endswith(f'/v{version}/{path.name}')
assert archive.attrib['url'].startswith('https://github.com/')
assert path.stat().st_size == int(archive.attrib['length'])
assert len(base64.b64decode(signature,validate=True)) == 64
subprocess.run(['xcrun','swift','-module-cache-path',str(root/'.build-cache/test-modules'),str(root/'tests/VerifyUpdate.swift'),str(path),info['SUPublicEDKey'],signature],check=True)
assert 'sparkle-signature' in feed.read_text(), 'Update feed must be signed too'
print('Release feed version, URL, size and signature verified.')
