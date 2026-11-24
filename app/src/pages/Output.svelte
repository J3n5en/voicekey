<script lang="ts">
  import { app, save } from "../lib/store.svelte";
  const s = $derived(app.s!);
  const all = $derived(s.channel === "all");
  const panelModes = [["remember", "记住上次"], ["collapsed", "默认收起"], ["expanded", "默认展开"]] as const;
</script>

<h2>输出</h2>
<div class="sub">识别结果如何进入输入框。</div>
<div class="group">
  <div class="row">
    <div class="lbl">边说边上屏<small>{all ? "「多渠道」模式下需先挑选结果，此项不可用" : "识别中的文字实时打到光标处，结束后按定稿修正；关闭后改为结束时一次性粘贴"}</small></div>
    <button class="sw" class:on={s.streaming} disabled={all} onclick={() => save({ streaming: !s.streaming })} aria-label="边说边上屏"></button>
  </div>
  <div class="row">
    <div class="lbl">胶囊显示实时文字<small>在屏幕底部胶囊中预览识别内容</small></div>
    <button class="sw" class:on={s.liveText} onclick={() => save({ liveText: !s.liveText })} aria-label="胶囊显示实时文字"></button>
  </div>
  <div class="row">
    <div class="lbl">多渠道候选窗<small>{s.pickPanelStart === "remember" ? "首次收起，以后按最后一次手动收展的状态打开。" : s.pickPanelStart === "expanded" ? "每次新录音先显示候选列表。" : "每次新录音先显示小胶囊。"}录音中仍可随时切换。</small></div>
    <div class="segc" role="group" aria-label="多渠道候选窗开始方式">
      {#each panelModes as [mode, label]}
        <button type="button" class:on={s.pickPanelStart === mode} aria-pressed={s.pickPanelStart === mode} onclick={() => save({ pickPanelStart: mode })}>{label}</button>
      {/each}
    </div>
  </div>
  <div class="row">
    <div class="lbl">去除标点<small>上屏前删掉逗号、句号等标点；小数点、千分位、时间和网址中的符号保留</small></div>
    <button class="sw" class:on={s.stripPunctuation} onclick={() => save({ stripPunctuation: !s.stripPunctuation })} aria-label="去除标点"></button>
  </div>
  <div class="row">
    <div class="lbl">无输入位置时也强制上屏<small>开启后即使识别不到输入框也会直接粘贴，可能贴到错误位置，默认关闭</small></div>
    <button class="sw" class:on={s.forcePasteWithoutTarget} onclick={() => save({ forcePasteWithoutTarget: !s.forcePasteWithoutTarget })} aria-label="无输入位置时也强制上屏"></button>
  </div>
</div>
