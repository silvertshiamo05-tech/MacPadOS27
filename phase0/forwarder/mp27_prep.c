// mp27_prep.c - prepare a macOS Unity 2022.3 player Data folder for the iOS player.
//
// Runs on the iPad (called by mp27_loader.m before the engine starts) and in CI
// (built as a command-line tool with -DMP27_PREP_MAIN). Two changes:
//
//  1. Every SerializedFile's BuildTarget field is set to iOS (9). The iOS
//     player refuses files "created for another build target", but the class
//     layouts of macOS and iOS player data are identical (checked with
//     tools/serialized_types.py --compare).
//  2. BC-compressed Texture2D objects (DXT1/DXT5/BC4/BC5/BC6H/BC7), which the
//     A14 GPU cannot sample and the iOS player cannot decompress, are decoded
//     to uncompressed formats. Pixel data goes to a sidecar "<file>.resT"
//     next to the original ".resS"; only fixed-size fields of the Texture2D
//     object are patched in place, so no other object in the file moves.
//
// Every step is idempotent: re-running after an interruption continues.
// The Texture2D field layout below is the one for Unity 2022.2/2022.3.
#include <dirent.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define BCDEC_IMPLEMENTATION
#include "third_party/bcdec.h"

#include "mp27_prep.h"

#define TARGET_IOS 9
#define CLASS_TEXTURE2D 28

enum {
    TF_RGBA32 = 4, TF_RGBAHalf = 17, TF_DXT1 = 10, TF_DXT5 = 12, TF_BC6H = 24, TF_BC7 = 25,
    TF_BC4 = 26, TF_BC5 = 27, TF_DXT1Crunched = 28, TF_DXT5Crunched = 29, TF_RG16 = 62, TF_R8 = 63,
};

typedef struct {
    mp27_log_fn log;
    mp27_prep_stats *st;
} ctx_t;

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static uint64_t be64(const uint8_t *p) { return (uint64_t)be32(p) << 32 | be32(p + 4); }
static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t le64(const uint8_t *p) { return le32(p) | (uint64_t)le32(p + 4) << 32; }
static void wle32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void wle64(uint8_t *p, uint64_t v) { wle32(p, (uint32_t)v); wle32(p + 4, (uint32_t)(v >> 32)); }
static size_t align4(size_t v) { return (v + 3) & ~(size_t)3; }

static int read_at(FILE *f, uint64_t off, void *buf, size_t n)
{
    if (fseeko(f, (off_t)off, SEEK_SET) != 0) return -1;
    return fread(buf, 1, n, f) == n ? 0 : -1;
}

static int write_at(FILE *f, uint64_t off, const void *buf, size_t n)
{
    if (fseeko(f, (off_t)off, SEEK_SET) != 0) return -1;
    if (fwrite(buf, 1, n, f) != n) return -1;
    return fflush(f);
}

// ---- texture decoding ----

typedef struct { int block_bytes; int out_bpp; int out_format; } bcinfo_t;

static int bc_info(int fmt, bcinfo_t *bi)
{
    switch (fmt) {
    case TF_DXT1: *bi = (bcinfo_t){8, 4, TF_RGBA32}; return 1;
    case TF_DXT5: *bi = (bcinfo_t){16, 4, TF_RGBA32}; return 1;
    case TF_BC7:  *bi = (bcinfo_t){16, 4, TF_RGBA32}; return 1;
    case TF_BC4:  *bi = (bcinfo_t){8, 1, TF_R8}; return 1;
    case TF_BC5:  *bi = (bcinfo_t){16, 2, TF_RG16}; return 1;
    case TF_BC6H: *bi = (bcinfo_t){16, 8, TF_RGBAHalf}; return 1;
    default: return 0;
    }
}

static void decode_block(int fmt, const uint8_t *src, uint8_t *dst, int pitch_bytes)
{
    switch (fmt) {
    case TF_DXT1: bcdec_bc1(src, dst, pitch_bytes); break;
    case TF_DXT5: bcdec_bc3(src, dst, pitch_bytes); break;
    case TF_BC7:  bcdec_bc7(src, dst, pitch_bytes); break;
    case TF_BC4:  bcdec_bc4(src, dst, pitch_bytes); break;
    case TF_BC5:  bcdec_bc5(src, dst, pitch_bytes); break;
    case TF_BC6H: {
        // bcdec writes RGB halfs; Unity has no RGBHalf, so expand to RGBA with A = 1.0.
        uint16_t rgb[16 * 3];
        bcdec_bc6h_half(src, rgb, 4 * 3, 0);
        for (int y = 0; y < 4; y++)
            for (int x = 0; x < 4; x++) {
                uint16_t *o = (uint16_t *)(dst + y * pitch_bytes) + x * 4;
                const uint16_t *i = rgb + (y * 4 + x) * 3;
                o[0] = i[0]; o[1] = i[1]; o[2] = i[2]; o[3] = 0x3C00;
            }
        break;
    }
    }
}

