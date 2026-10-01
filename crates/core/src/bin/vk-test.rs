//! vk-test doubao|wetype|qwen file.wav [asr|polish|translate]
use std::time::Instant;
use voicekey_core::{audio, DoubaoEngine, Engine, QwenEngine, QwenOutput, WeTypeEngine};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: vk-test doubao|wetype|qwen file.wav [asr|polish|translate]");
        std::process::exit(2);
    }
    let engine: Box<dyn Engine> = match args[1].as_str() {
        "wetype" => Box::new(WeTypeEngine::default()),
        "qwen" => {
            let q = QwenEngine::default();
            if let Some(o) = args.get(3) {
                q.set_output(serde_json::from_value(serde_json::json!(o)).expect("bad output"));
            } else {
                q.set_output(QwenOutput::Polish);
            }
            Box::new(q)
        }
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
