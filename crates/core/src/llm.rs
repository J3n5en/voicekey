//! 多渠道语音识别自动 LLM 融合定稿模块（OpenAI 兼容 `/v1/chat/completions`）。
//!
//! - 支持任意 OpenAI 兼容端点（OpenAI / DeepSeek / 通义 / Ollama / vLLM 等），支持非流式与 SSE 流式输出
//! - 内置本地「高相似度自动跳过」机制（归一化编辑距离 + 最大一致团 + 防截断保护），零 Token 省费
//! - 支持自定义 System Prompt 及实时 Prompt 预览
use crate::util::strip_punctuation;
use anyhow::{anyhow, bail, Result};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::{Duration, Instant};

pub const DEFAULT_TIMEOUT_MS: u64 = 8_000;
pub const MIN_TIMEOUT_MS: u64 = 2_000;
pub const MAX_TIMEOUT_MS: u64 = 30_000;
pub const DEFAULT_SIMILARITY_THRESHOLD: f64 = 0.92;
pub const MIN_SIMILARITY_THRESHOLD: f64 = 0.80;
pub const MAX_SIMILARITY_THRESHOLD: f64 = 1.00;
pub const DEFAULT_MIN_AGREE: usize = 2;
/// 流式输出回调，参数为目前累计的全文
pub type OnDelta = Box<dyn Fn(&str) + Send + Sync>;
/// 输出上限：按最长候选估 token，留余量但不让模型长篇输出
const MIN_MAX_TOKENS: usize = 64;
const MAX_MAX_TOKENS: usize = 2048;

pub const DEFAULT_SYSTEM_PROMPT: &str = "\
你是一个语音识别（ASR）多路结果融合专家。下面是一段同一份口语录音经多个语音识别引擎并行转写的结果。
请综合对比所有渠道的识别结果，还原出最准确、完整、自然、标点合理的最终文本。

融合原则：
1. 完整性优先：若某渠道因中途停顿触发 VAD 提前截断而漏掉后半句，以识别完整的渠道为准。
2. 多路交叉纠错：字词有分歧时，结合语音同音/近音规律与上下文语义选择最合理的词（含专有名词与中英文大小写）。
3. 忠于原意：整理标点与排版，不得擅自增删或改写说话人的核心意思。
4. 输出要求：仅输出最终定稿文本，不要输出解释、分析、前缀或外层引号。";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Config {
    pub enabled: bool,
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    /// 定稿完成后是否直接上屏；false 时停留在候选框的「最终定稿」行供确认
    pub auto_insert: bool,
    /// 是否使用 SSE 流式输出
    pub stream: bool,
    pub timeout_ms: u64,
    /// 自定义 System Prompt；留空使用内置默认提示词
    pub system_prompt: String,
    /// 多路结果高度相似时是否跳过 LLM（省 Token）
    pub skip_similar: bool,
    /// 归一化编辑距离相似度阈值（0.80..=1.00）
    pub similarity_threshold: f64,
    /// 触发跳过的最少一致渠道数（2..=6）
    pub min_agree_channels: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            enabled: false,
            base_url: String::new(),
            api_key: String::new(),
            model: String::new(),
            auto_insert: false,
            stream: true,
            timeout_ms: DEFAULT_TIMEOUT_MS,
            system_prompt: String::new(),
            skip_similar: true,
            similarity_threshold: DEFAULT_SIMILARITY_THRESHOLD,
            min_agree_channels: DEFAULT_MIN_AGREE,
        }
    }
}

