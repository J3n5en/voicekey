#if defined(__aarch64__)
/* hanbao：脱离 Docker，在 macOS 进程内直跑安卓 libaudioeffect.so 离线 ASR */
#include "elfload.h"
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef int (*create_fn)(void*, int, void*);
typedef int (*process_fn)(void*, void*);
typedef int (*destroy_fn)(void*);
static create_fn f_create;
static process_fn f_process;
static destroy_fn f_destroy;
static char g_model_path[512];

#define IDENT_ASR_V2 670
#define DT_AUDIOBIN 0x1f8
#define DT_SERVER_EVENT 600

typedef struct {
    volatile int final;
    char text[4096];
    pthread_mutex_t mu;
} req_state;

typedef struct {
    void* fn[5];
    void* pad1, *pad2;
    void* ctx;
} listener_t;

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void set_text(req_state* st, const char* s, size_t n) {
    pthread_mutex_lock(&st->mu);
    if (n >= sizeof(st->text)) n = sizeof(st->text) - 1;
    memcpy(st->text, s, n);
    st->text[n] = 0;
    pthread_mutex_unlock(&st->mu);
}

static void parse_event(req_state* st, const char* js) {
    static int evlog = -1;
    if (evlog < 0) evlog = getenv("HB_EVLOG") != NULL;
    if (evlog) fprintf(stderr, "[ev] %s\n", js);
    /*
     * 流式事件 results 有两项：[0] 整段累计（每 20s 窗口结束时已二遍校正），[1] 当前窗口；
     * 收尾的二遍结果只有一项，以此判定最终结果（end_time 跟着喂入进度走，不能用来判定）
     */
    const char* p = strstr(js, "\"text\":\"");
    if (!p) return;
    const char* v = p + 8;
    char buf[4096];
    size_t i = 0;
    while (*v && i < sizeof(buf) - 1) {
        if (*v == '\\' && v[1]) { buf[i++] = v[1]; v += 2; }
        else if (*v == '"') break;
        else buf[i++] = *v++;
    }
    set_text(st, buf, i);
    if (!strstr(p + 8, "\"text\":\"")) st->final = 1;
}

static void on_cb(void* block, void* ctx) {
    req_state* st = (req_state*)ctx;
    if (!st || !block) return;
    int dtype = *(int*)((char*)block + 0);
    if (dtype != DT_SERVER_EVENT) return;
    int n = *(int*)((char*)block + 4);
    if (n <= 0 || n > 64) return;
    char* ev = *(char**)((char*)block + 8);
    if (!ev) return;
    for (int i = 0; i < n; i++) {
        char* js = *(char**)(ev + i * 0x40 + 0x30);
        if (js && *js) parse_event(st, js);
    }
}

/* param 布局（0xf8） */
typedef struct { unsigned char raw[0xf8]; } asr_param_t;
/* 喂音 block */
typedef struct { int dtype; int len; const void* pcm; void* uc; const char* extra; } feed_blk_t;

static void msleep(long ms) {
    struct timespec t = {ms / 1000, (ms % 1000) * 1000000};
    nanosleep(&t, NULL);
}

static unsigned char* read_file(const char* path, size_t* out) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return NULL; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char* b = malloc(sz);
    if (fread(b, 1, sz, f) != (size_t)sz) { fclose(f); free(b); return NULL; }
    fclose(f);
    *out = sz;
    return b;
}

/* 调试钩子：在 vsnprintf 调用点植 brk（HB_TRAP=1 启用） */
static void trap_hook(hb_module* m) {
    if (strcmp(hb_name(m), "libaudioeffect.so")) return;
    uint32_t* p = (uint32_t*)((char*)hb_base((hb_module*)m) + 0xd7a30);
    *p = 0xd42000e0;  /* brk #0xe0 */
}

/* ---------------- 识别会话：open → feed* → finish → close ---------------- */
typedef struct {
    void* handle;
    listener_t lis;
    req_state st;
    unsigned char pend[3200];
    size_t pend_n;
    long t0;
} asr_sess;

