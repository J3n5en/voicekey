use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::{fmt, time::Duration};
use tokio::time::Instant;
use uuid::Uuid;

pub const OFFICIAL_ENDPOINT: &str = "https://api.typesafe.ai/v1/systemone";
pub const DEFAULT_MODEL: &str = "jev-latest";
/// 整次 pick 的总时限，含换 key
pub const TIMEOUT: Duration = Duration::from_secs(8);
/// 测试按钮用的两条示例转写
pub const SAMPLES: [&str; 2] = ["今天下午三点开会", "今天下午三点开灰"];

const GOAL: &str = "Several speech recognizers transcribed the same spoken utterance. Which transcript is the best rendition of it?";
const INSTRUCTIONS: &str = "Pick the transcript that is the most accurate, complete and natural rendition of the spoken utterance: no mis-recognised or hallucinated words, no dropped words, sensible punctuation. When in doubt, prefer the transcript that a careful listener would have written down.";
const ERR_BODY_CHARS: usize = 200;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    #[default]
    Off,
    Official,
    Yce,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Config {
    pub mode: Mode,
    pub key: String,
    pub endpoint: String,
    pub model: String,
    pub pool: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Protocol {
    SystemOne,
    Decisions,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub alias: String,
    pub key: String,
    pub endpoint: String,
}

#[derive(Debug, Serialize)]
pub struct Picked {
    pub index: usize,
    pub alias: String,
    pub ms: u64,
}

#[derive(Debug, Serialize)]
pub struct Tested {
    pub index: usize,
    pub text: String,
    pub alias: String,
    pub ms: u64,
    /// 脱敏后的 key
    pub key: String,
}

#[derive(Debug)]
pub enum JevError {
    Config(String),
    /// 401/402/403/429：key 本身的问题
    Key { status: u16, body: String },
    /// 其他非 2xx
    Status { status: u16, body: String },
    Net(String),
    Payload(String),
}

impl fmt::Display for JevError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            JevError::Config(s) | JevError::Net(s) | JevError::Payload(s) => f.write_str(s),
            JevError::Key { status, body } | JevError::Status { status, body } => {
                write!(f, "HTTP {status}：{}", clip(body))
            }
        }
    }
}

impl std::error::Error for JevError {}

fn clip(s: &str) -> String {
    s.chars().take(ERR_BODY_CHARS).collect()
}

fn net(e: reqwest::Error) -> JevError {
    JevError::Net(e.without_url().to_string())
}

/// 只看 URL 的 path（去尾部 '/'，查询串不影响）：以 /decisions 结尾为 Decisions，其余 SystemOne
pub fn protocol(endpoint: &str) -> Protocol {
    let endpoint = endpoint.trim();
    let path = match reqwest::Url::parse(endpoint) {
        Ok(u) => u.path().to_string(),
        Err(_) => endpoint.split(['?', '#']).next().unwrap_or("").to_string(),
    };
    if path.trim_end_matches('/').ends_with("/decisions") {
        Protocol::Decisions
    } else {
        Protocol::SystemOne
    }
}

/// 用户填的地址补成完整端点：空取官方；缺协议补 https；path 已以 /systemone 或 /decisions 结尾只去尾 '/'；以 /v1 结尾补 /systemone；其余补 /v1/systemone
pub fn endpoint(raw: &str) -> String {
    let raw = raw.trim();
    if raw.is_empty() {
        return OFFICIAL_ENDPOINT.to_string();
    }
    let lower = raw.to_ascii_lowercase();
    let full = if lower.starts_with("http://") || lower.starts_with("https://") {
        raw.to_string()
    } else {
        format!("https://{raw}")
    };
    let Ok(mut u) = reqwest::Url::parse(&full) else {
        return full;
    };
    let p = u.path().trim_end_matches('/').to_string();
    let path = if p.ends_with("/systemone") || p.ends_with("/decisions") {
        p
    } else if p.ends_with("/v1") {
        format!("{p}/systemone")
    } else {
        format!("{p}/v1/systemone")
    };
    u.set_path(&path);
    u.to_string()
}

/// 每行 alias|key|endpoint，2 或 3 段；endpoint 经 endpoint() 补全，留空取官方端点；空行、# 注释与坏行跳过
pub fn parse_pool(text: &str) -> Vec<Target> {
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let parts: Vec<&str> = line.split('|').map(str::trim).collect();
            if !(2..=3).contains(&parts.len()) || parts[0].is_empty() || parts[1].is_empty() {
                return None;
            }
            Some(Target {
                alias: parts[0].to_string(),
                key: parts[1].to_string(),
                endpoint: endpoint(parts.get(2).copied().unwrap_or("")),
            })
        })
        .collect()
}

