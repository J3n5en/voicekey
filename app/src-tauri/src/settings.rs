use serde::{Deserialize, Serialize};
use voicekey_core::util::data_file;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Channel {
    #[default]
    Doubao,
    Wetype,
    Qwen,
    Baidu,
    Sogou,
    Iflytek,
    Offline,
    WetypeOffline,
    All,
}

impl Channel {
    pub fn title(self) -> &'static str {
        match self {
            Channel::Doubao => "豆包输入法",
            Channel::Wetype => "微信输入法",
            Channel::Qwen => "千问输入法",
            Channel::Baidu => "百度输入法",
            Channel::Sogou => "搜狗输入法",
            Channel::Iflytek => "讯飞输入法",
            Channel::Offline => "豆包离线",
            Channel::WetypeOffline => "微信离线",
            Channel::All => "多渠道（说完挑选）",
        }
    }

    /// 当前平台可用的识别渠道（不含「全部」）
    pub fn engines() -> Vec<Channel> {
        let mut v = vec![Channel::Doubao, Channel::Wetype, Channel::Qwen, Channel::Baidu, Channel::Sogou, Channel::Iflytek];
        if crate::offline::SUPPORTED {
            v.push(Channel::Offline);
        }
        v.push(Channel::WetypeOffline);
        v
    }

    pub fn available() -> Vec<Channel> {
        let mut v = Self::engines();
        v.push(Channel::All);
        v
    }
}

/// 点按快捷键：单个修饰键（区分左右）或 修饰键+按键 组合
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Shortcut {
    pub code: u32,
    pub mods: u8,
    pub name: String,
}

impl Shortcut {
    pub fn is_modifier(&self) -> bool {
        voicekey_platform::modifier(self.code).is_some()
    }

    pub fn title(&self) -> String {
        voicekey_platform::mods_prefix(self.mods) + &self.name
    }
}

/// 自定义长按组合：键码（修饰键区分左右）
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Combo {
    pub codes: Vec<u32>,
    pub name: String,
}

pub const CUSTOM_HOLD: &str = "custom";

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub channel: Channel,
    /// 预设键 id，或 CUSTOM_HOLD 表示使用 hold_combo
    pub hold_key: String,
    pub hold_combo: Option<Combo>,
    pub tap_shortcut: Option<Shortcut>,
    pub silence: f64,
    /// 点按模式静音后自动结束；关闭后只能再点一次结束
    pub silence_stop: bool,
    pub streaming: bool,
    pub live_text: bool,
    pub mic: String,
    /// 多渠道模式下同时识别的渠道（至少 2 个）
    pub multi: Vec<Channel>,
    /// 候选框上次选中的渠道，下次默认聚焦
    pub last_pick: Option<Channel>,
    pub autostart: bool,
    pub theme: String,
    /// 真正进入聆听后把系统输出平滑压到原音量的 30%；默认关闭，升级用户不会被突然改变系统声音。
    pub lower_system_volume: bool,
    pub onboarded: bool,
}

impl Default for Settings {
    fn default() -> Self {
        let (hold, tap) = if cfg!(target_os = "macos") { ("rightAlt", (54, "右 ⌘")) } else { ("rightAlt", (0xA3, "右 Ctrl")) };
        Self {
            channel: Channel::Doubao,
            hold_key: hold.into(),
            hold_combo: None,
            tap_shortcut: Some(Shortcut { code: tap.0, mods: 0, name: tap.1.into() }),
            silence: 1.5,
            silence_stop: true,
            streaming: true,
            live_text: true,
            mic: String::new(),
            multi: Channel::engines().into_iter().filter(|&c| c != Channel::WetypeOffline).collect(),
            last_pick: None,
            autostart: false,
            theme: "system".into(),
            lower_system_volume: false,
            onboarded: false,
        }
    }
}

impl Settings {
    pub fn load() -> Self {
        let mut s: Settings = std::fs::read(data_file("settings.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        s.sanitize();
        s
    }

    pub fn save(&self) {
        if let Ok(b) = serde_json::to_vec_pretty(self) {
            let _ = std::fs::write(data_file("settings.json"), b);
        }
    }

    /// 不可用的渠道/按键回落默认
    pub fn sanitize(&mut self) {
        if !Channel::available().contains(&self.channel) {
            self.channel = Channel::Doubao;
        }
        let custom = self.hold_key == CUSTOM_HOLD && self.hold_combo.as_ref().is_some_and(|c| crate::hotkey::valid_hold(&c.codes));
        if !custom && !voicekey_platform::hold_keys().iter().any(|k| k.id == self.hold_key) {
            self.hold_key = voicekey_platform::hold_keys()[0].id.into();
        }
        self.silence = self.silence.clamp(1.0, 5.0);
        let engines = Channel::engines();
        let mut multi: Vec<Channel> = engines.iter().copied().filter(|c| self.multi.contains(c)).collect();
        if multi.len() < 2 {
            multi = engines;
        }
        self.multi = multi;
    }

    pub fn hold_codes(&self) -> Vec<u32> {
        match &self.hold_combo {
            Some(c) if self.hold_key == CUSTOM_HOLD => c.codes.clone(),
            _ => voicekey_platform::hold_keys().iter().filter(|k| k.id == self.hold_key).map(|k| k.code).collect(),
        }
    }

    pub fn hold_name(&self) -> String {
        match &self.hold_combo {
            Some(c) if self.hold_key == CUSTOM_HOLD => c.name.clone(),
            _ => voicekey_platform::hold_keys().iter().find(|k| k.id == self.hold_key).map_or("", |k| k.name).into(),
        }
    }
}