static int sess_open(asr_sess* s) {
    memset(s, 0, sizeof(*s));
    pthread_mutex_init(&s->st.mu, NULL);
    for (int i = 0; i < 5; i++) s->lis.fn[i] = (void*)on_cb;
    s->lis.ctx = &s->st;

    static const char* empty = "";
    asr_param_t p;
    memset(&p, 0, sizeof(p));
    *(char**)(p.raw + 0x08) = (char*)empty;        /* url 非空 */
    *(char**)(p.raw + 0x28) = NULL;                /* appKey 可空 */
    *(char**)(p.raw + 0x40) = (char*)empty;        /* token 空串 */
    *(int*)(p.raw + 0x50) = 16000;
    *(int*)(p.raw + 0x54) = 1;
    *(char**)(p.raw + 0x60) = (char*)"zh-CN";
    *(void**)(p.raw + 0xa8) = &s->lis;             /* 监听器必非空 */
    *(int*)(p.raw + 0xe0) = 10;                    /* frame_time_ms */
    *(int*)(p.raw + 0xe8) = 2;                     /* work_mode=2 离线（跳过 TTNet） */
    *(char**)(p.raw + 0xf0) = (char*)g_model_path;

    s->t0 = now_ms();
    int ret = f_create(&s->handle, IDENT_ASR_V2, &p);
    if (ret != 0 || !s->handle) {
        fprintf(stderr, "[hanbao] create ret=%d\n", ret);
        pthread_mutex_destroy(&s->st.mu);
        s->handle = NULL;
        return -1;
    }
    fprintf(stderr, "[hanbao] create ret=0 (%ldms)\n", now_ms() - s->t0);
    return 0;
}

/* 喂音：3200B/100ms 帧（HB_PACE_MS 调速，默认 25ms）；不足一帧的尾块留到下次 */
static void sess_feed(asr_sess* s, const unsigned char* src, size_t left) {
    feed_blk_t blk;
    static long pm = -1;
    if (pm < 0) { const char* e = getenv("HB_PACE_MS"); pm = e ? atol(e) : 25; }
    while (left) {
        size_t take = 3200 - s->pend_n < left ? 3200 - s->pend_n : left;
        memcpy(s->pend + s->pend_n, src, take);
        s->pend_n += take; src += take; left -= take;
        if (s->pend_n == 3200) {
            blk.dtype = DT_AUDIOBIN; blk.len = 3200; blk.pcm = s->pend; blk.uc = NULL; blk.extra = NULL;
            f_process(s->handle, &blk);
            s->pend_n = 0;
            if (pm) msleep(pm);
        }
    }
}

/*
 * 补 0.5s 静音 → finish_audio 挂在最后一块真实音频上（len=0 的空块引擎会忽略，二遍不跑）
 * → 等非流式二遍结果（见 parse_event）。
 * 全程没识别出字时引擎不发二遍事件，0.8s 即返回空；有字但二遍迟迟不来则 3s 后用流式结果兜底。
 */
static void sess_finish(asr_sess* s) {
    static const unsigned char pad[16000];
    req_state* st = &s->st;
    feed_blk_t blk;
    sess_feed(s, pad, sizeof(pad));
    memset(s->pend + s->pend_n, 0, 3200 - s->pend_n);
    blk.dtype = DT_AUDIOBIN; blk.len = 3200; blk.pcm = s->pend; blk.uc = NULL;
    blk.extra = "{\"finish_audio\":true}";
    st->final = 0;
    f_process(s->handle, &blk);
    s->pend_n = 0;

    long t_fin = now_ms();
    static long qm = -1;
    if (qm < 0) { const char* e = getenv("HB_QUIET_MS"); qm = e ? atol(e) : 20; }
    while (!st->final) {
        int has_text;
        pthread_mutex_lock(&st->mu);
        has_text = st->text[0] != 0;
        pthread_mutex_unlock(&st->mu);
        if (now_ms() - t_fin > (has_text ? 3000 : 800)) break;
        if (qm) msleep(qm);
    }
}

static char* sess_text(asr_sess* s) {
    pthread_mutex_lock(&s->st.mu);
    char* txt = strdup(s->st.text);
    pthread_mutex_unlock(&s->st.mu);
    return txt;
}

static void sess_close(asr_sess* s) {
    if (!s->handle) return;
    f_destroy(s->handle);
    s->handle = NULL;
    pthread_mutex_destroy(&s->st.mu);
}

