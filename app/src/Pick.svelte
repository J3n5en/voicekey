<script lang="ts">
  import { onMount, tick } from "svelte";
  import { call, on, applyLook, diffMark, esc, CH, type AppInfo, type Model, type Settings } from "./lib/api";
  import ChIcon from "./lib/ChIcon.svelte";
  import Wave from "./lib/Wave.svelte";

  let model = $state<Model>({ recording: false, rows: [], sel: 0 });
  let level = $state(0);
  let shake = $state(-1);
  let platform = $state("mac");
  let root: HTMLDivElement;
  const drafts = new Map<string, string>();
  const finals = new Map<string, string>();

  const waiting = $derived(model.rows.filter((r) => r.state === "wait" || r.state === "listen").length);
  const done = $derived(model.rows.filter((r) => r.state === "final").length);
  // 路数越多单条越矮，长文本在条目内滚动，避免把后面的候选顶出屏幕
  const lines = $derived(model.rows.length <= 2 ? 8 : model.rows.length === 3 ? 5 : 4);
  const streaming = new Set<string>();

  function receive(m: Model) {
    if (m.recording && m.rows.every((r) => !r.text || r.state === "skip")) {
      drafts.clear();
      finals.clear();
    }
    for (const r of m.rows) {
      if (r.state === "final") {
        if (!finals.has(r.channel)) finals.set(r.channel, diffMark(drafts.get(r.channel) ?? "", r.text));
      } else {
        drafts.set(r.channel, r.text);
        finals.delete(r.channel);
      }
    }
    model = m;
    report();
  }

  async function report() {
    await tick();
    if (!root) return;
    for (const node of root.querySelectorAll(".text")) {
      if (!(node instanceof HTMLElement)) continue;
      const ch = node.dataset.ch ?? "";
      if (node.classList.contains("live")) {
        node.scrollTop = node.scrollHeight;
        streaming.add(ch);
      } else if (streaming.delete(ch)) node.scrollTop = 0;
    }
    // 窗口被工作区卡住时，面板可见高度小于内容高度，用列表 scrollHeight 量自然高度
    const list = root.querySelector(".rows");
    const box = root.getBoundingClientRect().height;
    const natural = list instanceof HTMLElement ? box - list.getBoundingClientRect().height + list.scrollHeight : box;
    // 10px 上下边距，再留 8px 给缩放取整
    call("pick_resize", { height: Math.ceil(natural) + 28 });
  }

  onMount(() => {
    call<AppInfo>("get_state").then((i) => {
      platform = i.platform;
      applyLook(i.platform, i.settings.theme);
    });
    // 面板仅在安全输入开启时取得焦点，此时由这里接收选择按键
    const onKey = (e: KeyboardEvent) => {
      if (e.repeat || e.metaKey || e.ctrlKey || e.altKey) return;
      e.preventDefault();
      call("pick_key", { key: e.key });
    };
    window.addEventListener("keydown", onKey);
    const un = [
      on<Model>("pick", receive),
      on<number>("level", (v) => (level = v)),
      on<Settings>("settings", (s) => applyLook(platform, s.theme)),
      on<number>("pick-shake", (i) => {
        shake = -1;
        tick().then(() => (shake = i));
      }),
    ];
    return () => {
      window.removeEventListener("keydown", onKey);
      un.forEach((p) => p.then((f) => f()));
    };
  });
</script>

