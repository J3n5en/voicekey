#if defined(__aarch64__)
/* 极简 ELF64 加载器：映射段 → 重定位 → 跑 INIT/INIT_ARRAY
   仅支持本工程三个 .so（RELATIVE/ABS64/GLOB_DAT/JUMP_SLOT，无 TLS/IREL） */
#include "elfload.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef struct { unsigned char ident[16]; uint16_t type, machine; uint32_t version;
    uint64_t entry, phoff, shoff; uint32_t flags; uint16_t ehsize, phentsize, phnum,
    shentsize, shnum, shstrndx; } E64;
typedef struct { uint32_t type, flags; uint64_t offset, vaddr, paddr, filesz, memsz, align; } P64;
typedef struct { int64_t tag; uint64_t val; } D64;
typedef struct { uint32_t name; uint8_t info, other; uint16_t shndx; uint64_t value, size; } S64;
typedef struct { uint64_t offset, info; int64_t addend; } R64;

#define PT_LOAD 1
#define PT_DYNAMIC 2
#define DT_NULL 0
#define DT_INIT 12
#define DT_STRTAB 5
#define DT_SYMTAB 6
#define DT_RELA 7
#define DT_RELASZ 8
#define DT_JMPREL 23
#define DT_PLTRELSZ 2
#define DT_INIT_ARRAY 25
#define DT_INIT_ARRAYSZ 27
#define DT_HASH 4

#define R_AARCH64_ABS64 257
#define R_AARCH64_GLOB_DAT 1025
#define R_AARCH64_JUMP_SLOT 1026
#define R_AARCH64_RELATIVE 1027

#define HB_MAX_MODULES 16
struct hb_module {
    char name[256];
    uint8_t* base;
    uint64_t bias;      /* runtime = bias + vaddr */
    S64* symtab; int nsyms;
    const char* strtab;
    const P64* phdr; uint16_t phnum;
    uint64_t mapsz;
};
static hb_module* g_mods[HB_MAX_MODULES];
static int g_nmods = 0;
void (*g_prelock_hook)(hb_module*) = NULL;

static uint64_t align_up(uint64_t v, uint64_t a) { return (v + a - 1) & ~(a - 1); }

/* ---- tpidr_el0 → 栈金丝雀补丁 ----
   Android arm64 栈保护 = mrs Xt, tpidr_el0; ldr Xn, [Xt, #0x28]
   Darwin 的 tpidr_el0 是无关值 → 全部 mrs 补丁为 adrp Xt, <gap_page>
   金丝雀值放 gap 页 +0x28（bionic TLS slot 5） */
static uint8_t* find_gap_page(uint8_t* base, uint64_t minv, P64* ph, int phnum) {
    /* 第一个 LOAD 结束后的对齐空隙页 */
    uint64_t first_end = 0, second_start = ~0ULL;
    int loads = 0;
    for (int i = 0; i < phnum; i++) {
        if (ph[i].type != PT_LOAD) continue;
        if (loads == 0) first_end = align_up(ph[i].vaddr + ph[i].memsz, 0x1000);
        else if (ph[i].vaddr < second_start) second_start = ph[i].vaddr & ~0xfffUL;
        loads++;
    }
    if (loads < 2 || second_start - first_end < 0x1000) return NULL;
    return base + first_end - minv;
}

static int patch_tpidr(hb_module* m, P64* ph, uint64_t minv) {
    uint8_t* tls = find_gap_page(m->base, minv, ph, m->phnum);
    if (!tls) return 0;
    uint64_t canary = 0x9e3779b97f4a7c15ULL;  /* 固定值即可：只需每次读一致 */
    *(uint64_t*)(tls + 0x28) = canary;
    int patched = 0;
    for (int i = 0; i < m->phnum; i++) {
        if (ph[i].type != PT_LOAD || !(ph[i].flags & 1)) continue;
        uint64_t start = ph[i].vaddr & ~0xfffUL;
        uint64_t end = (ph[i].vaddr + ph[i].filesz) & ~0xfffUL;
        for (uint64_t va = start; va < end; va += 4) {
            uint32_t* w = (uint32_t*)(m->base + va - minv);
            if ((*w & 0xffffffe0) != 0xd53bd040) continue;   /* mrs Xt, tpidr_el0 */
            unsigned rt = *w & 0x1f;
            uint64_t pc = (uint64_t)w & ~0xfffUL;
            int64_t imm = ((int64_t)((uintptr_t)tls) - (int64_t)pc) >> 12;
            if (imm < -(1 << 20) || imm >= (1 << 20)) continue;
            uint32_t adrp = 0x90000000u | ((uint32_t)(imm & 3) << 29) |
                            ((uint32_t)((uint64_t)imm >> 2) << 5) | rt;
            *w = adrp;
            patched++;
        }
    }
    return patched;
}

