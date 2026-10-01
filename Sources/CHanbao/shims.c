#if defined(__aarch64__)
/* bionic(ARM64) → Darwin 兼容层：自研加载器在重定位期把 .so 导入直接绑到这里 */
#include "elfload.h"
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <syslog.h>
#include <locale.h>
static void hb_sincosf(float x, float* s, float* c) { *s = sinf(x); *c = cosf(x); }
#include <time.h>
#include <unistd.h>
#include <wchar.h>
#include <wctype.h>
#include <xlocale.h>

/* ================= AAPCS64 变参桥 =================
   Darwin arm64: 变参走栈, va_list=扁平指针
   bionic(AAPCS64): 变参走 x2-x7+q0-q7+栈溢出, va_list=五字段结构
   → 引擎调变参函数/传 va_list 结构时全错位。此处统一桥接。 */
#include <string.h>

typedef struct { char* __stack; char* __gr_top; char* __vr_top; int __gr_offs; int __vr_offs; } aapcs_va_t;
static FILE* fix(FILE* f);
int hb_pipe_stdout_err = 0;   /* 1=引擎 printf/puts 改道 stderr，保持 stdout 纯 JSON */
int b_puts2(const char* s) { fputs(s, hb_pipe_stdout_err ? stderr : stdout); fputc('\n', hb_pipe_stdout_err ? stderr : stdout); return 0; }

static int64_t va_gp(aapcs_va_t* ap) {
    int64_t v;
    if (ap->__gr_offs < 0) {
        memcpy(&v, ap->__gr_top + ap->__gr_offs, 8);
        ap->__gr_offs += 8;
    } else {
        memcpy(&v, ap->__stack, 8);
        ap->__stack += 8;
    }
    return v;
}
static double va_fp(aapcs_va_t* ap) {
    union { int64_t i; double d; } u;
    if (ap->__vr_offs < 0) {
        memcpy(&u.i, ap->__vr_top + ap->__vr_offs, 8);
        ap->__vr_offs += 16;
        return u.d;
    }
    memcpy(&u.i, ap->__stack, 8);
    ap->__stack += 8;
    return u.d;
}

/* 输出 sink：FILE 或定长缓冲 */
typedef struct { FILE* f; char* buf; size_t cap; size_t w; size_t len; } sink_t;
static void emit(sink_t* o, const char* s, size_t n) {
    o->len += n;
    if (o->f) { fwrite(s, 1, n, o->f); return; }
    if (!o->buf || !o->cap) return;
    size_t have = (o->w + n < o->cap) ? n : (o->cap - 1 > o->w ? o->cap - 1 - o->w : 0);
    if (have) { memcpy(o->buf + o->w, s, have); o->w += have; }
}

static int g_probe_fd = -1;
static int probe_str(const char* p) {
    if (!p) return 0;
    if (g_probe_fd < 0) {
        int fds[2];
        if (pipe(fds) < 0) return 0;
        g_probe_fd = fds[1];
        fcntl(fds[0], F_SETFL, O_NONBLOCK);
    }
    return write(g_probe_fd, p, 1) >= 0;
}

/* AAPCS 格式化器：宽度/精度/标志/长度修饰齐全，%s 指针全部探测 */
static void aapcs_format(sink_t* o, const char* fmt, aapcs_va_t* ap) {
    char tmp[600];
    for (const char* p = fmt; p && *p; p++) {
        if (*p != '%') { char c = *p; emit(o, &c, 1); continue; }
        p++;
        char fl[8] = {0}; int fn = 0;
        while (*p && strchr("-+ #0", *p) && fn < 6) fl[fn++] = *p++;
        int ljust = memchr(fl, '-', fn) != NULL, zpad = memchr(fl, '0', fn) != NULL;
        long width = 0, prec = -1;
        if (*p == '*') { width = (long)va_gp(ap); p++; }
        else while (*p >= '0' && *p <= '9') width = width * 10 + (*p++ - '0');
        if (*p == '.') {
            p++;
            if (*p == '*') { prec = (long)va_gp(ap); p++; }
            else { prec = 0; while (*p >= '0' && *p <= '9') prec = prec * 10 + (*p++ - '0'); }
        }
        int lng = 0;
        while (*p == 'l' || *p == 'z' || *p == 'j' || *p == 't') { if (*p == 'l') lng++; p++; }
        if (*p == 0) { char c = '%'; emit(o, &c, 1); break; }
        char cv = *p;
        char spec[40];
        int k = snprintf(spec, sizeof(spec), "%%%.*s", fn, fl);
        if (width) k += snprintf(spec + k, sizeof(spec) - k, "%ld", width);
        if (prec >= 0) k += snprintf(spec + k, sizeof(spec) - k, ".%ld", prec);
        if (lng >= 2) k += snprintf(spec + k, sizeof(spec) - k, "ll");
        else if (lng == 1) k += snprintf(spec + k, sizeof(spec) - k, "l");
        int n2;
        switch (cv) {
            case 's': {
                const char* sv = (const char*)va_gp(ap);
                if (!probe_str(sv)) sv = "(null)";
                size_t sl = prec >= 0 ? strnlen(sv, (size_t)prec) : strlen(sv);
                if (width > (long)sl && !ljust) {
                    char pad = zpad ? '0' : ' ';
                    for (long i = sl; i < width; i++) emit(o, &pad, 1);
                }
                emit(o, sv, sl);
                if (width > (long)sl && ljust) { for (long i = sl; i < width; i++) emit(o, " ", 1); }
                break;
            }
            case 'd': case 'i': case 'u': case 'x': case 'X': case 'o': {
                int64_t v = va_gp(ap);
                spec[k++] = cv; spec[k] = 0;
                n2 = snprintf(tmp, sizeof(tmp), spec, v);
                emit(o, tmp, n2);
                break;
            }
            case 'c': {
                int c = (int)va_gp(ap);
                emit(o, (char[]){(char)c, 0}, 1);
                break;
            }
            case 'p': {
                void* v = (void*)va_gp(ap);
                n2 = snprintf(tmp, sizeof(tmp), "%p", v);
                emit(o, tmp, n2);
                break;
            }
            case 'f': case 'F': case 'g': case 'G': case 'e': case 'E': {
                double v = va_fp(ap);
                spec[k++] = cv; spec[k] = 0;
                n2 = snprintf(tmp, sizeof(tmp), spec, v);
                emit(o, tmp, n2 > 0 ? n2 : 0);
                break;
            }
            case '%': { emit(o, "%", 1); break; }
            default: { char c = '%'; emit(o, &c, 1); emit(o, &cv, 1); break; }
        }
    }
    if (o->buf && o->cap) { if (o->w < o->cap) o->buf[o->w] = 0; else o->buf[o->cap - 1] = 0; }
}

