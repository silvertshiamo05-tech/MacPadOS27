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
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern const unsigned mp27_count;
extern void *mp27_table[];
extern const char *const mp27_names[];

static FILE *g_log;
static void *g_handle;
static char g_metadata_dir[1024];
static int g_data_dir_set;

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

static void *mp27_real(const char *name)
{
    for (unsigned i = 0; i < mp27_count; i++)
        if (strcmp(mp27_names[i], name) == 0) return mp27_table[i];
    return NULL;
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

static NSString *retarget_to_tmp(NSString *src)
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
        }
        off += size;
    }
    NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:@"GameAssembly-ios.dylib"];
    if (![out writeToFile:dst atomically:YES]) { mp27_log("cannot write %s", dst.UTF8String); return nil; }
    return dst;
}

// ---- locating the game ----

static NSString *find_in_documents(NSString *docs)
{
    NSString *root = [docs stringByAppendingPathComponent:@"Game"];
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

__attribute__((constructor)) static void mp27_init(void)
{
    @autoreleasepool {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        g_log = fopen([docs stringByAppendingPathComponent:@"mp27-loader.log"].UTF8String, "w");
        mp27_log("MacPadOS27 loader, %u forwarded symbols", mp27_count);

        NSString *bundle = [NSBundle mainBundle].bundlePath;
        NSString *dylib = nil, *path = find_in_documents(docs);
        if (path) {
            mp27_log("using Documents copy: %s", path.UTF8String);
            // <Game.app>/Contents/Frameworks/GameAssembly.dylib -> <Game.app>/Contents/Resources/Data/il2cpp_data
            NSString *contents = path.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
            remember_metadata_dir([contents stringByAppendingPathComponent:@"Resources/Data/il2cpp_data"]);
            dylib = retarget_to_tmp(path);
        } else {
            dylib = [bundle stringByAppendingPathComponent:@"Frameworks/GameAssembly.dylib"];
            mp27_log("using bundled copy: %s", dylib.UTF8String);
            remember_metadata_dir([bundle stringByAppendingPathComponent:@"Data/il2cpp_data"]);
        }
        if (dylib) {
            g_handle = dlopen(dylib.UTF8String, RTLD_NOW | RTLD_LOCAL);
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
