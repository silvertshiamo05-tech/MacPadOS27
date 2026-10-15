// MacPadOS27 loader: runs when UnityFramework is loaded, before the engine
// starts. Finds the game's macOS GameAssembly.dylib, makes it loadable on iOS
// and fills the forwarder table (mp27_table.c) used by the generated stubs.
//
// GameAssembly.dylib is looked for, in order:
//   1. Documents/Game/**/GameAssembly.dylib  (user-copied .app; patched here at
//      runtime, needs JIT/LiveContainer's signature bypass to load)
//   2. <app>/Frameworks/GameAssembly.dylib    (pre-patched in CI; LiveContainer
//      signs it at install, so it loads without JIT)
// The log goes to Documents/mp27-loader.log.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <execinfo.h>
#include <sys/ucontext.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "mp27_prep.h"

// Private but stable syscall wrapper in libsystem_kernel; used to read the
// process's code-signing flags. CS_DEBUGGED is set once a debugger (StikDebug)
// has attached, which is what "JIT enabled" means on stock iPadOS.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000

extern const unsigned mp27_count;
extern void *mp27_table[];
extern const char *const mp27_names[];

static FILE *g_log;
static void *g_handle;
static char g_metadata_dir[1024];
static int g_data_dir_set;
static char g_data_bundle[1024];

// Called by the patched UnityDataBundleDir() in Classes/Unity/Filesystem.mm.
// Unity reads its "Data" folder from <this dir>/Data, so for a macOS
// Game.app copied to Documents/Game this is <Game.app>/Contents/Resources.
const char *mp27_data_bundle_dir(void)
{
    return g_data_bundle[0] ? g_data_bundle : NULL;
}

static void mp27_log(const char *fmt, ...)
{
    va_list ap;
    char buf[2048];
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    NSLog(@"[mp27] %s", buf);
    if (g_log) { fprintf(g_log, "%s\n", buf); fflush(g_log); }
}

__attribute__((noreturn)) static void mp27_unresolved(void);

static void *mp27_real(const char *name)
{
    for (unsigned i = 0; i < mp27_count; i++)
        if (strcmp(mp27_names[i], name) == 0) return mp27_table[i];
    // Not something the engine forwards (e.g. set_data_dir); look it up directly.
    void *p = g_handle ? dlsym(g_handle, name) : NULL;
    if (!p) mp27_log("mp27_real: %s not found", name);
    return p ? p : (void *)mp27_unresolved;
}

__attribute__((noreturn)) static void mp27_unresolved(void)
{
    mp27_log("FATAL: the engine called an il2cpp function that GameAssembly.dylib does not export");
    abort();
}

// ---- macOS -> iOS retarget (same logic as tools/macho_retarget.py) ----