/* ---- va_list 结构直达版（引擎自建 tag 传入） ---- */
int b_vsnprintf(char* d, size_t n, const char* fmt, aapcs_va_t* ap) {
    if (!d && !n) { sink_t o = {0}; aapcs_format(&o, fmt, ap); return (int)o.len; }
    sink_t o = { .buf = d, .cap = n };
    aapcs_format(&o, fmt, ap);
    return (int)o.len;
}
int b_vfprintf(FILE* f, const char* fmt, aapcs_va_t* ap) {
    sink_t o = { .f = fix(f) };
    aapcs_format(&o, fmt, ap);
    return (int)o.len;
}
int b_vsprintf(char* d, const char* fmt, aapcs_va_t* ap) {
    sink_t o = { .buf = d, .cap = (size_t)-1 };
    aapcs_format(&o, fmt, ap);
    return (int)o.len;
}
int b_vsnprintf_chk(char* d, size_t n, int f, size_t mn, const char* fmt, aapcs_va_t* ap) {
    (void)f; (void)mn; return b_vsnprintf(d, n, fmt, ap);
}
int b_vsprintf_chk(char* d, int f, size_t mn, const char* fmt, aapcs_va_t* ap) {
    (void)f; (void)mn; return b_vsprintf(d, fmt, ap);
}
int b_vasprintf(char** out, const char* fmt, aapcs_va_t* ap) {
    sink_t o = {0};
    aapcs_format(&o, fmt, ap);
    *out = malloc(o.len + 1);
    sink_t o2 = { .buf = *out, .cap = o.len + 1 };
    aapcs_va_t ap2 = *ap;
    aapcs_format(&o2, fmt, &ap2);
    return (int)o.len;
}

/* ---- 变参跳板：保存 x2-x7/q0-q7 → 组装 tag → 调 worker ---- */
#define VTRAMP(cname, worker, N) \
    void cname(void); \
    __asm__( \
        ".globl _" #cname "\n_" #cname ":\n" \
        "    stp x29, x30, [sp, #-0x120]!\n" \
        "    mov x29, sp\n" \
        "    stp x0, x1, [sp, #0x10]\n" \
        "    stp x2, x3, [sp, #0x20]\n" \
        "    stp x4, x5, [sp, #0x30]\n" \
        "    stp x6, x7, [sp, #0x40]\n" \
        "    stp q0, q1, [sp, #0x50]\n" \
        "    stp q2, q3, [sp, #0x70]\n" \
        "    stp q4, q5, [sp, #0x90]\n" \
        "    stp q6, q7, [sp, #0xb0]\n" \
        "    add x8, x29, #0x120\n" \
        "    str x8, [sp, #0xd0]\n" \
        "    add x8, sp, #0x50\n" \
        "    str x8, [sp, #0xd8]\n" \
        "    add x8, sp, #0xd0\n" \
        "    str x8, [sp, #0xe0]\n" \
        "    mov w8, #-0x80\n" \
        "    stur w8, [sp, #0xec]\n" \
        "    mov w8, #(" #N "-8)*8\n" \
        "    stur w8, [sp, #0xe8]\n" \
        "    ldp x0, x1, [sp, #0x10]\n" \
        "    ldp x2, x3, [sp, #0x20]\n" \
        "    ldr x4, [sp, #0x30]\n" \
        "    add x" #N ", sp, #0xd0\n" \
        "    bl _" #worker "\n" \
        "    ldp x29, x30, [sp], #0x120\n" \
        "    ret\n" \
    );

int hb_alp_worker(int prio, const char* tag, const char* fmt, aapcs_va_t* ap) {
    if (prio >= 4) {
        if (probe_str(tag)) fprintf(stderr, "[alog:%s] ", tag); else fputs("[alog] ", stderr);
        if (probe_str(fmt)) { sink_t o = { .f = stderr }; aapcs_format(&o, fmt, ap); }
        fputc('\n', stderr);
    }
    return 1;
}
VTRAMP(b_alp, hb_alp_worker, 3)

int hb_printf_worker(const char* fmt, aapcs_va_t* ap) {
    sink_t o = { .f = stdout };
    if (probe_str(fmt)) aapcs_format(&o, fmt, ap);
    return (int)o.len;
}
VTRAMP(b_printf, hb_printf_worker, 1)

int hb_fprintf_worker(FILE* f, const char* fmt, aapcs_va_t* ap) {
    FILE* rf = fix(f);
    if (hb_pipe_stdout_err && rf == stdout) rf = stderr;
    sink_t o = { .f = rf };
    if (probe_str(fmt)) aapcs_format(&o, fmt, ap);
    return (int)o.len;
}
VTRAMP(b_fprintf2, hb_fprintf_worker, 2)

int hb_sprintf_worker(char* d, const char* fmt, aapcs_va_t* ap) {
    sink_t o = { .buf = d, .cap = (size_t)-1 };
    if (probe_str(fmt)) aapcs_format(&o, fmt, ap);
    return (int)o.len;
}
VTRAMP(b_sprintf2, hb_sprintf_worker, 2)

int hb_snprintf_worker(char* d, size_t n, const char* fmt, aapcs_va_t* ap) {
    sink_t o = { .buf = d, .cap = n };
    if (probe_str(fmt)) aapcs_format(&o, fmt, ap);
    return (int)o.len;
}
VTRAMP(b_snprintf2, hb_snprintf_worker, 3)

