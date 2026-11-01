<script lang="ts">
  import { app, save } from "../lib/store.svelte";
  import { call, type JevConfig, type JevTested } from "../lib/api";

  const MODES: [JevConfig["mode"], string][] = [["off", "关闭"], ["official", "官方格式"], ["yce", "自定义格式"]];
  // 输入框绑本地草稿，失焦才写回设置
  let d = $state<JevConfig>({ ...app.s!.jev });
  let busy = $state(false);
  let result = $state<{ ok: boolean; text: string } | null>(null);

  type Row = { addr: string; key: string };
  // pool → 行：跳过空行、# 注释和 core 也会跳过的坏行；alias 丢弃，地址存原文不补全
  const parsePool = (text: string): Row[] =>
    text
      .split("\n")
      .map((l) => l.trim())
      .filter((l) => l !== "" && !l.startsWith("#"))
      .flatMap((l) => {
        const parts = l.split("|").map((s) => s.trim());
        return parts.length >= 2 && parts.length <= 3 && parts[1] !== "" ? [{ addr: parts[2] ?? "", key: parts[1] }] : [];
      });
  const clean = (s: string) => s.replace(/[|\r\n]/g, "").trim();
  const hostOf = (addr: string) => {
    if (addr === "") return "official";
    try {
      return new URL(addr.includes("://") ? addr : "https://" + addr).hostname || "custom";
    } catch {
      return "custom";
    }
  };
  // 行 → 多行「别名|key|endpoint」存储格式；key 空的行不写；别名取地址 host，空地址用 official，重名追加 -2、-3
  const toPool = (rows: Row[]): string => {
    const seen = new Map<string, number>();
    const lines: string[] = [];
    for (const r of rows) {
      const addr = clean(r.addr);
      const key = clean(r.key);
      if (key === "") continue;
      const base = hostOf(addr);
      const n = (seen.get(base) ?? 0) + 1;
      seen.set(base, n);
      lines.push(`${n === 1 ? base : `${base}-${n}`}|${key}|${addr}`);
    }
    return lines.join("\n");
  };
  const blank = (): Row => ({ addr: "", key: "" });
  let rows = $state<Row[]>(parsePool(d.pool).length ? parsePool(d.pool) : [blank()]);

  const hasKey = $derived(d.key.trim() !== "");
  const hasPool = $derived(rows.some((r) => r.key.trim() !== ""));
  const commit = () => save({ jev: { ...d } });
  const syncPool = () => {
    d.pool = toPool(rows);
    commit();
  };
  const setMode = (m: JevConfig["mode"]) => {
    d.mode = m;
    result = null;
    commit();
  };

  async function test() {
    d.pool = toPool(rows);
    busy = true;
    result = null;
    try {
      const t = await call<JevTested>("jev_test", { config: { ...d } });
      result = { ok: true, text: `选中第 ${t.index + 1} 条：${t.text} · ${t.ms}ms · ${t.alias} · ${t.key}` };
    } catch (e) {
      result = { ok: false, text: String(e) };
    } finally {
      busy = false;
    }
  }
</script>

<h3>智能选择（Jev）</h3>
<div class="group">
  <div class="row">
    <div class="lbl">说完后由 Jev 自动挑一条上屏<small>仅多渠道模式生效；只把转写文字发给 Jev，不发渠道名；密钥只存本机</small></div>
    <div class="segc">
      {#each MODES as [k, v]}<button class:on={d.mode === k} onclick={() => setMode(k)}>{v}</button>{/each}
    </div>
  </div>
  {#if d.mode === "official"}
    <div class="row">
      <div class="lbl">API Key{#if !hasKey}<small class="err">请先填写 API Key，否则不会触发</small>{/if}</div>
      <input class="in" type="password" autocomplete="off" spellcheck="false" aria-label="API Key" placeholder="apikey_xxx" bind:value={d.key} onblur={commit} />
    </div>
    <div class="row">
      <div class="lbl">端点<small>留空使用官方端点；可只填域名，自动补全为 …/v1/systemone</small></div>
      <input class="in" type="text" spellcheck="false" aria-label="端点" placeholder="https://api.typesafe.ai" bind:value={d.endpoint} onblur={commit} />
    </div>
    <div class="row">
      <div class="lbl">模型<small>留空使用默认模型</small></div>
      <input class="in" type="text" spellcheck="false" aria-label="模型" placeholder="jev-latest" bind:value={d.model} onblur={commit} />
    </div>
  {:else if d.mode === "yce"}
    <div class="row col">
      {#each rows as r, i}
        <div class="pair">
          <input class="in" type="text" spellcheck="false" aria-label="地址" placeholder="https://api.typesafe.ai（可留空）" bind:value={r.addr} onblur={syncPool} />
          <input class="in" type="password" autocomplete="off" spellcheck="false" aria-label="密钥" placeholder="密钥" bind:value={r.key} onblur={syncPool} />
          <button class="btn" onclick={() => { rows.splice(i, 1); if (!rows.length) rows.push(blank()); syncPool(); }}>删除</button>
        </div>
      {/each}
      <button class="btn" onclick={() => rows.push(blank())}>添加一组</button>
      <small>从上到下依次尝试，一组用不了自动换下一组；地址可留空（用官方端点），只填域名会自动补全为 …/v1/systemone，以 /decisions 结尾按 decisions 协议发送</small>
      {#if !hasPool}<small class="err">至少填一组密钥，否则不会触发</small>{/if}
    </div>
  {/if}
  {#if d.mode !== "off"}
    <div class="row">
      <div class="lbl">
        {#if result}<small class={result.ok ? "ok" : "err"}>{result.text}</small>{:else}<small>用两条示例转写真发一次请求，验证配置</small>{/if}
      </div>
      <button class="btn" disabled={busy} onclick={test}>{busy ? "测试中…" : "测试"}</button>
    </div>
  {/if}
</div>

<style>
  .in { width: 280px; flex: none; border: 1px solid var(--line); background: var(--card2); border-radius: var(--rs); padding: 5px 10px; outline: none; -webkit-user-select: text; user-select: text; cursor: text; }
  .in:focus { border-color: var(--accent); }
  .in::placeholder { color: var(--fg3); }
  .row.col { flex-direction: column; align-items: stretch; gap: 6px; }
  .row.col small { color: var(--fg3); font-size: 11.5px; }
  .row.col small.err { color: var(--err); }
  .pair { display: flex; gap: 6px; align-items: center; }
  .pair .in { flex: 1; width: auto; min-width: 0; }
  .lbl small { word-break: break-all; -webkit-user-select: text; user-select: text; }
  .lbl small.err { color: var(--err); }
  .lbl small.ok { color: var(--ok); }
</style>
