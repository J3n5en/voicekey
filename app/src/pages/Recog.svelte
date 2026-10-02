<script lang="ts">
  import { app, save } from "../lib/store.svelte";
  import { call, CH, type Channel, type QwenOutput } from "../lib/api";
  import ChIcon from "../lib/ChIcon.svelte";
  import Compare from "./Compare.svelte";

  const s = $derived(app.s!);
  const engines = $derived(app.info!.channels.filter((c) => c !== "all"));
  const QO: [QwenOutput, string][] = [["asr", "原文"], ["polish", "润色"], ["translate", "译成英文"]];
  const pick = (c: Channel) => save({ channel: c });
  // 保持渠道顺序；至少保留 2 个
  const toggle = (c: Channel) => {
    const on = s.multi.includes(c);
    if (on && s.multi.length <= 2) return;
    save({ channel: "all", multi: engines.filter((e) => (e === c ? !on : s.multi.includes(e))) });
  };
</script>

<h2>识别渠道</h2>
<div class="sub">选择语音转文字的服务，随时可以在托盘菜单里切换。</div>
<div class="cards">
  {#each engines as c}
    <button class="ch" class:on={s.channel === c} onclick={() => pick(c)}>
      <div class="hd"><ChIcon ch={c} /><b>{CH[c].name}</b><span class="radio"></span></div>
      <p>{CH[c].desc}</p>
      <div class="tags">{#each CH[c].tags as t}<span class="pill">{t}</span>{/each}</div>
      {#if c === "offline" && (s.channel === "offline" || app.offline.state === "downloading" || app.offline.state === "failed")}
        <div class="dl">
          {#if app.offline.state === "ready"}<span class="ok">● 模型已就绪</span>
          {:else if app.offline.state === "downloading"}
            模型 <span class="bar"><i style="width:{(app.offline.progress ?? 0) * 100}%"></i></span>{Math.round((app.offline.progress ?? 0) * 100)}%
          {:else if app.offline.state === "failed"}
            <span class="err">{app.offline.error}</span>
            <span class="link" role="button" tabindex="-1" onclick={(e) => { e.stopPropagation(); call("offline_download"); }} onkeydown={() => {}}>重试</span>
          {:else}
            <span class="link" role="button" tabindex="-1" onclick={(e) => { e.stopPropagation(); call("offline_download"); }} onkeydown={() => {}}>下载模型（约 190MB）</span>
          {/if}
        </div>
      {/if}
    </button>
  {/each}
  <button class="ch" class:wide={engines.length % 2 === 0} class:on={s.channel === "all"} onclick={() => pick("all")}>
    <div class="hd"><ChIcon ch="all" /><b>{CH.all.name}</b><span class="radio"></span></div>
    <p>{CH.all.desc}</p>
    <div class="multi">
      {#each engines as c}
        {@const on = s.multi.includes(c)}
        <span class="mc" class:on class:lock={on && s.multi.length <= 2} role="checkbox" aria-checked={on} tabindex="-1"
          title={on && s.multi.length <= 2 ? "至少保留 2 个渠道" : ""}
          onclick={(e) => { e.stopPropagation(); toggle(c); }} onkeydown={() => {}}>
          <span class="box"></span><ChIcon ch={c} size="xs" />{CH[c].short}
        </span>
      {/each}
      <span class="cnt">已选 {s.multi.length} 个</span>
    </div>
  </button>
</div>
{#if !app.info!.offline.supported}
  <div class="note">ⓘ 离线识别仅支持 Apple 芯片的 Mac{app.info!.platform === "win" ? "，Windows 版暂不提供" : ""}。</div>
{/if}
{#if s.channel === "qwen" || (s.channel === "all" && s.multi.includes("qwen"))}
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
  .dl { margin-top: 10px; display: flex; align-items: center; gap: 8px; font-size: 11.5px; color: var(--fg2); }
  .bar { flex: 1; height: 5px; border-radius: 3px; background: var(--line); overflow: hidden; }
  .bar i { display: block; height: 100%; background: var(--accent); border-radius: 3px; transition: width 0.3s; }
  .link { color: var(--accent); cursor: pointer; }
  .multi { margin-top: 10px; display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
  .mc { display: inline-flex; align-items: center; gap: 6px; padding: 4px 10px 4px 7px; border: 1px solid var(--line); border-radius: 999px; font-size: 12px; color: var(--fg2); background: var(--card); cursor: pointer; transition: 0.15s; }
  .mc:hover { border-color: color-mix(in srgb, var(--accent) 40%, var(--line)); }
  .mc.on { color: var(--fg); border-color: color-mix(in srgb, var(--accent) 55%, var(--line)); background: color-mix(in srgb, var(--accent) 8%, var(--card)); }
  .mc.lock { cursor: default; }
  .box { width: 13px; height: 13px; border-radius: 4px; border: 1.5px solid var(--fg3); position: relative; flex: none; }
  .mc.on .box { background: var(--accent); border-color: var(--accent); }
  .mc.on .box::after { content: ""; position: absolute; left: 3.5px; top: 0.5px; width: 3px; height: 7px; border: solid #fff; border-width: 0 1.6px 1.6px 0; transform: rotate(45deg); }
  .cnt { margin-left: auto; font-size: 11.5px; color: var(--fg3); }
  .err { flex: 1; color: var(--err); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
</style>
