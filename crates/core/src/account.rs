//! 需要登录的渠道：官方账号的登录 Cookie，保存在数据目录的 accounts.json
use crate::util::data_file;
use anyhow::{bail, Result};
use futures_util::future::BoxFuture;
use std::collections::BTreeMap;
use std::io::Write;
use std::sync::Mutex;

/// 一个需要登录官方账号的渠道
pub struct Login {
    /// accounts.json 里的键，也是环境变量 VOICEKEY_<ID> 的后缀
    pub id: &'static str,
    /// 官方登录页
    pub page: &'static str,
    /// 登录 Cookie 所在的域，含子域
    pub domain: &'static str,
    /// 任意一组齐全即为已登录。只粘贴一个值时当作第一项
    pub cookies: &'static [&'static [&'static str]],
    /// 联网校验登录 Cookie
    pub check: fn(&str) -> BoxFuture<'_, Result<()>>,
}

static LOCK: Mutex<()> = Mutex::new(());

fn load() -> BTreeMap<String, String> {
    std::fs::read(data_file("accounts.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

impl Login {
    /// 登录 Cookie 头，未登录时为空串。环境变量 VOICEKEY_<ID> 优先，供命令行测试
    pub fn get(&self) -> String {
        let env = std::env::var(format!("VOICEKEY_{}", self.id.to_uppercase())).unwrap_or_default();
        let raw = if env.trim().is_empty() { load().remove(self.id).unwrap_or_default() } else { env };
        self.pick(&raw).unwrap_or_default()
    }

    pub fn has(&self) -> bool {
        !self.get().is_empty()
    }

    /// 保存登录 Cookie，空串即退出登录
    pub fn set(&self, cookie: &str) -> std::io::Result<()> {
        let _g = LOCK.lock().unwrap();
        let mut all = load();
        if cookie.is_empty() {
            all.remove(self.id);
        } else {
            all.insert(self.id.into(), cookie.into());
        }
        // 写临时文件再改名替换，中途失败也不会弄坏已保存的内容。新文件只允许当前用户读写
        let tmp = data_file("accounts.json.tmp");
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut opts, 0o600);
        opts.open(&tmp)?.write_all(&serde_json::to_vec_pretty(&all)?)?;
        std::fs::rename(tmp, data_file("accounts.json"))
    }

    /// 从粘贴内容或网页 Cookie 里只留下登录要用的几项，拼成 Cookie 头
    pub fn pick(&self, input: &str) -> Result<String> {
        let names = self.cookies.concat();
        let s = input.trim().trim_matches('"');
        let pairs = if s.contains('=') { cookies(s) } else { vec![(names[0], s)] };
        let mut kept: Vec<(&str, &str)> = Vec::new();
        for (k, v) in pairs {
            if names.contains(&k) && value(v) && !kept.iter().any(|(n, _)| *n == k) {
                kept.push((k, v));
            }
        }
        if !self.cookies.iter().any(|group| group.iter().all(|n| kept.iter().any(|(k, _)| k == n))) {
            let wanted: Vec<String> = self.cookies.iter().map(|group| group.join(" 与 ")).collect();
            bail!("没有找到 {}", wanted.join("，或 "));
        }
        Ok(kept.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("; "))
    }
}

/// Cookie 头或开发者工具里复制的 `名=值` 列表，分号或换行分隔
fn cookies(s: &str) -> Vec<(&str, &str)> {
    s.split([';', '\n'])
        .filter_map(|p| p.split_once('='))
        .map(|(k, v)| (k.trim(), v.trim().trim_matches('"')))
        .filter(|(k, v)| !k.is_empty() && !v.is_empty())
        .collect()
}

/// RFC 6265 的 cookie-octet：可见 ASCII，不含双引号、逗号、分号、反斜杠。否则进不了请求头
fn value(v: &str) -> bool {
    !v.is_empty() && v.bytes().all(|b| b.is_ascii_graphic() && !matches!(b, b'"' | b',' | b';' | b'\\'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(_: &str) -> BoxFuture<'_, Result<()>> {
        Box::pin(async { Ok(()) })
    }

    const TICKET: Login = Login { id: "unit", page: "", domain: "", cookies: &[&["t"]], check: ok };
    const PAIR: Login = Login { id: "unitpair", page: "", domain: "", cookies: &[&["P"], &["S", "L"]], check: ok };

    #[test]
    fn parses_cookie_header_and_devtools_lines() {
        assert_eq!(cookies("a=1; b = 2 ;c=\"3\""), [("a", "1"), ("b", "2"), ("c", "3")]);
        assert_eq!(cookies("a=1\r\nb=x=y\n\nbad\nc="), [("a", "1"), ("b", "x=y")]);
    }

    #[test]
    fn pick_keeps_only_login_cookies() {
        assert_eq!(TICKET.pick("a=1; t=abc$*_9; b=2").unwrap(), "t=abc$*_9");
        assert_eq!(TICKET.pick("  \"abc123\" \n").unwrap(), "t=abc123");
        assert_eq!(TICKET.pick("t=abc").unwrap(), "t=abc");
        assert_eq!(PAIR.pick("JSESSIONID=x; P=v2|a.b; UT=u").unwrap(), "P=v2|a.b");
        assert_eq!(PAIR.pick("S=s|1\nL=3|9").unwrap(), "S=s|1; L=3|9");
        assert_eq!(PAIR.pick("P=a; P=b").unwrap(), "P=a");
        assert_eq!(PAIR.pick("v2|urs-phone|x.y").unwrap(), "P=v2|urs-phone|x.y");
    }

    #[test]
    fn pick_rejects_missing_or_unusable_values() {
        assert_eq!(PAIR.pick("S=s").unwrap_err().to_string(), "没有找到 P，或 S 与 L");
        assert_eq!(TICKET.pick("").unwrap_err().to_string(), "没有找到 t");
        assert!(TICKET.pick("a=1; x=2").is_err());
        assert!(TICKET.pick("ab\tc").is_err());
        assert!(TICKET.pick("t=中文").is_err());
        assert!(TICKET.pick("t=a,b").is_err());
    }

    #[test]
    fn saves_privately_replaces_atomically_and_prefers_env() {
        let dir = std::env::temp_dir().join(format!("vk-account-{}", std::process::id()));
        crate::util::set_data_dir(dir.clone());
        assert_eq!(crate::util::data_dir(), dir, "测试不能写真实数据目录");
        TICKET.set("t=secret").unwrap();
        assert_eq!(TICKET.get(), "t=secret");
        assert!(!data_file("accounts.json.tmp").exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(data_file("accounts.json")).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        let env = Login { id: "unitenv", ..TICKET };
        std::env::set_var("VOICEKEY_UNITENV", "  a=1; t=from-env ");
        assert_eq!(env.get(), "t=from-env");
        TICKET.set("").unwrap();
        assert!(!TICKET.has());
    }
}
