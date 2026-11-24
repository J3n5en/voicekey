<script lang="ts">
  import { onDestroy } from "svelte";
  import { app, save, setRecordingId } from "../lib/store.svelte";
  import { call, holdName } from "../lib/api";

  const s = $derived(app.s!);
  const mac = $derived(app.info!.platform === "mac");
  const hold = $derived(holdName(s, app.info!.holdKeys));
  const prefix = (m: number) =>
    (mac ? [[1, "⌃"], [2, "⌥"], [4, "⇧"], [8, "⌘"]] : [[1, "Ctrl+"], [2, "Alt+"], [4, "Shift+"], [8, "Win+"]])
      .filter(([b]) => m & (b as number)).map(([, n]) => n).join("");
  const tap = $derived(s.tapShortcut ? prefix(s.tapShortcut.mods) + s.tapShortcut.name : "未设置");

  let target = $state<"tap" | "hold">("tap");
  const rec = (t: "tap" | "hold") => app.recording && target === t;

  let recordingId = 0;
  let revision = 0;
  let pending = Promise.resolve();
  let error = $state("");

  // WebView 的按下/松开不能越过开始或取消命令，尤其是只轻点一下的单修饰键。
  function enqueue(job: () => Promise<void>) {
    const current = revision;
    pending = pending.then(async () => { if (revision === current) await job(); }).catch(async () => {
      if (revision !== current) return;
      ++revision;
      app.recording = false;
      error = "未能连接快捷键录制器，请重试";
      await call("record_shortcut", { on: false }).catch(() => {});
    });
  }

  function setRecording(t: "tap" | "hold", on: boolean) {
    const current = ++revision;
    target = t;
    setRecordingId(0);
    app.recording = on;
    error = "";
    enqueue(async () => {
      const id = await call<number>("record_shortcut", { on, hold: t === "hold" });
      if (revision === current) { recordingId = id; setRecordingId(id); }
    });
  }
  const record = (t: "tap" | "hold") => setRecording(t, !rec(t));
  const cancel = () => { if (app.recording) setRecording(target, false); };
  onDestroy(cancel);

  async function useRightCtrl() {
    if (app.recording) {
      cancel();
      const current = revision;
      await pending;
      if (revision !== current) return;
    }
    save({ tapShortcut: { code: 0xa3, mods: 0, name: "右 Ctrl" } });
  }

  const winModifiers: Record<string, number> = { ShiftLeft: 0xa0, ShiftRight: 0xa1, ControlLeft: 0xa2, ControlRight: 0xa3,
    AltLeft: 0xa4, AltRight: 0xa5, MetaLeft: 0x5b, MetaRight: 0x5c };
  function forward(e: KeyboardEvent | MouseEvent, down: boolean) {
    if (mac || !app.recording) return;
    let code: number;
    let symbol: string | null = null;
    if (e instanceof KeyboardEvent) {
      if (e.isComposing || e.keyCode === 229) return;
      code = winModifiers[e.code] ?? e.keyCode;
      if (code < 1 || code > 254) return;
      if (e.key.length === 1) symbol = e.key;
    } else {
      if (![1, 3, 4].includes(e.button)) return;
      code = 0x10000 + (e.button === 1 ? 2 : e.button);
    }
    e.preventDefault();
    e.stopPropagation();
    if (e instanceof KeyboardEvent && e.repeat) return;
    const mods = +e.ctrlKey | (+e.altKey << 1) | (+e.shiftKey << 2) | (+e.metaKey << 3);
    enqueue(async () => { if (app.recording) await call("record_shortcut_input", { id: recordingId, code, down, mods, symbol }); });
  }
</script>

<svelte:window onkeydowncapture={(e) => forward(e, true)} onkeyupcapture={(e) => forward(e, false)}
  onmousedowncapture={(e) => forward(e, true)} onmouseupcapture={(e) => forward(e, false)} onblur={cancel} />