/* ---------------- 一次性 ASR：返回 malloc 文本 ---------------- */
static char* run_asr(const unsigned char* pcm, size_t pcmn, long* out_ms) {
    if (pcmn > 44 && !memcmp(pcm, "RIFF", 4)) { pcm += 44; pcmn -= 44; }
    fprintf(stderr, "[hanbao] audio %zu bytes (%.1fs)\n", pcmn, pcmn / 32000.0);
    asr_sess s;
    if (sess_open(&s)) return NULL;
    sess_feed(&s, pcm, pcmn);
    sess_finish(&s);
    if (out_ms) *out_ms = now_ms() - s.t0;
    char* txt = sess_text(&s);
    sess_close(&s);
    return txt;
}

/* ---------------- JSON 转义 + base64 ---------------- */
static void jput(FILE* f, const char* s) {
    fputc('"', f);
    for (; *s; s++) {
        if ((unsigned char)*s < 0x20 || *s == '"' || *s == '\\') fprintf(f, "\\u%04x", (unsigned char)*s);
        else fputc(*s, f);
    }
    fputc('"', f);
}

static int b64val(int c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}
/* 解码行内 "b64":"..." 字段，返回 malloc 缓冲（长度>=min 时有效） */
static unsigned char* extract_b64(const char* line, size_t* outn) {
    const char* k = strstr(line, "\"b64\":\"");
    if (!k) return NULL;
    k += 7;
    const char* e = strchr(k, '"');
    if (!e) return NULL;
    size_t n = e - k, o = 0;
    unsigned char* out = malloc(n / 4 * 3 + 3);
    int acc = 0, bits = 0;
    for (size_t i = 0; i < n; i++) {
        if (k[i] == '=') break;
        int v = b64val((unsigned char)k[i]);
        if (v < 0) { free(out); return NULL; }
        acc = (acc << 6) | v; bits += 6;
        if (bits >= 8) { bits -= 8; out[o++] = (unsigned char)(acc >> bits); }
    }
    *outn = o;
    return out;
}
static long extract_id(const char* line, long dflt) {
    const char* k = strstr(line, "\"id\":");
    if (!k) return dflt;
    return atol(k + 5);
}

/* ---------------- pipe 模式：stdin JSON-lines → stdout JSON-lines ---------------- */
static void reply_text(long id, long ms, const char* txt) {
    printf("{\"ok\":true,\"id\":%ld,\"ms\":%ld,\"text\":", id, ms);
    jput(stdout, txt);
    fputs("}\n", stdout);
    fflush(stdout);
}

static void reply_err(long id, const char* err) {
    printf("{\"ok\":false,\"id\":%ld,\"error\":\"%s\"}\n", id, err);
    fflush(stdout);
}