static size_t bc_level_size(int w, int h, int block_bytes)
{
    return (size_t)((w + 3) / 4) * ((h + 3) / 4) * block_bytes;
}

// Decodes one mip level into out (w*h*out_bpp bytes).
static void decode_level(int fmt, const bcinfo_t *bi, const uint8_t *src, int w, int h, uint8_t *out)
{
    int bw = (w + 3) / 4, bh = (h + 3) / 4;
    int pitch = bw * 4 * bi->out_bpp;
    uint8_t *tmp = (w % 4 || h % 4) ? malloc((size_t)pitch * bh * 4) : out;
    for (int by = 0; by < bh; by++)
        for (int bx = 0; bx < bw; bx++)
            decode_block(fmt, src + ((size_t)by * bw + bx) * bi->block_bytes,
                         tmp + (size_t)by * 4 * pitch + (size_t)bx * 4 * bi->out_bpp, pitch);
    if (tmp != out) {
        for (int y = 0; y < h; y++)
            memcpy(out + (size_t)y * w * bi->out_bpp, tmp + (size_t)y * pitch, (size_t)w * bi->out_bpp);
        free(tmp);
    }
}

// ---- Texture2D (Unity 2022.2/2022.3 player layout) ----

typedef struct {
    size_t format_at, complete_size_at, stream_offset_at, stream_size_at, stream_path_at;
    int width, height, mips_stripped, format, mip_count, image_count, dimension;
    uint32_t inline_size, stream_size;
    uint64_t stream_offset;
    char path[512];
    size_t path_len;
} tex_t;

static int parse_texture(const uint8_t *b, size_t n, tex_t *t)
{
#define NEED(k) do { if (p + (k) > n) return -1; } while (0)
    size_t p = 0;
    NEED(4); p = align4(4 + le32(b));                       // m_Name
    NEED(48);
    p += 4;                                                 // m_ForcedFallbackFormat
    p += 4;                                                 // m_DownscaleFallback, m_IsAlphaChannelOptional, align
    t->width = (int)le32(b + p); p += 4;
    t->height = (int)le32(b + p); p += 4;
    t->complete_size_at = p; p += 4;
    t->mips_stripped = (int)le32(b + p); p += 4;
    t->format_at = p; t->format = (int)le32(b + p); p += 4;
    t->mip_count = (int)le32(b + p); p += 4;
    p += 4;                                                 // m_IsReadable, m_IsPreProcessed, m_IgnoreMipmapLimit, align
    NEED(4); p = align4(p + 4 + le32(b + p));               // m_MipmapLimitGroupName
    NEED(56);
    p += 4;                                                 // m_StreamingMipmaps, align
    p += 4;                                                 // m_StreamingMipmapsPriority
    t->image_count = (int)le32(b + p); p += 4;
    t->dimension = (int)le32(b + p); p += 4;
    p += 24;                                                // m_TextureSettings
    p += 8;                                                 // m_LightmapFormat, m_ColorSpace
    NEED(4); p = align4(p + 4 + le32(b + p));               // m_PlatformBlob
    NEED(4); t->inline_size = le32(b + p); p = align4(p + 4 + t->inline_size);   // image data
    NEED(16);
    t->stream_offset_at = p; t->stream_offset = le64(b + p); p += 8;
    t->stream_size_at = p; t->stream_size = le32(b + p); p += 4;
    t->path_len = le32(b + p); p += 4;
    NEED(t->path_len);
    if (t->path_len >= sizeof t->path) return -1;
    t->stream_path_at = p;
    memcpy(t->path, b + p, t->path_len); t->path[t->path_len] = 0;
    return 0;
#undef NEED
}

static void dirname_of(const char *path, char *out, size_t n)
{
    snprintf(out, n, "%s", path);
    char *s = strrchr(out, '/');
    if (s) *s = 0; else snprintf(out, n, ".");
}