hb_module* hb_load(const char* path, hb_resolver_t resolver, void* ctx) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { fprintf(stderr, "[elf] open %s: %s\n", path, strerror(errno)); return NULL; }
    size_t sz = (size_t)lseek(fd, 0, SEEK_END);
    lseek(fd, 0, SEEK_SET);
    uint8_t* file = malloc(sz);
    if (read(fd, file, sz) != (ssize_t)sz) { close(fd); free(file); return NULL; }
    close(fd);

    E64* eh = (E64*)file;
    if (memcmp(eh->ident, "\x7f""ELF", 4) || eh->ident[4] != 2 || eh->machine != 183) {
        fprintf(stderr, "[elf] %s: not ELF64 arm64\n", path); free(file); return NULL;
    }
    P64* ph = (P64*)(file + eh->phoff);
    uint64_t minv = ~0ULL, maxv = 0;
    for (int i = 0; i < eh->phnum; i++) {
        if (ph[i].type != PT_LOAD) continue;
        if (ph[i].vaddr < minv) minv = ph[i].vaddr;
        if (ph[i].vaddr + ph[i].memsz > maxv) maxv = ph[i].vaddr + ph[i].memsz;
    }
    uint64_t total = align_up(maxv - minv, 0x1000);
    /* 固定基址（调试可复现；0x200000000 起每位次隔 0x2000000） */
    static uint64_t next_fixed = 0x200000000;
    uint8_t* base = MAP_FAILED;
    while (base == MAP_FAILED && next_fixed < 0x300000000) {
        base = mmap((void*)next_fixed, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        next_fixed += 0x2000000;
    }
    if (base == MAP_FAILED)
        base = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (base == MAP_FAILED) { perror("mmap"); free(file); return NULL; }
    for (int i = 0; i < eh->phnum; i++) {
        if (ph[i].type != PT_LOAD) continue;
        memcpy(base + ph[i].vaddr - minv, file + ph[i].offset, ph[i].filesz);
    }
    uint64_t bias = (uint64_t)base - minv;
    uint64_t eh_phoff = eh->phoff;

    /* 先建模块壳再补丁（patch_tpidr 需要 m->phnum） */

    hb_module* m = calloc(1, sizeof(*m));
    snprintf(m->name, sizeof(m->name), "%s", strrchr(path, '/') ? strrchr(path, '/') + 1 : path);
    m->base = base; m->bias = bias; m->mapsz = total;
    m->phdr = (const P64*)(base + eh_phoff - minv); m->phnum = eh->phnum;
    m->base = base; m->bias = bias;
    int n_tpidr = patch_tpidr(m, ph, minv);
    fprintf(stderr, "[elf] %s tpidr patches: %d\n", m->name, n_tpidr);

    /* dynamic */
    D64* dyn = NULL;
    for (int i = 0; i < eh->phnum; i++)
        if (ph[i].type == PT_DYNAMIC) dyn = (D64*)(base + ph[i].vaddr - minv);
    S64* symtab = NULL; const char* strtab = NULL;
    R64* rela = NULL; uint64_t relasz = 0;
    R64* jmprel = NULL; uint64_t jmprelsz = 0;
    uint64_t init = 0, initarr = 0, initarrsz = 0, hashoff = 0;
    for (D64* d = dyn; d->tag != DT_NULL; d++) {
        switch (d->tag) {
            case DT_SYMTAB: symtab = (S64*)(base + d->val - minv); break;
            case DT_STRTAB: strtab = (const char*)(base + d->val - minv); break;
            case DT_RELA: rela = (R64*)(base + d->val - minv); break;
            case DT_RELASZ: relasz = d->val; break;
            case DT_JMPREL: jmprel = (R64*)(base + d->val - minv); break;
            case DT_PLTRELSZ: jmprelsz = d->val; break;
            case DT_INIT: init = d->val; break;
            case DT_INIT_ARRAY: initarr = d->val; break;
            case DT_INIT_ARRAYSZ: initarrsz = d->val; break;
            case DT_HASH: hashoff = d->val; break;
        }
    }
    m->symtab = symtab; m->strtab = strtab;
    m->nsyms = (int)((const uint8_t*)strtab - (const uint8_t*)symtab) / sizeof(S64);
    if (hashoff) {  /* DT_HASH nchain 更准 */
        uint32_t nchain = *(uint32_t*)(base + hashoff - minv + 4);
        if (nchain > 0 && (int)nchain <= m->nsyms) m->nsyms = (int)nchain;
    }

    /* 重定位 */
    int unresolved = 0;
    for (int pass = 0; pass < 2; pass++) {
        R64* rs = pass ? jmprel : rela;
        uint64_t n = (pass ? jmprelsz : relasz) / sizeof(R64);
        if (!rs || !n) continue;
        for (uint64_t k = 0; k < n; k++) {
            uint64_t off = rs[k].offset, info = rs[k].info;
            int64_t add = rs[k].addend;
            uint64_t slot = bias + off;
            unsigned type = info & 0xffffffff;
            unsigned symi = info >> 32;
            if (type == R_AARCH64_RELATIVE) {
                *(uint64_t*)slot = bias + add;
            } else if (type == R_AARCH64_ABS64 || type == R_AARCH64_GLOB_DAT ||
                       type == R_AARCH64_JUMP_SLOT) {
                uint64_t s = 0;
                if (symi) {
                    S64* sym = &symtab[symi];
                    const char* nm = strtab + sym->name;
                    if (sym->shndx) {
                        s = m->bias + sym->value;   /* 本模块定义 */
                    } else {
                        void* found = resolver(nm, ctx);
                        if (!found) {
                            if ((sym->info >> 4) == 2) { s = 0; }  /* WEAK */
                            else { s = (uint64_t)hb_stub_for(nm); unresolved++; }
                        } else s = (uint64_t)found;
                    }
                }
                *(uint64_t*)slot = s + add;
            } else if (type) {
                fprintf(stderr, "[elf] %s: unhandled reloc type %u\n", m->name, type);
            }
        }
    }

    /* 锁定 RX 前的补丁钩子（之后代码签名会锁页） */
    if (g_prelock_hook) g_prelock_hook(m);
    /* 段权限：可执行段 → RX */
    for (int i = 0; i < eh->phnum; i++) {
        if (ph[i].type != PT_LOAD || !(ph[i].flags & 1)) continue;
        uint64_t s = ph[i].vaddr & ~0xfffUL;
        uint64_t e = (ph[i].vaddr + ph[i].filesz + 0xfff) & ~0xfffUL;
        if (mprotect(base + s - minv, e - s, PROT_READ | PROT_EXEC))
            fprintf(stderr, "[elf] mprotect RX fail %s seg%d: %s\n", m->name, i, strerror(errno));
    }
    free(file);

    g_mods[g_nmods++] = m;

    /* 构造器 */
    fprintf(stderr, "[elf] %s base=%p syms=%d relocs=%llu (%d unresolved->stub) init=%llx arr=%llx/%llu\n",
            m->name, base, m->nsyms, (unsigned long long)((relasz + jmprelsz) / 24), unresolved,
            (unsigned long long)init, (unsigned long long)initarr, (unsigned long long)(initarrsz / 8));
    if (init) ((void (*)(void))(bias + init))();
    if (initarrsz) {
        uint64_t* arr = (uint64_t*)(bias + initarr);
        for (uint64_t k = 0; k < initarrsz / 8; k++) {
            fprintf(stderr, "[elf] %s ctor[%llu] @%llx\n", m->name, (unsigned long long)k, (unsigned long long)arr[k]);
            ((void (*)(void))arr[k])();
        }
    }
    return m;
}

