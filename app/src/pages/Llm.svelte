<script lang="ts">
  import { app, save } from "../lib/store.svelte";
  import { call, type LlmConfig, type LlmTested, type PromptPreview } from "../lib/api";

  let d = $state<LlmConfig>({ ...app.s!.llm });
  let busy = $state(false);
  let testResult = $state<{ ok: boolean; text: string } | null>(null);
  let showPreview = $state(false);
  let preview = $state<PromptPreview | null>(null);
  let timeoutSec = $state<number>(Math.round(d.timeoutMs / 1000));
  let simPercent = $state<number>(Math.round(d.similarityThreshold * 100));
  let urlError = $state("");

  // 地址、Key、模型三项都填好之前视为未配置，后端同样不会发任何请求
  const missing = $derived(
    ([["地址", d.baseUrl], ["API Key", d.apiKey], ["模型", d.model]] as const).filter(([, v]) => !v.trim()).map(([k]) => k),
  );
  const ready = $derived(missing.length === 0 && !urlError);

  const commit = async () => {
    d.timeoutMs = Math.max(2, Math.min(30, Number.isFinite(timeoutSec) ? timeoutSec : 8)) * 1000;
    timeoutSec = Math.round(d.timeoutMs / 1000);
    d.similarityThreshold = Math.max(80, Math.min(100, simPercent)) / 100;
    urlError = "";
    let baseUrl = d.baseUrl;
    if (baseUrl.trim()) {
      try {
        await call<string>("llm_check_url", { baseUrl });
      } catch (e) {
        // 不合法的地址（如远程 http）不保存，其余改动照存
        urlError = String(e);
        baseUrl = app.s!.llm.baseUrl;
      }
    }
    save({ llm: { ...d, baseUrl } });
    if (showPreview) refreshPreview();
  };

  const toggleEnabled = () => {
    d.enabled = !d.enabled;
    testResult = null;
    commit();
  };

  async function refreshPreview() {
    try {
      preview = await call<PromptPreview>("llm_preview_prompt", { config: { ...d } });
    } catch {
      preview = null;
    }
  }

  function togglePreview() {
    showPreview = !showPreview;
    if (showPreview) refreshPreview();
  }

  function resetPrompt() {
    d.systemPrompt = "";
    commit();
  }

  function loadDefaultIntoEditor() {
    if (preview?.defaultSystem) {
      d.systemPrompt = preview.defaultSystem;
      commit();
    } else {
      refreshPreview().then(() => {
        if (preview?.defaultSystem) {
          d.systemPrompt = preview.defaultSystem;
          commit();
        }
      });
    }
  }

  async function testConn() {
    busy = true;
    testResult = null;
    try {
      const t = await call<LlmTested>("llm_test", { config: { ...d } });
      const tok = t.usage ? ` · ${t.usage.totalTokens} tokens` : "";
      testResult = { ok: true, text: `定稿：${t.text}（${t.ms}ms · ${t.model}${tok}）` };
    } catch (e) {
      testResult = { ok: false, text: String(e) };
    } finally {
      busy = false;
    }
  }
</script>

