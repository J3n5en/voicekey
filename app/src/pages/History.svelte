<script lang="ts">
  import { onMount } from "svelte";
  import { app, save } from "../lib/store.svelte";
  import { call, on, CH, type HistoryEntry } from "../lib/api";

  const s = $derived(app.s!);
  let list = $state<HistoryEntry[]>([]);
  let limit = $state<number | undefined>(app.s!.historyLimit);
  let copied = $state(-1);

  onMount(() => {
    call<HistoryEntry[]>("get_recognition_history").then((v) => (list = v));
    const off = on<HistoryEntry[]>("history", (v) => (list = v));
    return () => off.then((f) => f());
  });

  function commitLimit() {
    const n = Math.round(limit ?? 0);
    if (!Number.isFinite(n) || n < 1 || n > 100) return (limit = s.historyLimit);
    limit = n;
    if (n !== s.historyLimit) save({ historyLimit: n });
  }

  async function copy(i: number) {
    await navigator.clipboard.writeText(list[i].text);
    copied = i;
    setTimeout(() => copied === i && (copied = -1), 1200);
  }

  const time = (ts: number) => new Date(ts).toLocaleString(undefined, { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" });
</script>

<h2>识别历史</h2>
<div class="sub">保留最近几次识别结果，没输入进去时可在这里找回。只存内存，退出即清空。</div>
<div class="group">
  <div class="row">
    <div class="lbl">保留识别历史<small>{s.historyEnabled ? "识别结果会暂存在本机内存中" : "已关闭，不保留任何识别结果"}</small></div>
    <button class="sw" class:on={s.historyEnabled} onclick={() => save({ historyEnabled: !s.historyEnabled })} aria-label="保留识别历史"></button>
  </div>
  {#if s.historyEnabled}
    <div class="row">
      <label class="lbl" for="history-limit">保留条数<small>1～100 条，超出后丢弃最早的记录</small></label>
      <input id="history-limit" class="in" type="number" min="1" max="100" step="1" bind:value={limit} onblur={commitLimit} onkeydown={(e) => { if (e.key === "Enter") e.currentTarget.blur(); }} />
    </div>
  {/if}
</div>
{#if s.historyEnabled}
  <h3>最近记录</h3>
  <div class="group">
    {#each list as e, i}
      <button class="row item" onclick={() => copy(i)} title="点击复制">
        <div class="lbl">
          <span class="text">{e.text}</span>
          <small>{time(e.ts)} · {CH[e.channel]?.name ?? e.channel}{#if !e.delivered} · <span class="err">未输入</span>{/if}</small>
        </div>
        <span class="hint">{copied === i ? "已复制" : "复制"}</span>
      </button>
    {:else}
      <div class="row"><div class="lbl"><small>暂无记录</small></div></div>
    {/each}
  </div>
  {#if list.length}
    <div class="foot"><button class="btn" onclick={() => call("clear_recognition_history")}>清空</button></div>
  {/if}
{/if}

<style>
  .in { width: 90px; flex: none; border: 1px solid var(--line); background: var(--card2); border-radius: var(--rs); padding: 5px 10px; outline: none; -webkit-user-select: text; user-select: text; cursor: text; }
  .in:focus { border-color: var(--accent); }
  .item { width: 100%; border: 0; background: none; text-align: left; cursor: pointer; }
  .item:hover { background: var(--card2); }
  .item + .item { border-top: 1px solid var(--line); }
  .text { display: block; white-space: pre-wrap; word-break: break-word; }
  .hint { flex: none; font-size: 11.5px; color: var(--fg3); }
  .foot { display: flex; justify-content: flex-end; margin-top: 10px; }
</style>
