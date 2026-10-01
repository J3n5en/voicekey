<script lang="ts">
  import { app, save } from "../lib/store.svelte";
  import { CH, type Channel, type QwenOutput } from "../lib/api";
  import ChIcon from "../lib/ChIcon.svelte";
  import Compare from "./Compare.svelte";

  const s = $derived(app.s!);
  const engines = $derived(app.info!.channels.filter((c) => c !== "all"));
  const QO: [QwenOutput, string][] = [["asr", "原文"], ["polish", "润色"], ["translate", "译成英文"]];
  const pick = (c: Channel) => save({ channel: c });
</script>

<h2>识别渠道</h2>
<div class="sub">选择语音转文字的服务，随时可以在托盘菜单里切换。</div>
<div class="cards">
  {#each engines as c}
    <button class="ch" class:on={s.channel === c} onclick={() => pick(c)}>
      <div class="hd"><ChIcon ch={c} /><b>{CH[c].name}</b><span class="radio"></span></div>
      <p>{CH[c].desc}</p>
      <div class="tags">{#each CH[c].tags as t}<span class="pill">{t}</span>{/each}</div>
    </button>
  {/each}
  <button class="ch" class:wide={engines.length % 2 === 0} class:on={s.channel === "all"} onclick={() => pick("all")}>
    <div class="hd"><ChIcon ch="all" /><b>{CH.all.name}</b><span class="radio"></span></div>
    <p>{CH.all.desc}</p>
  </button>
</div>
{#if !app.info!.offline.supported}
  <div class="note">ⓘ 离线识别仅支持 Apple 芯片的 Mac{app.info!.platform === "win" ? "，Windows 版暂不提供" : ""}。</div>
{/if}
{#if s.channel === "qwen" || s.channel === "all"}
  <h3>千问输出</h3>
  <div class="group">
    <div class="row">
      <div class="lbl">输出方式<small>润色会去除口头语并补全标点</small></div>
      <div class="segc">
        {#each QO as [k, v]}<button class:on={s.qwenOutput === k} onclick={() => save({ qwenOutput: k })}>{v}</button>{/each}
      </div>
    </div>
  </div>
{/if}
<h3>渠道对比</h3>
<Compare />

<style>
  .cards { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
  .ch { position: relative; background: var(--card); border: 1.5px solid var(--line); border-radius: var(--r); padding: 14px; cursor: pointer; transition: 0.15s; text-align: left; }
  .ch:hover { border-color: color-mix(in srgb, var(--accent) 40%, var(--line)); }
  .ch.on { border-color: var(--accent); box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 18%, transparent); }
  .ch.wide { grid-column: span 2; }
  .hd { display: flex; align-items: center; gap: 10px; }
  .hd b { font-size: 13.5px; }
  p { color: var(--fg2); font-size: 12px; margin: 8px 0 10px; }
  .ch.wide p { margin-bottom: 0; }
  .tags { display: flex; gap: 5px; flex-wrap: wrap; }
  .radio { margin-left: auto; width: 16px; height: 16px; border-radius: 50%; border: 1.5px solid var(--fg3); }
  .on .radio { border: 5px solid var(--accent); }
</style>
