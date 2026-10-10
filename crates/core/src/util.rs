use std::path::PathBuf;
use std::sync::OnceLock;

static DATA_DIR: OnceLock<PathBuf> = OnceLock::new();

/// 安卓等取不到系统数据目录的平台，在首次使用前指定
pub fn set_data_dir(dir: PathBuf) {
    let _ = DATA_DIR.set(dir);
}

/// macOS: ~/Library/Application Support/VoiceKey；Windows: %APPDATA%\VoiceKey
pub fn data_dir() -> PathBuf {
    let d = DATA_DIR.get().cloned().unwrap_or_else(|| dirs::data_dir().unwrap_or_else(std::env::temp_dir).join("VoiceKey"));
    let _ = std::fs::create_dir_all(&d);
    d
}

pub fn data_file(name: &str) -> PathBuf {
    data_dir().join(name)
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}

pub fn rand_lower(n: usize) -> String {
    use rand::Rng;
    let mut r = rand::thread_rng();
    (0..n).map(|_| r.gen_range(b'a'..=b'z') as char).collect()
}

fn cjk(c: char) -> bool {
    matches!(c as u32, 0x2E80..=0x9FFF | 0xF900..=0xFAFF | 0xFF00..=0xFFEF)
}

/// 两侧都不是中日韩字符时补空格
pub fn join_sentences<S: AsRef<str>>(parts: &[S]) -> String {
    let mut out = String::new();
    for t in parts.iter().map(AsRef::as_ref).filter(|t| !t.is_empty()) {
        if let (Some(a), Some(b)) = (out.chars().last(), t.chars().next()) {
            if !cjk(a) && !cjk(b) {
                out.push(' ');
            }
        }
        out.push_str(t);
    }
    out
}
