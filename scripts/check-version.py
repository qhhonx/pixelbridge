"""Keep one release identity across Cargo, Info.plist and the git tag."""
import os, pathlib, plistlib, re
root = pathlib.Path(__file__).resolve().parents[1]
version = (root / 'VERSION').read_text().strip()
assert re.fullmatch(r'\d+\.\d+\.\d+(?:-beta\.\d+)?', version), version
info = plistlib.loads((root / 'macos/Info.plist').read_bytes())
assert info['CFBundleShortVersionString'] == version.split('-')[0]
assert str(info['CFBundleVersion']).isdigit() and int(info['CFBundleVersion']) > 0
assert f'version = "{version}"' in (root / 'Cargo.toml').read_text()
if os.environ.get('GITHUB_REF_TYPE') == 'tag':
    assert os.environ['GITHUB_REF_NAME'] == 'v' + version
print('Version metadata consistent:', version, 'build', info['CFBundleVersion'])