void hb_syslog_worker(int pri, const char* fmt, aapcs_va_t* ap) {
    (void)pri;
    sink_t o = { .f = stderr };
    if (probe_str(fmt)) aapcs_format(&o, fmt, ap);
}
VTRAMP(b_syslog2, hb_syslog_worker, 2)

int hb_snprintf_chk_worker(char* d, size_t n, int f, size_t mn, const char* fmt, aapcs_va_t* ap) {
    (void)f; (void)mn;
    return hb_snprintf_worker(d, n, fmt, ap);
}
VTRAMP(b_snprintf_chk, hb_snprintf_chk_worker, 5)

int hb_sprintf_chk_worker(char* d, int f, size_t mn, const char* fmt, aapcs_va_t* ap) {
    (void)f; (void)mn;
    return hb_sprintf_worker(d, fmt, ap);
}
VTRAMP(b_sprintf_chk, hb_sprintf_chk_worker, 4)

int b_android_log_write(int prio, const char* tag, const char* text) {
    if (prio >= 4) {
        if (probe_str(tag)) fprintf(stderr, "[alog:%s] ", tag); else fputs("[alog] ", stderr);
        if (probe_str(text)) fputs(text, stderr); else fputs("(null)", stderr);
        fputc('\n', stderr);
    }
    return 1;
}
int b_system_property_get(const char* name, char* value) {
    if (!strcmp(name, "ro.build.version.sdk")) { strcpy(value, "31"); return 2; }
    if (!strcmp(name, "ro.product.model")) { strcpy(value, "Linux"); return 5; }
    if (!strcmp(name, "ro.build.version.release")) { strcpy(value, "12"); return 2; }
    value[0] = 0;
    return 0;
}
void b_android_set_abort_message(const char* msg) { fprintf(stderr, "[abort] %s\n", msg); }
int b_android_api_level(void) { return 31; }

/* ---------------- __sF 假 FILE + 假 vtable（std::cout 走这里） ---------------- */
char __sF[3 * 152 + 256] __attribute__((aligned(16)));

extern int hb_pipe_stdout_err;   /* 前向 */
static FILE* stream_of(void* fake) {
    long d = (char*)fake - (char*)__sF;
    if (d < 152) return stdin;
    if (d < 304) return hb_pipe_stdout_err ? stderr : stdout;
    return stderr;
}
static long fb_xsputn(void* t, const char* s, unsigned long n) { return fwrite(s, 1, n, stream_of(t)); }
static long fb_xsgetn(void* t, char* d, unsigned long n) { return fread(d, 1, n, stream_of(t)); }
static int fb_overflow(void* t, int c) { return fputc(c, stream_of(t)); }
static int fb_underflow(void* t) { return fgetc(stream_of(t)); }
static int fb_sync(void* t) { return fflush(stream_of(t)); }
static long fb_stub(void* a, ...) { (void)a; return 0; }
static long fake_vt_in[32], fake_vt_out[32], fake_vt_err[32];

__attribute__((constructor)) static void init_fake_vtables(void) {
    for (int i = 0; i < 32; i++) {
        fake_vt_in[i] = (long)fb_stub; fake_vt_out[i] = (long)fb_stub; fake_vt_err[i] = (long)fb_stub;
    }
    fake_vt_out[6] = (long)fb_sync; fake_vt_out[8] = (long)fb_xsgetn;
    fake_vt_out[12] = (long)fb_xsputn; fake_vt_out[13] = (long)fb_overflow;
    fake_vt_in[6] = (long)fb_sync; fake_vt_in[8] = (long)fb_xsgetn;
    fake_vt_in[9] = (long)fb_underflow; fake_vt_in[12] = (long)fb_xsputn;
    fake_vt_in[13] = (long)fb_overflow;
    memcpy(fake_vt_err, fake_vt_out, sizeof(fake_vt_out));
    *(long*)((char*)__sF) = (long)fake_vt_in;
    *(long*)((char*)__sF + 152) = (long)fake_vt_out;
    *(long*)((char*)__sF + 304) = (long)fake_vt_err;
}

/* stdio：__sF 假指针 → 真流 */
static FILE* fix(FILE* f) {
    char* p = (char*)f;
    if (p >= (char*)__sF && p < (char*)__sF + 3 * 152 + 96) return stream_of(p);
    return f;
}
size_t b_fwrite(const void* p, size_t s, size_t n, FILE* f) { return fwrite(p, s, n, fix(f)); }
int b_fputc(int c, FILE* f) { return fputc(c, fix(f)); }
int b_fputs(const char* s, FILE* f) { return fputs(s, fix(f)); }
size_t b_fread(void* p, size_t s, size_t n, FILE* f) { return fread(p, s, n, fix(f)); }
char* b_fgets(char* d, int n, FILE* f) { return fgets(d, n, fix(f)); }
int b_feof(FILE* f) { return feof(fix(f)); }
int b_ferror(FILE* f) { return ferror(fix(f)); }
int b_fflush(FILE* f) { return fflush(f ? fix(f) : NULL); }
int b_getc(FILE* f) { return fgetc(fix(f)); }
int b_ungetc(int c, FILE* f) { return ungetc(c, fix(f)); }
int b_fscanf(FILE* f, const char* fmt, ...) { return 0; }   /* 变参输出指针桥接复杂，先桩 */

/* ---------------- errno ---------------- */
/* Darwin 与 Linux errno 编号不同（ETIMEDOUT 60/110, EAGAIN 35/11...），统一翻译 */
static int errno_d2l(int e) {
    switch (e) {
        case 0: return 0;
        case 60: return 110;   /* ETIMEDOUT */
        case 35: return 11;    /* EAGAIN */
        case 11: return 35;    /* EDEADLK */
        case 45: return 95;    /* ENOTSUP */
        case 62: return 40;    /* ELOOP */
        case 84: return 75;    /* EOVERFLOW */
        case 92: return 84;    /* EILSEQ */
        case 89: return 115;   /* ECANCELED */
        default: return e;
    }
}
/* POSIX 类失败后把 errno 翻译成 Linux 值 */
static void fix_errno(void) { *__error() = errno_d2l(*__error()); }
int* b_errno(void) { return __error(); }

