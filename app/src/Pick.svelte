<script lang="ts">
  import { onMount, tick } from "svelte";
  import { call, on, applyLook, diffMark, esc, CH, type AppInfo, type PickModel, type Settings } from "./lib/api";
  import ChIcon from "./lib/ChIcon.svelte";
  import Wave from "./lib/Wave.svelte";

  const empty = (session = 0): PickModel => ({ session, expanded: false, recording: false, rows: [], sel: 0 });
  let model = $state<PickModel>(empty());
  const action = (name: string, args: Record<string, unknown> = {}) => call(name, { session: model.session, ...args });
  const expand = (expanded: boolean) => action("pick_expand", { expanded });
  let level = $state(0);
  let shake = $state(-1);
  let platform = $state("mac");
  let root = $state<HTMLDivElement>();
  const drafts = new Map<string, string>();
  const finals = new Map<string, string>();

  const waiting = $derived(model.rows.filter((r) => r.state === "wait" || r.state === "listen").length);
  const done = $derived(model.rows.filter((r) => r.state === "final").length);
  const participating = $derived(model.rows.filter((r) => r.state !== "skip").length);
  const phase = $derived(!model.rows.length ? "准备中" : model.recording ? "录音中" :
    model.jev === "busy" ? "评选中" : model.finalized?.state === "busy" ? "定稿中" :
    model.jev === "failed" || model.finalized?.state === "failed" ? (done ? "待选择" : "无结果") :
    waiting ? "识别中" : done ? "待选择" : "无结果");
  const detail = $derived(phase === "待选择" ? "点开选择" : phase === "无结果" ? "点开查看" : `${participating} 路`);
  // 路数越多单条越矮，长文本在条目内滚动，避免把后面的候选顶出屏幕
  const count = $derived(model.history ? model.history.items.length : model.rows.length);
  const lines = $derived(count <= 2 ? 8 : count === 3 ? 5 : 4);
  const streaming = new Set<string>();

  let reportedHeight = 0;
  function receive(m: PickModel) {
    if (m.session < model.session) return;
    if (m.session !== model.session || m.expanded !== model.expanded) reportedHeight = 0;
    if (m.session !== model.session || (m.recording && m.rows.every((r) => !r.text || r.state === "skip"))) {
      drafts.clear();
      finals.clear();
      streaming.clear();
      shake = -1;
    }
    for (const r of m.rows) {
      if (r.state === "final") {
        if (m.expanded && !finals.has(r.channel)) finals.set(r.channel, diffMark(drafts.get(r.channel) ?? "", r.text));
      } else {
        drafts.set(r.channel, r.text);
        finals.delete(r.channel);
      }
    }
    model = m;
    report();
  }

  function relTime(ts: number) {
    const sec = Math.max(0, Math.floor((Date.now() - ts) / 1000));
    if (sec < 60) return "刚刚";
    if (sec < 3600) return `${Math.floor(sec / 60)} 分钟前`;
    return new Date(ts).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit", hour12: false });
  }

  async function report() {
    if (!model.expanded) return;
    const session = model.session;
    await tick();
    if (!root || !model.expanded || session !== model.session) return;
    if (model.history) root.querySelector(".row.active")?.scrollIntoView({ block: "nearest" });
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
    // 10px 上下边距，再留 8px 给缩放取整；历史列表限高，超出在列表内滚动
    const h = Math.ceil(natural) + 28;
    const height = model.history ? Math.min(h, 520) : h;
    if (height === reportedHeight) return;
    reportedHeight = height;
    void action("pick_resize", { height });
  }

  onMount(() => {
    call<AppInfo>("get_state").then((i) => {
      platform = i.platform;
      applyLook(i.platform, i.settings.theme);
    });
    // 面板仅在安全输入开启时取得焦点，此时由这里接收选择按键
    const onKey = (e: KeyboardEvent) => {
      if (!model.expanded || e.repeat || e.metaKey || e.ctrlKey || e.altKey || (e.key === "Tab" && e.shiftKey)) return;
      if ((e.key === "Enter" || e.key === " ") && e.target instanceof Element && e.target.closest("[data-fold]")) return;
      e.preventDefault();
      void action("pick_key", { key: e.key });
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("resize", report);
    let mounted = true;
    const un = [
      on<PickModel>("pick", receive),
      on<number>("pick-hidden", (session) => receive(empty(session))),
      on<number>("level", (v) => (level = v)),
      on<Settings>("settings", (s) => applyLook(platform, s.theme)),
      on<number>("pick-shake", (i) => {
        shake = -1;
        tick().then(() => (shake = i));
      }),
    ];
    void Promise.all(un).then(() => { if (mounted) return call("pick_ready"); });
    return () => {
      mounted = false;
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("resize", report);
      un.forEach((p) => p.then((f) => f()));
    };
  });
</script>

{#snippet foldButton()}
  <button type="button" class="fold" data-fold aria-label="收起候选" aria-expanded="true" onclick={() => expand(false)}>
    收起<svg aria-hidden="true" width="10" height="10" viewBox="0 0 12 12"><path d="m3 7.5 3-3 3 3" /></svg>
  </button>
{/snippet}

{#if !model.expanded}
  <button type="button" class="chip" class:listening={model.recording} class:attention={phase === "待选择" || phase === "无结果"}
    aria-label={`展开候选：${phase}，${participating} 路`} aria-expanded="false" title="展开候选，不停止录音"
    disabled={!model.rows.length} onclick={() => expand(true)}>
    <span class="signal" aria-hidden="true"></span><b>{phase}</b><span class="detail">{detail}</span>
    <svg aria-hidden="true" width="12" height="12" viewBox="0 0 12 12"><path d="m4.5 2.5 3.5 3.5-3.5 3.5" /></svg>
  </button>
{:else}
<div class="pick" bind:this={root} style:--lines={lines}>
  {#if model.history}
  {@const h = model.history}
  <div class="hd">
    <span class="htitle">识别历史</span>
    <span class="hsub">{h.enabled ? `最近 ${h.items.length} 条` : ""}</span>
    <button class="close" title="返回候选（Tab / Esc）" aria-label="返回候选" onclick={() => action("pick_key", { key: "Escape" })}>
      <svg viewBox="0 0 12 12" width="10" height="10"><path d="M2 2l8 8M10 2l-8 8" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" /></svg>
    </button>
  </div>
  <div class="rows">
  {#each h.items as e, i (`${e.ts}-${i}`)}
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="row" class:active={i === h.sel} onclick={() => action("pick_choose", { index: i })}>
      <span class="num">{i < 9 ? i + 1 : "•"}</span>
      <span class="name"><span class="sdot" class:s-final={e.delivered} class:s-error={!e.delivered}></span><ChIcon ch={e.channel} size="xs" />{CH[e.channel]?.short ?? e.channel}</span>
      <div class="text">{e.text}</div>
      <span class="meta">{relTime(e.ts)}</span>
    </div>
  {:else}
    <div class="empty">{h.enabled ? "暂无识别历史" : "识别历史未开启，可在「设置 → 历史」中打开"}</div>
  {/each}
  </div>
  <div class="ft">
    {#if h.items.length}<span><kbd>1-{Math.min(h.items.length, 9)}</kbd>选择</span><span><kbd>↑↓</kbd>切换</span><span><kbd>↵</kbd>上屏</span>{/if}
    <span><kbd>Tab</kbd>返回候选</span>
    {@render foldButton()}
  </div>
  {:else}
  <div class="hd">
    {#if model.recording}<span class="rec"></span>{/if}
    <div class="wave"><Wave level={model.recording ? level : 0} idle={!model.recording} height={26} /></div>
    <span class="state">
      {#if model.recording}录音中
      {:else if model.finalized?.state === "busy"}<span class="spinner"></span>LLM 融合定稿中 · 可手选
      {:else if model.finalized?.state === "failed"}<span class="err">LLM 定稿失败{model.finalized.note ? `，${model.finalized.note}` : "，请手动选择"}</span>
      {:else if model.finalized?.state === "skipped"}<span class="ok">● 已省去 LLM · 按回车上屏</span>
      {:else if model.finalized?.state === "ready"}<span class="ok">● LLM 定稿完成 · 按回车上屏</span>
      {:else if model.jev === "busy"}<span class="spinner"></span>Jev 智能选择中 · 可手选
      {:else if model.jev === "failed"}<span class="err">智能选择失败，请手动选择</span>
      {:else if waiting}<span class="spinner"></span>定稿中 {done}/{model.rows.length}
      {:else}<span class="ok">● 全部完成</span>{/if}
    </span>
    <button class="close" title="关闭（Esc）" aria-label="关闭" onclick={() => action("pick_key", { key: "Escape" })}>
      <svg viewBox="0 0 12 12" width="10" height="10"><path d="M2 2l8 8M10 2l-8 8" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" /></svg>
    </button>
  </div>
  <div class="rows">
  {#if model.finalized}
    {@const f = model.finalized}
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div
      class="row final-row"
      class:active={!!model.selFinal}
      class:disabled={f.state === "idle" || f.state === "busy" || f.state === "failed"}
      onclick={() => {
        if (f.state === "ready" || f.state === "skipped") action("pick_choose_final");
      }}
    >
      <span class="num star">✦</span>
      <span class="name">
        <span class="sdot s-{f.state === 'ready' || f.state === 'skipped' ? 'final' : f.state === 'failed' ? 'error' : 'wait'}"></span>
        最终定稿
      </span>
      <div
        class="text"
        class:live={f.state === "busy"}
        class:muted={f.state === "idle" || (f.state === "busy" && !f.text)}
        class:bad={f.state === "failed"}
        data-ch="llm"
      >
        {#if f.state === "idle"}
          等待各渠道定稿后生成…
        {:else if f.state === "busy"}
          {f.text || "LLM 正在综合对比各渠道结果…"}{#if f.text}<span class="cur"></span>{/if}
        {:else}
          {f.text}
        {/if}
        {#if f.note && (f.state === "ready" || f.state === "skipped")}
          <div class="fnote">{f.note}</div>
        {/if}
      </div>
      <span class="meta">
        {#if f.state === "busy"}<span class="spinner"></span>{:else if f.state === "skipped"}省 Token{:else if f.ms != null}{(f.ms / 1000).toFixed(2)}s{/if}
      </span>
    </div>
  {/if}
  {#each model.rows as r, i (r.channel)}
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="row" class:active={!model.selFinal && i === model.sel} class:shake={i === shake} onclick={() => action("pick_choose", { index: i })}>
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
    <span><kbd>1-{model.rows.length}</kbd>选择</span><span><kbd>↑↓</kbd>切换</span><span><kbd>↵</kbd>上屏</span><span><kbd>Esc</kbd>取消</span><button class="ft-btn" onclick={() => action("pick_key", { key: "Tab" })}><kbd>Tab</kbd>历史</button>
    {#if model.recording}<span class="tip">可提前预选</span>{/if}
    {@render foldButton()}
  </div>
  {/if}
</div>
{/if}

<style>
  .chip { width: min(100vw, 152px); height: min(100vh, 34px); display: flex; align-items: center; gap: 7px; padding: 0 11px; border: 1px solid var(--line); border-radius: 999px; background: var(--card); color: var(--fg); cursor: pointer; white-space: nowrap; }
  .chip b { font-size: 12.5px; font-weight: 600; }
  .chip .detail { flex: 1; color: var(--fg2); font-size: 11.5px; text-align: right; font-variant-numeric: tabular-nums; }
  .signal { width: 7px; height: 7px; border-radius: 50%; flex: none; background: var(--accent); }
  .chip.listening .signal { background: var(--err); }
  .chip.attention .signal { background: var(--warn); }
  .chip svg, .fold svg { fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; flex: none; }
  .chip svg { color: var(--fg2); }
  .fold { flex: none; display: inline-flex; align-items: center; justify-content: center; gap: 4px; min-width: 52px; min-height: 26px; margin-left: auto; padding: 2px 7px; border: 1px solid var(--line); border-radius: 4px; background: transparent; font-size: 12px; color: var(--fg); cursor: pointer; }
  .chip:hover, .fold:hover { background: var(--card2); }
  .chip:focus-visible, .fold:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
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
  .row.final-row { background: color-mix(in srgb, var(--accent) 6%, transparent); border-bottom: 1.5px solid color-mix(in srgb, var(--accent) 28%, var(--line)); }
  .row.final-row.disabled { cursor: default; }
  .row.active { background: color-mix(in srgb, var(--accent) 14%, transparent); }
  .row.active::before { content: ""; position: absolute; left: 0; top: 8px; bottom: 8px; width: 3px; border-radius: 0 2px 2px 0; background: var(--accent); }
  .row.shake { animation: shake 0.3s; }
  .num { width: 18px; height: 18px; border-radius: 5px; border: 1px solid var(--line); font-size: 11px; display: grid; place-items: center; color: var(--fg2); flex: none; margin-top: 2px; }
  .num.star { border-color: color-mix(in srgb, var(--accent) 45%, var(--line)); color: var(--accent); font-size: 12px; }
  .fnote { font-size: 11px; color: var(--fg3); margin-top: 2px; }
  .row.active .num { background: var(--accent); color: #fff; border-color: transparent; }
  .name { width: 88px; flex: none; font-size: 12px; color: var(--fg2); margin-top: 2px; display: flex; align-items: center; gap: 6px; white-space: nowrap; }
  .text {
    flex: 1; font-size: 14px; line-height: 1.55; min-height: 22px; max-height: calc(1.55em * var(--lines, 4));
    overflow-y: auto; scrollbar-width: thin; word-break: break-all; -webkit-user-select: text; user-select: text;
  }
  .text.muted { color: var(--fg3); font-size: 13px; }
  .text.bad { color: var(--err); }
  .meta { font-size: 11px; color: var(--fg3); white-space: nowrap; margin-top: 3px; min-width: 40px; text-align: right; font-variant-numeric: tabular-nums; }
  .ft { display: flex; align-items: center; gap: 10px; padding: 3px 10px 3px 14px; border-top: 1px solid var(--line); font-size: 11px; color: var(--fg3); flex: none; }
  .ft kbd { font: inherit; padding: 0 4px; border-radius: 4px; border: 1px solid var(--line); color: var(--fg2); margin-right: 3px; }
  .ft-btn { border: 0; background: none; padding: 0; font: inherit; color: inherit; cursor: pointer; }
  .ft-btn:hover { color: var(--fg); }
  .htitle { font-size: 12.5px; font-weight: 600; color: var(--fg); }
  .hsub { flex: 1; font-size: 11.5px; color: var(--fg3); }
  .empty { padding: 20px 14px; border-top: 1px solid var(--line); font-size: 12.5px; color: var(--fg3); text-align: center; }
  .tip { flex: 1; text-align: right; }
</style>
