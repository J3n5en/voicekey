<script lang="ts">
  import { app } from "../lib/store.svelte";
  import { call } from "../lib/api";
  const p = $derived(app.perms);
</script>

<div class="row">
  <div class="lbl">辅助功能<small>监听快捷键、把文字打到光标处</small></div>
  {#if p.accessibility}<span class="ok">● 已授权</span>
  {:else}<button class="btn pri" onclick={() => call("perm_action", { kind: "accessibility" })}>去授权</button>{/if}
</div>
<div class="row">
  <div class="lbl">麦克风<small>录制语音用于识别</small></div>
  {#if p.mic === "granted"}<span class="ok">● 已授权</span>
  {:else if p.mic === "undetermined"}<button class="btn pri" onclick={() => call("perm_action", { kind: "mic-request" })}>授权</button>
  {:else}<button class="btn pri" onclick={() => call("perm_action", { kind: "mic" })}>去授权</button>{/if}
</div>