<h2>快捷键</h2>
<div class="sub">两种方式可同时使用；同一个修饰键也可以既长按又点按。也支持鼠标中键和侧键，录制时按一下即可。</div>
<div class="keys">
  <div class="kcard">
    <button type="button" class="art" aria-label="录制长按快捷键" aria-pressed={rec("hold")} onclick={() => record("hold")}><span class="kbd press">{rec("hold") ? "录制中" : hold}</span><span class="hint">{rec("hold") ? "按住组合，再松开" : "按住说话 · 松开结束"}</span></button>
    <h4>长按说话</h4>
    <small>适合短句，松手即识别完成</small>
    <select class="sel" value={s.holdKey} onchange={(e) => save({ holdKey: e.currentTarget.value })}>
      {#each app.info!.holdKeys as k}<option value={k.id}>{k.name}</option>{/each}
      {#if s.holdCombo}<option value="custom">{s.holdCombo.name}</option>{/if}
    </select>
    <button class="rec hold" class:active={rec("hold")} onclick={() => record("hold")}>
      {#if rec("hold")}按住组合键或鼠标键再松开…（Esc 取消）{:else}自定义组合键，如 {mac ? "⌃ + ⌥" : "Ctrl + Alt"}、修饰键 + 空格 或 鼠标侧键{/if}
    </button>
  </div>
  <div class="kcard">
    <button type="button" class="art" aria-label="录制点按快捷键" aria-pressed={rec("tap")} onclick={() => record("tap")}>
      <span class="kbd tap">{rec("tap") ? "录制中" : tap}</span>
      <span class="hint">{rec("tap") ? "按下并松开你的快捷键" : `点一下开始 · ${s.silenceStop ? "停顿自动结束" : "再点一下结束"}`}</span>
    </button>
    <h4>点按说话</h4>
    <small>{!s.tapShortcut ? `点下方录制框，再单独按下并松开${mac ? "右 ⌘" : "右 Ctrl"}或你想用的键` : s.silenceStop ? "停顿自动结束，也可再点一次提前结束" : `点一下 ${tap} 开始，再点一下结束`}</small>
    <div class="recrow">
      <button class="rec" class:active={rec("tap")} onclick={() => record("tap")}>
        {#if rec("tap")}请按下快捷键或鼠标键…（Esc 取消）{:else}<span class="kbd mini">{tap}</span>点击后按下新的快捷键{/if}
      </button>
      {#if s.tapShortcut && !rec("tap")}<button class="clear" title="关闭点按快捷键" onclick={() => save({ tapShortcut: null })}>✕</button>{/if}
    </div>
    {#if !mac && (s.tapShortcut?.code !== 0xa3 || s.tapShortcut.mods !== 0)}
      <button type="button" class="btn preset" onclick={useRightCtrl}>直接用右 Ctrl</button>
    {/if}
  </div>
</div>
{#if error}<p role="alert">{error}</p>{/if}
<h3>点按模式</h3>
<div class="group">
  <div class="row">
    <div class="lbl">如何结束录音<small>{!s.tapShortcut ? "可以先选结束方式；绑定上方的点按快捷键后生效。" : s.silenceStop ? "停顿超过设定时长即结束，也可手动提前结束" : "免按口述：停顿、移动鼠标或滚动不会结束录音。再按启动录音的快捷键即可结束。"}</small></div>
    <div class="segc" role="group" aria-label="点按结束方式">
      <button class:on={s.silenceStop} aria-pressed={s.silenceStop} onclick={() => save({ silenceStop: true })}>静音自动结束</button>
      <button class:on={!s.silenceStop} aria-pressed={!s.silenceStop} onclick={() => save({ silenceStop: false })}>再按同一快捷键结束</button>
    </div>
  </div>
  {#if !s.silenceStop && s.channel !== "all" && s.streaming}
    <div class="row"><div class="lbl"><small>如需再按结束后才一次性输入，在「输出」中关闭「边说边上屏」。</small></div></div>
  {/if}
  {#if s.silenceStop}
    <div class="row">
      <label class="lbl" for="tap-silence">停顿时长</label>
      <input id="tap-silence" type="range" min="1" max="5" step="0.5" value={s.silence} oninput={(e) => save({ silence: +e.currentTarget.value })} />
      <b class="val">{s.silence} 秒</b>
    </div>
  {/if}
</div>

<style>
  .keys { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
  .kcard { background: var(--card); border: 1px solid var(--line); border-radius: var(--r); padding: 16px; }
  .art { width: 100%; height: 86px; border: 0; border-radius: var(--rs); background: var(--card2); display: flex; align-items: center; justify-content: center; gap: 10px; margin-bottom: 12px; cursor: pointer; }
  .art[aria-pressed="true"] { outline: 2px solid var(--accent); color: var(--accent); }
  .preset { margin-top: 8px; }
  [role="alert"] { color: var(--err); }
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
  .rec.hold { width: 100%; margin-top: 8px; font-size: 12px; }
  .clear { border: 0; background: none; color: var(--fg3); cursor: pointer; font-size: 13px; padding: 4px; }
  input[type="range"] { accent-color: var(--accent); width: 180px; }
  .val { width: 48px; }
</style>
