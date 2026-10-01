<script lang="ts">
  import { onMount } from "svelte";
  import { app, save, refreshPerms, refreshMics } from "../lib/store.svelte";
  import { call } from "../lib/api";
  import Logo from "../lib/Logo.svelte";
  import Perms from "./Perms.svelte";
  import Wave from "../lib/Wave.svelte";

  let { done }: { done: () => void } = $props();
  const mac = app.info!.platform === "mac";
  const steps = mac ? ["perm", "mic", "try"] : ["mic", "try"];
  let i = $state(0);
  const step = $derived(steps[i]);
  const hold = $derived(app.info!.holdKeys.find((k) => k.id === app.s!.holdKey)?.name ?? "");
  const tap = $derived(app.s!.tapShortcut?.name);

  onMount(() => {
    refreshMics();
    const iv = setInterval(refreshPerms, 1000);
    return () => {
      clearInterval(iv);
      call("meter", { on: false });
    };
  });

  $effect(() => {
    call("meter", { on: step === "mic" });
  });

  function next() {
    if (i < steps.length - 1) i++;
    else {
      save({ onboarded: true });
      done();
    }
  }
</script>

<div class="ob">
  <div class="drag" data-tauri-drag-region></div>
  <div class="steps">{#each steps as _, k}<i class:on={k <= i}></i>{/each}</div>
  {#if i === 0}<div class="hero"><Logo /></div>{/if}
  {#if step === "perm"}
    <h2>授予两项权限</h2>
    <div class="sub">VoiceKey 需要监听快捷键并把文字打到光标处。授权后状态会自动刷新。</div>
    <div class="group left"><Perms /></div>
  {:else if step === "mic"}
    <h2>试试麦克风</h2>
    <div class="sub">说几句话，看看声波是否跟着起伏。</div>
    <div class="big"><Wave level={app.level} height={64} /></div>
    <div class="group left">
      <div class="row">
        <div class="lbl">输入设备</div>
        <select class="sel" value={app.s!.mic} onchange={(e) => { save({ mic: e.currentTarget.value }); call("meter", { on: true }); }}>
          <option value="">系统默认</option>
          {#each app.mics as m}<option value={m}>{m}</option>{/each}
        </select>
      </div>
    </div>
  {:else}
    <h2>按住快捷键说一句</h2>
    <div class="sub">点一下下面的输入框，按住 <b>{hold}</b> 说「你好 VoiceKey」，松开即上屏。</div>
    <textarea class="try" placeholder="在这里试一试"></textarea>
    {#if tap}<div class="tip">也可以点按 <b>{tap}</b>，停顿后自动结束</div>{/if}
  {/if}
  <div class="nav">
    <button class="btn" style:visibility={i ? "visible" : "hidden"} onclick={() => i--}>上一步</button>
    <button class="btn pri" onclick={next}>{i === steps.length - 1 ? "开始使用" : "继续"}</button>
  </div>
</div>

<style>
  .ob { height: 100vh; display: flex; flex-direction: column; align-items: center; padding: 0 140px 32px; text-align: center; }
  .drag { height: 28px; width: 100%; flex: none; }
  .steps { display: flex; gap: 8px; margin: 16px 0 26px; }
  .steps i { width: 28px; height: 4px; border-radius: 2px; background: var(--line); }
  .steps i.on { background: var(--accent); }
  .hero { width: 72px; height: 72px; border-radius: 18px; background: #171a2e; display: grid; place-items: center; margin-bottom: 16px; box-shadow: 0 10px 30px rgba(80, 60, 200, 0.35); }
  .hero :global(svg) { width: 52px; height: 52px; }
  h2 { font-size: 22px; font-weight: 650; }
  .sub { color: var(--fg2); max-width: 440px; margin: 6px auto 22px; }
  .left { text-align: left; width: 100%; }
  .big { width: 100%; height: 72px; border-radius: var(--r); background: var(--card); border: 1px solid var(--line); margin-bottom: 12px; padding: 4px 8px; }
  .try { width: 100%; height: 96px; resize: none; border: 1px solid var(--line); background: var(--card); border-radius: var(--rs); padding: 12px 14px; font-size: 14px; outline: none; -webkit-user-select: text; user-select: text; }
  .try:focus { border-color: var(--accent); }
  .tip { margin-top: 12px; color: var(--fg2); font-size: 12px; }
  .nav { margin-top: auto; width: 100%; display: flex; justify-content: space-between; }
</style>
