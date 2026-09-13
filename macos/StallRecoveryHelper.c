// An opt-in recovery helper. It can only recover the app that launched it.
#include <libproc.h>
#include <sys/proc.h>
#include <sys/stat.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>

typedef struct { pid_t pid; struct proc_bsdinfo info; } Identity;
static Identity stopped[4096];
static size_t count;
static int identify(pid_t pid, Identity *identity) {
    identity->pid = pid;
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &identity->info, sizeof(identity->info)) == sizeof(identity->info);
}
static int same(Identity identity) {
    Identity current;
    return identify(identity.pid, &current) && current.info.pbi_status != SZOMB &&
        current.info.pbi_start_tvsec == identity.info.pbi_start_tvsec &&
        current.info.pbi_start_tvusec == identity.info.pbi_start_tvusec;
}
static int signal_owned(Identity identity, int signal) {
    return same(identity) && kill(identity.pid, signal) == 0;
}
static int receipt_exists(const char *path) {
    struct stat st;
    return lstat(path, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == getuid() && st.st_size > 0;
}
static void thaw(void) {
    for (size_t i = count; i > 0; --i) signal_owned(stopped[i - 1], SIGCONT);
}
static int freeze(Identity process) {
    if (count >= 4096 || !signal_owned(process, SIGSTOP)) return 0;
    stopped[count++] = process;
    for (int n = 0; n < 200; ++n) {
        Identity current;
        if (!same(process) || !identify(process.pid, &current)) return 0;
        if (current.info.pbi_status == SSTOP) return 1;
        usleep(5000);
    }
    return 0;
}
static int freeze_tree(Identity parent) {
    if (!freeze(parent)) return 0;
    for (size_t next = 0; next < count; ++next) {
        pid_t children[4096];
        int bytes = proc_listpids(PROC_PPID_ONLY, stopped[next].pid, children, sizeof(children));
        if (bytes < 0 || bytes >= (int)sizeof(children)) return 0;
        for (int i = 0; i < bytes / (int)sizeof(pid_t); ++i) {
            if (children[i] == getpid()) continue;
            Identity child;
            if (!identify(children[i], &child) || child.info.pbi_ppid != (uint32_t)stopped[next].pid ||
                child.info.pbi_uid != getuid() || child.info.pbi_status == SZOMB) continue;
            if (!freeze(child) && same(child)) return 0;
        }
    }
    return 1;
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    char app[PATH_MAX], parent_path[PROC_PIDPATHINFO_MAXSIZE], own_path[PROC_PIDPATHINFO_MAXSIZE];
    char expected_parent[PATH_MAX], expected_helper[PATH_MAX];
    if (!realpath(argv[1], app)) return 3;
    snprintf(expected_parent, sizeof(expected_parent), "%s/Contents/MacOS/PixelBridge", app);
    snprintf(expected_helper, sizeof(expected_helper), "%s/Contents/MacOS/PixelBridgeRecovery", app);
    pid_t parent = getppid();
    Identity identity;
    if (parent <= 1 || !identify(parent, &identity) || identity.info.pbi_uid != getuid() ||
        proc_pidpath(parent, parent_path, sizeof(parent_path)) <= 0 || strcmp(parent_path, expected_parent) ||
        proc_pidpath(getpid(), own_path, sizeof(own_path)) <= 0 || strcmp(own_path, expected_helper)) return 4;
    // Completion removes this unique attempt receipt. Recheck before freezing.
    usleep(500000);
    if (!receipt_exists(argv[2]) || !same(identity)) return 0;
    if (!freeze_tree(identity)) { thaw(); return 5; }
    if (!receipt_exists(argv[2])) { thaw(); return 0; }
    // Wait for every owned writer before ending the parent. A kernel-blocked
    // worker must never overlap a new attempt after relaunch.
    for (size_t i = count; i > 1; --i) signal_owned(stopped[i - 1], SIGKILL);
    int remaining = 0;
    for (int n = 0; n < 100; ++n) {
        remaining = 0;
        for (size_t i = 1; i < count; ++i) if (same(stopped[i])) remaining = 1;
        if (!remaining) break;
        usleep(50000);
    }
    if (remaining) { thaw(); return 6; }
    signal_owned(identity, SIGKILL);
    for (int n = 0; n < 100 && same(identity); ++n) usleep(50000);
    if (same(identity)) { thaw(); return 6; }
    // The old process must be gone before Launch Services starts its replacement.
    execl("/usr/bin/open", "open", "-n", "-a", app, (char *)NULL);
    return 7;
}
