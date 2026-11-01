//! Jev 真网验收（默认忽略）：用真实 key 走 yce 中继打 systemone 上游，整套只发 4 次请求。
//! key 只从环境变量读，绝不落盘、不打日志：
//! ```sh
//! JEV_LIVE_KEY=<key> JEV_LIVE_ENDPOINT=https://yce.aigy.de/systemone/v1/systemone \
//!   cargo test -p voicekey-core --test jev_live -- --ignored --nocapture
//! ```

use voicekey_core::jev::{self, Config, Mode};

/// 缺环境变量时返回 None，用例直接跳过不 panic
fn live() -> Option<(String, String)> {
    let key = std::env::var("JEV_LIVE_KEY").ok()?;
    let endpoint = std::env::var("JEV_LIVE_ENDPOINT").ok()?;
    let (key, endpoint) = (key.trim().to_string(), endpoint.trim().to_string());
    (!key.is_empty() && !endpoint.is_empty()).then_some((key, endpoint))
}

/// 上游错误文本若意外回显了真实 key，输出前替换掉
fn redact(s: &str, key: &str) -> String {
    s.replace(key, "***")
}

fn official(key: &str, endpoint: &str) -> Config {
    Config {
        mode: Mode::Official,
        key: key.to_string(),
        endpoint: endpoint.to_string(),
        model: String::new(),
        pool: String::new(),
    }
}

/// 官方格式单 key：真实调 jev::test，验鉴权、请求体与响应解析
#[tokio::test]
#[ignore = "真网用例：需 JEV_LIVE_KEY 与 JEV_LIVE_ENDPOINT"]
async fn official_format_test_call() {
    let Some((key, endpoint)) = live() else {
        eprintln!("skip：未设置 JEV_LIVE_KEY / JEV_LIVE_ENDPOINT");
        return;
    };
    let cfg = official(&key, &endpoint);
    let t = match jev::test(&cfg).await {
        Ok(t) => t,
        Err(e) => panic!("官方格式 jev::test 失败：{}", redact(&e.to_string(), &key)),
    };
    assert!(matches!(t.index, 0 | 1), "index 应在 0/1 内，实际 {}", t.index);
    assert!(t.ms > 0, "耗时应大于 0");
    assert!(t.key != key, "Tested.key 未脱敏");
    assert!(t.key.contains('…'), "Tested.key 应含省略号，实际 {:?}", t.key);
    println!(
        "官方格式 ok：index={} text={:?} alias={} ms={} key={}",
        t.index, t.text, t.alias, t.ms, t.key
    );
}

/// yce 格式两行池：第一把坏 key 被上游拒后应换到第二把真 key（alias=live）
#[tokio::test]
#[ignore = "真网用例：需 JEV_LIVE_KEY 与 JEV_LIVE_ENDPOINT"]
async fn yce_pool_swaps_bad_key_to_live() {
    let Some((key, endpoint)) = live() else {
        eprintln!("skip：未设置 JEV_LIVE_KEY / JEV_LIVE_ENDPOINT");
        return;
    };
    let pool = format!("bad|apikey_invalid000000000000|{endpoint}\nlive|{key}|{endpoint}");
    let cfg = Config {
        mode: Mode::Yce,
        key: String::new(),
        endpoint: String::new(),
        model: String::new(),
        pool,
    };
    let t = match jev::test(&cfg).await {
        Ok(t) => t,
        Err(e) => panic!("yce 格式换 key 失败：{}", redact(&e.to_string(), &key)),
    };
    assert!(t.alias == "live", "应换到第二行 live，实际 alias {:?}", t.alias);
    assert!(matches!(t.index, 0 | 1), "index 应在 0/1 内，实际 {}", t.index);
    assert!(t.ms > 0, "耗时应大于 0");
    println!(
        "yce 换 key ok：alias={} index={} ms={} key={}",
        t.alias, t.index, t.ms, t.key
    );
}

/// 真实评选：三条候选里有一条明显残缺，jev::pick 不应选中它
#[tokio::test]
#[ignore = "真网用例：需 JEV_LIVE_KEY 与 JEV_LIVE_ENDPOINT"]
async fn pick_avoids_broken_transcript() {
    let Some((key, endpoint)) = live() else {
        eprintln!("skip：未设置 JEV_LIVE_KEY / JEV_LIVE_ENDPOINT");
        return;
    };
    let texts: Vec<String> = ["今天下午三点开会", "今天下午三点开灰", "天下午点会开"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    let cfg = official(&key, &endpoint);
    let p = match jev::pick(&cfg, &texts).await {
        Ok(p) => p,
        Err(e) => panic!("jev::pick 失败：{}", redact(&e.to_string(), &key)),
    };
    println!(
        "真实评选：index={} text={:?} alias={} ms={}",
        p.index, texts[p.index], p.alias, p.ms
    );
    assert!(p.index != 2, "选中了明显残缺的候选「{}」", texts[2]);
}