/* ---------------- 文件：flags/布局翻译（POSIX 返回约定） ---------------- */
static int ofl_l2d(int f) {
    int r = f & 3;
    if (f & 0x40) r |= O_CREAT;
    if (f & 0x80) r |= O_EXCL;
    if (f & 0x200) r |= O_TRUNC;
    if (f & 0x400) r |= O_APPEND;
    if (f & 0x800) r |= O_NONBLOCK;
    if (f & 0x80000) r |= O_CLOEXEC;
    return r;
}
int b_open(const char* p, int f, long mode) {   /* AAPCS: mode=x2 */
    int r = open(p, ofl_l2d(f), (f & 0x40) ? (mode_t)mode : 0);
    if (r < 0) fix_errno();
    return r;
}
int b_open_2(const char* p, int f) { return open(p, ofl_l2d(f)); }
int b_close(int fd) { int r = close(fd); if (r) fix_errno(); return r; }
long b_read(int fd, void* b, size_t n) { long r = (long)read(fd, b, n); if (r < 0) fix_errno(); return r; }
long b_lseek(int fd, long off, int w) { return (long)lseek(fd, (off_t)off, w); }
int b_ftruncate(int fd, long l) { return ftruncate(fd, (off_t)l); }
int b_access(const char* p, int m) { return access(p, m); }
int b_mkdir(const char* p, mode_t m) { return mkdir(p, m); }
int b_unlink(const char* p) { return unlink(p); }

void* b_mmap(void* a, size_t len, int prot, int flags, int fd, long off) {
    int df = 0;
    if (flags & 0x02) df |= MAP_PRIVATE;
    if (flags & 0x01) df |= MAP_SHARED;
    if (flags & 0x20) df |= MAP_ANON;
    if (flags & 0x10) df |= MAP_FIXED;
    return mmap(a, len, prot, df, (df & MAP_ANON) ? -1 : fd, (off_t)off);
}
int b_munmap(void* p, size_t n) { return munmap(p, n); }
int b_msync(void* p, size_t n, int f) { return msync(p, n, f); }

/* bionic arm64 struct stat(128B) ← Darwin stat */
static void stat_l_from_d(void* out, const struct stat* st) {
    unsigned char* b = out;
    memset(b, 0, 128);
    *(uint64_t*)(b + 0x00) = st->st_dev;
    *(uint64_t*)(b + 0x08) = st->st_ino;
    *(uint32_t*)(b + 0x10) = st->st_mode;
    *(uint32_t*)(b + 0x14) = st->st_nlink;
    *(uint32_t*)(b + 0x18) = st->st_uid;
    *(uint32_t*)(b + 0x1c) = st->st_gid;
    *(uint64_t*)(b + 0x20) = st->st_rdev;
    *(int64_t*)(b + 0x30) = st->st_size;
    *(uint32_t*)(b + 0x38) = st->st_blksize;
    *(int64_t*)(b + 0x40) = st->st_blocks;
    *(int64_t*)(b + 0x48) = st->st_atimespec.tv_sec;
    *(int64_t*)(b + 0x50) = st->st_atimespec.tv_nsec;
    *(int64_t*)(b + 0x58) = st->st_mtimespec.tv_sec;
    *(int64_t*)(b + 0x60) = st->st_mtimespec.tv_nsec;
    *(int64_t*)(b + 0x68) = st->st_ctimespec.tv_sec;
    *(int64_t*)(b + 0x70) = st->st_ctimespec.tv_nsec;
}
int b_stat(const char* p, void* out) {
    struct stat st; int r = stat(p, &st);
    if (r == 0) stat_l_from_d(out, &st);
    return r;
}
int b_lstat(const char* p, void* out) {
    struct stat st; int r = lstat(p, &st);
    if (r == 0) stat_l_from_d(out, &st);
    return r;
}
int b_fstat(int fd, void* out) {
    struct stat st; int r = fstat(fd, &st);
    if (r == 0) stat_l_from_d(out, &st);
    return r;
}

/* dirent：bionic d_name@0x13, d_reclen@0x10, d_type@0x12 */
typedef struct {
    uint64_t ino; int64_t off; uint16_t reclen; uint8_t type; char name[256];
} b_dirent_t;
typedef struct { DIR* d; b_dirent_t ent; } b_dir_t;
void* b_opendir(const char* p) {
    DIR* d = opendir(p);
    if (!d) return NULL;
    b_dir_t* bd = calloc(1, sizeof(*bd));
    bd->d = d;
    return bd;
}
void* b_readdir(void* dir) {
    b_dir_t* bd = dir;
    struct dirent* e = readdir(bd->d);
    if (!e) return NULL;
    bd->ent.ino = e->d_ino;
    bd->ent.off = 0;
    snprintf(bd->ent.name, sizeof(bd->ent.name), "%s", e->d_name);
    bd->ent.reclen = (uint16_t)(0x13 + strlen(bd->ent.name) + 1);
    bd->ent.reclen = (bd->ent.reclen + 7) & ~7;
    bd->ent.type = e->d_type;
    return &bd->ent;
}
int b_closedir(void* dir) {
    b_dir_t* bd = dir;
    int r = closedir(bd->d);
    free(bd);
    return r;
}