<div class="pick" bind:this={root} style:--lines={lines}>
  <div class="hd">
    {#if model.recording}<span class="rec"></span>{/if}
    <div class="wave"><Wave level={model.recording ? level : 0} idle={!model.recording} height={26} /></div>
    <span class="state">
      {#if model.recording}聆听中 · 松开结束
      {:else if model.jev === "busy"}<span class="spinner"></span>Jev 智能选择中 · 可手选
      {:else if model.jev === "failed"}<span class="err">智能选择失败，请手动选择</span>
      {:else if waiting}<span class="spinner"></span>定稿中 {done}/{model.rows.length}
      {:else}<span class="ok">● 全部完成</span>{/if}
    </span>
    <button class="close" title="关闭（Esc）" aria-label="关闭" onclick={() => call("pick_key", { key: "Escape" })}>
      <svg viewBox="0 0 12 12" width="10" height="10"><path d="M2 2l8 8M10 2l-8 8" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" /></svg>
    </button>
  </div>
  <div class="rows">
  {#each model.rows as r, i (r.channel)}
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="row" class:active={i === model.sel} class:shake={i === shake} onclick={() => call("pick_choose", { index: i })}>
      <span class="num">{i + 1}</span>
      <span class="name"><span class="sdot s-{r.state}"></span><ChIcon ch={r.channel} size="xs" />{CH[r.channel].short}</span>
      <div
        class="text"
        class:live={r.state === "listen" || r.state === "wait"}
        class:muted={r.state === "skip" || r.state === "error" || !r.text}
        class:bad={r.state === "error"}
        data-ch={r.channel}
      >
        {#if r.state === "final"}
          {@html finals.get(r.channel) ?? esc(r.text)}
        {:else}
          {r.text}{#if r.state === "listen" || r.state === "wait"}<span class="cur"></span>{/if}
        {/if}
      </div>
      <span class="meta">
        {#if r.state === "wait"}<span class="spinner"></span>{:else if r.ms != null}{(r.ms / 1000).toFixed(2)}s{/if}
      </span>
    </div>
  {/each}
  </div>
  <div class="ft">
    <span><kbd>1-{model.rows.length}</kbd>选择</span><span><kbd>↑↓</kbd>切换</span><span><kbd>↵</kbd>上屏</span><span><kbd>Esc</kbd>取消</span>
    {#if model.recording}<span class="tip">可提前预选</span>{/if}
  </div>
</div>

<style>
  .pick {
    margin: 10px; width: calc(100% - 20px); max-height: calc(100vh - 20px); display: flex; flex-direction: column;
    border-radius: 14px; background: var(--pop); backdrop-filter: blur(36px) saturate(1.8);
    -webkit-backdrop-filter: blur(36px) saturate(1.8); box-shadow: 0 2px 8px rgba(20, 20, 50, 0.12); border: 1px solid var(--line); overflow: hidden;
  }
  :global(.win) .pick { border-radius: 8px; }
  .hd { display: flex; align-items: center; gap: 10px; padding: 9px 12px 7px 14px; flex: none; }
  .rows { min-height: 0; overflow-y: auto; scrollbar-width: thin; }
  .wave { flex: 1; min-width: 0; }
  .rec { width: 8px; height: 8px; border-radius: 50%; background: var(--err); animation: pulse 1.2s infinite; flex: none; }
  .state { font-size: 11.5px; color: var(--fg2); white-space: nowrap; display: flex; align-items: center; gap: 6px; }
  .close { flex: none; width: 20px; height: 20px; margin-right: -4px; border: 0; border-radius: 6px; background: transparent; color: var(--fg3); display: grid; place-items: center; cursor: pointer; padding: 0; }
  .close:hover { background: color-mix(in srgb, var(--fg) 10%, transparent); color: var(--fg); }
  .row { display: flex; align-items: flex-start; gap: 10px; padding: 9px 12px 9px 14px; cursor: pointer; position: relative; border-top: 1px solid var(--line); }
  .row.active { background: color-mix(in srgb, var(--accent) 14%, transparent); }
  .row.active::before { content: ""; position: absolute; left: 0; top: 8px; bottom: 8px; width: 3px; border-radius: 0 2px 2px 0; background: var(--accent); }
  .row.shake { animation: shake 0.3s; }
  .num { width: 18px; height: 18px; border-radius: 5px; border: 1px solid var(--line); font-size: 11px; display: grid; place-items: center; color: var(--fg2); flex: none; margin-top: 2px; }
  .row.active .num { background: var(--accent); color: #fff; border-color: transparent; }
  .name { width: 88px; flex: none; font-size: 12px; color: var(--fg2); margin-top: 2px; display: flex; align-items: center; gap: 6px; white-space: nowrap; }
  .text {
    flex: 1; font-size: 14px; line-height: 1.55; min-height: 22px; max-height: calc(1.55em * var(--lines, 4));
    overflow-y: auto; scrollbar-width: thin; word-break: break-all; -webkit-user-select: text; user-select: text;
  }
  .text.muted { color: var(--fg3); font-size: 13px; }
  .text.bad { color: var(--err); }
  .meta { font-size: 11px; color: var(--fg3); white-space: nowrap; margin-top: 3px; min-width: 40px; text-align: right; font-variant-numeric: tabular-nums; }
  .ft { display: flex; gap: 14px; padding: 7px 14px; border-top: 1px solid var(--line); font-size: 11px; color: var(--fg3); flex: none; }
  .ft kbd { font: inherit; padding: 0 4px; border-radius: 4px; border: 1px solid var(--line); color: var(--fg2); margin-right: 3px; }
  .tip { margin-left: auto; }
</style>
