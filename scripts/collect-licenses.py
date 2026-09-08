"""Bundle upstream license texts for all resolved Rust crates and Sparkle."""
import json, pathlib, shutil, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[1]
destination = pathlib.Path(sys.argv[1]); destination.mkdir(parents=True, exist_ok=True)
metadata = json.loads(subprocess.check_output(['cargo', 'metadata', '--locked', '--format-version', '1', '--filter-platform', 'aarch64-apple-darwin'], cwd=root))
index = []
resolved = {node['id'] for node in metadata['resolve']['nodes']}
for package in metadata['packages']:
    if not package['source'] or package['id'] not in resolved: continue
    source = pathlib.Path(package['manifest_path']).parent
    target = destination / f"{package['name']}-{package['version']}"
    texts = [p for p in source.iterdir() if p.is_file() and p.name.lower().startswith(('license','copying','notice','copyright'))]
    if package.get('license_file'):
        declared = source / package['license_file']
        if declared.is_file() and declared not in texts: texts.append(declared)
    if not texts: raise RuntimeError(f"Missing license text for {package['name']}")
    target.mkdir(exist_ok=True)
    for path in texts: shutil.copyfile(path, target / path.name)
    index.append(f"{package['name']} {package['version']}: {package['license']} ({package.get('repository') or 'https://crates.io'})")
for path in (root / '.build-cache/sparkle').glob('LICENSE*'):
    shutil.copyfile(path, destination / ('Sparkle-' + path.name))
(destination / 'INDEX.txt').write_text('\n'.join(index) + '\n')
print('Bundled licenses for', len(index), 'Rust dependencies and Sparkle.')
