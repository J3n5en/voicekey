<script lang="ts">
  import { app } from "./store.svelte";
  const n = $derived(Math.round(app.level * 20));
</script>

<div class="meter">
  {#each Array(20) as _, i}<i class:lit={i < n && i <= 15} class:hi={i < n && i > 15}></i>{/each}
</div>

<style>
  .meter { display: flex; gap: 3px; align-items: flex-end; height: 22px; width: 180px; }
  i { flex: 1; background: var(--line); border-radius: 2px; height: 100%; }
  i.lit { background: var(--ok); }
  i.hi { background: var(--warn); }
</style>
