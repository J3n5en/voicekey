<script lang="ts">
  import { app, save } from "../lib/store.svelte";
  import { call, CH, diffMark, esc, type Row } from "../lib/api";
  import ChIcon from "../lib/ChIcon.svelte";
  import Wave from "../lib/Wave.svelte";

  let elapsed = $state(0);
  const drafts = new Map<string, string>();
  const finals = new Map<string, string>();

  const m = $derived(app.compare);
  const rows = $derived<Row[]>(m?.rows ?? app.info!.channels.filter((c) => c !== "all").map((c) => ({ channel: c, text: "", state: "skip", ms: null })));
  const recording = $derived(!!m?.recording);
  const waiting = $derived(rows.some((r) => r.state === "listen" || r.state === "wait"));
  const finished = $derived(rows.filter((r) => r.state === "final"));
  const best = $derived(m && !waiting && finished.length ? finished.reduce((a, b) => ((a.ms ?? 0) <= (b.ms ?? 0) ? a : b)) : null);
  const maxMs = $derived(Math.max(1, ...finished.map((r) => r.ms ?? 0)));

  $effect(() => {
    for (const r of rows) {
      if (r.state === "final") {
        if (!finals.has(r.channel)) finals.set(r.channel, diffMark(drafts.get(r.channel) ?? "", r.text));
      } else {
        drafts.set(r.channel, r.text);
        finals.delete(r.channel);
      }
    }
  });

  $effect(() => {
    if (!recording) return;
    const t0 = performance.now();
    elapsed = 0;
    const iv = setInterval(() => (elapsed = Math.floor((performance.now() - t0) / 1000)), 250);
    return () => clearInterval(iv);
  });

  function toggle() {
    if (!recording) {
      drafts.clear();
      finals.clear();
    }
    call("compare_toggle");
  }
</script>