static int convert_texture(ctx_t *c, const char *file, FILE *f, uint64_t obj_off, uint32_t obj_size)
{
    uint8_t *obj = malloc(obj_size);
    tex_t t;
    int rc = -1;
    if (!obj || read_at(f, obj_off, obj, obj_size) || parse_texture(obj, obj_size, &t)) {
        c->log("  texture at %llu: unexpected layout, skipped", (unsigned long long)obj_off);
        c->st->textures_skipped++;
        goto out;
    }
    bcinfo_t bi;
    if (!bc_info(t.format, &bi)) {
        if (t.format == TF_DXT1Crunched || t.format == TF_DXT5Crunched) {
            c->log("  texture %dx%d is Crunch-compressed: not supported yet", t.width, t.height);
            c->st->textures_skipped++;
        }
        rc = 0;
        goto out;
    }
    if (t.inline_size || !t.stream_size || t.path_len < 5 || strcmp(t.path + t.path_len - 5, ".resS") ||
        t.image_count != 1 || t.width <= 0 || t.height <= 0 || t.mip_count < 1 || t.mip_count > 16) {
        c->log("  texture %dx%d format %d: not a streamed 2D texture, skipped", t.width, t.height, t.format);
        c->st->textures_skipped++;
        goto out;
    }

    size_t in_total = 0, out_total = 0;
    for (int i = t.mips_stripped; i < t.mip_count; i++) {
        int w = t.width >> i, h = t.height >> i;
        if (w < 1) w = 1;
        if (h < 1) h = 1;
        in_total += bc_level_size(w, h, bi.block_bytes);
        out_total += (size_t)w * h * bi.out_bpp;
    }
    if (in_total != t.stream_size) {
        c->log("  texture %dx%d format %d: %u bytes, expected %zu; skipped", t.width, t.height, t.format,
               t.stream_size, in_total);
        c->st->textures_skipped++;
        goto out;
    }

    char dir[1024], src_path[1600], dst_path[1600];
    dirname_of(file, dir, sizeof dir);
    snprintf(src_path, sizeof src_path, "%s/%s", dir, t.path);
    snprintf(dst_path, sizeof dst_path, "%s/%.*sT", dir, (int)t.path_len - 1, t.path);
    FILE *src = fopen(src_path, "rb");
    FILE *dst = fopen(dst_path, "ab");
    uint8_t *in = malloc(in_total), *outbuf = malloc(out_total);
    if (!src || !dst || !in || !outbuf || read_at(src, t.stream_offset, in, in_total)) {
        c->log("  texture %dx%d: cannot read %s or write %s", t.width, t.height, src_path, dst_path);
        c->st->textures_skipped++;
    } else {
        const uint8_t *ip = in;
        uint8_t *op = outbuf;
        for (int i = t.mips_stripped; i < t.mip_count; i++) {
            int w = t.width >> i, h = t.height >> i;
            if (w < 1) w = 1;
            if (h < 1) h = 1;
            decode_level(t.format, &bi, ip, w, h, op);
            ip += bc_level_size(w, h, bi.block_bytes);
            op += (size_t)w * h * bi.out_bpp;
        }
        fseeko(dst, 0, SEEK_END);
        uint64_t new_off = (uint64_t)ftello(dst);
        if (fwrite(outbuf, 1, out_total, dst) == out_total && fflush(dst) == 0 && fsync(fileno(dst)) == 0) {
            // Pixel data is safely on disk; now point the object at it.
            wle32(obj + t.format_at, (uint32_t)bi.out_format);
            wle32(obj + t.complete_size_at, (uint32_t)out_total);
            wle64(obj + t.stream_offset_at, new_off);
            wle32(obj + t.stream_size_at, (uint32_t)out_total);
            obj[t.stream_path_at + t.path_len - 1] = 'T';
            if (write_at(f, obj_off, obj, obj_size) == 0) {
                c->st->textures_converted++;
                c->st->bytes_written += out_total;
                rc = 0;
            }
        } else {
            c->log("  texture %dx%d: write failed (%s)", t.width, t.height, strerror(errno));
            c->st->textures_skipped++;
        }
    }
    if (src) fclose(src);
    if (dst) fclose(dst);
    free(in);
    free(outbuf);
out:
    free(obj);
    return rc;
}

// ---- SerializedFile ----

