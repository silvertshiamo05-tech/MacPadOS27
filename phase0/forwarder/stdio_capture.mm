// MacPadOS27: inserted into MainApp/main.mm by phase0/scripts/package_ios.sh.
#include <execinfo.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

static int mp27_log_fd = -1;

static void MP27Signal(int sig)
{
    char msg[64];
    int n = snprintf(msg, sizeof msg, "\n*** MacPadOS27: fatal signal %d ***\n", sig);
    write(mp27_log_fd, msg, n);
    void* frames[64];
    int count = backtrace(frames, 64);
    backtrace_symbols_fd(frames, count, mp27_log_fd);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void MP27Exception(NSException* e)
{
    fprintf(stderr, "\n*** MacPadOS27: uncaught %s: %s\n%s\n", e.name.UTF8String, e.reason.UTF8String,
            [e.callStackSymbols componentsJoinedByString:@"\n"].UTF8String);
}

static void MP27RedirectStdio(void)
{
    NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString* path = [docs stringByAppendingPathComponent:@"unity-player.log"];
    if (!freopen(path.UTF8String, "w", stdout)) return;
    dup2(fileno(stdout), fileno(stderr));
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    mp27_log_fd = fileno(stderr);
    printf("MacPadOS27 log: %s\n", path.UTF8String);
    int sigs[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP };
    for (unsigned i = 0; i < sizeof sigs / sizeof sigs[0]; i++) signal(sigs[i], MP27Signal);
    NSSetUncaughtExceptionHandler(MP27Exception);
}
