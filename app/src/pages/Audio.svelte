<script lang="ts">
  import { onMount } from "svelte";
  import { app, save, refreshMics } from "../lib/store.svelte";
  import { call } from "../lib/api";
  import Meter from "../lib/Meter.svelte";

  const s = $derived(app.s!);
  const missing = $derived(s.mic && !app.mics.includes(s.mic));
  // 设置值和 UI 都直接表示“降低比例”；100% 只改变展示为“静音”，数值本身不做反转。
  const duckReductionLabel = $derived(s.lowerSystemVolumePercent === 100 ? "静音" : `−${s.lowerSystemVolumePercent}%`);

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
<div class="sub" aria-hidden="true">&nbsp;</div>
<h3>输入设备</h3>
<div class="group">
  <div class="row">
    <div class="lbl">麦克风<small>用于识别的麦克风，设备断开时自动切回系统默认</small></div>
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
<h3>系统音频</h3>
<div class="group">
  <div class="row">
    <div class="lbl">录音时降低音量<small>减少背景声音的干扰，结束后自动恢复</small></div>
    {#if s.lowerSystemVolume}
      <!-- 录音中拖动比例会即时生效；worker 从当前实际音量平滑重定向到新目标，不等待当前过渡完成。 -->
      <input class="duck-range" type="range" min="20" max="100" step="5" value={s.lowerSystemVolumePercent} oninput={(e) => save({ lowerSystemVolumePercent: +e.currentTarget.value })} aria-label="录音时降低音量比例" aria-valuetext={s.lowerSystemVolumePercent === 100 ? "静音" : `降低 ${s.lowerSystemVolumePercent}%`} />
      <b class="duck-value">{duckReductionLabel}</b>
    {/if}
    <button class="sw" class:on={s.lowerSystemVolume} onclick={() => save({ lowerSystemVolume: !s.lowerSystemVolume })} aria-label="录音时降低音量"></button>
  </div>
</div>

<style>
  .duck-range { width: 160px; accent-color: var(--accent); }
  .duck-value { width: 42px; text-align: right; font-variant-numeric: tabular-nums; }
</style>
