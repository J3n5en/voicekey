<script lang="ts">
  import { onMount } from "svelte";
  import { app, save, refreshPerms } from "../lib/store.svelte";
  import { call } from "../lib/api";
  import Perms from "./Perms.svelte";

  let { rerun }: { rerun: () => void } = $props();
  const s = $derived(app.s!);
  const info = $derived(app.info!);
  const u = $derived(app.update);
  const THEMES: [string, string][] = [["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]];

  onMount(() => {
    const iv = setInterval(refreshPerms, 1000);
    return () => clearInterval(iv);
  });
</script>

<h2>通用</h2>
<div class="sub">启动、权限与更新。</div>
<div class="group">
  <div class="row">
    <div class="lbl">开机自动启动</div>
    <button class="sw" class:on={s.autostart} onclick={() => save({ autostart: !s.autostart })} aria-label="开机自动启动"></button>
  </div>
  <div class="row">
    <div class="lbl">界面外观</div>
    <div class="segc">
      {#each THEMES as [k, v]}<button class:on={s.theme === k} onclick={() => save({ theme: k })}>{v}</button>{/each}
    </div>
  </div>
</div>
{#if info.platform === "mac"}
  <h3>权限</h3>
  <div class="group"><Perms /></div>
{/if}
<h3>关于</h3>
<div class="group">
  <div class="row">
    <div class="lbl">VoiceKey {info.version}<small>{info.platform === "mac" ? "macOS" : "Windows"} · {info.arch}
      {#if u.state === "available"} · 新版本 v{u.version} 可用{:else if u.state === "latest"} · 已是最新版本{:else if u.state === "error"} · 更新失败：{u.error}{/if}</small></div>
    {#if u.state === "available"}
      <button class="btn pri" onclick={() => call("update_install")}>更新并重启</button>
    {:else if u.state === "downloading"}
      <button class="btn" disabled>下载中 {u.progress ?? 0}%</button>
    {:else}
      <button class="btn" disabled={u.state === "checking"} onclick={() => call("update_check")}>{u.state === "checking" ? "检查中…" : "检查更新"}</button>
    {/if}
  </div>
  <div class="row">
    <div class="lbl">重新运行首次引导</div>
    <button class="btn" onclick={rerun}>打开</button>
  </div>
</div>
