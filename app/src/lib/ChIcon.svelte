<script lang="ts">
  import { CH, type Channel } from "./api";
  import Logo from "./Logo.svelte";
  let { ch, size = "" }: { ch: Channel; size?: string } = $props();
</script>

{#if ch === "all"}
  <span class="ic {size} all"><Logo /></span>
{:else if !CH[ch].logo}
  <span class="ic {size} local">SV</span>
{:else}
  <span class="ic {size}" style="background-image:url({CH[ch].logo})"></span>
{/if}

<style>
  .local { background: #2f6bff; color: #fff; display: flex; align-items: center; justify-content: center; font-size: 9px; font-weight: 700; letter-spacing: 0.2px; }
  .all { background: #171a2e; }
  .all :global(svg) { width: 78%; height: 78%; }
</style>
