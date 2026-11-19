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

/// 去除句读标点；数字内的 `.` `,` `:`、单词内撇号、URL/路径中的 `.` `:` 保留。
/// 被删标点两侧都不是中日韩字符时以单个空格分隔。纯函数，流式上屏依赖其确定性。
pub fn strip_punctuation(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut gap = false;
    for (i, &c) in chars.iter().enumerate() {
        let prev = i.checked_sub(1).map(|j| chars[j]);
        if is_punct(c) && !kept_punct(prev, c, &chars[i + 1..]) {
            gap = true;
        } else if c.is_whitespace() {
            if !out.is_empty() && !out.ends_with(' ') {
                out.push(' ');
            }
        } else {
            if gap && out.chars().last().is_some_and(|p| p != ' ' && !cjk(p)) && !cjk(c) {
                out.push(' ');
            }
            gap = false;
            out.push(c);
        }
    }
    out.truncate(out.trim_end().len());
    out
}

const PUNCT: &str = ",.!?;:\"'()[]，。！？；：、“”‘’（）【】《》〈〉「」『』…—～·・";

fn is_punct(c: char) -> bool {
    PUNCT.contains(c)
}

/// 只看原文左右邻居判断，保证结果与调用次数无关
fn kept_punct(prev: Option<char>, c: char, rest: &[char]) -> bool {
    let next = rest.first().copied();
    let is = |o: Option<char>, f: fn(&char) -> bool| o.as_ref().is_some_and(f);
    match c {
        // 3.14、1.5万、example.com、b.txt
        '.' => is(prev, char::is_ascii_alphanumeric) && is(next, char::is_ascii_alphanumeric),
        // 10:30、localhost:8080、https://、C:\
        ':' => {
            is(prev, char::is_ascii_alphanumeric)
                && (is(next, char::is_ascii_digit) || matches!(next, Some('/' | '\\')))
        }
        // 千分位：逗号后恰好三位数字
        ',' => {
            is(prev, char::is_ascii_digit)
                && rest.len() >= 3
                && rest[..3].iter().all(char::is_ascii_digit)
                && !rest.get(3).is_some_and(char::is_ascii_digit)
        }
        // don't、it’s
        '\'' | '’' => is(prev, char::is_ascii_alphabetic) && is(next, char::is_ascii_alphabetic),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::strip_punctuation as s;

    #[test]
    fn strips_chinese_punctuation_without_spaces() {
        assert_eq!(
            s("你好，世界！今天（周一）天气“不错”；对吧？"),
            "你好世界今天周一天气不错对吧"
        );
        assert_eq!(s("《三体》、【注】〈一〉…—～·好：‘是’。"), "三体注一好是");
    }

    #[test]
    fn english_punctuation_becomes_single_space() {
        assert_eq!(s("hello, world."), "hello world");
        assert_eq!(s("hello,world!How are you?"), "hello world How are you");
        assert_eq!(
            s("He said \"hi\" (twice); ok: fine"),
            "He said hi twice ok fine"
        );
        assert_eq!(s("hello，世界。OK"), "hello世界OK");
    }

    #[test]
    fn keeps_decimal_point() {
        assert_eq!(s("圆周率是3.14。"), "圆周率是3.14");
        assert_eq!(s("涨了1.5万，还有0.5%。"), "涨了1.5万还有0.5%");
    }

    #[test]
    fn keeps_thousands_separator() {
        assert_eq!(
            s("一共1,000元，另有12,345,678个。"),
            "一共1,000元另有12,345,678个"
        );
    }

    #[test]
    fn keeps_time_colon() {
        assert_eq!(s("10:30开会：别迟到。"), "10:30开会别迟到");
    }

    #[test]
    fn keeps_urls_paths_and_apostrophes() {
        assert_eq!(
            s("打开https://example.com/a/b.txt。"),
            "打开https://example.com/a/b.txt"
        );
        assert_eq!(s("don't stop, it's fine."), "don't stop it's fine");
    }

    #[test]
    fn removes_consecutive_punctuation() {
        assert_eq!(s("好，。！？吧"), "好吧");
        assert_eq!(s("wait...what?!"), "wait what");
    }

    #[test]
    fn normalizes_whitespace() {
        assert_eq!(s("  hello ,   world  "), "hello world");
        assert_eq!(s(" ，你好 。 "), "你好");
    }

    #[test]
    fn deterministic_and_idempotent() {
        let input = "Hi, 你好！3.14 and 1,000 at 10:30... ok?";
        let a = s(input);
        assert_eq!(a, s(input));
        assert_eq!(s(&a), a);
    }

    #[test]
    fn empty_and_punctuation_only() {
        assert_eq!(s(""), "");
        assert_eq!(s("，。！？…"), "");
        assert_eq!(s(" , . ! "), "");
    }
}
