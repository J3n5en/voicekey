//! vk-test doubao|wetype|qwen|baidu|sogou|iflytek file.wav
use std::time::Instant;
use voicekey_core::{audio, BaiduEngine, DoubaoEngine, Engine, IflyEngine, QwenEngine, SogouEngine, WeTypeEngine};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: vk-test doubao|wetype|qwen|baidu|sogou|iflytek file.wav");
        std::process::exit(2);
    }
    let engine: Box<dyn Engine> = match args[1].as_str() {
        "wetype" => Box::new(WeTypeEngine::default()),
        "baidu" => Box::new(BaiduEngine),
        "sogou" => Box::new(SogouEngine),
        "iflytek" => Box::new(IflyEngine),
        "qwen" => Box::new(QwenEngine::default()),
        _ => Box::new(DoubaoEngine),
    };
    let start = Instant::now();
    let audio = audio::file_frames(&args[2], true).expect("read wav");
    match engine.run(audio, Box::new(|p| println!("… {p}"))).await {
        Ok(t) => println!("FINAL: {t} ({:.2}s)", start.elapsed().as_secs_f64()),
        Err(e) => {
            println!("ERROR: {e:#}");
            std::process::exit(1);
        }
    }
}
