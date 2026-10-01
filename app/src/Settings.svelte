<script lang="ts">
  import { onMount } from "svelte";
  import { app, init } from "./lib/store.svelte";
  import Logo from "./lib/Logo.svelte";
  import Recog from "./pages/Recog.svelte";
  import Keys from "./pages/Keys.svelte";
  import Audio from "./pages/Audio.svelte";
  import Output from "./pages/Output.svelte";
  import General from "./pages/General.svelte";
  import Onboard from "./pages/Onboard.svelte";

  const PAGES = [
    { id: "recog", name: "识别", icon: '<path d="M12 3a3 3 0 0 1 3 3v6a3 3 0 0 1-6 0V6a3 3 0 0 1 3-3zM5 11a7 7 0 0 0 14 0M12 18v3"/>' },
    { id: "keys", name: "快捷键", icon: '<rect x="3" y="6" width="18" height="12" rx="2"/><path d="M7 10h.01M11 10h.01M15 10h.01M8 14h8"/>' },
    { id: "audio", name: "音频", icon: '<path d="M4 10v4M8 7v10M12 4v16M16 8v8M20 11v2"/>' },
    { id: "output", name: "输出", icon: '<path d="M4 6h16M4 12h10M4 18h7M17 15l3 3-3 3"/>' },
    { id: "general", name: "通用", icon: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"/>' },
  ];
  let page = $state("recog");
  let onboarding = $state(false);

  onMount(() => {
    init().then(() => (onboarding = !app.s!.onboarded));
  });

  const hold = $derived(app.info?.holdKeys.find((k) => k.id === app.s?.holdKey)?.name ?? "");
</script>

{#if app.s && app.info}
  {#if onboarding}
    <Onboard done={() => (onboarding = false)} />
  {:else}
    <div class="shell">
      <nav class="side">
        <div class="drag" data-tauri-drag-region></div>
        <div class="brand">
          <div class="app"><Logo /></div>
          <div><b>VoiceKey</b><small>v{app.info.version}</small></div>
        </div>
        {#each PAGES as p}
          <button class="nav" class:on={page === p.id} onclick={() => (page = p.id)}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">{@html p.icon}</svg>
            {p.name}
          </button>
        {/each}
        <div class="foot">
          {#if app.perms.accessibility}
            <span class="dot"></span><span>就绪 · 长按 <b>{hold}</b> 说话</span>
          {:else}
            <span class="dot bad"></span><span>需要辅助功能权限</span>
          {/if}
        </div>
      </nav>
      <main>
        <div class="drag" data-tauri-drag-region></div>
        {#if page === "recog"}<Recog />
        {:else if page === "keys"}<Keys />
        {:else if page === "audio"}<Audio />
        {:else if page === "output"}<Output />
        {:else}<General rerun={() => (onboarding = true)} />{/if}
      </main>
    </div>
  {/if}
{/if}

<style>
  .shell { display: flex; height: 100vh; }
  .side { width: 196px; background: var(--side); padding: 0 10px 12px; display: flex; flex-direction: column; gap: 2px; border-right: 1px solid var(--line); }
  .drag { height: 28px; flex: none; }
  :global(.win) .drag { height: 8px; }
  .brand { display: flex; align-items: center; gap: 10px; padding: 6px 8px 14px; }
  .brand .app { width: 34px; height: 34px; border-radius: 9px; background: #171a2e; display: grid; place-items: center; box-shadow: 0 2px 6px rgba(0, 0, 0, 0.2); }
  .brand .app :global(svg) { width: 26px; height: 26px; }
  .brand b { font-size: 14px; display: block; }
  .brand small { color: var(--fg3); font-size: 11px; }
  .nav { display: flex; align-items: center; gap: 10px; padding: 7px 10px; border-radius: var(--rs); cursor: pointer; color: var(--fg2); border: 0; background: none; text-align: left; width: 100%; position: relative; }
  .nav svg { width: 16px; height: 16px; flex: none; }
  .nav:hover { background: var(--line); }
  .nav.on { background: var(--card); color: var(--fg); box-shadow: 0 1px 2px rgba(0, 0, 0, 0.06); }
  :global(.win) .nav.on::before { content: ""; position: absolute; left: 0; top: 9px; bottom: 9px; width: 3px; border-radius: 2px; background: var(--accent); }
  .foot { margin-top: auto; padding: 10px; border-radius: var(--rs); background: var(--card); font-size: 11px; color: var(--fg2); display: flex; gap: 8px; align-items: center; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--ok); flex: none; }
  .dot.bad { background: var(--err); }
  main { flex: 1; overflow: auto; padding: 0 28px 28px; }
  main :global(h2) { font-size: 20px; font-weight: 650; margin: 0 0 4px; }
  main :global(.sub) { color: var(--fg2); margin-bottom: 18px; }
  main :global(h3) { font-size: 12px; font-weight: 600; color: var(--fg2); margin: 20px 0 8px; letter-spacing: 0.02em; }
</style>