/* ---------------- clock / syscall / misc ---------------- */
int b_clock_gettime(int clk, void* ts) {
    int d = clk == 0 ? CLOCK_REALTIME : CLOCK_MONOTONIC;
    return clock_gettime(d, (struct timespec*)ts);
}
static long g_fake_tid_counter = 1000;
long b_gettid(void) {
    static _Thread_local long tid = 0;
    if (!tid) tid = __sync_add_and_fetch(&g_fake_tid_counter, 1);
    return tid;
}
long b_syscall(long nr, ...) {
    va_list ap; va_start(ap, nr);
    long a0 = va_arg(ap, long), a1 = va_arg(ap, long), a2 = va_arg(ap, long);
    va_end(ap);
    switch (nr) {
        case 178: return b_gettid();
        case 384: {
            unsigned char* buf = (unsigned char*)a0; size_t n = (size_t)a1;
            arc4random_buf(buf, n); return (long)n;
        }
        default:
            fprintf(stderr, "[shim] syscall(%ld) unhandled -> ENOSYS\n", nr);
            errno = 38; return -1;
    }
}
unsigned long b_getauxval(int type) {
    switch (type) {
        case 6: return 4096;
        case 16: return 3;
        case 23: return 0;
        default: return 0;
    }
}
char* b_strerror_r(int err, char* buf, size_t n) {
    snprintf(buf, n, "%s", strerror(err));
    return buf;
}
long b_sysconf(int name) {
    switch (name) {
        case 84: case 83: return sysconf(_SC_NPROCESSORS_ONLN);
        case 30: case 29: return 4096;
        default: return sysconf(name);
    }
}
int b_mb_cur_max(void) { return 4; }
int b_cxa_thread_atexit(void (*dtor)(void*), void* obj, void* dso) {
    (void)dtor; (void)obj; (void)dso; return 0;
}
int b_cxa_atexit(void (*fn)(void*), void* arg, void* dso) { return 0; }
void b_cxa_finalize(void* dso) {}
void b_stack_chk_fail(void) {
    fprintf(stderr, "[shim] stack smashing detected\n");
    abort();
}
void b_flute_tls_wrapper(void) {}

/* ---------------- pthread：bionic 结构 → Darwin 对象侧表 ---------------- */
typedef struct bslot {
    void* key;
    pthread_mutex_t m;
    pthread_cond_t c;
    pthread_rwlock_t rw;
    int kind;
    struct bslot* next;
} bslot_t;
static bslot_t* g_slots[128];
static pthread_mutex_t g_slot_mu = PTHREAD_MUTEX_INITIALIZER;

static bslot_t* slot_for(void* key, int recursive) {
    uintptr_t h = (uintptr_t)key >> 4 & 127;
    pthread_mutex_lock(&g_slot_mu);
    for (bslot_t* s = g_slots[h]; s; s = s->next)
        if (s->key == key) { pthread_mutex_unlock(&g_slot_mu); return s; }
    bslot_t* s = calloc(1, sizeof(*s));
    s->key = key;
    if (recursive) {
        pthread_mutexattr_t a; pthread_mutexattr_init(&a);
        pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&s->m, &a);
        s->kind = 1;
    } else pthread_mutex_init(&s->m, NULL);
    pthread_cond_init(&s->c, NULL);
    pthread_rwlock_init(&s->rw, NULL);
    s->next = g_slots[h]; g_slots[h] = s;
    pthread_mutex_unlock(&g_slot_mu);
    return s;
}
int b_mu_lock(void* m) { return errno_d2l(pthread_mutex_lock(&slot_for(m, 0)->m)); }
int b_mu_unlock(void* m) { return errno_d2l(pthread_mutex_unlock(&slot_for(m, 0)->m)); }
int b_mu_trylock(void* m) { return errno_d2l(pthread_mutex_trylock(&slot_for(m, 0)->m)); }
int b_mu_destroy(void* m) { return 0; }
int b_mu_init(void* m, const void* attr) {
    int recursive = attr && *(const int*)attr == 1;
    slot_for(m, recursive);
    return 0;
}
int b_muattr_init(void* a) { *(int*)a = 0; return 0; }
int b_muattr_destroy(void* a) { return 0; }
int b_muattr_settype(void* a, int t) { *(int*)a = t; return 0; }
int b_cond_wait(void* c, void* m) { return errno_d2l(pthread_cond_wait(&slot_for(c, 0)->c, &slot_for(m, 0)->m)); }
int b_cond_timedwait(void* c, void* m, const void* ts) {
    int r = errno_d2l(pthread_cond_timedwait(&slot_for(c, 0)->c, &slot_for(m, 0)->m, (const struct timespec*)ts));
    if (r && r != 110) fprintf(stderr, "[shim] cond_timedwait err=%d\n", r);
    return r;
}
int b_cond_signal(void* c) { return pthread_cond_signal(&slot_for(c, 0)->c); }
int b_cond_broadcast(void* c) { return pthread_cond_broadcast(&slot_for(c, 0)->c); }
int b_cond_destroy(void* c) { return 0; }
int b_rw_rdlock(void* l) { return pthread_rwlock_rdlock(&slot_for(l, 0)->rw); }
int b_rw_wrlock(void* l) { return pthread_rwlock_wrlock(&slot_for(l, 0)->rw); }
int b_rw_unlock(void* l) { return pthread_rwlock_unlock(&slot_for(l, 0)->rw); }
int b_rw_init(void* l, const void* a) { slot_for(l, 0); return 0; }
int b_rw_destroy(void* l) { return 0; }
int b_once(void* once, void (*fn)(void)) {
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    if (*(volatile int*)once == 0) { fn(); *(volatile int*)once = 1; }
    pthread_mutex_unlock(&mu);
    return 0;
}
static pthread_key_t g_keys[256];
static int g_nkey = 0;
static pthread_mutex_t g_key_mu = PTHREAD_MUTEX_INITIALIZER;
int b_key_create(void* k, void (*dtor)(void*)) {
    pthread_key_t dk;
    int r = pthread_key_create(&dk, dtor);
    if (r) return r;
    pthread_mutex_lock(&g_key_mu);
    g_keys[g_nkey] = dk;
    *(unsigned*)k = (unsigned)g_nkey++;
    pthread_mutex_unlock(&g_key_mu);
    return 0;
}
int b_key_delete(unsigned k) { return k < 256 ? pthread_key_delete(g_keys[k]) : 0; }
void* b_getspecific(unsigned k) { return k < 256 ? pthread_getspecific(g_keys[k]) : NULL; }
int b_setspecific(unsigned k, const void* v) { return k < 256 ? pthread_setspecific(g_keys[k], v) : 0; }

