//! 需要登录的渠道真网验收（默认忽略）：校验登录 Cookie，再用仓库里的示例录音识别一次。
//! 登录 Cookie 只从环境变量读，不落盘、不打日志：
//! ```sh
//! VOICEKEY_QWENAPP='tongyi_sso_ticket=…' VOICEKEY_BAGESHUO='DICT_PERS=…' \
//!   cargo test -p voicekey-core --test login_live -- --ignored --nocapture
//! ```

use voicekey_core::account::Login;
use voicekey_core::{audio, bageshuo, qwenapp, BageshuoEngine, Engine, QwenAppEngine};

const SAMPLE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../ios/Resources/sample.wav");

/// 缺环境变量时返回 false，用例直接跳过不 panic
async fn ready(login: &Login) -> bool {
    let cookie = login.get();
    if cookie.is_empty() {
        eprintln!("skip：未设置 VOICEKEY_{}", login.id.to_uppercase());
        return false;
    }
    (login.check)(&cookie).await.expect("登录 Cookie 校验失败");
    true
}

async fn recognize(engine: &dyn Engine) -> String {
    let frames = audio::file_frames(SAMPLE, true).expect("读取示例录音");
    engine.run(frames, Box::new(|_| {})).await.expect("识别失败")
}

#[tokio::test]
#[ignore = "真网用例：需 VOICEKEY_QWENAPP"]
async fn qwenapp_recognizes_sample() {
    if !ready(&qwenapp::LOGIN).await {
        return;
    }
    let text = recognize(&QwenAppEngine::default()).await;
    println!("千问 App：{text}");
    assert!(text.contains("天气"), "识别结果不符：{text}");
}

#[tokio::test]
#[ignore = "真网用例：需 VOICEKEY_BAGESHUO"]
async fn bageshuo_recognizes_sample() {
    if !ready(&bageshuo::LOGIN).await {
        return;
    }
    let text = recognize(&BageshuoEngine).await;
    println!("叭哥说：{text}");
    assert!(text.contains("天气"), "识别结果不符：{text}");
}
