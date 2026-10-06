<script lang="ts">
  import { onMount } from "svelte";
  import { app, save, refreshMics } from "../lib/store.svelte";
  import { call } from "../lib/api";
  import Meter from "../lib/Meter.svelte";

  const s = $derived(app.s!);
  const missing = $derived(s.mic && !app.mics.includes(s.mic));

  onMount(() => {
    refreshMics();
    window.addEventListener("focus", refreshMics);
    call("meter", { on: true });
    return () => {
      window.removeEventListener("focus", refreshMics);
      call("meter", { on: false });
    };
  });

  function pick(v: string) {
    save({ mic: v });
  }
</script>

<h2>音频</h2>
<div class="sub">选择用于识别的麦克风。</div>
<div class="group">
  <div class="row">
    <div class="lbl">麦克风<small>设备断开时自动回落到系统默认</small></div>
    <select class="sel" value={s.mic} onchange={(e) => pick(e.currentTarget.value)}>
      <option value="">系统默认</option>
      {#each app.mics as m}<option value={m}>{m}</option>{/each}
      {#if missing}<option value={s.mic}>已断开（暂用系统默认）</option>{/if}
    </select>
  </div>
  <div class="row">
    <div class="lbl">输入电平<small>对着麦克风说话测试</small></div>
    <Meter />
  </div>
</div>