impl Config {
    pub fn sanitize(&mut self) {
        self.base_url = self.base_url.trim().to_string();
        self.api_key = self.api_key.trim().to_string();
        self.model = self.model.trim().to_string();
        self.timeout_ms = self.timeout_ms.clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);
        if !self.similarity_threshold.is_finite() {
            self.similarity_threshold = DEFAULT_SIMILARITY_THRESHOLD;
        }
        self.similarity_threshold = self.similarity_threshold.clamp(MIN_SIMILARITY_THRESHOLD, MAX_SIMILARITY_THRESHOLD);
        self.min_agree_channels = self.min_agree_channels.clamp(2, 6);
    }

    /// 启用且配置完整、地址合法；否则一律不发请求
    pub fn is_ready(&self) -> bool {
        self.enabled && self.check().is_ok()
    }

    /// 还没填的项（地址、API Key、模型），界面据此提示
    pub fn missing(&self) -> Vec<&'static str> {
        [("地址", &self.base_url), ("API Key", &self.api_key), ("模型", &self.model)]
            .into_iter()
            .filter(|(_, v)| v.trim().is_empty())
            .map(|(k, _)| k)
            .collect()
    }

    /// 三项都填好且地址合法时返回请求地址
    pub fn check(&self) -> Result<String> {
        let missing = self.missing();
        if !missing.is_empty() {
            bail!("LLM 未配置：缺少{}", missing.join("、"));
        }
        self.endpoint()
    }

    /// 规范化 OpenAI 兼容 `/chat/completions` 完整地址。远程必须 https，http 只允许本机回环
    pub fn endpoint(&self) -> Result<String> {
        let raw = self.base_url.trim();
        if raw.is_empty() {
            bail!("请先填写 LLM API 地址（Base URL）");
        }
        let full = if raw.contains("://") { raw.to_string() } else { format!("https://{raw}") };
        let mut u = reqwest::Url::parse(&full).map_err(|e| anyhow!("LLM API 地址格式无效：{e}"))?;
        match u.scheme() {
            "https" => {}
            "http" if matches!(u.host_str(), Some("localhost" | "127.0.0.1" | "[::1]")) => {}
            "http" => bail!("远程 LLM 地址必须使用 https://，http:// 只允许 localhost、127.0.0.1、::1"),
            s => bail!("不支持的 LLM 地址协议：{s}"),
        }
        let p = u.path().trim_end_matches('/').to_string();
        let path = if p.ends_with("/chat/completions") {
            p
        } else if p.ends_with("/v1") || p.ends_with("/v1beta/openai") || p.ends_with("/compatible-mode/v1") {
            format!("{p}/chat/completions")
        } else if p.is_empty() {
            "/v1/chat/completions".to_string()
        } else {
            format!("{p}/chat/completions")
        };
        u.set_path(&path);
        Ok(u.to_string())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CandidateInput {
    pub channel: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub elapsed_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hints: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub total_tokens: u64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FuseResult {
    pub text: String,
    pub ms: u64,
    pub model: String,
    pub usage: Option<Usage>,
    pub system_prompt: String,
    pub user_prompt: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Tested {
    pub text: String,
    pub ms: u64,
    pub model: String,
    pub usage: Option<Usage>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PromptPreview {
    pub system: String,
    pub user: String,
    pub default_system: String,
    pub estimated_tokens: usize,
    pub source: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SkipDecision {
    pub picked_index: usize,
    pub agree_count: usize,
    pub avg_similarity: f64,
    pub cluster_indices: Vec<usize>,
    pub matrix: Vec<Vec<f64>>,
}

/// 组装实际发给 LLM 的 `(system_prompt, user_prompt)`
pub fn build_prompt(cfg: &Config, candidates: &[CandidateInput]) -> (String, String) {
    let system = if cfg.system_prompt.trim().is_empty() {
        DEFAULT_SYSTEM_PROMPT.to_string()
    } else {
        cfg.system_prompt.trim().to_string()
    };

    let mut user = String::from("以下是各语音识别渠道的定稿结果：\n");
    for (i, c) in candidates.iter().enumerate() {
        user.push_str(&format!("\n{}. [{}]", i + 1, c.channel));
        if let Some(ms) = c.elapsed_ms {
            user.push_str(&format!("（耗时 {:.2}s）", ms as f64 / 1000.0));
        }
        user.push_str(&format!("\n{}", c.text.trim()));
        for h in &c.hints {
            user.push_str(&format!("\n  - 线索：{h}"));
        }
        user.push('\n');
    }
    (system, user)
}

/// 设置页预览用：生成完整 `PromptPreview`
pub fn preview_prompt(cfg: &Config, candidates: &[CandidateInput], source: &str) -> PromptPreview {
    let (system, user) = build_prompt(cfg, candidates);
    // 粗略估算 Token：中文约 1 字 ~ 1.5 token，ASCII 约 4 字符 ~ 1 token
    let est = estimate_tokens(&system) + estimate_tokens(&user);
    PromptPreview {
        system,
        user,
        default_system: DEFAULT_SYSTEM_PROMPT.to_string(),
        estimated_tokens: est,
        source: source.to_string(),
    }
}

fn estimate_tokens(s: &str) -> usize {
    let mut ascii = 0usize;
    let mut other = 0usize;
    for c in s.chars() {
        if c.is_ascii() {
            ascii += 1;
        } else {
            other += 1;
        }
    }
    ascii.div_ceil(4) + (other * 3).div_ceil(2)
}

/// 比较用文本归一化：去标点、全角字母数字转半角、ASCII 转小写、去空白
pub fn normalize_for_similarity(s: &str) -> Vec<char> {
    let stripped = strip_punctuation(s);
    stripped
        .chars()
        .filter_map(|c| {
            if c.is_whitespace() {
                return None;
            }
            let c = match c as u32 {
                0xFF01..=0xFF5E => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
                _ => c,
            };
            Some(c.to_ascii_lowercase())
        })
        .collect()
}

fn levenshtein(a: &[char], b: &[char]) -> usize {
    let (n, m) = (a.len(), b.len());
    if n == 0 {
        return m;
    }
    if m == 0 {
        return n;
    }
    let mut prev: Vec<usize> = (0..=m).collect();
    let mut curr = vec![0usize; m + 1];
    for (i, &ca) in a.iter().enumerate() {
        curr[0] = i + 1;
        for (j, &cb) in b.iter().enumerate() {
            let cost = usize::from(ca != cb);
            curr[j + 1] = (prev[j + 1] + 1).min(curr[j] + 1).min(prev[j] + cost);
        }
        std::mem::swap(&mut prev, &mut curr);
    }
    prev[m]
}

/// 两段文本的归一化字符相似度（0.0..=1.0）
pub fn similarity(a: &str, b: &str) -> f64 {
    let na = normalize_for_similarity(a);
    let nb = normalize_for_similarity(b);
    let denom = na.len().max(nb.len());
    if denom == 0 {
        return 1.0;
    }
    1.0 - (levenshtein(&na, &nb) as f64 / denom as f64)
}

/// 尝试判定多路结果是否高度一致以跳过 LLM（省 Token）。
/// `preferred_order` 为 `candidates` 下标的偏好排序（靠前优先，如按历史 pick_counts 排序）。
pub fn try_skip_similar(cfg: &Config, candidates: &[CandidateInput], preferred_order: &[usize]) -> Option<SkipDecision> {
    let n = candidates.len();
    if !cfg.skip_similar || n < 2 {
        return None;
    }
    let norms: Vec<Vec<char>> = candidates.iter().map(|c| normalize_for_similarity(&c.text)).collect();
    let max_len = norms.iter().map(Vec::len).max().unwrap_or(0);
    if max_len == 0 {
        return None;
    }

    let mut matrix = vec![vec![1.0f64; n]; n];
    for i in 0..n {
        for j in (i + 1)..n {
            let denom = norms[i].len().max(norms[j].len());
            let sim = if denom == 0 {
                1.0
            } else {
                1.0 - (levenshtein(&norms[i], &norms[j]) as f64 / denom as f64)
            };
            matrix[i][j] = sim;
            matrix[j][i] = sim;
        }
    }

    let threshold = cfg.similarity_threshold.clamp(MIN_SIMILARITY_THRESHOLD, MAX_SIMILARITY_THRESHOLD);
    let required = if n <= 3 {
        cfg.min_agree_channels.max(2)
    } else {
        cfg.min_agree_channels.max(n.div_ceil(2))
    };

    // 寻找最大一致团（以每个节点为锚，收集与之相似度 >= threshold 的成员，并验证两两平均相似度）
    let mut best_cluster: Vec<usize> = Vec::new();
    let mut best_avg = 0.0f64;
    for i in 0..n {
        let cluster: Vec<usize> = (0..n).filter(|&j| matrix[i][j] >= threshold).collect();
        if cluster.len() < required {
            continue;
        }
        // 防截断保护：一致团中最长文本必须至少达到全局最长的 85%
        let cluster_max = cluster.iter().map(|&idx| norms[idx].len()).max().unwrap_or(0);
        if (cluster_max as f64) < (max_len as f64) * 0.85 {
            continue;
        }
        let mut sum = 0.0;
        let mut pairs = 0usize;
        for a in 0..cluster.len() {
            for b in (a + 1)..cluster.len() {
                sum += matrix[cluster[a]][cluster[b]];
                pairs += 1;
            }
        }
        let avg = if pairs > 0 { sum / pairs as f64 } else { 1.0 };
        if cluster.len() > best_cluster.len() || (cluster.len() == best_cluster.len() && avg > best_avg) {
            best_cluster = cluster;
            best_avg = avg;
        }
    }

    if best_cluster.len() < required {
        return None;
    }

    // 在一致团内择优：1) 有句末标点优先 2) 标点数量更合理 3) 用户偏好顺序
    let pref_rank = |idx: usize| -> usize {
        preferred_order.iter().position(|&p| p == idx).unwrap_or(usize::MAX)
    };
    let picked = *best_cluster
        .iter()
        .min_by_key(|&&idx| {
            let t = candidates[idx].text.trim();
            let has_end_punct = t.chars().last().is_some_and(|c| matches!(c, '。' | '！' | '？' | '.' | '!' | '?'));
            let punct_count = t.chars().filter(|c| matches!(c, '，' | '。' | '！' | '？' | '、' | '；' | ',' | '.' | '!' | '?')).count();
            (
                usize::from(!has_end_punct),
                std::cmp::Reverse(punct_count),
                pref_rank(idx),
            )
        })
        .unwrap();

    Some(SkipDecision {
        picked_index: picked,
        agree_count: best_cluster.len(),
        avg_similarity: best_avg,
        cluster_indices: best_cluster,
        matrix,
    })
}

/// 剥离模型偶发输出的外层引号或 Markdown 代码块包裹
fn clean_llm_output(raw: &str) -> String {
    let mut s = raw.trim().to_string();
    if let Some(inner) = s.strip_prefix("```").and_then(|rest| rest.strip_suffix("```")) {
        let inner = inner.trim();
        let inner = inner
            .split_once('\n')
            .filter(|(first, _)| !first.is_empty() && first.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'))
            .map_or(inner, |(_, body)| body);
        s = inner.trim().to_string();
    }
    for (l, r) in [('"', '"'), ('“', '”'), ('「', '」')] {
        if s.starts_with(l) && s.ends_with(r) && s.chars().count() >= 2 {
            let inner = &s[l.len_utf8()..s.len() - r.len_utf8()];
            if !inner.contains(l) && !inner.contains(r) {
                s = inner.trim().to_string();
            }
        }
    }
    s
}

/// 调用 OpenAI 兼容 `/chat/completions` 接口进行多路融合定稿
pub async fn fuse(
    cfg: &Config,
    candidates: &[CandidateInput],
    on_delta: Option<OnDelta>,
) -> Result<FuseResult> {
    if candidates.is_empty() {
        bail!("没有可用于融合的识别结果");
    }
    let url = cfg.check()?;
    let model = cfg.model.trim().to_string();
    let (system_prompt, user_prompt) = build_prompt(cfg, candidates);
    let use_stream = cfg.stream && on_delta.is_some();
    let timeout = Duration::from_millis(cfg.timeout_ms.clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS));
    let longest = candidates.iter().map(|c| c.text.trim().chars().count()).max().unwrap_or(0);

    let mut body = json!({
        "model": model,
        "temperature": 0.1,
        "max_tokens": (longest * 2 + MIN_MAX_TOKENS).min(MAX_MAX_TOKENS),
        "stream": use_stream,
        "messages": [
            { "role": "system", "content": system_prompt },
            { "role": "user", "content": user_prompt },
        ],
    });
    if use_stream {
        body["stream_options"] = json!({ "include_usage": true });
    }

    let builder = reqwest::Client::builder().timeout(timeout);
    // 单测只打回环假服务，不能被本机代理环境变量带偏
    #[cfg(test)]
    let builder = builder.no_proxy();
    let req = builder
        .build()?
        .post(&url)
        .header("Content-Type", "application/json")
        .header("Authorization", format!("Bearer {}", cfg.api_key.trim()));

    let started = Instant::now();
    let resp = req.json(&body).send().await.map_err(|e| anyhow!("LLM 请求失败：{e}"))?;
    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().await.unwrap_or_default();
        let clip: String = text.chars().take(200).collect();
        bail!("LLM HTTP {}：{}", status.as_u16(), clip);
    }

    let (text, usage) = if use_stream {
        parse_sse_stream(resp, on_delta.as_deref()).await?
    } else {
        let v: Value = resp.json().await.map_err(|e| anyhow!("LLM 响应解析失败：{e}"))?;
        let content = v["choices"][0]["message"]["content"]
            .as_str()
            .unwrap_or("")
            .to_string();
        let usage = parse_usage(&v["usage"]);
        (content, usage)
    };

    let text = clean_llm_output(&text);
    if text.is_empty() {
        bail!("LLM 返回了空内容");
    }
    // 定稿只做纠错和标点，明显长于所有候选说明模型答非所问（或被识别文本里的指令带偏），不能上屏
    if text.chars().count() > longest * 2 + 20 {
        bail!("LLM 输出明显长于各渠道结果，已忽略");
    }
    Ok(FuseResult {
        text,
        ms: started.elapsed().as_millis() as u64,
        model,
        usage,
        system_prompt,
        user_prompt,
    })
}

fn parse_usage(u: &Value) -> Option<Usage> {
    let prompt = u.get("prompt_tokens")?.as_u64()?;
    let completion = u.get("completion_tokens")?.as_u64()?;
    let total = u.get("total_tokens").and_then(Value::as_u64).unwrap_or(prompt + completion);
    Some(Usage { prompt_tokens: prompt, completion_tokens: completion, total_tokens: total })
}

async fn parse_sse_stream(
    resp: reqwest::Response,
    on_delta: Option<&(dyn Fn(&str) + Send + Sync)>,
) -> Result<(String, Option<Usage>)> {
    let mut stream = resp.bytes_stream();
    // 按字节攒到换行再解码：网络块可能切在多字节字符中间，逐块解码会出乱码
    let mut buf: Vec<u8> = Vec::new();
    let mut acc = String::new();
    let mut usage: Option<Usage> = None;

    while let Some(chunk) = stream.next().await {
        let bytes = chunk.map_err(|e| anyhow!("LLM 流式读取失败：{e}"))?;
        buf.extend_from_slice(&bytes);
        while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
            let raw: Vec<u8> = buf.drain(..=pos).collect();
            let line = String::from_utf8_lossy(&raw);
            let line = line.trim();
            if let Some(data) = line.strip_prefix("data:") {
                let data = data.trim();
                if data == "[DONE]" || data.is_empty() {
                    continue;
                }
                if let Ok(v) = serde_json::from_str::<Value>(data) {
                    if let Some(u) = parse_usage(&v["usage"]) {
                        usage = Some(u);
                    }
                    if let Some(delta) = v["choices"][0]["delta"]["content"].as_str() {
                        if !delta.is_empty() {
                            acc.push_str(delta);
                            if let Some(cb) = on_delta {
                                cb(&acc);
                            }
                        }
                    }
                }
            }
        }
    }
    Ok((acc, usage))
}

/// 内置示例候选（用于测试按钮及无历史日志时的 Prompt 预览）
pub fn sample_candidates() -> Vec<CandidateInput> {
    vec![
        CandidateInput {
            channel: "doubao".into(),
            text: "今天下午三点开会，记得带上最新版的 PPT。".into(),
            elapsed_ms: Some(420),
            hints: Vec::new(),
        },
        CandidateInput {
            channel: "wetype".into(),
            text: "今天下午三点开灰，记得带上呃那个最新版的ppt。".into(),
            elapsed_ms: Some(390),
            hints: Vec::new(),
        },
        CandidateInput {
            channel: "qwen".into(),
            text: "今天下午三点开会记得带上呃最新版的ppt".into(),
            elapsed_ms: Some(510),
            hints: Vec::new(),
        },
    ]
}

/// 设置页「测试连接」按钮
pub async fn test(cfg: &Config) -> Result<Tested> {
    let mut c = cfg.clone();
    c.stream = false;
    let res = fuse(&c, &sample_candidates(), None).await?;
    Ok(Tested { text: res.text, ms: res.ms, model: res.model, usage: res.usage })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_normalizes_openai_compatible_urls() {
        let mut c = Config::default();
        c.base_url = "https://api.openai.com/v1".into();
        assert_eq!(c.endpoint().unwrap(), "https://api.openai.com/v1/chat/completions");

        c.base_url = "https://api.deepseek.com".into();
        assert_eq!(c.endpoint().unwrap(), "https://api.deepseek.com/v1/chat/completions");

        c.base_url = "http://localhost:11434/v1/chat/completions".into();
        assert_eq!(c.endpoint().unwrap(), "http://localhost:11434/v1/chat/completions");
    }

    #[test]
    fn skip_similar_triggers_on_matching_clean_results_and_picks_punctuated() {
        let cfg = Config::default();
        let cands = vec![
            CandidateInput { channel: "qwen".into(), text: "今天下午三点开会".into(), elapsed_ms: None, hints: vec![] },
            CandidateInput { channel: "doubao".into(), text: "今天下午三点开会。".into(), elapsed_ms: None, hints: vec![] },
            CandidateInput { channel: "wetype".into(), text: "今天下午三点开会！".into(), elapsed_ms: None, hints: vec![] },
        ];
        let skip = try_skip_similar(&cfg, &cands, &[0, 1, 2]).expect("should skip");
        assert_eq!(skip.agree_count, 3);
        // 优先选带句末标点的 doubao (index 1) 而不是无标点的 qwen (index 0)
        assert_eq!(skip.picked_index, 1);
    }

    #[test]
    fn skip_similar_guards_against_truncated_consensus() {
        let cfg = Config::default();
        let cands = vec![
            CandidateInput { channel: "a".into(), text: "今天下午三点开会".into(), elapsed_ms: None, hints: vec![] },
            CandidateInput { channel: "b".into(), text: "今天下午三点开会".into(), elapsed_ms: None, hints: vec![] },
            CandidateInput { channel: "c".into(), text: "今天下午三点开会并且讨论下季度产品规划方案".into(), elapsed_ms: None, hints: vec![] },
        ];
        // a 和 b 虽完全一致，但远短于 c（疑似截断），不能跳过 LLM
        assert!(try_skip_similar(&cfg, &cands, &[0, 1, 2]).is_none());
    }

    #[test]
    fn build_prompt_uses_default_or_custom_system_prompt() {
        let cfg = Config::default();
        let (sys, user) = build_prompt(&cfg, &sample_candidates());
        assert_eq!(sys, DEFAULT_SYSTEM_PROMPT);
        assert!(user.contains("[doubao]"));
    }

    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    fn ready(port: u16) -> Config {
        Config {
            enabled: true,
            base_url: format!("http://127.0.0.1:{port}/v1"),
            api_key: "test-key".into(),
            model: "m".into(),
            timeout_ms: MIN_TIMEOUT_MS,
            ..Config::default()
        }
    }

    /// 读完一个 HTTP 请求（头 + Content-Length 正文），返回正文
    async fn read_request(s: &mut TcpStream) -> String {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            let n = s.read(&mut chunk).await.unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&chunk[..n]);
            let text = String::from_utf8_lossy(&buf);
            if let Some(end) = text.find("\r\n\r\n") {
                let len = text[..end]
                    .lines()
                    .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap()))
                    .unwrap_or(0);
                if buf.len() >= end + 4 + len {
                    return String::from_utf8_lossy(&buf[end + 4..end + 4 + len]).into_owned();
                }
            }
        }
        String::new()
    }

    /// 本地假服务：按顺序写出各段（段间停顿，模拟网络分块），返回收到的请求正文
    async fn serve(parts: Vec<Vec<u8>>) -> (u16, tokio::task::JoinHandle<String>) {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        let h = tokio::spawn(async move {
            let (mut s, _) = l.accept().await.unwrap();
            let body = read_request(&mut s).await;
            for p in parts {
                s.write_all(&p).await.unwrap();
                s.flush().await.unwrap();
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            body
        });
        (port, h)
    }

    fn sse_head() -> Vec<u8> {
        b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".to_vec()
    }

    fn json_response(v: &Value) -> Vec<u8> {
        let body = v.to_string();
        format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).into_bytes()
    }

    fn sink() -> Option<OnDelta> {
        Some(Box::new(|_: &str| {}))
    }

    #[test]
    fn remote_http_is_rejected_but_loopback_http_and_https_pass() {
        let mut c = Config::default();
        for ok in ["https://api.example.com/v1", "api.example.com/v1", "http://localhost:11434/v1", "http://127.0.0.1:8000", "http://[::1]:8000/v1"] {
            c.base_url = ok.into();
            assert!(c.endpoint().is_ok(), "{ok} 应允许");
        }
        for bad in ["http://api.example.com/v1", "http://192.168.1.2:11434/v1", "http://127.0.0.2/v1", "ftp://example.com"] {
            c.base_url = bad.into();
            assert!(c.endpoint().is_err(), "{bad} 应拒绝");
        }
    }

    #[test]
    fn defaults_point_nowhere_and_need_all_three_fields() {
        let mut c = Config { enabled: true, ..Config::default() };
        assert!(c.base_url.is_empty() && c.model.is_empty());
        assert_eq!(c.missing(), ["地址", "API Key", "模型"]);
        assert!(!c.is_ready());
        c.base_url = "https://api.example.com/v1".into();
        c.model = "m".into();
        assert_eq!(c.missing(), ["API Key"]);
        assert!(!c.is_ready());
        c.api_key = "k".into();
        assert!(c.is_ready());
        c.enabled = false;
        assert!(!c.is_ready());
    }

    #[tokio::test]
    async fn unconfigured_fuse_sends_nothing() {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        let hits = Arc::new(AtomicUsize::new(0));
        let h = hits.clone();
        tokio::spawn(async move {
            while l.accept().await.is_ok() {
                h.fetch_add(1, Ordering::SeqCst);
            }
        });
        let mut cfg = ready(port);
        cfg.api_key.clear();
        assert!(fuse(&cfg, &sample_candidates(), None).await.unwrap_err().to_string().contains("API Key"));
        let mut cfg = ready(port);
        cfg.model.clear();
        assert!(test(&cfg).await.is_err());
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(hits.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn sse_decodes_char_split_across_chunks_and_reads_usage() {
        let line = "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\n".as_bytes();
        let cut = line.iter().position(|&b| b >= 0x80).unwrap() + 1;
        let tail = b"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}\n\ndata: [DONE]\n\n".to_vec();
        let (port, req) = serve(vec![sse_head(), line[..cut].to_vec(), line[cut..].to_vec(), tail]).await;
        let res = fuse(&ready(port), &sample_candidates(), sink()).await.unwrap();
        assert_eq!(res.text, "你好");
        assert_eq!(res.usage.unwrap().total_tokens, 5);
        let body: Value = serde_json::from_str(&req.await.unwrap()).unwrap();
        assert_eq!(body["stream"], true);
        let longest = sample_candidates().iter().map(|c| c.text.chars().count()).max().unwrap();
        assert_eq!(body["max_tokens"], longest * 2 + MIN_MAX_TOKENS);
    }

    #[tokio::test]
    async fn non_stream_response_is_parsed() {
        let v = json!({ "choices": [{ "message": { "content": "「今天下午三点开会。」" } }] });
        let (port, req) = serve(vec![json_response(&v)]).await;
        let res = fuse(&ready(port), &sample_candidates(), None).await.unwrap();
        assert_eq!(res.text, "今天下午三点开会。");
        assert_eq!(serde_json::from_str::<Value>(&req.await.unwrap()).unwrap()["stream"], false);
    }

    #[tokio::test]
    async fn http_error_too_long_output_and_timeout_fail() {
        let (port, _) = serve(vec![b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 4\r\nConnection: close\r\n\r\noops".to_vec()]).await;
        assert!(fuse(&ready(port), &sample_candidates(), None).await.unwrap_err().to_string().contains("500"));

        let v = json!({ "choices": [{ "message": { "content": "好".repeat(200) } }] });
        let (port, _) = serve(vec![json_response(&v)]).await;
        assert!(fuse(&ready(port), &sample_candidates(), None).await.unwrap_err().to_string().contains("明显长于"));

        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        tokio::spawn(async move {
            let (mut s, _) = l.accept().await.unwrap();
            read_request(&mut s).await;
            tokio::time::sleep(Duration::from_secs(10)).await;
        });
        let started = Instant::now();
        assert!(fuse(&ready(port), &sample_candidates(), None).await.is_err());
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[tokio::test]
    async fn dropping_the_request_closes_the_connection() {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        let (got, got_rx) = tokio::sync::oneshot::channel();
        let closed = tokio::spawn(async move {
            let (mut s, _) = l.accept().await.unwrap();
            read_request(&mut s).await;
            let _ = got.send(());
            let mut b = [0u8; 16];
            matches!(tokio::time::timeout(Duration::from_secs(1), s.read(&mut b)).await, Ok(Ok(0)) | Ok(Err(_)))
        });
        let cfg = ready(port);
        let task = tokio::spawn(async move { fuse(&cfg, &sample_candidates(), sink()).await });
        got_rx.await.unwrap();
        task.abort();
        assert!(closed.await.unwrap(), "中止后连接应立即断开");
    }
}
