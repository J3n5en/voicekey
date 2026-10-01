<script lang="ts">
  import { CH, type Channel } from "./api";
  import Logo from "./Logo.svelte";
  let { ch, size = "" }: { ch: Channel; size?: string } = $props();
</script>

{#if ch === "all"}
  <span class="ic {size} all"><Logo /></span>
{:else}
  <span class="ic {size}" style="background-image:url({CH[ch].logo})"></span>
{/if}

<style>
  .all { background: #171a2e; }
  .all :global(svg) { width: 78%; height: 78%; }
</style>
