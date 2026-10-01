<script lang="ts">
  import { onMount } from "svelte";
  import { call, on, applyLook, type AppInfo, type Channel } from "./lib/api";
  import ChIcon from "./lib/ChIcon.svelte";
  import Wave from "./lib/Wave.svelte";

  let st = $state<{ state: string; text: string; channel: Channel }>({ state: "hidden", text: "", channel: "doubao" });
  let level = $state(0);

  onMount(() => {
    call<AppInfo>("get_state").then((i) => applyLook(i.platform, "dark"));
    const un = [
      on<{ state: string; text?: string; channel?: Channel }>("hud", (p) => (st = { ...st, text: "", ...p })),
      on<number>("level", (v) => (level = v)),
    ];
    return () => un.forEach((p) => p.then((f) => f()));
  });
</script>

<div class="wrap">
  <div class="capsule" class:show={st.state !== "hidden"} class:error={st.state === "error"}>
    {#if st.state === "error"}
      <span class="ic sm bad">!</span>
    {:else}
      <ChIcon ch={st.channel} size="sm" />
    {/if}
    {#if st.state === "listen"}
      <div class="wave"><Wave {level} height={30} /></div>
    {/if}
    {#if st.text}
      <div class="live"><span>{st.text}</span></div>
    {:else if st.state === "wait"}
      <div class="hint">识别中…</div>
    {/if}
    {#if st.state === "wait"}<span class="spin"></span>{/if}
  </div>
</div>

<style>
  .wrap { height: 100vh; display: flex; align-items: flex-end; justify-content: center; padding-bottom: 14px; }
  .capsule {
    display: flex; align-items: center; gap: 12px; height: 46px; max-width: 640px; padding: 0 18px 0 12px; border-radius: 23px;
    background: rgba(18, 19, 30, 0.86); color: #fff; box-shadow: 0 8px 28px rgba(0, 0, 0, 0.35), inset 0 0 0 1px rgba(255, 255, 255, 0.08);
    opacity: 0; transform: translateY(8px) scale(0.98); transition: opacity 0.16s, transform 0.16s;
  }
  .capsule.show { opacity: 1; transform: none; }
  .wave { width: 120px; flex: none; }
  .live { min-width: 0; max-width: 460px; white-space: nowrap; overflow: hidden; direction: rtl; text-align: left; font-size: 14px; }
  .live span { direction: ltr; unicode-bidi: plaintext; }
  .hint { font-size: 13px; opacity: 0.7; }
  .bad { background: var(--err); font-size: 13px; }
  .spin { width: 14px; height: 14px; border-radius: 50%; border: 2px solid rgba(255, 255, 255, 0.25); border-top-color: #fff; animation: spin 0.8s linear infinite; flex: none; }
</style>