void* hb_sym(hb_module* m, const char* name) {
    if (!m) return NULL;
    for (int i = 0; i < m->nsyms; i++) {
        S64* s = &m->symtab[i];
        if (s->shndx && s->name && !strcmp(m->strtab + s->name, name))
            return (void*)(m->bias + s->value);
    }
    return NULL;
}

void* hb_base(hb_module* m) { return m ? (void*)m->base : NULL; }

const char* hb_name(hb_module* m) { return m ? m->name : ""; }
void hb_write_text(hb_module* m, uint64_t vaddr, uint32_t word) {
    if (!m) return;
    uint32_t* p = (uint32_t*)(m->bias + vaddr);
    uint64_t pg = (uint64_t)p & ~0xfffUL;
    mprotect((void*)pg, 0x2000, PROT_READ | PROT_WRITE);
    *p = word;
    mprotect((void*)pg, 0x2000, PROT_READ | PROT_EXEC);
}

void hb_modules(hb_modinfo* out, int max, int* n) {
    int c = 0;
    for (int i = 0; i < g_nmods && c < max; i++) {
        out[c].addr = g_mods[i]->bias;
        out[c].name = g_mods[i]->name;
        out[c].phdr = g_mods[i]->phdr;
        out[c].phnum = g_mods[i]->phnum;
        c++;
    }
    *n = c;
}

/* 未解析符号 → 统一零返回桩（Cronet 等 work_mode=2 不会调） */
static long generic_stub(void) { return 0; }
typedef struct { const char* name; void* fn; } stubent_t;
static stubent_t g_stubs[2048];
static int g_nstubs = 0;
void* hb_stub_for(const char* name) {
    for (int i = 0; i < g_nstubs; i++)
        if (!strcmp(g_stubs[i].name, name)) return g_stubs[i].fn;
    if (g_nstubs >= 2048) return (void*)generic_stub;
    g_stubs[g_nstubs].name = strdup(name);
    g_stubs[g_nstubs].fn = (void*)generic_stub;
    fprintf(stderr, "[elf] STUB %s\n", name);
    g_nstubs++;
    return (void*)generic_stub;
}
#endif