<h3>LLM 融合定稿（OpenAI 兼容）</h3>
<div class="group">
  <div class="row">
    <div class="lbl">
      多渠道定稿后由 LLM 综合生成最终结果
      <small>对比各渠道识别文本，纠错并补全标点，在候选框顶部新增「最终定稿」行。识别文本会发送到你填写的地址。配置完成后由 LLM 代替 Jev 评选，Jev 设置保持不变，关闭 LLM 即恢复</small>
    </div>
    <button class="sw" class:on={d.enabled} onclick={toggleEnabled} aria-label="启用 LLM 融合定稿"></button>
  </div>

  {#if d.enabled}
    {#if missing.length}
      <div class="row"><small class="err">尚未配置，不会发送任何请求：还缺 {missing.join("、")}</small></div>
    {/if}
    <div class="row">
      <div class="lbl">
        Base URL
        <small>OpenAI 兼容接口地址，自动补全 /chat/completions。远程须 https://，本机可用 http://localhost</small>
      </div>
      <input
        class="in"
        type="text"
        spellcheck="false"
        placeholder="https://…/v1"
        bind:value={d.baseUrl}
        onblur={commit}
      />
    </div>
    {#if urlError}
      <div class="row"><small class="err">{urlError}（未保存）</small></div>
    {/if}
    <div class="row">
      <div class="lbl">
        API Key
        <small>仅存本机；本地 Ollama / vLLM 不校验时填任意值</small>
      </div>
      <input
        class="in"
        type="password"
        autocomplete="off"
        spellcheck="false"
        placeholder="sk-..."
        bind:value={d.apiKey}
        onblur={commit}
      />
    </div>
    <div class="row">
      <div class="lbl">
        模型
        <small>填服务商提供的模型名</small>
      </div>
      <input
        class="in"
        type="text"
        spellcheck="false"
        placeholder="模型名"
        bind:value={d.model}
        onblur={commit}
      />
    </div>
    <div class="row">
      <div class="lbl">
        定稿后直接上屏
        <small>开启后融合完成自动上屏；关闭则停留在候选框顶部「最终定稿」行，按回车确认或按数字键选原始渠道</small>
      </div>
      <button
        class="sw"
        class:on={d.autoInsert}
        onclick={() => {
          d.autoInsert = !d.autoInsert;
          commit();
        }}
        aria-label="定稿后直接上屏"
      ></button>
    </div>
    <div class="row">
      <div class="lbl">
        流式输出（SSE）
        <small>开启后在候选框「最终定稿」行边生成边显示</small>
      </div>
      <button
        class="sw"
        class:on={d.stream}
        onclick={() => {
          d.stream = !d.stream;
          commit();
        }}
        aria-label="流式输出"
      ></button>
    </div>
    <div class="row">
      <div class="lbl">请求超时<small>2–30 秒，超时后保留原始渠道供手选</small></div>
      <div class="numbox">
        <input class="in sm" type="number" min="2" max="30" step="1" bind:value={timeoutSec} onblur={commit} />
        <span class="unit">秒</span>
      </div>
    </div>

    <!-- 省 Token：高相似度自动跳过 -->
    <div class="row">
      <div class="lbl">
        高相似度自动跳过 LLM（省 Token）
        <small>当多个渠道定稿文本高度一致且未发生截断时，直接采用最优渠道，跳过 LLM 请求</small>
      </div>
      <button
        class="sw"
        class:on={d.skipSimilar}
        onclick={() => {
          d.skipSimilar = !d.skipSimilar;
          commit();
        }}
        aria-label="高相似度自动跳过 LLM"
      ></button>
    </div>
    {#if d.skipSimilar}
      <div class="row">
        <div class="lbl">
          相似度阈值：{simPercent}%
          <small>越低越容易跳过省 Token，越高越严谨（推荐 92%）</small>
        </div>
        <input
          class="rng"
          type="range"
          min="80"
          max="100"
          step="1"
          bind:value={simPercent}
          onchange={commit}
        />
      </div>
      <div class="row">
        <div class="lbl">最少一致渠道数<small>达到该路数且相似度达标时跳过（≥4 路时同时要求半数一致）</small></div>
        <div class="segc">
          {#each [2, 3] as n}
            <button
              class:on={d.minAgreeChannels === n}
              onclick={() => {
                d.minAgreeChannels = n;
                commit();
              }}
            >{n} 路</button>
          {/each}
        </div>
      </div>
    {/if}

    <!-- 自定义 Prompt 与实时预览 -->
    <div class="row col">
      <div class="bar-hd">
        <div class="lbl">
          自定义 System Prompt
          <small>留空使用内置默认提示词</small>
        </div>
        <div class="acts">
          {#if !d.systemPrompt.trim()}
            <button class="linkbtn" onclick={loadDefaultIntoEditor}>填入默认模板</button>
          {:else}
            <button class="linkbtn" onclick={resetPrompt}>恢复默认</button>
          {/if}
          <button class="btn smbtn" onclick={togglePreview}>{showPreview ? "收起预览" : "预览最终 Prompt"}</button>
        </div>
      </div>
      <textarea
        class="ta"
        rows="5"
        placeholder="留空则自动使用内置默认融合提示词……"
        bind:value={d.systemPrompt}
        onblur={commit}
      ></textarea>

      {#if showPreview}
        <div class="prev">
          <div class="bar-hd">
            <span class="mini">
              实际发送预览{#if preview}（{preview.source} · 约 {preview.estimatedTokens} tokens）{/if}
            </span>
            <div class="acts">
              <button class="linkbtn" onclick={refreshPreview}>刷新</button>
            </div>
          </div>
          {#if preview}
            <div class="psec">
              <div class="plbl">SYSTEM</div>
              <pre>{preview.system}</pre>
            </div>
            <div class="psec">
              <div class="plbl">USER</div>
              <pre>{preview.user}</pre>
            </div>
          {/if}
        </div>
      {/if}
    </div>

    <!-- 连接测试 -->
    <div class="row">
      <div class="lbl">
        连接测试
        {#if testResult}
          <small class:ok={testResult.ok} class:err={!testResult.ok}>{testResult.text}</small>
        {:else if !ready}
          <small class="err">请先填好地址、API Key 和模型</small>
        {:else}
          <small>用内置多渠道分歧示例实测一次 LLM 定稿</small>
        {/if}
      </div>
      <button class="btn" disabled={busy || !ready} onclick={testConn}>{busy ? "测试中…" : "测试连接"}</button>
    </div>
  {/if}
</div>

<style>
  .in { width: 220px; padding: 6px 10px; border: 1px solid var(--line); border-radius: 7px; background: var(--bg); color: var(--fg); font: inherit; font-size: 12.5px; }
  .in.sm { width: 68px; text-align: right; }
  .numbox { display: flex; align-items: center; gap: 6px; }
  .unit { font-size: 12px; color: var(--fg2); }
  .rng { width: 140px; accent-color: var(--accent); }
  .row.col { flex-direction: column; align-items: stretch; gap: 8px; }
  .bar-hd { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
  .acts { display: flex; align-items: center; gap: 10px; flex: none; }
  .mini { font-size: 11.5px; color: var(--fg2); font-weight: 500; }
  .linkbtn { border: 0; background: transparent; color: var(--accent); cursor: pointer; font: inherit; font-size: 12px; padding: 0; }
  .linkbtn:hover { text-decoration: underline; }
  .smbtn { padding: 4px 10px; font-size: 12px; }
  .ta {
    width: 100%; box-sizing: border-box; padding: 8px 10px; border: 1px solid var(--line); border-radius: 8px;
    background: var(--bg); color: var(--fg); font: inherit; font-size: 12px; line-height: 1.5; resize: vertical;
  }
  .prev { border: 1px solid var(--line); border-radius: 8px; background: var(--bg); padding: 10px; display: flex; flex-direction: column; gap: 8px; }
  .psec { display: flex; flex-direction: column; gap: 4px; }
  .plbl { font-size: 10.5px; font-weight: 600; color: var(--accent); letter-spacing: 0.05em; }
  .prev pre {
    margin: 0; white-space: pre-wrap; word-break: break-word; font-family: ui-monospace, SFMono-Regular, Consolas, monospace;
    font-size: 11.5px; line-height: 1.5; color: var(--fg2); max-height: 180px; overflow-y: auto;
    padding: 6px 8px; border-radius: 6px; background: var(--card); border: 1px solid var(--line);
  }
  .ok { color: var(--ok, #2ea043); }
  .err { color: var(--err); }
</style>