static uint32_t rd32le(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint32_t rd32be(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static void wr32le(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

static NSString *retarget_to(NSString *src, NSString *dst)
{
    NSData *data = [NSData dataWithContentsOfFile:src options:NSDataReadingMappedIfSafe error:nil];
    if (!data) { mp27_log("cannot read %s", src.UTF8String); return nil; }
    const uint8_t *b = data.bytes;
    NSRange slice = NSMakeRange(0, data.length);
    if (rd32be(b) == 0xCAFEBABE) {
        uint32_t n = rd32be(b + 4);
        slice.length = 0;
        for (uint32_t i = 0; i < n; i++) {
            const uint8_t *e = b + 8 + i * 20;
            if (rd32be(e) == 0x0100000C && (rd32be(e + 4) & 0xFF) != 2) {
                slice = NSMakeRange(rd32be(e + 8), rd32be(e + 12));
                break;
            }
        }
        if (!slice.length) { mp27_log("no arm64 slice in %s", src.UTF8String); return nil; }
    }
    NSMutableData *out = [[data subdataWithRange:slice] mutableCopy];
    uint8_t *m = out.mutableBytes;
    if (rd32le(m) != 0xFEEDFACF || rd32le(m + 4) != 0x0100000C) { mp27_log("not an arm64 Mach-O"); return nil; }
    uint32_t ncmds = rd32le(m + 16), off = 32;
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = rd32le(m + off), size = rd32le(m + off + 4);
        if (cmd == 0x32) { // LC_BUILD_VERSION
            mp27_log("LC_BUILD_VERSION platform %u -> 2 (iOS)", rd32le(m + off + 8));
            wr32le(m + off + 8, 2);
            wr32le(m + off + 12, 15 << 16);
        } else if (cmd == 0x24) { // LC_VERSION_MIN_MACOSX -> LC_VERSION_MIN_IPHONEOS
            wr32le(m + off, 0x25);
            wr32le(m + off + 8, 15 << 16);
        } else if (cmd == 0xC || cmd == 0x80000018 || cmd == 0x8000001F || cmd == 0x80000023) {
            // macOS framework install names have a Versions/X/ level that iOS lacks:
            // /System/Library/Frameworks/F.framework/Versions/C/F -> .../F.framework/F
            char *name = (char *)m + off + rd32le(m + off + 8);
            char *ver = strstr(name, ".framework/Versions/");
            if (ver) {
                char *leaf = strchr(ver + 20, '/');
                if (leaf) {
                    size_t keep = (ver + 11) - name, avail = size - rd32le(m + off + 8);
                    char fixed[512];
                    snprintf(fixed, sizeof fixed, "%.*s%s", (int)keep, name, leaf + 1);
                    mp27_log("dylib %s -> %s", name, fixed);
                    memset(name, 0, avail);
                    memcpy(name, fixed, strlen(fixed));
                }
            }
        }
        off += size;
    }
    if (![out writeToFile:dst atomically:YES]) { mp27_log("cannot write %s", dst.UTF8String); return nil; }
    return dst;
}

// ---- preparing a macOS game's Data folder for the iOS player ----

static void copy_if_missing(NSString *from, NSString *to)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:to] || ![fm fileExistsAtPath:from]) return;
    [fm createDirectoryAtPath:to.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *err = nil;
    if ([fm copyItemAtPath:from toPath:to error:&err]) mp27_log("added %s", to.lastPathComponent.UTF8String);
    else mp27_log("could not add %s: %s", to.lastPathComponent.UTF8String, err.localizedDescription.UTF8String);
}

static void prepare_game_data(NSString *data, NSString *bundle)
{
    // iOS-only files the iOS engine expects inside Data (macOS keeps its own
    // "unity default resources" outside Data, built for macOS).
    NSString *shellData = [bundle stringByAppendingPathComponent:@"Data"];
    copy_if_missing([shellData stringByAppendingPathComponent:@"unity default resources"],
                    [data stringByAppendingPathComponent:@"unity default resources"]);
    copy_if_missing([shellData stringByAppendingPathComponent:@"Managed/mono"],
                    [data stringByAppendingPathComponent:@"Managed/mono"]);
    NSDate *t0 = [NSDate date];
    mp27_prep_stats st;
    int rc = mp27_prepare_data(data.UTF8String, mp27_log, &st);
    mp27_log("data preparation %s in %.1f s", rc == 0 ? "ok" : "FAILED", -t0.timeIntervalSinceNow);
}

// ---- locating the game ----

static NSString *find_in_documents(NSString *docs)
{
    NSString *root = [docs stringByAppendingPathComponent:@"Game"];
    // Create the folder so it shows up in the Files app, ready for a game.
    [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:root];
    for (NSString *rel in en)
        if ([rel.lastPathComponent isEqualToString:@"GameAssembly.dylib"])
            return [root stringByAppendingPathComponent:rel];
    return nil;
}

static void remember_metadata_dir(NSString *dir)
{
    NSString *md = [dir stringByAppendingPathComponent:@"Metadata/global-metadata.dat"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:md]) {
        strlcpy(g_metadata_dir, dir.UTF8String, sizeof g_metadata_dir);
        mp27_log("metadata dir: %s", g_metadata_dir);
    }
}

