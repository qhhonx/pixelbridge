"""Read-only local date audit. Never modifies media, queue rows or cloud items."""
import argparse
import csv
import datetime as dt
import hashlib
import json
import pathlib
import re
import shlex
import sqlite3
import subprocess
from collections import Counter


def classify(source_ms, taken_ms, modified_s, kind):
    if source_ms is None:
        return 'source_date_unknown'
    if taken_ms and taken_ms > 0:
        if abs(taken_ms - source_ms) < 1000:
            return 'indexed_capture_matches'
        return 'video_embedded_date_review' if kind == 'video' else 'capture_date_conflict_review'
    if modified_s is not None and modified_s == source_ms // 1000:
        return 'filesystem_fallback_matches'
    return 'missing_capture_date_wrong_fallback'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', type=pathlib.Path, required=True)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--known-dates', type=pathlib.Path, help='Optional reviewed assetRef/date mappings; never guessed from filenames.')
    args = parser.parse_args()
    inventory_path = args.state_dir / 'capture-date-inventory.json'
    inventory = json.loads(inventory_path.read_text()) if inventory_path.exists() else {'assets': []}
    if inventory.get('schema', 1) != 1:
        raise ValueError('Unsupported inventory schema')
    assets = {x['assetRef']: x for x in inventory['assets']}
    reviewed = json.loads(args.known_dates.read_text()) if args.known_dates else {}
    connection = sqlite3.connect((args.state_dir / 'queue.sqlite3').resolve().as_uri() + '?mode=ro', uri=True)
    connection.row_factory = sqlite3.Row
    with connection:
        queue = [dict(x) for x in connection.execute('SELECT asset_id, filename, phase, timestamp_ms, sha256, remote FROM jobs')]
    connection.close()
    indexed = {}
    raw = {}
    for kind in ('images', 'video'):
        query = 'content query --uri content://media/external/' + kind + '/media --projection _id:_data:datetaken:date_modified:date_added --where ' + shlex.quote("_display_name LIKE 'PB_%'")
        output = subprocess.check_output([args.adb, '-s', args.device, 'shell', query], text=True, timeout=120)
        if 'Error' in output or 'Exception' in output:
            raise RuntimeError(output)
        raw[kind] = output
        for line in output.splitlines():
            if not line.startswith('Row: '):
                continue
            values = dict(part.split('=', 1) for part in re.sub(r'^Row: \d+ ', '', line).split(', ') if '=' in part)
            name = pathlib.PurePosixPath(values.get('_data', '')).name
            if re.fullmatch(r'PB_[a-f0-9]{64}(?:_MP)?\.[A-Za-z0-9]+', name):
                indexed.setdefault(name, []).append(values)
    rows = []
    def number(value):
        return int(value) if value and value != 'NULL' else None
    def iso(ms):
        return dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc).isoformat(timespec='milliseconds') if ms is not None else ''
    for job in queue:
        if job['phase'] not in ('transferred', 'backup_seen', 'motion_verified'):
            continue
        ref = hashlib.sha256(job['asset_id'].encode()).hexdigest()
        info = assets.get(ref, {})
        manual = reviewed.get(ref, {})
        source_ms = info.get('captureTimeMilliseconds', manual.get('captureTimeMilliseconds'))
        remote = job['remote'] or ''
        name = pathlib.PurePosixPath(remote).name
        matches = indexed.get(name, [])
        item = matches[0] if len(matches) == 1 else {}
        taken, modified = number(item.get('datetaken')), number(item.get('date_modified'))
        kind = info.get('kind', 'video' if name.lower().endswith(('.mov', '.mp4', '.m4v')) else 'motion' if '_MP.' in name else 'photo')
        status = 'pixel_file_not_indexed' if not matches else 'ambiguous_pixel_rows' if len(matches) > 1 else classify(source_ms, taken, modified, kind)
        rows.append(dict(asset_ref=ref, original_filename=job['filename'], delivery_filename=name, kind=kind,
            source_capture_ms=source_ms, source_capture_utc=iso(source_ms), source_evidence='PhotoKit.creationDate' if info.get('captureTimeMilliseconds') is not None else manual.get('evidence', 'unavailable'),
            reviewed_display_date=manual.get('displayDate', ''), pixel_date_taken_ms=taken, pixel_indexed_modified_s=modified,
            status=status, delivered_sha256=job['sha256'], remote=remote,
            cloud_status=manual.get('cloudStatus', 'not_checked'), cloud_display_date=manual.get('cloudDisplayDate', '')))
    rows.sort(key=lambda row: (row['status'], row['delivery_filename']))
    args.output.mkdir(parents=True, exist_ok=True)
    columns = 'asset_ref original_filename delivery_filename kind source_capture_ms source_capture_utc source_evidence reviewed_display_date pixel_date_taken_ms pixel_indexed_modified_s status delivered_sha256 remote cloud_status cloud_display_date'.split()
    candidates = [r for r in rows if r['cloud_status'] == 'user_confirmed_wrong_date' or
                  (r['status'] != 'pixel_file_not_indexed' and
                   (not r['pixel_date_taken_ms'] or r['pixel_date_taken_ms'] <= 0 or 'conflict' in r['status'] or 'review' in r['status']))]
    for name, selected in [('capture-date-audit.csv', rows), ('capture-date-candidates.csv', candidates)]:
        with (args.output / name).open('w', newline='') as file:
            writer = csv.DictWriter(file, fieldnames=columns); writer.writeheader(); writer.writerows(selected)
    summary = dict(generated_at=dt.datetime.now(dt.timezone.utc).isoformat(), inventory_generated_at=inventory.get('generatedAt'),
        delivered_rows=len(rows), candidate_rows=len(candidates), statuses=dict(Counter(x['status'] for x in rows)),
        notes=['Read-only audit; Google Photos cloud dates were not queried automatically.',
               'date_modified is the scanner index, not a fresh filesystem stat.',
               'Conflicts can contain valid embedded dates; review before any repair.',
               'Unknown source dates and ambiguous matches must not be repaired automatically.'])
    (args.output / 'capture-date-audit-summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    (args.output / 'pixel-index-snapshot.json').write_text(json.dumps(raw))
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
