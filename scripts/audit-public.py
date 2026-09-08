"""Check distributable files for accidentally included user data or local paths."""
import argparse, pathlib, re, subprocess
root = pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(); parser.add_argument('--app',type=pathlib.Path);args=parser.parse_args()
forbidden_names = {'.DS_Store', '.env', 'auth.json', 'queue.sqlite3', 'queue.jsonl', 'retry.json', 'activity.log'}
patterns = [rb'/Users/[^/\s]+/', rb'/home/runner/work/', rb'Apple Development:', rb'-----BEGIN [A-Z ]*PRIVATE KEY-----', rb'gh[pousr]_[A-Za-z0-9]{30,}']
if args.app:
    paths=[p for p in args.app.rglob('*') if p.is_file() and not p.is_symlink()]
else:
    paths=[root / p for p in subprocess.check_output(['git','ls-files'],cwd=root,text=True).splitlines()]
errors=[]
for p in paths:
    if p.name in forbidden_names: errors.append(str(p.relative_to(root)))
    if p.name == pathlib.Path(__file__).name: continue
    raw=p.read_bytes()
    # Upstream ExifTool ships documentation examples with generic user paths.
    # Its archive is checksum-pinned; still scan it for credentials, and scan
    # all product-owned code/binaries for local developer paths.
    upstream = 'Resources/exiftool' in str(p)
    checked = patterns[2:] if upstream else patterns
    for pattern in checked:
        if re.search(pattern,raw): errors.append(str(p.relative_to(root))+': private data pattern')
if errors: raise SystemExit('\n'.join(errors))
print('Public-file audit passed:',len(paths),'files')