typedef unsigned long b_pthread_t;
typedef struct { void* (*fn)(void*); void* arg; } b_start_t;
static void* b_tramp(void* p) {
    b_start_t s = *(b_start_t*)p; free(p);
    return s.fn(s.arg);
}
int b_thread_create(void* t, const void* attr, void* (*fn)(void*), void* arg) {
    int detached = attr && (*(const unsigned*)attr & 1);
    pthread_attr_t da;
    const pthread_attr_t* use = NULL;
    if (detached) {
        pthread_attr_init(&da);
        pthread_attr_setdetachstate(&da, PTHREAD_CREATE_DETACHED);
        use = &da;
    }
    b_start_t* st = malloc(sizeof(*st));
    st->fn = fn; st->arg = arg;
    pthread_t dt;
    int r = pthread_create(&dt, use, b_tramp, st);
    *(b_pthread_t*)t = (b_pthread_t)dt;
    return r;
}
int b_thread_join(b_pthread_t t, void** ret) { return errno_d2l(pthread_join((pthread_t)t, ret)); }
int b_thread_detach(b_pthread_t t) { return pthread_detach((pthread_t)t); }
b_pthread_t b_thread_self(void) { return (b_pthread_t)pthread_self(); }
int b_thread_equal(b_pthread_t a, b_pthread_t b) { return a == b; }
int b_thread_setname(b_pthread_t t, const char* n) {
    if (t == (b_pthread_t)pthread_self()) return pthread_setname_np(n);
    return 0;
}

/* ---------------- dl_iterate_phdr ---------------- */
typedef struct {
    uint64_t addr; const char* name; const void* phdr; uint16_t phnum;
} b_phdr_info_t;
int b_dl_iterate_phdr(int (*cb)(b_phdr_info_t*, size_t, void*), void* data) {
    hb_modinfo mods[8]; int n;
    hb_modules(mods, 8, &n);
    for (int i = 0; i < n; i++) {
        b_phdr_info_t info = { mods[i].addr, mods[i].name, mods[i].phdr, mods[i].phnum };
        int r = cb(&info, sizeof(info), data);
        if (r) return r;
    }
    return 0;
}

/* ---------------- Android 属性 ---------------- */
/* ---------------- FORTIFY ---------------- */
size_t b_strlen_chk(const char* s, size_t n) { (void)n; return strlen(s); }
char* b_strcpy_chk(char* d, const char* s, size_t ds, size_t ss) { (void)ds; (void)ss; return strcpy(d, s); }
char* b_strcat_chk(char* d, const char* s, size_t dl, size_t sl) { (void)sl; return strcat(d, s); }
char* b_strncpy_chk(char* d, const char* s, size_t n, size_t ds) { (void)ds; return strncpy(d, s, n); }
char* b_stpcpy_chk(char* d, const char* s, size_t ds) { (void)ds; return stpcpy(d, s); }
void* b_memcpy_chk(void* d, const void* s, size_t n, size_t ds) { (void)ds; return memcpy(d, s, n); }
void* b_memmove_chk(void* d, const void* s, size_t n, size_t ds) { (void)ds; return memmove(d, s, n); }
void* b_memset_chk(void* d, int c, size_t n, size_t ds) { (void)ds; return memset(d, c, n); }
char* b_strrchr_chk(const char* s, int c, size_t n) { (void)n; return strrchr(s, c); }
long b_read_chk(int fd, void* buf, size_t n, size_t bn) { (void)bn; return b_read(fd, buf, n); }
int b_strncpy_chk2(char* d, const char* s, size_t n, size_t ds, size_t ss) {
    (void)ds; (void)ss; return strncpy(d, s, n) != NULL;
}

/* ---------------- locale _l（忽略 locale 参数） ---------------- */
long long b_strtoll_l(const char* s, char** e, int b, locale_t l) { (void)l; return strtoll(s, e, b); }
unsigned long long b_strtoull_l(const char* s, char** e, int b, locale_t l) { (void)l; return strtoull(s, e, b); }
double b_strtod_l(const char* s, char** e, locale_t l) { (void)l; return strtod(s, e); }
float b_strtof_l(const char* s, char** e, locale_t l) { (void)l; return strtof(s, e); }
long double b_strtold_l(const char* s, char** e, locale_t l) { (void)l; return strtold(s, e); }
long b_strtol_l(const char* s, char** e, int b, locale_t l) { (void)l; return strtol(s, e, b); }
unsigned long b_strtoul_l(const char* s, char** e, int b, locale_t l) { (void)l; return strtoul(s, e, b); }