// ---- getting the game's GameAssembly.dylib signed and loaded ----
//
// iPadOS only maps code signed by a trusted certificate. On iOS 26+
// LiveContainer no longer bypasses this with JIT, but it signs and loads any
// dylib in its Tweaks folder before the app starts. So the patched dylib is
// placed in <LiveContainer>/Documents/Tweaks/MacPadOS27/, and once the user
// sets the app's Tweak Folder to "MacPadOS27" it is already loaded when this
// constructor runs.

static NSString *livecontainer_tweaks_dir(NSString *docs)
{
    // Guest Documents: <LC container>/Documents/Data/Application/<UUID>/Documents
    NSRange r = [docs rangeOfString:@"/Documents/Data/Application/"];
    if (r.location == NSNotFound) return nil;
    return [[docs substringToIndex:r.location] stringByAppendingPathComponent:@"Documents/Tweaks/MacPadOS27"];
}

static NSString *file_stamp(NSString *path)
{
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return a ? [NSString stringWithFormat:@"%llu:%.0f", [a fileSize], [[a fileModificationDate] timeIntervalSince1970]] : @"";
}

// Patches the game's dylib once (cached by size+mtime) and offers it to LiveContainer.
static NSString *patched_game_dylib(NSString *src, NSString *docs)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [docs stringByAppendingPathComponent:@".mp27"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [dir stringByAppendingPathComponent:@"GameAssembly.dylib"];
    NSString *stampPath = [dir stringByAppendingPathComponent:@"GameAssembly.stamp"];
    NSString *stamp = file_stamp(src);
    NSString *old = [NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:nil];
    BOOL fresh = ![fm fileExistsAtPath:dst] || ![old isEqualToString:stamp];
    if (fresh) {
        if (!retarget_to(src, dst)) return nil;
        [stamp writeToFile:stampPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        mp27_log("patched GameAssembly.dylib for iOS");
    }
    NSString *tweaks = livecontainer_tweaks_dir(docs);
    if (tweaks) {
        NSString *t = [tweaks stringByAppendingPathComponent:@"GameAssembly.dylib"];
        if (fresh || ![fm fileExistsAtPath:t]) {
            [fm createDirectoryAtPath:tweaks withIntermediateDirectories:YES attributes:nil error:nil];
            [fm removeItemAtPath:t error:nil];
            NSError *err = nil;
            if ([fm copyItemAtPath:dst toPath:t error:&err])
                mp27_log("copied to LiveContainer tweak folder: %s", t.UTF8String);
            else
                mp27_log("could not copy to %s: %s", t.UTF8String, err.localizedDescription.UTF8String);
        }
    }
    return dst;
}

// A GameAssembly.dylib that LiveContainer's TweakLoader already loaded (and signed).
static void *already_loaded_game_dylib(NSString *bundle)
{
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        const char *base = strrchr(n, '/');
        if (!base || strncmp(base + 1, "GameAssembly", 12) != 0) continue;
        if (strncmp(n, bundle.UTF8String, bundle.length) == 0) continue;  // our bundled demo
        mp27_log("found GameAssembly loaded by LiveContainer: %s", n);
        return dlopen(n, RTLD_NOW | RTLD_NOLOAD);
    }
    return NULL;
}

// ---- crash reporting into mp27-loader.log ----

static struct sigaction g_old_actions[32];

