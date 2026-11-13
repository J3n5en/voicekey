//! 识别历史：只存内存（重启清空），默认关闭，避免网络/焦点问题导致整段文字丢失后只能重说。

use crate::settings::{Channel, Settings};
use crate::AppState;
use serde::Serialize;
use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub text: String,
    /// Unix 毫秒
    pub ts: u64,
    pub channel: Channel,
    /// 是否成功输入到焦点（false 表示只写了剪贴板）
    pub delivered: bool,
}

/// 最新的在前
#[derive(Default)]
struct History(VecDeque<HistoryEntry>);

impl History {
    fn push(&mut self, e: HistoryEntry, limit: usize) {
        self.0.push_front(e);
        self.0.truncate(limit);
    }

    /// 关闭即清空；调小条数即裁剪
    fn configure(&mut self, enabled: bool, limit: usize) {
        self.0.truncate(if enabled { limit } else { 0 });
    }
}

static HISTORY: Mutex<History> = Mutex::new(History(VecDeque::new()));

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

pub fn record(app: &AppHandle, text: &str, channel: Channel, delivered: bool) {
    let (enabled, limit) = {
        let state = app.state::<AppState>();
        let s = state.settings.read().unwrap();
        (s.history_enabled, s.history_limit as usize)
    };
    if !enabled || text.is_empty() {
        return;
    }
    HISTORY.lock().unwrap().push(HistoryEntry { text: text.into(), ts: now_ms(), channel, delivered }, limit);
    let _ = app.emit("history", list());
}

pub fn configure(s: &Settings) {
    HISTORY.lock().unwrap().configure(s.history_enabled, s.history_limit as usize);
}

pub fn list() -> Vec<HistoryEntry> {
    HISTORY.lock().unwrap().0.iter().cloned().collect()
}

pub fn clear() {
    HISTORY.lock().unwrap().0.clear();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(text: &str) -> HistoryEntry {
        HistoryEntry { text: text.into(), ts: 0, channel: Channel::Doubao, delivered: false }
    }

    fn texts(h: &History) -> Vec<&str> {
        h.0.iter().map(|e| e.text.as_str()).collect()
    }

    #[test]
    fn push_keeps_newest_first_within_limit() {
        let mut h = History::default();
        for t in ["a", "b", "c"] {
            h.push(entry(t), 2);
        }
        assert_eq!(texts(&h), ["c", "b"]);
    }

    #[test]
    fn configure_trims_on_smaller_limit_and_clears_when_disabled() {
        let mut h = History::default();
        for t in ["a", "b", "c"] {
            h.push(entry(t), 10);
        }
        h.configure(true, 2);
        assert_eq!(texts(&h), ["c", "b"]);
        h.configure(false, 2);
        assert!(h.0.is_empty());
    }

    #[test]
    fn entry_serializes_camel_case_with_channel_id() {
        let v = serde_json::to_value(HistoryEntry { text: "你好".into(), ts: 1, channel: Channel::QwenApp, delivered: true }).unwrap();
        assert_eq!(v, serde_json::json!({ "text": "你好", "ts": 1, "channel": "qwenapp", "delivered": true }));
    }
}
