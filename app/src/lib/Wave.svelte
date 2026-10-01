<script lang="ts">
  import { onMount } from "svelte";
  let { level = 0, idle = false, height = 32 }: { level?: number; idle?: boolean; height?: number } = $props();
  let cv: HTMLCanvasElement;
  let shown = 0;

  onMount(() => {
    let raf = 0;
    const draw = () => {
      // 起音快、释放慢，避免波形抖动
      shown = level > shown ? shown * 0.3 + level * 0.7 : shown * 0.85 + level * 0.15;
      const r = devicePixelRatio || 1, w = cv.clientWidth, h = cv.clientHeight;
      if (w) {
        if (cv.width !== w * r) { cv.width = w * r; cv.height = h * r; }
        const x = cv.getContext("2d")!;
        x.setTransform(r, 0, 0, r, 0, 0);
        x.clearRect(0, 0, w, h);
        const g = x.createLinearGradient(0, 0, w, 0);
        g.addColorStop(0, "#22c3ff"); g.addColorStop(0.55, "#7b5cff"); g.addColorStop(1, "#ff3d8b");
        const t = performance.now() / 1000;
        const amp = idle ? 0.16 + 0.1 * (Math.sin(t * 2.1) * 0.5 + 0.5) : 0.06 + shown * 0.94;
        const speed = idle ? 0.42 : 1;
        ([[1.5, 5, 1, 0.95], [2.2, -3.6, 0.7, 0.55], [1, 2.4, 0.5, 0.35]] as const).forEach(([f, sp, sc, al], i) => {
          x.beginPath(); x.globalAlpha = al; x.lineWidth = i ? 1.4 : 2; x.strokeStyle = g; x.lineCap = "round";
          for (let px = 0; px <= w; px += 2) {
            const p = px / w, env = Math.sin(Math.PI * p) ** 2;
            const y = h / 2 + Math.sin(p * Math.PI * 2 * f + t * sp * speed) * amp * (h / 2 - 1) * sc * env;
            px ? x.lineTo(px, y) : x.moveTo(px, y);
          }
          x.stroke();
        });
        x.globalAlpha = 1;
      }
      raf = requestAnimationFrame(draw);
    };
    draw();
    return () => cancelAnimationFrame(raf);
  });
</script>

<canvas bind:this={cv} style="height:{height}px"></canvas>

<style>
  canvas { display: block; width: 100%; min-width: 0; }
</style>