static void crash_handler(int sig, siginfo_t *info, void *uap)
{
    ucontext_t *uc = (ucontext_t *)uap;
    uintptr_t pc = uc ? (uintptr_t)uc->uc_mcontext->__ss.__pc : 0;
    uintptr_t lr = uc ? (uintptr_t)uc->uc_mcontext->__ss.__lr : 0;
    mp27_log("*** CRASH: signal %d, fault address %p", sig, info ? info->si_addr : NULL);
    uintptr_t addrs[2] = { pc, lr };
    const char *labels[2] = { "pc", "lr" };
    for (int i = 0; i < 2; i++) {
        Dl_info di;
        if (addrs[i] && dladdr((void *)addrs[i], &di) && di.dli_fname)
            mp27_log("  %s %s+0x%lx (%s)", labels[i], strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname,
                     (unsigned long)(addrs[i] - (uintptr_t)di.dli_fbase), di.dli_sname ? di.dli_sname : "?");
    }
    void *frames[48];
    int n = backtrace(frames, 48);
    for (int i = 0; i < n; i++) {
        Dl_info di;
        if (dladdr(frames[i], &di) && di.dli_fname)
            mp27_log("  #%d %s+0x%lx %s", i, strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname,
                     (unsigned long)((uintptr_t)frames[i] - (uintptr_t)di.dli_fbase), di.dli_sname ? di.dli_sname : "");
    }
    sigaction(sig, &g_old_actions[sig], NULL);  // let Unity's / the system handler finish
}

static void install_crash_handler(void)
{
    int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE };
    for (unsigned i = 0; i < sizeof sigs / sizeof *sigs; i++) {
        struct sigaction sa = {0};
        sa.sa_sigaction = crash_handler;
        sa.sa_flags = SA_SIGINFO;
        sigemptyset(&sa.sa_mask);
        sigaction(sigs[i], &sa, &g_old_actions[sigs[i]]);
    }
}

__attribute__((constructor)) static void mp27_init(void)
{
    @autoreleasepool {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        g_log = fopen([docs stringByAppendingPathComponent:@"mp27-loader.log"].UTF8String, "w");
        mp27_log("MacPadOS27 loader, %u forwarded symbols", mp27_count);
        uint32_t csflags = 0;
        csops(getpid(), CS_OPS_STATUS, &csflags, sizeof csflags);
        mp27_log("JIT (CS_DEBUGGED): %s, cs flags 0x%08x", (csflags & CS_DEBUGGED) ? "YES" : "no", csflags);

        NSString *bundle = [NSBundle mainBundle].bundlePath;
        NSString *dylib = nil, *path = find_in_documents(docs);
        if (path) {
            mp27_log("using Documents copy: %s", path.UTF8String);
            // <Game.app>/Contents/Frameworks/GameAssembly.dylib -> <Game.app>/Contents/Resources/Data/il2cpp_data
            NSString *contents = path.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
            remember_metadata_dir([contents stringByAppendingPathComponent:@"Resources/Data/il2cpp_data"]);
            NSString *resources = [contents stringByAppendingPathComponent:@"Resources"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:[resources stringByAppendingPathComponent:@"Data/globalgamemanagers"]]) {
                strlcpy(g_data_bundle, resources.UTF8String, sizeof g_data_bundle);
                mp27_log("data bundle dir: %s", g_data_bundle);
                prepare_game_data([resources stringByAppendingPathComponent:@"Data"], bundle);
            } else {
                mp27_log("no Data/globalgamemanagers next to it; using the app's bundled data");
            }
            g_handle = already_loaded_game_dylib(bundle);
            dylib = patched_game_dylib(path, docs);
            if (!g_handle && dylib) {
                // Works where unsigned code may be mapped (JIT before iOS 26).
                g_handle = dlopen(dylib.UTF8String, RTLD_NOW | RTLD_LOCAL);
                if (!g_handle) {
                    mp27_log("dlopen failed: %s", dlerror());
                    mp27_log("ACTION NEEDED: in LiveContainer, hold MacPadOS27 -> Settings -> Tweak Folder -> MacPadOS27, then launch again");
                }
            }
            dylib = nil;
        } else {
            dylib = [bundle stringByAppendingPathComponent:@"Frameworks/GameAssembly.dylib"];
            mp27_log("using bundled copy: %s", dylib.UTF8String);
            remember_metadata_dir([bundle stringByAppendingPathComponent:@"Data/il2cpp_data"]);
        }
        if (dylib && !g_handle) {
            g_handle = dlopen(dylib.UTF8String, RTLD_NOW | RTLD_LOCAL);
            if (!g_handle) mp27_log("dlopen failed: %s", dlerror());
        }
        NSString *bundled = [bundle stringByAppendingPathComponent:@"Frameworks/GameAssembly.dylib"];
        if (!g_handle && path && [[NSFileManager defaultManager] fileExistsAtPath:bundled]) {
            mp27_log("falling back to the bundled GameAssembly.dylib and bundled data");
            g_data_bundle[0] = 0;
            g_metadata_dir[0] = 0;
            remember_metadata_dir([bundle stringByAppendingPathComponent:@"Data/il2cpp_data"]);
            g_handle = dlopen(bundled.UTF8String, RTLD_NOW | RTLD_LOCAL);
            if (!g_handle) mp27_log("dlopen failed: %s", dlerror());
        }

        unsigned missing = 0;
        for (unsigned i = 0; i < mp27_count; i++) {
            void *p = g_handle ? dlsym(g_handle, mp27_names[i]) : NULL;
            if (!p) {
                if (missing++ < 50) mp27_log("missing: %s", mp27_names[i]);
                p = (void *)mp27_unresolved;
            }
            mp27_table[i] = p;
        }
        mp27_log("resolved %u/%u symbols", mp27_count - missing, mp27_count);
    }
}

