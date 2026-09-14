"""Exercise the audit CLI against isolated SQLite and media-index fixtures."""
import csv
import hashlib
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile

script = pathlib.Path(__file__).resolve().parents[1] / 'scripts/audit-capture-dates.py'
with tempfile.TemporaryDirectory() as folder:
    root = pathlib.Path(folder)
    db = root / 'queue.sqlite3'
    ref = hashlib.sha256(b'asset').hexdigest()
    name = 'PB_' + ref + '.jpg'
    with sqlite3.connect(db) as c:
        c.execute('CREATE TABLE jobs(asset_id,filename,phase,timestamp_ms,sha256,remote)')
        c.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?)', ('asset', 'same.jpg', 'transferred', 999, 'proof', '/sdcard/DCIM/Camera/' + name))
    inventory = {'schema': 1, 'assets': [{'assetRef': ref, 'kind': 'photo', 'captureTimeMilliseconds': 1234567}]}
    (root / 'capture-date-inventory.json').write_text(json.dumps(inventory))
    adb = root / 'adb'
    adb.write_text('#!' + sys.executable + '\nimport sys\nprint(' + repr('Row: 0 _id=1, _data=/storage/emulated/0/DCIM/Camera/' + name + ', datetaken=NULL, date_modified=999, date_added=999') + ' if "images" in sys.argv[-1] else "No result found.")\n')
    adb.chmod(0o755)
    args = [sys.executable, str(script), '--state-dir', str(root), '--adb', str(adb), '--device', 'fixture', '--output', str(root / 'output')]
    original = db.read_bytes()
    subprocess.run(args, check=True, capture_output=True)
    rows = list(csv.DictReader((root / 'output/capture-date-candidates.csv').open()))
    assert len(rows) == 1 and rows[0]['status'] == 'missing_capture_date_wrong_fallback'
    assert rows[0]['source_capture_ms'] == '1234567' and rows[0]['cloud_status'] == 'not_checked'
    assert db.read_bytes() == original, 'Audit altered the queue'
    (root / 'capture-date-inventory.json').unlink()
    subprocess.run(args, check=True, capture_output=True)
    rows = list(csv.DictReader((root / 'output/capture-date-candidates.csv').open()))
    assert rows[0]['source_capture_ms'] == '' and rows[0]['status'] == 'source_date_unknown'
    with sqlite3.connect(db) as c:
        c.execute('DELETE FROM jobs')
    subprocess.run(args, check=True, capture_output=True)
    assert list(csv.DictReader((root / 'output/capture-date-candidates.csv').open())) == [], 'Stale candidates retained'
    assert list(csv.DictReader((root / 'output/capture-date-audit.csv').open())) == []
print('PASS: audit joins stable identity, reports missing dates without guessing, preserves database bytes, and replaces stale reports')