/// 两协议请求体互斥：SystemOne 带 model 不带 request_id，Decisions 带 request_id 不带 model
pub fn body(p: Protocol, model: &str, texts: &[String], request_id: &str) -> Value {
    let criteria: Map<String, Value> = texts
        .iter()
        .enumerate()
        .map(|(i, t)| (format!("cand_{i}"), Value::String(t.clone())))
        .collect();
    let state = json!({ "goal": GOAL });
    let questions = json!({
        "pick": { "type": "choice", "instructions": INSTRUCTIONS, "criteria": criteria }
    });
    match p {
        Protocol::SystemOne => json!({ "model": model, "state": state, "questions": questions }),
        Protocol::Decisions => {
            json!({ "request_id": request_id, "state": state, "questions": questions })
        }
    }
}

/// answers.pick.probabilities 里 cand_0..cand_{n-1} 取最大；缺失或非数跳过，并列取下标小者
pub fn best(resp: &Value, n: usize) -> Option<usize> {
    let probs = resp
        .get("answers")?
        .get("pick")?
        .get("probabilities")?
        .as_object()?;
    let mut top: Option<(usize, f64)> = None;
    for i in 0..n {
        let Some(v) = probs
            .get(&format!("cand_{i}"))
            .and_then(Value::as_f64)
            .filter(|v| v.is_finite())
        else {
            continue;
        };
        match top {
            Some((_, t)) if v <= t => {}
            _ => top = Some((i, v)),
        }
    }
    top.map(|(i, _)| i)
}

/// 前 7 + "…" + 后 4；长度 ≤ 12 时全部打码
pub fn mask(key: &str) -> String {
    let c: Vec<char> = key.chars().collect();
    if c.len() <= 12 {
        return "****".to_string();
    }
    let head: String = c[..7].iter().collect();
    let tail: String = c[c.len() - 4..].iter().collect();
    format!("{head}…{tail}")
}

impl Config {
    /// 解析失败返回 Default（Off）
    pub fn from_json(s: &str) -> Config {
        serde_json::from_str(s).unwrap_or_default()
    }

    pub fn targets(&self) -> Result<Vec<Target>, String> {
        match self.mode {
            Mode::Off => Err("智能选择未开启".to_string()),
            Mode::Official => {
                let key = self.key.trim();
                if key.is_empty() {
                    return Err("请填写 API Key".to_string());
                }
                Ok(vec![Target {
                    alias: "official".to_string(),
                    key: key.to_string(),
                    endpoint: endpoint(&self.endpoint),
                }])
            }
            Mode::Yce => {
                let t = parse_pool(&self.pool);
                if t.is_empty() {
                    Err("没有可用的 key 行".to_string())
                } else {
                    Ok(t)
                }
            }
        }
    }

    pub fn model(&self) -> &str {
        let m = self.model.trim();
        if self.mode == Mode::Official && !m.is_empty() {
            m
        } else {
            DEFAULT_MODEL
        }
    }
}