static int process_serialized(ctx_t *c, const char *path)
{
    FILE *f = fopen(path, "r+b");
    if (!f) return -1;
    uint8_t head[48];
    int rc = 0;
    if (read_at(f, 0, head, sizeof head)) { fclose(f); return 0; }
    uint32_t version = be32(head + 8);
    if (version < 9 || version > 64) { fclose(f); return 0; }
    int little = head[16] == 0;
    uint64_t meta_start = version >= 22 ? 48 : 20;
    uint64_t meta_size = version >= 22 ? be32(head + 20) : be32(head);
    uint64_t data_off = version >= 22 ? be64(head + 32) : be32(head + 12);
    if (meta_size < 8 || meta_size > (64u << 20)) { fclose(f); return 0; }
    uint8_t *m = malloc(meta_size);
    if (!m || read_at(f, meta_start, m, meta_size)) { free(m); fclose(f); return 0; }

    // Unity version string, then BuildTarget.
    uint8_t *z = memchr(m, 0, 32);
    if (!z || m[0] < '1' || m[0] > '9' || !memchr(m, '.', z - m)) { free(m); fclose(f); return 0; }
    size_t p = z - m + 1;
    uint32_t target = little ? le32(m + p) : be32(m + p);
    c->st->files_seen++;
    if (target != TARGET_IOS) {
        uint8_t v[4];
        if (little) wle32(v, TARGET_IOS); else { v[0] = 0; v[1] = 0; v[2] = 0; v[3] = TARGET_IOS; }
        if (write_at(f, meta_start + p, v, 4) == 0) c->st->files_patched++;
    }
    p += 4;

    // Types and objects (little-endian player data, format 22+ only).
    if (!little || version < 22) goto done;
    int typetree = m[p++];
    if (typetree) goto done;
    int32_t ntypes = (int32_t)le32(m + p); p += 4;
    if (ntypes < 0 || ntypes > 100000) goto done;
    int32_t *classes = calloc((size_t)ntypes + 1, sizeof *classes);
    for (int32_t i = 0; i < ntypes && p + 23 <= meta_size; i++) {
        int32_t cid = (int32_t)le32(m + p);
        classes[i] = cid;
        p += 4 + 1 + 2 + (cid == 114 ? 16 : 0) + 16;
    }
    int32_t nobj = (int32_t)le32(m + p); p += 4;
    for (int32_t i = 0; i < nobj; i++) {
        size_t abs = align4(meta_start + p);
        p = abs - meta_start;
        if (p + 24 > meta_size) break;
        uint64_t start = le64(m + p + 8);
        uint32_t size = le32(m + p + 16);
        int32_t ti = (int32_t)le32(m + p + 20);
        p += 24;
        if (ti >= 0 && ti < ntypes && classes[ti] == CLASS_TEXTURE2D)
            convert_texture(c, path, f, data_off + start, size);
    }
    free(classes);
done:
    free(m);
    fclose(f);
    return rc;
}

static int skip_name(const char *name)
{
    size_t n = strlen(name);
    static const char *exts[] = { ".resS", ".resT", ".resource", ".json", ".config", ".info", ".dat", ".dylib" };
    if (name[0] == '.') return 1;
    for (size_t i = 0; i < sizeof exts / sizeof *exts; i++) {
        size_t k = strlen(exts[i]);
        if (n >= k && strcmp(name + n - k, exts[i]) == 0) return 1;
    }
    return !strcmp(name, "il2cpp_data") || !strcmp(name, "StreamingAssets") || !strcmp(name, "Managed");
}

static void walk(ctx_t *c, const char *dir, int depth)
{
    DIR *d = opendir(dir);
    if (!d || depth > 4) { if (d) closedir(d); return; }
    struct dirent *e;
    while ((e = readdir(d))) {
        if (skip_name(e->d_name)) continue;
        char path[1600];
        struct stat sb;
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        if (stat(path, &sb) != 0) continue;
        if (S_ISDIR(sb.st_mode)) walk(c, path, depth + 1);
        else if (S_ISREG(sb.st_mode)) process_serialized(c, path);
    }
    closedir(d);
}

int mp27_prepare_data(const char *data_dir, mp27_log_fn log, mp27_prep_stats *stats)
{
    mp27_prep_stats local = {0};
    ctx_t c = { log, stats ? stats : &local };
    memset(c.st, 0, sizeof *c.st);
    char marker[1600];
    snprintf(marker, sizeof marker, "%s/.mp27-prepared", data_dir);
    FILE *mk = fopen(marker, "r");
    if (mk) {
        char v[32] = {0};
        fgets(v, sizeof v, mk);
        fclose(mk);
        if (strncmp(v, MP27_PREP_VERSION, strlen(MP27_PREP_VERSION)) == 0) {
            log("data already prepared (version %s)", MP27_PREP_VERSION);
            return 0;
        }
    }
    log("preparing %s", data_dir);
    walk(&c, data_dir, 0);
    log("serialized files: %d, retargeted to iOS: %d; textures converted: %d (%.1f MB), skipped: %d",
        c.st->files_seen, c.st->files_patched, c.st->textures_converted,
        c.st->bytes_written / 1048576.0, c.st->textures_skipped);
    if (!c.st->files_seen) return -1;
    mk = fopen(marker, "w");
    if (mk) { fputs(MP27_PREP_VERSION "\n", mk); fclose(mk); }
    return 0;
}

#ifdef MP27_PREP_MAIN
static void cli_log(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <Data folder>\n", argv[0]);
        return 2;
    }
    return mp27_prepare_data(argv[1], cli_log, NULL) == 0 ? 0 : 1;
}
#endif
