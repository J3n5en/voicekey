<script lang="ts">
  import { app } from "../lib/store.svelte";
  import { call, CH, LOGIN, type Channel } from "../lib/api";

  let { ch }: { ch: Channel } = $props();
  const info = $derived(LOGIN[ch]!);
  const on = $derived(app.accounts[ch] ?? false);
  let cookie = $state("");
  let busy = $state(false);
  let err = $state("");

  async function login() {
    err = "";
    try {
      await call("account_login", { ch });
    } catch (e) {
      err = String(e);
    }
  }

  async function submit() {
    busy = true;
    err = "";
    try {
      await call("account_save", { ch, value: cookie });
      cookie = "";
    } catch (e) {
      err = String(e);
    } finally {
      busy = false;
    }
  }

  function logout() {
    err = "";
    call("account_logout", { ch });
  }
</script>

<h3>{CH[ch].name}账号</h3>
<div class="group">
  <div class="row">
    <div class="lbl">
      {#if on}<span class="ok">● 已登录</span>{:else}未登录{/if}
      <small>在弹出的官方网页登录{info.account}账号，完成后窗口自动关闭。登录 Cookie 只保存在本机</small>
    </div>
    {#if on}<button class="btn" onclick={logout}>退出登录</button>{:else}<button class="btn pri" onclick={login}>登录</button>{/if}
  </div>
  {#if !on}
    <div class="row">
      <div class="lbl">或手动粘贴登录 Cookie<small>{info.cookie}</small></div>
      <input class="in" type="password" autocomplete="off" spellcheck="false" aria-label="Cookie" placeholder="Cookie" bind:value={cookie} />
      <button class="btn" disabled={busy || !cookie.trim()} onclick={submit}>{busy ? "验证中…" : "保存"}</button>
    </div>
  {/if}
  {#if err && !on}<div class="row"><small class="err">{err}</small></div>{/if}
</div>

<style>
  .in { width: 200px; flex: none; border: 1px solid var(--line); background: var(--card2); border-radius: var(--rs); padding: 5px 10px; outline: none; -webkit-user-select: text; user-select: text; cursor: text; }
  .in:focus { border-color: var(--accent); }
  .in::placeholder { color: var(--fg3); }
  .lbl small { word-break: break-all; -webkit-user-select: text; user-select: text; }
</style>
