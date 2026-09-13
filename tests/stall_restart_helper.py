"""Exercise the shipped helper with a disposable background app, never user data."""
import pathlib, plistlib, subprocess, tempfile, time, os, signal
root = pathlib.Path(__file__).resolve().parents[1]
def until(check, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check(): return
        time.sleep(.05)
    raise AssertionError('Timed out waiting for fixture')
def stopped(pid):
    result = subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True)
    return not result.stdout.strip() or 'Z' in result.stdout
with tempfile.TemporaryDirectory(prefix='pixelbridge-restart-test-') as temp:
    folder = pathlib.Path(temp).resolve()
    app = folder / 'Recovery Fixture.app'
    macos = app / 'Contents/MacOS'; macos.mkdir(parents=True)
    info = {'CFBundleIdentifier':'org.pixelbridge.recovery-fixture.' + str(os.getpid()),
            'CFBundleExecutable':'PixelBridge', 'CFBundleName':'Recovery Fixture',
            'CFBundlePackageType':'APPL', 'CFBundleVersion':'1', 'LSBackgroundOnly':True}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    source = folder/'fixture.c'
    source.write_text(r'''
#include <libproc.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    char own[4096], app[4096], helper[4096], ready[4096];
    proc_pidpath(getpid(), own, sizeof(own));
    strcpy(app, own); *strstr(app, "/Contents/MacOS/") = 0;
    snprintf(ready, sizeof(ready), "%s/restarted", app);
    if (argc == 1) { FILE *f=fopen(ready,"w"); if(f){ fputs("restarted",f); fclose(f); } return 0; }
    pid_t worker = fork();
    if (!worker) { execl("/bin/sleep", "sleep", "60", (char*)0); return 2; }
    snprintf(ready, sizeof(ready), "%s/worker", app);
    FILE *f=fopen(ready,"w"); fprintf(f,"%d",worker); fclose(f);
    snprintf(helper,sizeof(helper),"%s/Contents/MacOS/PixelBridgeRecovery",app);
    if (!fork()) { execl(helper,helper,app,argv[1],(char*)0); return 3; }
    sleep(30); return 0;
}
''')
    subprocess.run(['xcrun','clang','-O2',str(source),'-o',str(macos/'PixelBridge')],check=True)
    subprocess.run(['xcrun','clang','-O2','-Wall','-Wextra','-Werror',str(root/'macos/StallRecoveryHelper.c'),'-o',str(macos/'PixelBridgeRecovery')],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(macos/'PixelBridgeRecovery')],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
    receipt = folder/'attempt.json'; receipt.write_text('{"attempt":"fixture"}')
    # An unrelated caller may not use the helper to terminate any application.
    assert subprocess.run([str(macos/'PixelBridgeRecovery'),str(app),str(receipt)]).returncode == 4
    print('PASS: helper rejects callers outside its owning app', flush=True)
    outside = subprocess.Popen(['/bin/sleep','60'])
    processes=[]; workers=[]
    try:
        receipt.unlink()
        parent = subprocess.Popen([str(macos/'PixelBridge'),str(receipt)]); processes.append(parent)
        until(lambda:(app/'worker').exists()); worker=int((app/'worker').read_text()); workers.append(worker)
        time.sleep(1)
        assert parent.poll() is None and not stopped(worker) and not (app/'restarted').exists()
        print('PASS: completed/removed recovery receipt leaves the app and worker running', flush=True)
        parent.terminate(); parent.wait(); os.kill(worker,signal.SIGTERM)
        (app/'worker').unlink(); receipt.write_text('{"attempt":"fixture"}')
        parent = subprocess.Popen([str(macos/'PixelBridge'),str(receipt)]); processes.append(parent)
        until(lambda:(app/'worker').exists()); worker=int((app/'worker').read_text()); workers.append(worker)
        until(lambda:parent.poll() is not None)
        until(lambda:stopped(worker))
        until(lambda:(app/'restarted').exists())
        assert receipt.exists() and outside.poll() is None
        print('PASS: helper ends only its app and worker, preserves recovery receipt, then relaunches through Launch Services', flush=True)
    finally:
        for process in processes:
            if process.poll() is None: process.terminate(); process.wait()
        for worker in workers:
            if not stopped(worker):
                try: os.kill(worker,signal.SIGTERM)
                except ProcessLookupError: pass
        outside.terminate(); outside.wait()
