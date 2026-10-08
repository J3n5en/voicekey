#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// 识别事件：0 中间结果（整句覆盖），1 定稿，2 错误
typedef enum { VK_EVENT_PARTIAL = 0, VK_EVENT_FINAL = 1, VK_EVENT_ERROR = 2 } vk_event_kind;

/// 在 Rust 工作线程上调用；text 仅在回调期间有效
typedef void (*vk_event_fn)(void *ctx, int32_t kind, const char *text);
typedef void (*vk_release_fn)(void *ctx);

typedef struct VKSession VKSession;

const char *vk_version(void);

/// engine: doubao / wetype / qwen / baidu / sogou / iflytek；sample_rate 为后续推送的单声道 f32 采样率。
/// 成功后保证恰好一次 FINAL 或 ERROR 事件，之后调用 release(ctx)（可为 NULL）。
/// 参数无效返回 NULL，此时不会调用 on_event / release。
VKSession *vk_session_start(const char *engine, uint32_t sample_rate, vk_event_fn on_event, vk_release_fn release, void *ctx);
/// 推送音频，线程安全；finish 之后的推送被忽略
void vk_session_push(const VKSession *session, const float *pcm, size_t n);
/// 说完：冲刷尾帧并关闭音频流，定稿经回调返回；可重复调用
void vk_session_finish(const VKSession *session);
/// 释放句柄（未 finish 则先 finish），不影响进行中的识别和回调
void vk_session_free(VKSession *session);

/// 用 wav 文件按实时速度识别一次，事件与 release 约定同 vk_session_start；参数无效返回 false
bool vk_run_file(const char *engine, const char *path, vk_event_fn on_event, vk_release_fn release, void *ctx);
/// 预热渠道（建连、取凭据等），引擎名无效返回 false
bool vk_prewarm(const char *engine);