static int pipe_mode(const char* model) {
    extern int hb_pipe_stdout_err;
    hb_pipe_stdout_err = 1;
    snprintf(g_model_path, sizeof(g_model_path), "%s", model);
    fprintf(stderr, "[hanbao] pipe mode, model=%s\n", g_model_path);
    char* line = NULL;
    size_t cap = 0;
    ssize_t len;
    long next_id = 1;
    /* 流式会话（同一时刻至多一个）：begin → chunk*（每次回当前中间结果）→ end | cancel */
    static asr_sess live;
    int live_open = 0;
    while ((len = getline(&line, &cap, stdin)) > 0) {
        if (strstr(line, "\"op\":\"ping\"")) {
            printf("{\"ok\":true,\"pong\":true}\n"); fflush(stdout);
        } else if (strstr(line, "\"op\":\"shutdown\"")) {
            if (live_open) sess_close(&live);
            printf("{\"ok\":true}\n"); fflush(stdout);
            free(line);
            return 0;
        } else if (strstr(line, "\"op\":\"begin\"")) {
            long id = extract_id(line, next_id++);
            if (live_open) sess_close(&live);
            live_open = sess_open(&live) == 0;
            if (live_open) reply_text(id, now_ms() - live.t0, "");
            else reply_err(id, "engine");
        } else if (strstr(line, "\"op\":\"chunk\"")) {
            long id = extract_id(line, next_id++);
            size_t bn = 0;
            unsigned char* b = extract_b64(line, &bn);
            if (!live_open) reply_err(id, "no session");
            else if (!b) reply_err(id, "bad b64");
            else {
                sess_feed(&live, b, bn);
                char* txt = sess_text(&live);
                reply_text(id, now_ms() - live.t0, txt);
                free(txt);
            }
            free(b);
        } else if (strstr(line, "\"op\":\"end\"")) {
            long id = extract_id(line, next_id++);
            if (!live_open) { reply_err(id, "no session"); continue; }
            sess_finish(&live);
            char* txt = sess_text(&live);
            sess_close(&live);
            live_open = 0;
            reply_text(id, now_ms() - live.t0, txt);
            free(txt);
        } else if (strstr(line, "\"op\":\"cancel\"")) {
            long id = extract_id(line, next_id++);
            if (live_open) sess_close(&live);
            live_open = 0;
            reply_text(id, 0, "");
        } else if (strstr(line, "\"op\":\"asr\"")) {
            size_t bn = 0;
            unsigned char* b = extract_b64(line, &bn);
            if (!b || bn < 160) {
                printf("{\"ok\":false,\"error\":\"bad b64\"}\n"); fflush(stdout);
                free(b);
                continue;
            }
            long id = extract_id(line, next_id++);
            long ms = 0;
            char* txt = run_asr(b, bn, &ms);
            free(b);
            if (!txt) { printf("{\"ok\":false,\"error\":\"engine\"}\n"); fflush(stdout); continue; }
            fputs("{\"ok\":true,\"id\":", stdout);
            printf("%ld,\"ms\":%ld,\"text\":", id, ms);
            jput(stdout, txt);
            fputs("}\n", stdout);
            fflush(stdout);
            free(txt);
        } else {
            printf("{\"ok\":false,\"error\":\"bad op\"}\n"); fflush(stdout);
        }
    }
    free(line);
    return 0;
}

int hanbao_main(int argc, char** argv) {
    const char* libdir = getenv("HB_LIBDIR");
    if (!libdir || !*libdir) libdir = argc > 3 ? argv[3] : "libs";
    extern void (*g_prelock_hook)(hb_module*);
    if (getenv("HB_TRAP")) g_prelock_hook = trap_hook;
    char path[512];

    hb_module* mods[3];
    snprintf(path, sizeof(path), "%s/libc++_shared.so", libdir);
    mods[0] = hb_load(path, hb_resolve, NULL);
    hb_register_search_modules(mods, 1);
    snprintf(path, sizeof(path), "%s/libiesapplogger.so", libdir);
    mods[1] = hb_load(path, hb_resolve, NULL);
    hb_register_search_modules(mods, 2);
    snprintf(path, sizeof(path), "%s/libaudioeffect.so", libdir);
    mods[2] = hb_load(path, hb_resolve, NULL);
    hb_register_search_modules(mods, 3);
    if (!mods[0] || !mods[1] || !mods[2]) return 1;

    f_create = (create_fn)hb_sym(mods[2], "SAMICoreCreateHandleByIdentify");
    f_process = (process_fn)hb_sym(mods[2], "SAMICoreProcess");
    f_destroy = (destroy_fn)hb_sym(mods[2], "SAMICoreDestroyHandle");
    if (!f_create || !f_process || !f_destroy) return 1;

    if (argc > 1 && !strcmp(argv[1], "--pipe")) {
        const char* model = argc > 2 ? argv[2] : "model.flute";
        return pipe_mode(model);
    }

    /* CLI 模式：hanbao model.flute file.wav */
    const char* model_path = argc > 1 ? argv[1] : "model.flute";
    const char* wav_path = argc > 2 ? argv[2] : "test.wav";
    snprintf(g_model_path, sizeof(g_model_path), "%s", model_path);

    size_t wsn;
    unsigned char* wav = read_file(wav_path, &wsn);
    if (!wav) return 1;
    long ms = 0;
    char* txt = run_asr(wav, wsn, &ms);
    free(wav);
    if (!txt) return 1;
    fprintf(stderr, "[hanbao] done in %ldms\n", ms);
    printf("%s\n", txt);
    free(txt);
    return 0;
}
#endif
