use serde::{Deserialize, Serialize};
use voicekey_core::util::data_file;
use voicekey_core::QwenOutput;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Channel {
    #[default]
    Doubao,
    Wetype,
    Qwen,
    Offline,
    All,
}

impl Channel {
    pub fn title(self) -> &'static str {
        match self {
            Channel::Doubao => "豆包输入法",
            Channel::Wetype => "微信输入法",
            Channel::Qwen => "千问输入法",
            Channel::Offline => "离线（本地模型）",
            Channel::All => "多渠道（说完挑选）",
        }
    }

    /// 当前平台可用的识别渠道（不含「全部」）
    pub fn engines() -> Vec<Channel> {
        let mut v = vec![Channel::Doubao, Channel::Wetype, Channel::Qwen];
        if crate::offline::SUPPORTED {
            v.push(Channel::Offline);
        }
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

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub channel: Channel,
    pub hold_key: String,
    pub tap_shortcut: Option<Shortcut>,
    pub silence: f64,
    pub streaming: bool,
    pub live_text: bool,
    pub mic: String,
    pub qwen_output: QwenOutput,
    /// 多渠道模式下同时识别的渠道（至少 2 个）
    pub multi: Vec<Channel>,
    pub autostart: bool,
    pub theme: String,
    pub onboarded: bool,
}

impl Default for Settings {
    fn default() -> Self {
        let (hold, tap) = if cfg!(target_os = "macos") { ("rightAlt", (54, "右 ⌘")) } else { ("rightAlt", (0xA3, "右 Ctrl")) };
        Self {
            channel: Channel::Doubao,
            hold_key: hold.into(),
            tap_shortcut: Some(Shortcut { code: tap.0, mods: 0, name: tap.1.into() }),
            silence: 1.5,
            streaming: true,
            live_text: true,
            mic: String::new(),
            qwen_output: QwenOutput::Polish,
            multi: Channel::engines(),
            autostart: false,
            theme: "system".into(),
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
        if !voicekey_platform::hold_keys().iter().any(|k| k.id == self.hold_key) {
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

    pub fn hold_code(&self) -> u32 {
        voicekey_platform::hold_keys().iter().find(|k| k.id == self.hold_key).map_or(0, |k| k.code)
    }

    pub fn hold_name(&self) -> &'static str {
        voicekey_platform::hold_keys().iter().find(|k| k.id == self.hold_key).map_or("", |k| k.name)
    }
}