// ---- overrides (no generated stub; see gen_forwarder.py DEFAULT_OVERRIDES) ----

void il2cpp_set_data_dir(const char *dir)
{
    mp27_log("engine set_data_dir(%s)", dir ? dir : "(null)");
    g_data_dir_set = 1;
    ((void (*)(const char *))mp27_real("il2cpp_set_data_dir"))(g_metadata_dir[0] ? g_metadata_dir : dir);
}

static void ensure_data_dir(void)
{
    if (!g_data_dir_set && g_metadata_dir[0]) {
        mp27_log("engine did not set a data dir; using %s", g_metadata_dir);
        ((void (*)(const char *))mp27_real("il2cpp_set_data_dir"))(g_metadata_dir);
        g_data_dir_set = 1;
    }
}

int il2cpp_init(const char *domain_name)
{
    ensure_data_dir();
    mp27_log("il2cpp_init(%s)", domain_name ? domain_name : "(null)");
    int r = ((int (*)(const char *))mp27_real("il2cpp_init"))(domain_name);
    mp27_log("il2cpp_init -> %d", r);
    install_crash_handler();
    return r;
}

int il2cpp_init_utf16(const uint16_t *domain_name)
{
    ensure_data_dir();
    mp27_log("il2cpp_init_utf16");
    int r = ((int (*)(const uint16_t *))mp27_real("il2cpp_init_utf16"))(domain_name);
    mp27_log("il2cpp_init_utf16 -> %d", r);
    return r;
}

// ---- managed methods the iOS engine expects but a macOS build lacks ----
//
// The iOS engine looks up a few [RequiredByNativeCode] methods that exist only
// in the iOS build of Unity's managed modules, by walking a class's methods
// (il2cpp_class_get_methods) and comparing names. It crashes later when it
// calls one it did not find. For each, the method list is extended with a
// copy of a real method of the same shape (same MethodInfo: function pointer,
// invoker, parameters) whose name is changed to the missing one.

typedef struct {
    const char *cls, *declaring, *missing;   // where the iOS engine looks
    const char *ns, *src_cls, *src_method;    // the real method to copy
    int argc;
} standin_spec;

static const standin_spec kStandIns[] = {
    // static bool InvokeIsStopAudioOutputOnMuteEnabled() -> false
    { "Mobile", "AudioSettings", "InvokeIsStopAudioOutputOnMuteEnabled", "UnityEngine", "Application", "get_isBatchMode", 0 },
    // static void InvokeOnMuteStateChanged(bool) -> harmless static void(bool)
    { "Mobile", "AudioSettings", "InvokeOnMuteStateChanged", "UnityEngine", "Cursor", "set_visible", 1 },
};
#define N_STANDINS (sizeof kStandIns / sizeof *kStandIns)