/* ---------------- 符号表 ---------------- */
typedef struct { const char* name; void* fn; } shim_ent_t;
static const shim_ent_t SHIMS[] = {
    /* stdio */
    {"fwrite", (void*)b_fwrite}, {"fputc", (void*)b_fputc}, {"fputs", (void*)b_fputs},
    {"fprintf", (void*)b_fprintf2}, {"vfprintf", (void*)b_vfprintf},
    {"fread", (void*)b_fread}, {"fgets", (void*)b_fgets}, {"feof", (void*)b_feof},
    {"ferror", (void*)b_ferror}, {"fflush", (void*)b_fflush}, {"getc", (void*)b_getc},
    {"ungetc", (void*)b_ungetc}, {"fscanf", (void*)b_fscanf},
    {"fopen", (void*)fopen}, {"fclose", (void*)fclose}, {"fseek", (void*)fseek},
    {"fseeko", (void*)fseeko}, {"ftello", (void*)ftello}, {"printf", (void*)b_printf},
    {"puts", (void*)b_puts2}, {"perror", (void*)perror}, {"snprintf", (void*)b_snprintf2},
    {"sprintf", (void*)b_sprintf2}, {"vsnprintf", (void*)b_vsnprintf},
    {"vasprintf", (void*)b_vasprintf}, {"openlog", (void*)openlog},
    {"closelog", (void*)closelog}, {"syslog", (void*)b_syslog2},
    {"__sF", (void*)__sF},
    /* errno/misc */
    {"__errno", (void*)b_errno}, {"abort", (void*)abort}, {"getenv", (void*)getenv},
    {"time", (void*)time}, {"srand", (void*)srand}, {"rand", (void*)rand},
    {"atoi", (void*)atoi}, {"atol", (void*)atol}, {"signal", (void*)signal},
    {"__stack_chk_fail", (void*)b_stack_chk_fail},
    {"strerror", (void*)strerror}, {"strerror_r", (void*)b_strerror_r},
    {"sysconf", (void*)b_sysconf}, {"syscall", (void*)b_syscall},
    {"gettid", (void*)b_gettid}, {"getauxval", (void*)b_getauxval},
    {"__ctype_get_mb_cur_max", (void*)b_mb_cur_max},
    {"localeconv", (void*)localeconv},
    {"__cxa_thread_atexit", (void*)b_cxa_thread_atexit},
    {"__cxa_thread_atexit_impl", (void*)b_cxa_thread_atexit},
    {"__cxa_atexit", (void*)b_cxa_atexit},
    {"__cxa_finalize", (void*)b_cxa_finalize},
    {"_ZTHN5flute8internal7logging21to_string_reentrancesE", (void*)b_flute_tls_wrapper},
    /* 文件 */
    {"open", (void*)b_open}, {"__open_2", (void*)b_open_2}, {"close", (void*)b_close},
    {"read", (void*)b_read}, {"lseek", (void*)b_lseek}, {"access", (void*)b_access},
    {"mkdir", (void*)b_mkdir}, {"unlink", (void*)b_unlink},
    {"ftruncate", (void*)b_ftruncate},
    {"mmap", (void*)b_mmap}, {"munmap", (void*)b_munmap}, {"msync", (void*)b_msync},
    {"stat", (void*)b_stat}, {"lstat", (void*)b_lstat}, {"fstat", (void*)b_fstat},
    {"opendir", (void*)b_opendir}, {"readdir", (void*)b_readdir}, {"closedir", (void*)b_closedir},
    /* clock */
    {"clock_gettime", (void*)b_clock_gettime}, {"nanosleep", (void*)nanosleep},
    {"gettimeofday", (void*)gettimeofday}, {"sched_yield", (void*)sched_yield},
    {"gmtime", (void*)gmtime}, {"localtime", (void*)localtime},
    {"localtime_r", (void*)localtime_r}, {"strftime", (void*)strftime},
    /* pthread */
    {"pthread_create", (void*)b_thread_create}, {"pthread_join", (void*)b_thread_join},
    {"pthread_detach", (void*)b_thread_detach}, {"pthread_self", (void*)b_thread_self},
    {"pthread_equal", (void*)b_thread_equal},
    {"pthread_setname_np", (void*)b_thread_setname},
    {"pthread_mutex_lock", (void*)b_mu_lock}, {"pthread_mutex_unlock", (void*)b_mu_unlock},
    {"pthread_mutex_trylock", (void*)b_mu_trylock}, {"pthread_mutex_destroy", (void*)b_mu_destroy},
    {"pthread_mutex_init", (void*)b_mu_init},
    {"pthread_mutexattr_init", (void*)b_muattr_init},
    {"pthread_mutexattr_destroy", (void*)b_muattr_destroy},
    {"pthread_mutexattr_settype", (void*)b_muattr_settype},
    {"pthread_cond_wait", (void*)b_cond_wait},
    {"pthread_cond_timedwait", (void*)b_cond_timedwait},
    {"pthread_cond_signal", (void*)b_cond_signal},
    {"pthread_cond_broadcast", (void*)b_cond_broadcast},
    {"pthread_cond_destroy", (void*)b_cond_destroy},
    {"pthread_rwlock_init", (void*)b_rw_init}, {"pthread_rwlock_destroy", (void*)b_rw_destroy},
    {"pthread_rwlock_rdlock", (void*)b_rw_rdlock}, {"pthread_rwlock_wrlock", (void*)b_rw_wrlock},
    {"pthread_rwlock_unlock", (void*)b_rw_unlock},
    {"pthread_once", (void*)b_once},
    {"pthread_key_create", (void*)b_key_create}, {"pthread_key_delete", (void*)b_key_delete},
    {"pthread_getspecific", (void*)b_getspecific}, {"pthread_setspecific", (void*)b_setspecific},
    {"dl_iterate_phdr", (void*)b_dl_iterate_phdr},
    /* 内存/字符串 */
    {"malloc", (void*)malloc}, {"calloc", (void*)calloc}, {"realloc", (void*)realloc},
    {"free", (void*)free}, {"posix_memalign", (void*)posix_memalign},
    {"memchr", (void*)memchr}, {"memcmp", (void*)memcmp}, {"memcpy", (void*)memcpy},
    {"memmove", (void*)memmove}, {"memset", (void*)memset},
    {"wmemchr", (void*)wmemchr}, {"wmemcmp", (void*)wmemcmp}, {"wmemcpy", (void*)wmemcpy},
    {"wmemmove", (void*)wmemmove}, {"wmemset", (void*)wmemset},
    {"strcat", (void*)strcat}, {"strchr", (void*)strchr}, {"strcmp", (void*)strcmp},
    {"strcpy", (void*)strcpy}, {"strdup", (void*)strdup}, {"strncat", (void*)strncat},
    {"strncmp", (void*)strncmp}, {"strncpy", (void*)strncpy}, {"strnlen", (void*)strnlen},
    {"strrchr", (void*)strrchr}, {"strstr", (void*)strstr}, {"strlen", (void*)strlen},
    {"vsscanf", (void*)vsscanf},
    {"strcoll", (void*)strcoll}, {"strxfrm", (void*)strxfrm}, {"wcsxfrm", (void*)wcsxfrm},
    {"wcscoll", (void*)wcscoll}, {"wcslen", (void*)wcslen}, {"swprintf", (void*)swprintf},
    {"strtof", (void*)strtof}, {"strtod", (void*)strtod}, {"strtold", (void*)strtold},
    {"strtol", (void*)strtol}, {"strtoll", (void*)strtoll}, {"strtoul", (void*)strtoul},
    {"strtoull", (void*)strtoull},
    {"wcstod", (void*)wcstod}, {"wcstof", (void*)wcstof}, {"wcstold", (void*)wcstold},
    {"wcstol", (void*)wcstol}, {"wcstoll", (void*)wcstoll}, {"wcstoul", (void*)wcstoul},
    {"wcstoull", (void*)wcstoull},
    {"mbtowc", (void*)mbtowc}, {"mbrlen", (void*)mbrlen}, {"mbrtowc", (void*)mbrtowc},
    {"mbsrtowcs", (void*)mbsrtowcs}, {"mbsnrtowcs", (void*)mbsnrtowcs},
    {"wcrtomb", (void*)wcrtomb}, {"wcsnrtombs", (void*)wcsnrtombs},
    {"btowc", (void*)btowc}, {"wctob", (void*)wctob},
    /* ctype */
    {"isalnum", (void*)isalnum}, {"isalpha", (void*)isalpha}, {"ispunct", (void*)ispunct},
    {"isspace", (void*)isspace}, {"islower", (void*)islower}, {"isupper", (void*)isupper},
    {"isxdigit", (void*)isxdigit}, {"tolower", (void*)tolower}, {"toupper", (void*)toupper},
    {"iswalpha", (void*)iswalpha}, {"iswblank", (void*)iswblank}, {"iswcntrl", (void*)iswcntrl},
    {"iswdigit", (void*)iswdigit}, {"iswlower", (void*)iswlower}, {"iswprint", (void*)iswprint},
    {"iswpunct", (void*)iswpunct}, {"iswspace", (void*)iswspace}, {"iswupper", (void*)iswupper},
    {"iswxdigit", (void*)iswxdigit}, {"towlower", (void*)towlower}, {"towupper", (void*)towupper},
    /* 数学 */
    {"acosf", (void*)acosf}, {"acoshf", (void*)acoshf}, {"asinf", (void*)asinf},
    {"asinhf", (void*)asinhf}, {"atan2f", (void*)atan2f}, {"atanf", (void*)atanf},
    {"atanhf", (void*)atanhf}, {"cos", (void*)cos}, {"cosf", (void*)cosf}, {"coshf", (void*)coshf},
    {"erf", (void*)erf}, {"erfcf", (void*)erfcf}, {"erff", (void*)erff},
    {"exp", (void*)exp}, {"exp2", (void*)exp2}, {"expf", (void*)expf},
    {"fmodf", (void*)fmodf}, {"ldexpf", (void*)ldexpf}, {"log", (void*)log},
    {"log10", (void*)log10}, {"log10f", (void*)log10f}, {"log1pf", (void*)log1pf},
    {"log2", (void*)log2}, {"logf", (void*)logf}, {"pow", (void*)pow}, {"powf", (void*)powf},
    {"sin", (void*)sin}, {"sinf", (void*)sinf}, {"sinhf", (void*)sinhf},
    {"sincosf", (void*)hb_sincosf}, {"tanf", (void*)tanf}, {"tanhf", (void*)tanhf},
    /* locale */
    {"newlocale", (void*)newlocale}, {"freelocale", (void*)freelocale},
    {"uselocale", (void*)uselocale}, {"setlocale", (void*)setlocale},
    {"strtod_l", (void*)b_strtod_l}, {"strtof_l", (void*)b_strtof_l},
    {"strtold_l", (void*)b_strtold_l}, {"strtoll_l", (void*)b_strtoll_l},
    {"strtoul_l", (void*)b_strtoul_l}, {"strtoull_l", (void*)b_strtoull_l},
    {"strtol_l", (void*)b_strtol_l},
    /* FORTIFY */
    {"__strlen_chk", (void*)b_strlen_chk}, {"__strcpy_chk", (void*)b_strcpy_chk},
    {"__strcat_chk", (void*)b_strcat_chk}, {"__strncpy_chk", (void*)b_strncpy_chk},
    {"__stpcpy_chk", (void*)b_stpcpy_chk}, {"__memcpy_chk", (void*)b_memcpy_chk},
    {"__memmove_chk", (void*)b_memmove_chk}, {"__memset_chk", (void*)b_memset_chk},
    {"__strrchr_chk", (void*)b_strrchr_chk}, {"__read_chk", (void*)b_read_chk},
    {"__vsnprintf_chk", (void*)b_vsnprintf_chk}, {"__snprintf_chk", (void*)b_snprintf_chk},
    {"__vsprintf_chk", (void*)b_vsprintf_chk},
    {"__strncpy_chk2", (void*)b_strncpy_chk2},
    /* Android */
    {"__android_log_print", (void*)b_alp},
    {"__android_log_write", (void*)b_android_log_write},
    {"__system_property_get", (void*)b_system_property_get},
    {"android_set_abort_message", (void*)b_android_set_abort_message},
    {"android_get_device_api_level", (void*)b_android_api_level},
};

static hb_module* g_search_mods[8];
static int g_search_n = 0;

void hb_register_search_modules(hb_module** mods, int n) {
    g_search_n = n < 8 ? n : 8;
    for (int i = 0; i < g_search_n; i++) g_search_mods[i] = mods[i];
}

/* resolver：先查垫片表，再查已加载模块导出（libc++_shared 等） */
void* hb_resolve(const char* name, void* ctx) {
    (void)ctx;
    for (size_t i = 0; i < sizeof(SHIMS) / sizeof(SHIMS[0]); i++)
        if (!strcmp(SHIMS[i].name, name)) return SHIMS[i].fn;
    for (int i = 0; i < g_search_n; i++) {
        void* s = hb_sym(g_search_mods[i], name);
        if (s) return s;
    }
    return NULL;
}
#endif