<div class="cmp">
  <div class="hero">
    <button class="mic" class:on={recording} onclick={toggle} aria-label="开始或结束">
      {#if recording}
        <svg viewBox="0 0 24 24"><rect x="7" y="7" width="10" height="10" rx="2" fill="currentColor" /></svg>
      {:else}
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 3a3 3 0 0 1 3 3v6a3 3 0 0 1-6 0V6a3 3 0 0 1 3-3zM5 11a7 7 0 0 0 14 0M12 18v3" /></svg>
      {/if}
    </button>
    <div class="info">
      <b>{!m ? "说一句话试试" : recording ? "正在聆听…" : waiting ? "各渠道定稿中…" : "对比完成"}</b>
      <small>{!m ? "各渠道同时识别，录音不会保存" : recording ? "点击红色按钮结束" : waiting ? "条形长度表示定稿耗时" : best ? `${CH[best.channel].short} 最快，可设为默认` : "可重新录一句"}</small>
    </div>
    <div class="wave"><Wave level={recording ? app.level : 0} idle={!recording} height={36} /></div>
    <span class="time">{Math.floor(elapsed / 60)}:{String(elapsed % 60).padStart(2, "0")}</span>
  </div>
  <div class="grid" style="--n:{rows.length % 2 && rows.length > 1 ? 3 : 2}">
    {#each rows as r (r.channel)}
      <div class="cc" class:best={r === best} class:dim={m && r.state === "skip"} class:error={r.state === "error"}>
        <div class="cc-hd">
          <ChIcon ch={r.channel} size="sm" /><b>{CH[r.channel].short}</b>
          {#if app.s!.channel === r.channel}<span class="badge cur">当前</span>{/if}
          {#if r === best}<span class="badge fast">最快</span>{/if}
          <span class="chip">
            {#if r.state === "listen"}<span class="sdot s-listen"></span>聆听
            {:else if r.state === "wait"}<span class="sdot s-wait"></span>定稿中
            {:else if r.state === "error"}<span class="sdot s-error"></span>出错{/if}
          </span>
        </div>
        <div class="cc-tx">
          {#if !m}<span class="sk" style="width:92%"></span><span class="sk" style="width:64%"></span>
          {:else if r.state === "final"}{@html finals.get(r.channel) ?? esc(r.text)}
          {:else if r.state === "skip" || r.state === "error"}<span class="muted">{r.text}</span>
          {:else}{r.text}<span class="cur"></span>{/if}
        </div>
        <div class="cc-ft">
          {#if r.state === "final"}
            <span class="lat"><i style="width:{Math.max(6, ((r.ms ?? 0) / maxMs) * 100)}%"></i></span>
            <span class="t">{((r.ms ?? 0) / 1000).toFixed(2)}s</span>
            {#if app.s!.channel !== r.channel}<button class="use" onclick={() => save({ channel: r.channel })}>设为默认</button>{/if}
          {:else if r.state === "wait"}
            <span class="lat"><i class="ind"></i></span>
          {/if}
        </div>
      </div>
    {/each}
  </div>
</div>

<style>
  .cmp { background: var(--card); border: 1px solid var(--line); border-radius: var(--r); padding: 14px; }
  .hero { display: flex; align-items: center; gap: 14px; padding: 4px 4px 14px; }
  .mic { position: relative; width: 46px; height: 46px; border-radius: 50%; border: 0; background: var(--accent); color: #fff; display: grid; place-items: center; cursor: pointer; flex: none; box-shadow: 0 2px 6px rgba(0, 0, 0, 0.15); transition: transform 0.15s; }
  .mic:hover { transform: scale(1.05); }
  .mic svg { width: 20px; height: 20px; }
  .mic.on { background: var(--err); }
  .mic.on::before, .mic.on::after { content: ""; position: absolute; inset: -6px; border-radius: 50%; border: 2px solid var(--err); opacity: 0; animation: ring 1.6s infinite; }
  .mic.on::after { animation-delay: 0.8s; }
  @keyframes ring { 0% { transform: scale(0.85); opacity: 0.6; } 100% { transform: scale(1.35); opacity: 0; } }
  .info { flex: none; min-width: 170px; white-space: nowrap; }
  .info b { display: block; font-size: 13.5px; }
  .info small { color: var(--fg3); font-size: 11.5px; }
  .wave { flex: 1; min-width: 0; }
  .time { font-variant-numeric: tabular-nums; color: var(--fg2); font-size: 12px; width: 34px; text-align: right; }
  .grid { display: grid; grid-template-columns: repeat(var(--n), minmax(0, 1fr)); gap: 10px; }
  .cc { display: flex; flex-direction: column; border-radius: calc(var(--r) - 2px); background: var(--card2); border: 1px solid var(--line); padding: 11px 12px 10px; min-height: 128px; transition: border-color 0.2s; }
  .cc.best { border-color: color-mix(in srgb, var(--ok) 55%, var(--line)); }
  .cc.dim { opacity: 0.55; }
  .cc-hd { display: flex; align-items: center; gap: 8px; }
  .cc-hd b { font-size: 12.5px; white-space: nowrap; }
  .chip { margin-left: auto; display: inline-flex; align-items: center; gap: 5px; font-size: 11px; color: var(--fg2); white-space: nowrap; }
  .badge { flex: none; font-size: 10.5px; padding: 0 6px; border-radius: 10px; line-height: 17px; white-space: nowrap; }
  .badge.cur { background: color-mix(in srgb, var(--accent) 16%, transparent); color: var(--accent); }
  .badge.fast { background: color-mix(in srgb, var(--ok) 16%, transparent); color: var(--ok); }
  .cc-tx { flex: 1; margin: 9px 0 10px; font-size: 13.5px; line-height: 1.6; word-break: break-all; -webkit-user-select: text; user-select: text; }
  .cc.error .cc-tx { color: var(--err); font-size: 12.5px; }
  .muted { color: var(--fg3); font-size: 12.5px; }
  .sk { display: block; height: 9px; border-radius: 5px; background: var(--line); margin: 6px 0; }
  .cc-ft { display: flex; align-items: center; gap: 8px; font-size: 11px; color: var(--fg3); min-height: 24px; }
  .lat { flex: 1; height: 4px; border-radius: 2px; background: var(--line); overflow: hidden; }
  .lat i { display: block; height: 100%; border-radius: 2px; background: var(--fg3); transition: width 0.4s; }
  .cc.best .lat i { background: var(--ok); }
  .lat i.ind { width: 30%; background: var(--accent); animation: ind 1s ease-in-out infinite; }
  @keyframes ind { from { transform: translateX(-100%); } to { transform: translateX(340%); } }
  .t { font-variant-numeric: tabular-nums; width: 38px; text-align: right; }
  .use { border: 0; background: none; color: var(--accent); cursor: pointer; font-size: 12px; padding: 2px 4px; border-radius: 4px; white-space: nowrap; }
  .use:hover { background: color-mix(in srgb, var(--accent) 12%, transparent); }
</style>