static void *g_standin[N_STANDINS];
static int g_standins_built;
static char g_iter_sentinel[N_STANDINS + 1];

static void *api(const char *name) { return mp27_real(name); }

static void *find_method(const char *ns, const char *cls, const char *method, int argc)
{
    void *dom = ((void *(*)(void))api("il2cpp_domain_get"))();
    void *as = ((void *(*)(void *, const char *))api("il2cpp_domain_assembly_open"))(dom, "UnityEngine.CoreModule");
    void *img = as ? ((void *(*)(void *))api("il2cpp_assembly_get_image"))(as) : NULL;
    void *k = img ? ((void *(*)(void *, const char *, const char *))api("il2cpp_class_from_name"))(img, ns, cls) : NULL;
    return k ? ((void *(*)(void *, const char *, int))api("il2cpp_class_get_method_from_name"))(k, method, argc) : NULL;
}

static void build_standins(void)
{
    if (g_standins_built) return;
    g_standins_built = 1;
    const char *(*method_name)(void *) = (const char *(*)(void *))api("il2cpp_method_get_name");
    for (unsigned i = 0; i < N_STANDINS; i++) {
        void *src = find_method(kStandIns[i].ns, kStandIns[i].src_cls, kStandIns[i].src_method, kStandIns[i].argc);
        if (!src) { mp27_log("stand-in source %s.%s not found", kStandIns[i].src_cls, kStandIns[i].src_method); continue; }
        // Copy the MethodInfo and point its name field at the missing name. The
        // name field is located by value, so no struct layout is assumed.
        enum { COPY = 128 };
        uint8_t *copy = calloc(1, COPY);
        memcpy(copy, src, COPY);
        const char *src_name = method_name(src);
        int patched = 0;
        for (int off = 0; off + 8 <= 64; off += 8)
            if (*(const char **)(copy + off) == src_name) { *(const char **)(copy + off) = kStandIns[i].missing; patched = 1; break; }
        mp27_log("stand-in %s.%s = copy of %s.%s%s", kStandIns[i].cls, kStandIns[i].missing, kStandIns[i].src_cls,
                 kStandIns[i].src_method, patched ? "" : " (name field not found!)");
        g_standin[i] = patched ? copy : NULL;
    }
}

static int class_matches(void *klass, const standin_spec *sp)
{
    const char *(*class_name)(void *) = (const char *(*)(void *))api("il2cpp_class_get_name");
    void *(*declaring)(void *) = (void *(*)(void *))api("il2cpp_class_get_declaring_type");
    if (strcmp(class_name(klass), sp->cls) != 0) return 0;
    void *d = declaring(klass);
    return d && strcmp(class_name(d), sp->declaring) == 0;
}

void *il2cpp_class_get_methods(void *klass, void **iter)
{
    void *(*real)(void *, void **) = (void *(*)(void *, void **))api("il2cpp_class_get_methods");
    char *it = iter ? (char *)*iter : NULL;
    unsigned next = 0;
    if (it >= g_iter_sentinel && it < g_iter_sentinel + sizeof g_iter_sentinel) {
        next = (unsigned)(it - g_iter_sentinel);   // continuing with our extra entries
    } else {
        void *m = real(klass, iter);
        if (m || !klass) return m;
    }
    // The real list has ended; append stand-ins that this class lacks.
    int matched = 0;
    for (unsigned i = next; i < N_STANDINS; i++) {
        if (!class_matches(klass, &kStandIns[i])) continue;
        matched = 1;
        build_standins();
        if (!g_standin[i]) continue;
        if (((void *(*)(void *, const char *, int))api("il2cpp_class_get_method_from_name"))(klass, kStandIns[i].missing, kStandIns[i].argc))
            continue;   // the game's build has the real one
        *iter = g_iter_sentinel + i + 1;
        return g_standin[i];
    }
    if (iter && (matched || next)) *iter = g_iter_sentinel + N_STANDINS;
    return NULL;
}
