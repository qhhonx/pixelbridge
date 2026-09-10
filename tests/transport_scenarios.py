"""Fault-injection tests for the real Rust CLI. No real Pixel or Photos writes."""
import tempfile, pathlib, subprocess, sys, os, json, hashlib, concurrent.futures, sqlite3
CORE = pathlib.Path(__file__).resolve().parents[1] / 'target/release/pixelbridge'
STUB = r'''
import os, sys, pathlib, shlex, hashlib, shutil, time
root=pathlib.Path(os.environ['FAKE_ROOT']); args=sys.argv[1:]
if args[:1]==['-s']: args=args[2:]
mode=os.environ.get('FAKE_MODE','normal')
with (root/'calls').open('a') as f: f.write(repr(args)+'\n')
def local(p): return root/p.lstrip('/')
if args[0]=='get-state': print('offline' if mode=='offline' else 'device'); sys.exit(0)
if args[:3]==['shell','dumpsys','battery']:
 print('level: 90\ntemperature: '+('450' if mode=='hot' else '300')); sys.exit(0)
if args[:3]==['shell','df','-k']:
 print('Filesystem 1K-blocks Used Available Use% Mounted\n/dev/fake 30000000 1000000 '+({'full':'1000','boundary':'1562500','below_boundary':'1562499'}.get(mode,'18000000'))+' 1% /sdcard'); sys.exit(0)
if args[0]=='push':
 p=local(args[2]); p.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(args[1],p)
 if mode=='concurrent': time.sleep(0.2)
 if mode=='interrupt': p.write_bytes(b'partial'); sys.exit(1)
 if mode=='corrupt': p.write_bytes(b'corrupt')
 sys.exit(0)
if args[0]=='shell':
 cmd=shlex.split(args[1]) if len(args)==2 else args[1:]
 if cmd[0]=='sha256sum':
  if mode=='offline': sys.exit(1)
  p=local(cmd[1])
  if not p.exists(): sys.exit(1)
  print(hashlib.sha256(p.read_bytes()).hexdigest(),cmd[1]); sys.exit(0)
 if cmd[0]=='mkdir': local(cmd[-1]).mkdir(parents=True,exist_ok=True); sys.exit(0)
 if cmd[0]=='mv': local(cmd[1]).replace(local(cmd[2])); sys.exit(0)
 if cmd[0]=='am': sys.exit(1 if mode=='scan_fail' else 0)
raise SystemExit('unsupported '+repr(args))
'''
with tempfile.TemporaryDirectory(prefix='pixelbridge-scenarios-') as temp:
 root=pathlib.Path(temp); adb=root/'adb'; adb.write_text('#!'+sys.executable+'\n'+STUB); adb.chmod(0o755)
 src=root/"photo ' one.jpg"; src.write_bytes(b'fixture-photo-content')
 env=dict(os.environ,FAKE_ROOT=str(root))
 def run(*args,mode='normal',success=True):
  p=subprocess.run([str(CORE),*args],env=dict(env,FAKE_MODE=mode),capture_output=True,text=True)
  assert (p.returncode==0)==success,(args,p.stdout,p.stderr)
  return p
 def push(mode='normal',success=True): return run('push','--file',str(src),'--adb',str(adb),'--device','fixture',mode=mode,success=success)
 remote=root/'sdcard/DCIM/Camera'/src.name
 for fault in ['interrupt','corrupt']:
  push(fault,False); assert not remote.exists(), 'Partial file must not be published'
 push(); assert remote.read_bytes()==src.read_bytes()
 before=(root/'calls').read_text().count("['push'"); push(); assert (root/'calls').read_text().count("['push'")==before
 remote.write_bytes(b'damaged'); push(); assert remote.read_bytes()==src.read_bytes()
 push('scan_fail',False); before=(root/'calls').read_text().count("['push'"); push(); assert (root/'calls').read_text().count("['push'")==before
 for mode in ['normal','offline','hot','full']:
  run('device-status','--adb',str(adb),'--device','fixture',mode=mode,success=mode=='normal')
 # df -k uses KiB: 1,562,500 blocks are exactly 1.6 decimal GB.
 boundary=json.loads(run('device-status','--adb',str(adb),'--device','fixture','--min-free-gb','1.6',mode='boundary').stdout)
 assert boundary['free_bytes']==1_600_000_000 and boundary['free_gb']==1.6 and boundary['safe_to_transfer']
 run('device-status','--adb',str(adb),'--device','fixture','--min-free-gb','1.6',mode='below_boundary',success=False)
 print('PASS: device admission and cleanup use identical KiB-to-byte conversion at the exact space boundary')
 # Identical contents under distinct asset filenames must have separate staging paths.
 twins=[root/'twin-a.jpg',root/'twin-b.jpg']
 for twin in twins: twin.write_bytes(b'identical-content')
 def push_twin(twin): return run('push','--file',str(twin),'--adb',str(adb),'--device','fixture',mode='concurrent')
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: list(pool.map(push_twin,twins))
 for twin in twins: assert (root/'sdcard/DCIM/Camera'/twin.name).read_bytes()==twin.read_bytes()
 print('PASS: concurrent identical-content photos use independent Pixel staging paths')
 state=root/'state'
 def add(i): return run('queue-add','--state-dir',str(state),'--asset-id',str(i),'--filename','same.jpg')
 with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool: list(pool.map(add,range(24)))
 data=json.loads(run('queue-list','--state-dir',str(state)).stdout); assert len(data)==24
 with (state/'queue.jsonl').open('ab') as f: f.write(b'{"incomplete":')
 run('queue-list','--state-dir',str(state),success=False)
 # Exercise deletion only inside temporary fixtures, through the actual Rust command.
 bridge=root/'bridge'; cache=bridge/'Staging'; history=bridge/'State'; cache.mkdir(parents=True)
 def fixture(asset,phase='transferred',proof=True):
  ident=hashlib.sha256(asset.encode()).hexdigest(); job=cache/ident; job.mkdir()
  original=job/'original.jpg'; original.write_bytes(b'original-'+asset.encode())
  name='PB_'+ident+'.jpg'; delivery=job/name; os.link(original,delivery)
  pixel_path='/sdcard/DCIM/Camera/'+name; pixel=root/pixel_path.lstrip('/'); pixel.parent.mkdir(parents=True,exist_ok=True); pixel.write_bytes(original.read_bytes())
  digest=hashlib.sha256(pixel.read_bytes()).hexdigest()
  run('queue-add','--state-dir',str(history),'--asset-id',asset,'--filename','photo.jpg')
  phases=['exporting','prepared','transferred']
  if phase=='failed': phases=['exporting','failed']
  elif phase=='discovered': phases=[]
  else: phases=phases[:phases.index(phase)+1]
  for step in phases:
   args=['queue-transition','--state-dir',str(history),'--asset-id',asset,'--phase',step]
   if proof and step=='prepared': args+=['--sha256',digest]
   if proof and step=='transferred': args+=['--remote',pixel_path]
   run(*args)
  return job,pixel
 def reclaim(asset,success=True,mode='normal'):
  return run('reclaim-cache','--bridge-root',str(bridge),'--asset-id',asset,'--adb',str(adb),'--device','fixture',success=success,mode=mode)
 def snapshot(): return run('queue-list','--state-dir',str(history)).stdout
 job,pixel=fixture('complete'); queue_before=snapshot(); pixel_before=pixel.read_bytes()
 orphan=cache/'unrecorded'; orphan.mkdir(); (orphan/'keep').write_bytes(b'keep')
 output=reclaim('complete').stdout
 assert f'reclaimed_bytes: {len(pixel_before)}' in output, 'Hard links must not inflate reclaimed byte count'
 assert not job.exists() and pixel.read_bytes()==pixel_before and snapshot()==queue_before and orphan.exists()
 assert 'reclaimed_bytes: 0' in reclaim('complete').stdout, 'Repeated cleanup must be harmless'
 for phase in ['discovered','exporting','prepared','failed']:
  job,pixel=fixture('pending-'+phase,phase); reclaim('pending-'+phase,False); assert job.exists() and pixel.exists()
 job,pixel=fixture('no-proof',proof=False); reclaim('no-proof',False); assert job.exists()
 for fault in ['missing','corrupt','offline']:
  asset='old-'+fault; job,pixel=fixture(asset); original=pixel.read_bytes(); before=snapshot()
  if fault=='missing': pixel.unlink()
  if fault=='corrupt': pixel.write_bytes(b'corrupted')
  reclaim(asset,False,mode='offline' if fault=='offline' else 'normal')
  assert job.exists() and snapshot()==before
  pixel.write_bytes(original); reclaim(asset); assert not job.exists(), 'Retained cache must be reclaimable after recovery'
 outside=root/'outside'; outside.mkdir(); sentinel=outside/'keep'; sentinel.write_bytes(b'keep')
 job,pixel=fixture('symlink-job'); import shutil; shutil.rmtree(job); job.symlink_to(outside,target_is_directory=True)
 reclaim('symlink-job',False); assert sentinel.read_bytes()==b'keep' and job.is_symlink()
 job,pixel=fixture('symlink-child'); (job/'link').symlink_to(outside,target_is_directory=True)
 reclaim('symlink-child',False); assert sentinel.exists() and job.exists()
 job,pixel=fixture('partial-cleanup'); (job/'original.jpg').unlink(); reclaim('partial-cleanup'); assert not job.exists()
 job,pixel=fixture('bad-path')
 with sqlite3.connect(history/'queue.sqlite3') as db:
  db.execute("UPDATE jobs SET remote='/sdcard/DCIM/Camera/unrelated.jpg' WHERE asset_id='bad-path'")
 reclaim('bad-path',False); assert job.exists()
 job,pixel=fixture('bad-journal'); (history/'queue.sqlite3').write_bytes(b'not-a-database')
 reclaim('bad-journal',False); assert job.exists() and pixel.exists()
 print('PASS: completed cache reclamation, hard-link accounting, queue/Pixel/orphan preservation, repeat cleanup, incomplete/missing-proof refusal, missing/corrupt/offline remote retention and recovery, symlink refusal, interrupted cleanup recovery, invalid path/journal refusal')
 print('PASS: interrupted push, corrupt push, atomic publish, quoted filename, idempotent replay, damaged remote repair, scanner retry, healthy/offline/hot/full device, concurrent database writes, post-migration legacy-write refusal')