impl Picked {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

impl Tested {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

fn client() -> Result<reqwest::Client, JevError> {
    let b = reqwest::Client::builder();
    // 单测只打回环假服务，不能被本机代理环境变量带偏
    #[cfg(test)]
    let b = b.no_proxy();
    b.build().map_err(net)
}

/// 向一条 target 发一次请求，返回最佳候选下标
async fn attempt(
    client: &reqwest::Client,
    t: &Target,
    model: &str,
    texts: &[String],
    remaining: Duration,
) -> Result<usize, JevError> {
    let req = body(
        protocol(&t.endpoint),
        model,
        texts,
        &Uuid::new_v4().to_string(),
    );
    let resp = client
        .post(&t.endpoint)
        .bearer_auth(&t.key)
        .json(&req)
        .timeout(remaining)
        .send()
        .await
        .map_err(net)?;
    let status = resp.status().as_u16();
    let text = resp.text().await.map_err(net)?;
    if (200..300).contains(&status) {
        let v: Value = serde_json::from_str(&text)
            .map_err(|_| JevError::Payload(format!("响应不是 JSON：{}", clip(&text))))?;
        return best(&v, texts.len()).ok_or_else(|| {
            JevError::Payload(format!("响应缺少 answers.pick.probabilities：{}", clip(&text)))
        });
    }
    let body = clip(&text);
    Err(match status {
        401 | 402 | 403 | 429 => JevError::Key { status, body },
        400..=599 => JevError::Status { status, body },
        _ => JevError::Payload(format!("HTTP {status}：{body}")),
    })
}

/// 这类错误换下一条 key 还有意义；其他 4xx 是请求体问题，换 key 也一样
fn retryable(e: &JevError) -> bool {
    match e {
        JevError::Key { .. } | JevError::Net(_) | JevError::Payload(_) => true,
        JevError::Status { status, .. } => *status >= 500,
        JevError::Config(_) => false,
    }
}

/// 按顺序逐条试，每条最多一次；返回结果与命中的 target 下标
async fn run(
    targets: &[Target],
    model: &str,
    texts: &[String],
    deadline: Duration,
) -> Result<(Picked, usize), JevError> {
    if targets.is_empty() {
        return Err(JevError::Config("没有可用的 key 行".to_string()));
    }
    if texts.len() < 2 {
        return Err(JevError::Config("至少需要两条候选转写".to_string()));
    }
    let client = client()?;
    let start = Instant::now();
    let mut last = JevError::Net("等待 Jev 超时".to_string());
    for (i, t) in targets.iter().enumerate() {
        let remaining = deadline.saturating_sub(start.elapsed());
        if remaining.is_zero() {
            break;
        }
        match attempt(&client, t, model, texts, remaining).await {
            Ok(index) => {
                let picked = Picked {
                    index,
                    alias: t.alias.clone(),
                    ms: start.elapsed().as_millis() as u64,
                };
                return Ok((picked, i));
            }
            Err(e) => {
                let again = retryable(&e);
                last = e;
                if !again {
                    break;
                }
            }
        }
    }
    Err(last)
}

pub async fn pick_with(
    targets: &[Target],
    model: &str,
    texts: &[String],
    deadline: Duration,
) -> Result<Picked, JevError> {
    run(targets, model, texts, deadline).await.map(|(p, _)| p)
}

pub async fn pick(cfg: &Config, texts: &[String]) -> Result<Picked, JevError> {
    let targets = cfg.targets().map_err(JevError::Config)?;
    pick_with(&targets, cfg.model(), texts, TIMEOUT).await
}

/// 用 SAMPLES 真打一次
pub async fn test(cfg: &Config) -> Result<Tested, JevError> {
    let targets = cfg.targets().map_err(JevError::Config)?;
    let texts: Vec<String> = SAMPLES.iter().map(|s| s.to_string()).collect();
    let (picked, ti) = run(&targets, cfg.model(), &texts, TIMEOUT).await?;
    Ok(Tested {
        index: picked.index,
        text: texts[picked.index].clone(),
        alias: picked.alias,
        ms: picked.ms,
        key: mask(&targets[ti].key),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    fn texts(n: usize) -> Vec<String> {
        (0..n).map(|i| format!("文本{i}")).collect()
    }

    fn pool_target(alias: &str, key: &str, endpoint: &str) -> Target {
        Target {
            alias: alias.to_string(),
            key: key.to_string(),
            endpoint: endpoint.to_string(),
        }
    }

    // ---- body ----

    #[test]
    fn body_systemone_has_model_no_request_id() {
        let v = body(Protocol::SystemOne, DEFAULT_MODEL, &texts(3), "rid");
        assert_eq!(v["model"], "jev-latest");
        assert!(v.get("request_id").is_none());
        assert_eq!(v["questions"]["pick"]["type"], "choice");
        assert!(v["state"]["goal"].as_str().unwrap().starts_with("Several speech recognizers"));
        assert!(!v["questions"]["pick"]["instructions"].as_str().unwrap().is_empty());
    }

    #[test]
    fn body_decisions_has_request_id_no_model() {
        let id = Uuid::new_v4().to_string();
        let v = body(Protocol::Decisions, DEFAULT_MODEL, &texts(2), &id);
        assert_eq!(v["request_id"], Value::String(id));
        assert!(v.get("model").is_none());
    }

    #[test]
    fn body_criteria_keys_and_values() {
        for p in [Protocol::SystemOne, Protocol::Decisions] {
            let v = body(p, DEFAULT_MODEL, &texts(3), "rid");
            let c = v["questions"]["pick"]["criteria"].as_object().unwrap();
            assert_eq!(c.len(), 3);
            for i in 0..3 {
                assert_eq!(c[&format!("cand_{i}")], format!("文本{i}"));
            }
        }
    }

    // ---- protocol ----

    #[test]
    fn protocol_by_path() {
        assert_eq!(protocol("https://api.typesafe.ai/v1/systemone"), Protocol::SystemOne);
        assert_eq!(protocol("https://x/decisions"), Protocol::Decisions);
        assert_eq!(protocol("https://x/decisions/"), Protocol::Decisions);
        assert_eq!(protocol("https://x/decisions?x=1"), Protocol::Decisions);
        assert_eq!(protocol("https://x/decisionsX"), Protocol::SystemOne);
        assert_eq!(protocol("https://x/v1/systemone?next=/decisions"), Protocol::SystemOne);
        assert_eq!(protocol("https://decisions"), Protocol::SystemOne);
    }

    // ---- endpoint ----

    #[test]
    fn endpoint_empty_is_official() {
        assert_eq!(endpoint(""), OFFICIAL_ENDPOINT);
        assert_eq!(endpoint("   "), OFFICIAL_ENDPOINT);
    }

    #[test]
    fn endpoint_bare_host_adds_scheme_and_path() {
        assert_eq!(endpoint("sub.nekopeer.com"), "https://sub.nekopeer.com/v1/systemone");
        assert_eq!(endpoint("  sub.nekopeer.com  "), "https://sub.nekopeer.com/v1/systemone");
    }

    #[test]
    fn endpoint_root_path_appends_v1_systemone() {
        assert_eq!(endpoint("https://sub.nekopeer.com/"), "https://sub.nekopeer.com/v1/systemone");
        assert_eq!(endpoint("https://sub.nekopeer.com"), "https://sub.nekopeer.com/v1/systemone");
        assert_eq!(endpoint("https://x.com/api"), "https://x.com/api/v1/systemone");
    }

    #[test]
    fn endpoint_v1_appends_systemone() {
        assert_eq!(endpoint("https://x.com/api/v1"), "https://x.com/api/v1/systemone");
        assert_eq!(endpoint("https://x.com/v1/"), "https://x.com/v1/systemone");
    }

    #[test]
    fn endpoint_full_paths_kept() {
        assert_eq!(endpoint("https://freejev.org/api/v1/decisions"), "https://freejev.org/api/v1/decisions");
        assert_eq!(endpoint("https://api.typesafe.ai/v1/systemone/"), "https://api.typesafe.ai/v1/systemone");
        assert_eq!(endpoint(OFFICIAL_ENDPOINT), OFFICIAL_ENDPOINT);
        assert_eq!(endpoint("http://127.0.0.1:8080/v1/systemone"), "http://127.0.0.1:8080/v1/systemone");
    }

    #[test]
    fn endpoint_keeps_query_last() {
        assert_eq!(endpoint("https://x.com/api?k=1"), "https://x.com/api/v1/systemone?k=1");
        assert_eq!(endpoint("https://x.com/decisions/?k=1"), "https://x.com/decisions?k=1");
    }

    #[test]
    fn endpoint_protocol_roundtrip() {
        assert_eq!(protocol(&endpoint("https://freejev.org/api/v1/decisions")), Protocol::Decisions);
        assert_eq!(protocol(&endpoint("sub.nekopeer.com")), Protocol::SystemOne);
    }

    // ---- parse_pool ----

    #[test]
    fn parse_pool_two_segments_default_endpoint() {
        let t = parse_pool("a|apikey_xxx");
        assert_eq!(t, vec![pool_target("a", "apikey_xxx", OFFICIAL_ENDPOINT)]);
    }

    #[test]
    fn parse_pool_three_segments() {
        let t = parse_pool("b|jevpk_xxx|https://x/decisions");
        assert_eq!(t, vec![pool_target("b", "jevpk_xxx", "https://x/decisions")]);
    }

    #[test]
    fn parse_pool_empty_endpoint_default() {
        let t = parse_pool("c|apikey_xxx|");
        assert_eq!(t, vec![pool_target("c", "apikey_xxx", OFFICIAL_ENDPOINT)]);
    }

    #[test]
    fn parse_pool_skips_bad_lines() {
        assert!(parse_pool("only-one").is_empty());
        assert!(parse_pool("a|k|https://x|extra").is_empty());
        assert!(parse_pool("a||https://x").is_empty());
        assert!(parse_pool("a|  ").is_empty());
        assert!(parse_pool("|apikey_xxx").is_empty());
    }

    #[test]
    fn parse_pool_skips_blank_and_comments_and_trims() {
        let text = "\n# 注释\n   \n  a  |  apikey_xxx  |  https://x/y  \r\n#b|k\nbad\nz|jevpk_xxx\n";
        let t = parse_pool(text);
        assert_eq!(
            t,
            vec![
                pool_target("a", "apikey_xxx", "https://x/y/v1/systemone"),
                pool_target("z", "jevpk_xxx", OFFICIAL_ENDPOINT),
            ]
        );
    }

    #[test]
    fn parse_pool_completes_endpoint() {
        let t = parse_pool("a|k1|sub.nekopeer.com\nb|k2|https://x.com/api/v1");
        assert_eq!(
            t,
            vec![
                pool_target("a", "k1", "https://sub.nekopeer.com/v1/systemone"),
                pool_target("b", "k2", "https://x.com/api/v1/systemone"),
            ]
        );
    }

    // ---- Config ----

    fn cfg(mode: Mode, key: &str, endpoint: &str, model: &str, pool: &str) -> Config {
        Config {
            mode,
            key: key.to_string(),
            endpoint: endpoint.to_string(),
            model: model.to_string(),
            pool: pool.to_string(),
        }
    }

    #[test]
    fn config_targets_off() {
        let c = cfg(Mode::Off, "apikey_xxx", "", "", "a|k");
        assert_eq!(c.targets(), Err("智能选择未开启".to_string()));
    }

    #[test]
    fn config_targets_official_missing_key() {
        let c = cfg(Mode::Official, "  ", "", "", "");
        assert_eq!(c.targets(), Err("请填写 API Key".to_string()));
    }

    #[test]
    fn config_targets_official_default_endpoint() {
        let c = cfg(Mode::Official, " apikey_xxx ", "  ", "", "");
        let t = c.targets().unwrap();
        assert_eq!(t.len(), 1);
        assert_eq!(t[0].key, "apikey_xxx");
        assert_eq!(t[0].endpoint, OFFICIAL_ENDPOINT);
        let c = cfg(Mode::Official, "apikey_xxx", "https://x/decisions", "", "");
        assert_eq!(c.targets().unwrap()[0].endpoint, "https://x/decisions");
    }

    #[test]
    fn config_targets_official_completes_endpoint() {
        let c = cfg(Mode::Official, "apikey_xxx", "sub.nekopeer.com", "", "");
        assert_eq!(c.targets().unwrap()[0].endpoint, "https://sub.nekopeer.com/v1/systemone");
    }

    #[test]
    fn config_targets_yce() {
        let c = cfg(Mode::Yce, "", "", "", "bad\n# c\n|k|");
        assert_eq!(c.targets(), Err("没有可用的 key 行".to_string()));
        let c = cfg(Mode::Yce, "", "", "", "a|jevpk_xxx\nb|apikey_xxx|https://x/decisions");
        assert_eq!(c.targets().unwrap().len(), 2);
    }

    #[test]
    fn config_from_json() {
        assert_eq!(Config::from_json("not json"), Config::default());
        assert_eq!(Config::from_json("").mode, Mode::Off);
        assert_eq!(Config::from_json(r#"{"mode":"weird"}"#), Config::default());
        let c = Config::from_json(r#"{"mode":"yce","pool":"a|jevpk_xxx"}"#);
        assert_eq!(c.mode, Mode::Yce);
        assert_eq!(c.pool, "a|jevpk_xxx");
        assert_eq!(c.key, "");
        let c = Config::from_json(r#"{"mode":"official","key":"apikey_xxx","endpoint":"","model":"m1","pool":""}"#);
        assert_eq!(c.mode, Mode::Official);
        assert_eq!(c.model, "m1");
    }

    #[test]
    fn config_model_by_mode() {
        assert_eq!(cfg(Mode::Official, "k", "", "", "").model(), DEFAULT_MODEL);
        assert_eq!(cfg(Mode::Official, "k", "", " my-model ", "").model(), "my-model");
        assert_eq!(cfg(Mode::Yce, "", "", "my-model", "a|k").model(), DEFAULT_MODEL);
        assert_eq!(cfg(Mode::Off, "", "", "my-model", "").model(), DEFAULT_MODEL);
    }

    // ---- best ----

    fn resp(probs: Value) -> Value {
        json!({ "answers": { "pick": { "probabilities": probs } } })
    }

    #[test]
    fn best_takes_max() {
        let r = resp(json!({ "cand_0": 0.2, "cand_1": 0.7, "cand_2": 0.1 }));
        assert_eq!(best(&r, 3), Some(1));
    }

    #[test]
    fn best_tie_takes_lower_index() {
        let r = resp(json!({ "cand_0": 0.1, "cand_1": 0.45, "cand_2": 0.45 }));
        assert_eq!(best(&r, 3), Some(1));
    }

    #[test]
    fn best_skips_missing_key() {
        let r = resp(json!({ "cand_0": 0.2, "cand_2": 0.5 }));
        assert_eq!(best(&r, 3), Some(2));
        let r = resp(json!({ "cand_1": 0.3 }));
        assert_eq!(best(&r, 3), Some(1));
        assert_eq!(best(&resp(json!({})), 3), None);
    }

    #[test]
    fn best_skips_non_numbers() {
        let r = resp(json!({ "cand_0": "0.9", "cand_1": null, "cand_2": 0.1 }));
        assert_eq!(best(&r, 3), Some(2));
        let r = resp(json!({ "cand_0": "x", "cand_1": [1] }));
        assert_eq!(best(&r, 2), None);
    }

    #[test]
    fn best_ignores_cands_beyond_n() {
        let r = resp(json!({ "cand_0": 0.1, "cand_1": 0.2, "cand_2": 0.9 }));
        assert_eq!(best(&r, 2), Some(1));
    }

    #[test]
    fn best_missing_answers_pick() {
        assert_eq!(best(&json!({}), 2), None);
        assert_eq!(best(&json!({ "answers": {} }), 2), None);
        assert_eq!(best(&json!({ "answers": { "other": { "probabilities": { "cand_0": 1.0 } } } }), 2), None);
        assert_eq!(best(&json!({ "answers": { "pick": {} } }), 2), None);
    }

    // ---- mask / to_json / Display ----

    #[test]
    fn mask_long_and_short() {
        assert_eq!(mask("apikey_xxxxxxxxxxxx"), "apikey_…xxxx");
        assert_eq!(mask("jevpk_xxx"), "****");
        assert_eq!(mask("123456789012"), "****");
        assert_eq!(mask("1234567890123"), "1234567…0123");
        assert_eq!(mask(""), "****");
    }

    #[test]
    fn to_json_shapes() {
        let p = Picked { index: 1, alias: "a".into(), ms: 5 };
        let v: Value = serde_json::from_str(&p.to_json()).unwrap();
        assert_eq!(v, json!({ "index": 1, "alias": "a", "ms": 5 }));
        let t = Tested { index: 0, text: "文".into(), alias: "a".into(), ms: 7, key: "****".into() };
        let v: Value = serde_json::from_str(&t.to_json()).unwrap();
        assert_eq!(v, json!({ "index": 0, "text": "文", "alias": "a", "ms": 7, "key": "****" }));
    }

    #[test]
    fn error_display() {
        assert_eq!(JevError::Config("c".into()).to_string(), "c");
        assert_eq!(JevError::Net("n".into()).to_string(), "n");
        assert_eq!(JevError::Payload("p".into()).to_string(), "p");
        let e = JevError::Key { status: 401, body: "bad".into() };
        assert_eq!(e.to_string(), "HTTP 401：bad");
        let e = JevError::Status { status: 500, body: "字".repeat(300) };
        assert_eq!(e.to_string(), format!("HTTP 500：{}", "字".repeat(200)));
    }

    // ---- pick_with（回环假服务）----

    #[derive(Clone)]
    enum Reply {
        Json(u16, String),
        Hang,
    }

    struct Fake {
        url: String,
        reqs: Arc<Mutex<Vec<String>>>,
    }

    impl Fake {
        fn count(&self) -> usize {
            self.reqs.lock().unwrap().len()
        }
        fn head(&self, i: usize) -> String {
            let r = self.reqs.lock().unwrap()[i].clone();
            r.split("\r\n\r\n").next().unwrap().to_string()
        }
        fn body(&self, i: usize) -> Value {
            let r = self.reqs.lock().unwrap()[i].clone();
            serde_json::from_str(r.split_once("\r\n\r\n").unwrap().1).unwrap()
        }
    }

    async fn read_request(s: &mut TcpStream) -> Option<String> {
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        loop {
            if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                let head = String::from_utf8_lossy(&buf[..pos]).to_lowercase();
                let len = head
                    .lines()
                    .find_map(|l| l.strip_prefix("content-length:"))
                    .and_then(|v| v.trim().parse::<usize>().ok())
                    .unwrap_or(0);
                if buf.len() >= pos + 4 + len {
                    return Some(String::from_utf8_lossy(&buf).into_owned());
                }
            }
            let n = s.read(&mut tmp).await.ok()?;
            if n == 0 {
                return None;
            }
            buf.extend_from_slice(&tmp[..n]);
        }
    }

    async fn serve(path: &str, reply: Reply) -> Fake {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}{}", listener.local_addr().unwrap(), path);
        let reqs = Arc::new(Mutex::new(Vec::new()));
        let log = reqs.clone();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = listener.accept().await {
                let (log, reply) = (log.clone(), reply.clone());
                tokio::spawn(async move {
                    let Some(req) = read_request(&mut s).await else { return };
                    log.lock().unwrap().push(req);
                    match reply {
                        Reply::Json(code, body) => {
                            let head = format!(
                                "HTTP/1.1 {code} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                body.len()
                            );
                            let _ = s.write_all(head.as_bytes()).await;
                            let _ = s.write_all(body.as_bytes()).await;
                            let _ = s.shutdown().await;
                        }
                        Reply::Hang => tokio::time::sleep(Duration::from_secs(60)).await,
                    }
                });
            }
        });
        Fake { url, reqs }
    }

    fn ok_body(p0: f64, p1: f64) -> Reply {
        Reply::Json(
            200,
            json!({ "answers": { "pick": { "probabilities": { "cand_0": p0, "cand_1": p1 } } } })
                .to_string(),
        )
    }

    const LONG: Duration = Duration::from_secs(5);

    #[tokio::test]
    async fn pick_with_key_error_falls_to_next() {
        for status in [401u16, 402, 403, 429, 500, 503] {
            let a = serve("/v1/systemone", Reply::Json(status, "{\"error\":\"nope\"}".into())).await;
            let b = serve("/v1/systemone", ok_body(0.2, 0.8)).await;
            let targets = [
                pool_target("first", "apikey_xxx", &a.url),
                pool_target("second", "jevpk_xxx", &b.url),
            ];
            let p = pick_with(&targets, DEFAULT_MODEL, &texts(2), LONG).await.unwrap();
            assert_eq!((p.index, p.alias.as_str()), (1, "second"), "status {status}");
            assert_eq!((a.count(), b.count()), (1, 1), "status {status}");
            assert!(a.head(0).to_lowercase().contains("authorization: bearer apikey_xxx"));
            assert!(b.head(0).to_lowercase().contains("authorization: bearer jevpk_xxx"));
        }
    }

    #[tokio::test]
    async fn pick_with_payload_error_falls_to_next() {
        for bad in ["not json", "{}", "{\"answers\":{\"pick\":{\"probabilities\":{}}}}"] {
            let a = serve("/v1/systemone", Reply::Json(200, bad.into())).await;
            let b = serve("/v1/systemone", ok_body(0.9, 0.1)).await;
            let targets = [
                pool_target("first", "apikey_xxx", &a.url),
                pool_target("second", "apikey_xxx", &b.url),
            ];
            let p = pick_with(&targets, DEFAULT_MODEL, &texts(2), LONG).await.unwrap();
            assert_eq!((p.index, p.alias.as_str()), (0, "second"), "bad {bad}");
        }
    }

    #[tokio::test]
    async fn pick_with_connect_failure_falls_to_next() {
        let dead = {
            let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
            format!("http://{}/v1/systemone", l.local_addr().unwrap())
        };
        let b = serve("/v1/systemone", ok_body(0.3, 0.7)).await;
        let targets = [
            pool_target("dead", "apikey_xxx", &dead),
            pool_target("live", "apikey_xxx", &b.url),
        ];
        let p = pick_with(&targets, DEFAULT_MODEL, &texts(2), LONG).await.unwrap();
        assert_eq!((p.index, p.alias.as_str()), (1, "live"));
    }

    #[tokio::test]
    async fn pick_with_other_4xx_stops_immediately() {
        for status in [400u16, 404, 422] {
            let a = serve("/v1/systemone", Reply::Json(status, "{\"error\":\"bad body\"}".into())).await;
            let b = serve("/v1/systemone", ok_body(0.2, 0.8)).await;
            let targets = [
                pool_target("first", "apikey_xxx", &a.url),
                pool_target("second", "apikey_xxx", &b.url),
            ];
            let e = pick_with(&targets, DEFAULT_MODEL, &texts(2), LONG).await.unwrap_err();
            assert!(matches!(e, JevError::Status { status: s, .. } if s == status), "{e:?}");
            assert_eq!(e.to_string(), format!("HTTP {status}：{{\"error\":\"bad body\"}}"));
            assert_eq!((a.count(), b.count()), (1, 0), "status {status}");
        }
    }

    #[tokio::test]
    async fn pick_with_all_failed_returns_last_error() {
        let a = serve("/v1/systemone", Reply::Json(401, "first".into())).await;
        let b = serve("/v1/systemone", Reply::Json(429, "second".into())).await;
        let targets = [
            pool_target("a", "apikey_xxx", &a.url),
            pool_target("b", "apikey_xxx", &b.url),
        ];
        let e = pick_with(&targets, DEFAULT_MODEL, &texts(2), LONG).await.unwrap_err();
        assert!(matches!(&e, JevError::Key { status: 429, body } if body == "second"), "{e:?}");
        assert_eq!((a.count(), b.count()), (1, 1));
    }

    #[tokio::test]
    async fn pick_with_deadline_returns_net() {
        let a = serve("/v1/systemone", Reply::Hang).await;
        let b = serve("/v1/systemone", ok_body(0.2, 0.8)).await;
        let targets = [
            pool_target("hang", "apikey_xxx", &a.url),
            pool_target("live", "apikey_xxx", &b.url),
        ];
        let t = Instant::now();
        let e = pick_with(&targets, DEFAULT_MODEL, &texts(2), Duration::from_millis(600))
            .await
            .unwrap_err();
        assert!(matches!(e, JevError::Net(_)), "{e:?}");
        // 总时限含换 key：首条吃光剩余时间，第二条不再请求
        assert!(t.elapsed() < Duration::from_secs(3));
        assert_eq!(b.count(), 0);
    }

    #[tokio::test]
    async fn pick_with_protocol_bodies() {
        let sys = serve("/v1/systemone", ok_body(0.4, 0.6)).await;
        let dec = serve("/v1/decisions", ok_body(0.6, 0.4)).await;
        let targets = [pool_target("s", "apikey_xxx", &sys.url)];
        let p = pick_with(&targets, "jev-latest", &texts(2), LONG).await.unwrap();
        assert_eq!(p.index, 1);
        let v = sys.body(0);
        assert_eq!(v["model"], "jev-latest");
        assert!(v.get("request_id").is_none());
        assert!(sys.head(0).to_lowercase().contains("content-type: application/json"));

        let targets = [pool_target("d", "jevpk_xxx", &dec.url)];
        let p = pick_with(&targets, "jev-latest", &texts(2), LONG).await.unwrap();
        assert_eq!(p.index, 0);
        let v = dec.body(0);
        assert!(v.get("model").is_none());
        assert!(Uuid::parse_str(v["request_id"].as_str().unwrap()).is_ok());
        assert_eq!(v["questions"]["pick"]["criteria"]["cand_1"], "文本1");
    }

    #[tokio::test]
    async fn pick_with_rejects_bad_input_without_request() {
        let a = serve("/v1/systemone", ok_body(0.2, 0.8)).await;
        let targets = [pool_target("a", "apikey_xxx", &a.url)];
        let e = pick_with(&targets, DEFAULT_MODEL, &texts(1), LONG).await.unwrap_err();
        assert!(matches!(e, JevError::Config(_)));
        let e = pick_with(&[], DEFAULT_MODEL, &texts(2), LONG).await.unwrap_err();
        assert!(matches!(e, JevError::Config(_)));
        assert_eq!(a.count(), 0);
    }

    #[tokio::test]
    async fn pick_and_test_use_config() {
        let a = serve("/v1/systemone", ok_body(0.1, 0.9)).await;
        let c = cfg(Mode::Official, "apikey_xxxxxxxxxxxx", &a.url, "my-model", "");
        let p = pick(&c, &texts(2)).await.unwrap();
        assert_eq!((p.index, p.alias.as_str()), (1, "official"));
        assert_eq!(a.body(0)["model"], "my-model");

        let t = test(&c).await.unwrap();
        assert_eq!(t.index, 1);
        assert_eq!(t.text, SAMPLES[1]);
        assert_eq!(t.key, "apikey_…xxxx");
        assert_eq!(a.body(1)["questions"]["pick"]["criteria"]["cand_0"], SAMPLES[0]);

        let off = Config::default();
        assert!(matches!(pick(&off, &texts(2)).await, Err(JevError::Config(m)) if m == "智能选择未开启"));
        assert!(matches!(test(&off).await, Err(JevError::Config(_))));
    }
}
