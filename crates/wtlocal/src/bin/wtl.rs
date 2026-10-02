//! wtl <模型目录> a.wav [b.wav ...]   逐文件离线解码并计时
//! wtl <模型目录> --live a.wav         按实时节奏推流，打印中间结果
//! wtl --unpack pack.apk <模型目录>    解包官方语音包
use std::time::Instant;
use voicekey_core::Engine;
use voicekey_wtlocal::{load, pack, LocalEngine, Stream};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args[0] == "--unpack" {
        let t = Instant::now();
        pack::unpack(args[1].as_ref(), args[2].as_ref()).unwrap();
        println!("unpacked in {:.1}s", t.elapsed().as_secs_f64());
        return;
    }
    let dir = std::path::PathBuf::from(&args[0]);
    let t = Instant::now();
    let m = load(&dir).expect("load model");
    eprintln!("load {:.0}ms", t.elapsed().as_secs_f64() * 1e3);
    if args[1] == "--live" {
        let pcm: Vec<i16> = hound::WavReader::open(&args[2]).unwrap().samples::<i16>().map(|s| s.unwrap()).collect();
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let t = Instant::now();
        let feed = tokio::spawn(async move {
            let mut iv = tokio::time::interval(std::time::Duration::from_millis(20));
            for c in pcm.chunks(320) {
                iv.tick().await;
                let _ = tx.send(c.to_vec());
            }
            Instant::now()
        });
        let r = LocalEngine { dir }.run(rx, Box::new(move |p| println!("… {:.2}s {p}", t.elapsed().as_secs_f64()))).await;
        let end = feed.await.unwrap();
        println!("FINAL +{:.0}ms after audio end ({:.2}s) {}", end.elapsed().as_secs_f64() * 1e3, t.elapsed().as_secs_f64(), r.unwrap());
        return;
    }
    for f in &args[1..] {
        let pcm: Vec<i16> = hound::WavReader::open(f).unwrap().samples::<i16>().map(|s| s.unwrap()).collect();
        let t = Instant::now();
        let mut s = Stream::new(m.clone());
        for c in pcm.chunks(320) {
            s.push(c);
        }
        let txt = s.finish();
        let name = std::path::Path::new(f).file_stem().unwrap().to_string_lossy();
        println!("{name} audio {:.2}s {:.0}ms\t{txt}", pcm.len() as f64 / 16000.0, t.elapsed().as_secs_f64() * 1e3);
    }
}
