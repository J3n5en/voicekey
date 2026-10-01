#ifndef HB_ELFLOAD_H
#define HB_ELFLOAD_H
#include <stddef.h>
#include <stdint.h>

typedef struct hb_module hb_module;
/* 解析失败返回 NULL；找不到符号返回 NULL（弱符号由加载器写 0） */
typedef void* (*hb_resolver_t)(const char* name, void* ctx);

hb_module* hb_load(const char* path, hb_resolver_t resolver, void* ctx);
void* hb_sym(hb_module* m, const char* name);
void* hb_base(hb_module* m);
void* hb_stub_for(const char* name);
extern void (*g_prelock_hook)(hb_module*);
const char* hb_name(hb_module* m);
void hb_write_text(hb_module* m, uint64_t vaddr, uint32_t word);

/* 供 dl_iterate_phdr 垫片枚举已加载模块 */
typedef struct {
    uint64_t addr;
    const char* name;
    const void* phdr;
    uint16_t phnum;
} hb_modinfo;
void hb_modules(hb_modinfo* out, int max, int* n);
/* shims.c 提供 */
void hb_register_search_modules(hb_module** mods, int n);
void* hb_resolve(const char* name, void* ctx);

#endif
