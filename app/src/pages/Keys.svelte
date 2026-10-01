<script lang="ts">
  import { app, save } from "../lib/store.svelte";
  import { call } from "../lib/api";

  const s = $derived(app.s!);
  const mac = $derived(app.info!.platform === "mac");
  const hold = $derived(app.info!.holdKeys.find((k) => k.id === s.holdKey)?.name ?? "");
  const prefix = (m: number) =>
    (mac ? [[1, "⌃"], [2, "⌥"], [4, "⇧"], [8, "⌘"]] : [[1, "Ctrl+"], [2, "Alt+"], [4, "Shift+"], [8, "Win+"]])
      .filter(([b]) => m & (b as number)).map(([, n]) => n).join("");
  const tap = $derived(s.tapShortcut ? prefix(s.tapShortcut.mods) + s.tapShortcut.name : "未设置");

  function record() {
    app.recording = !app.recording;
    call("record_shortcut", { on: app.recording });
  }
</script>

<h2>快捷键</h2>
<div class="sub">两种方式可同时使用；同一个修饰键也可以既长按又点按。</div>
<div class="keys">
  <div class="kcard">
    <div class="art"><span class="kbd press">{hold}</span><span class="hint">按住说话 · 松开结束</span></div>
    <h4>长按说话</h4>
    <small>适合短句，松手即识别完成</small>
    <select class="sel" value={s.holdKey} onchange={(e) => save({ holdKey: e.currentTarget.value })}>
      {#each app.info!.holdKeys as k}<option value={k.id}>{k.name}</option>{/each}
    </select>
  </div>
  <div class="kcard">
    <div class="art"><span class="kbd tap">{tap}</span><span class="hint">点一下开始 · 停顿自动结束</span></div>
    <h4>点按说话</h4>
    <small>适合长段口述，再点一次可提前结束</small>
    <div class="recrow">
      <button class="rec" class:active={app.recording} onclick={record}>
        {#if app.recording}请按下快捷键…（Esc 取消）{:else}<span class="kbd mini">{tap}</span>点击后按下新的快捷键{/if}
      </button>
      {#if s.tapShortcut && !app.recording}<button class="clear" title="关闭点按快捷键" onclick={() => save({ tapShortcut: null })}>✕</button>{/if}
    </div>
  </div>
</div>
{#if s.tapShortcut}
  <h3>点按模式</h3>
  <div class="group">
    <div class="row">
      <div class="lbl">静音自动结束<small>停顿超过该时长视为说完</small></div>
      <input type="range" min="1" max="5" step="0.5" value={s.silence} oninput={(e) => save({ silence: +e.currentTarget.value })} />
      <b class="val">{s.silence} 秒</b>
    </div>
  </div>
{/if}

<style>
  .keys { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
  .kcard { background: var(--card); border: 1px solid var(--line); border-radius: var(--r); padding: 16px; }
  .art { height: 86px; border-radius: var(--rs); background: var(--card2); display: flex; align-items: center; justify-content: center; gap: 10px; margin-bottom: 12px; }
  .hint { color: var(--fg3); }
  .kbd { min-width: 44px; height: 36px; padding: 0 10px; border-radius: 7px; background: var(--card); border: 1px solid var(--line); border-bottom-width: 3px; display: grid; place-items: center; font-weight: 600; font-size: 13px; white-space: nowrap; }
  .kbd.mini { height: 24px; min-width: 0; font-size: 12px; border-bottom-width: 2px; }
  .kbd.press { animation: press 2.4s infinite; }
  .kbd.tap { animation: tap 2.4s infinite; }
  @keyframes press { 0%, 10% { transform: none; border-bottom-width: 3px; } 15%, 70% { transform: translateY(2px); border-bottom-width: 1px; background: color-mix(in srgb, var(--accent) 18%, var(--card)); } 75%, 100% { transform: none; border-bottom-width: 3px; } }
  @keyframes tap { 0%, 8% { transform: none; } 10%, 16% { transform: translateY(2px); background: color-mix(in srgb, var(--accent) 18%, var(--card)); } 18%, 100% { transform: none; } }
  h4 { font-size: 14px; margin-bottom: 2px; }
  .kcard small { color: var(--fg2); font-size: 12px; display: block; margin-bottom: 12px; }
  .recrow { display: flex; gap: 6px; align-items: center; }
  .rec { flex: 1; display: flex; align-items: center; gap: 6px; border: 1.5px dashed var(--accent); border-radius: var(--rs); padding: 6px 10px; color: var(--fg2); cursor: pointer; background: none; text-align: left; }
  .rec.active { background: color-mix(in srgb, var(--accent) 10%, transparent); color: var(--accent); }
  .clear { border: 0; background: none; color: var(--fg3); cursor: pointer; font-size: 13px; padding: 4px; }
  input[type="range"] { accent-color: var(--accent); width: 180px; }
  .val { width: 48px; }
</style>
