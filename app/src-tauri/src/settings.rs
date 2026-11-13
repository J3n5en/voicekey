use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use voicekey_core::account::Login;
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
    Chatterfly,
    QwenApp,
    Bageshuo,
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
            Channel::Chatterfly => "Chatterfly",
            Channel::QwenApp => "千问 App",
            Channel::Bageshuo => "叭哥说",
            Channel::Offline => "豆包离线",
            Channel::WetypeOffline => "微信离线",
            Channel::All => "多渠道（说完挑选）",
        }
    }

    /// 需要登录官方账号的渠道
    pub fn login(self) -> Option<&'static Login> {
        match self {
            Channel::QwenApp => Some(&voicekey_core::qwenapp::LOGIN),
            Channel::Bageshuo => Some(&voicekey_core::bageshuo::LOGIN),
            _ => None,
        }
    }

    /// 当前平台可用的识别渠道（不含「全部」）
    pub fn engines() -> Vec<Channel> {
        let mut v = vec![Channel::Doubao, Channel::Wetype, Channel::Qwen, Channel::Baidu, Channel::Sogou, Channel::Iflytek, Channel::Chatterfly, Channel::QwenApp, Channel::Bageshuo];
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
const LOWER_SYSTEM_VOLUME_PERCENT_MIN: u8 = 20;
const LOWER_SYSTEM_VOLUME_PERCENT_MAX: u8 = 100;
const LOWER_SYSTEM_VOLUME_PERCENT_STEP: u8 = 5;
const LOWER_SYSTEM_VOLUME_PERCENT_DEFAULT: u8 = 70;
const HISTORY_LIMIT_MAX: u32 = 100;
const HISTORY_LIMIT_DEFAULT: u32 = 20;

/// 「无」保留字：音效逐事件的显式停用取值
pub const NONE: &str = "none";

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
    /// 候选框各渠道上屏次数，次数多的排前
    pub pick_counts: HashMap<Channel, u32>,
    /// 音频反馈提示音总开关；默认关闭——缺省键=关，升级用户不会被突然出声
    /// （与 lower_system_volume 默认关闭原则一致，review #4）
    pub sound_enabled: bool,
    /// 录音开始的提示音 id（见 crate::sound::SYSTEM_SOUNDS）
    pub sound_start: String,
    /// 进入识别处理的提示音 id
    pub sound_processing: String,
    /// 识别失败的提示音 id
    pub sound_error: String,
    pub autostart: bool,
    pub theme: String,
    /// 真正进入聆听后按相对比例压低系统输出；默认关闭，升级用户不会被突然改变系统声音。
    pub lower_system_volume: bool,
    /// 录音时相对原始系统音量降低的百分比；持久化为 settings.json 的 lowerSystemVolumePercent。
    pub lower_system_volume_percent: u8,
    pub onboarded: bool,
    /// 多渠道定稿后的 Jev 智能选择配置；默认关闭
    pub jev: voicekey_core::jev::Config,
    /// 识别历史（只存内存）；默认关闭，隐私优先
    pub history_enabled: bool,
    pub history_limit: u32,
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
            multi: Channel::engines().into_iter().filter(|&c| c != Channel::WetypeOffline && c.login().is_none()).collect(),
            last_pick: None,
            pick_counts: HashMap::new(),
            sound_enabled: false,
            sound_start: crate::sound::DEFAULT_START.into(),
            sound_processing: crate::sound::DEFAULT_PROCESSING.into(),
            sound_error: crate::sound::DEFAULT_ERROR.into(),
            autostart: false,
            theme: "system".into(),
            lower_system_volume: false,
            lower_system_volume_percent: LOWER_SYSTEM_VOLUME_PERCENT_DEFAULT,
            onboarded: false,
            jev: voicekey_core::jev::Config::default(),
            history_enabled: false,
            history_limit: HISTORY_LIMIT_DEFAULT,
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
        self.jev.sanitize_selection();
        if !Channel::available().contains(&self.channel) {
            self.channel = Channel::Doubao;
        }
        let custom = self.hold_key == CUSTOM_HOLD && self.hold_combo.as_ref().is_some_and(|c| crate::hotkey::valid_hold(&c.codes));
        if !custom && !voicekey_platform::hold_keys().iter().any(|k| k.id == self.hold_key) {
            self.hold_key = voicekey_platform::hold_keys()[0].id.into();
        }
        self.silence = self.silence.clamp(1.0, 5.0);
        self.history_limit = self.history_limit.clamp(1, HISTORY_LIMIT_MAX);
        for (id, default) in [
            (&mut self.sound_start, crate::sound::DEFAULT_START),
            (&mut self.sound_processing, crate::sound::DEFAULT_PROCESSING),
            (&mut self.sound_error, crate::sound::DEFAULT_ERROR),
        ] {
            // 非法值或当前平台不可选（无发声路径，如非 macOS 上无兜底 WAV 的系统音）
            // 一律回退该事件默认值，避免「选了不响」（review #3）
            if id != NONE && !crate::sound::selectable_sounds().contains(&id.as_str()) {
                *id = default.into();
            }
        }
        let percent = self
            .lower_system_volume_percent
            .clamp(LOWER_SYSTEM_VOLUME_PERCENT_MIN, LOWER_SYSTEM_VOLUME_PERCENT_MAX);
        self.lower_system_volume_percent = ((percent + LOWER_SYSTEM_VOLUME_PERCENT_STEP / 2)
            / LOWER_SYSTEM_VOLUME_PERCENT_STEP)
            * LOWER_SYSTEM_VOLUME_PERCENT_STEP;
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

    /// 音量 worker 使用“最终保留比例”，这里只在执行边界做一次 `1 - 降低比例` 换算。
    pub fn retained_system_volume_fraction(&self) -> f32 {
        1.0 - self.lower_system_volume_percent as f32 / 100.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_jev_selection_defaults_and_new_values_are_sanitized() {
        let mut settings: Settings = serde_json::from_str(r#"{"jev":{"mode":"official","key":"test-key"}}"#).unwrap();
        assert_eq!(settings.jev.selection_threshold, voicekey_core::jev::SelectionThreshold::TwoThirds);
        assert_eq!(settings.jev.selection_wait_ms, 2500);
        for (input, expected) in [(0, 500), (500, 500), (5000, 5000), (u64::MAX, 5000)] {
            settings.jev.selection_wait_ms = input;
            settings.sanitize();
            assert_eq!(settings.jev.selection_wait_ms, expected);
            assert_eq!(settings.jev.key, "test-key");
        }
    }

    #[test]
    fn missing_duck_percent_uses_default() {
        let mut value = serde_json::to_value(Settings::default()).unwrap();
        value.as_object_mut().unwrap().remove("lowerSystemVolumePercent");
        let settings: Settings = serde_json::from_value(value).unwrap();
        assert_eq!(settings.lower_system_volume_percent, LOWER_SYSTEM_VOLUME_PERCENT_DEFAULT);
    }

    #[test]
    fn legacy_config_without_history_fields_defaults_off_with_limit_20() {
        let s: Settings = serde_json::from_str(r#"{"channel":"doubao","mic":""}"#).unwrap();
        assert!(!s.history_enabled);
        assert_eq!(s.history_limit, 20);
    }

    #[test]
    fn history_limit_is_clamped() {
        let mut s = Settings::default();
        for (input, expected) in [(0, 1), (20, 20), (1000, HISTORY_LIMIT_MAX)] {
            s.history_limit = input;
            s.sanitize();
            assert_eq!(s.history_limit, expected);
        }
    }

    #[test]
    fn duck_percent_is_clamped_and_snapped_to_step() {
        let mut settings = Settings::default();

        settings.lower_system_volume_percent = 1;
        settings.sanitize();
        assert_eq!(settings.lower_system_volume_percent, 20);

        settings.lower_system_volume_percent = 33;
        settings.sanitize();
        assert_eq!(settings.lower_system_volume_percent, 35);

        settings.lower_system_volume_percent = 99;
        settings.sanitize();
        assert_eq!(settings.lower_system_volume_percent, 100);
    }

    #[test]
    fn duck_reduction_percent_maps_to_retained_fraction_once() {
        let mut settings = Settings::default();
        assert!((settings.retained_system_volume_fraction() - 0.3).abs() < f32::EPSILON);

        settings.lower_system_volume_percent = 100;
        assert!(settings.retained_system_volume_fraction().abs() < f32::EPSILON);

        settings.lower_system_volume_percent = 20;
        assert!((settings.retained_system_volume_fraction() - 0.8).abs() < f32::EPSILON);
    }
}

#[cfg(test)]
mod sound_settings_tests {
    use super::*;

    /// 旧版配置文件没有提示音字段：反序列化后应得到默认值，不报错
    #[test]
    fn legacy_config_without_sound_fields_falls_back_to_defaults() {
        let s: Settings = serde_json::from_str(r#"{"channel":"doubao","mic":""}"#).unwrap();
        assert!(!s.sound_enabled, "缺省键=关：升级用户不被突然出声（review #4）");
        assert!(crate::sound::is_known(&s.sound_start), "默认开始音效必须在音效池中");
        assert!(crate::sound::is_known(&s.sound_processing));
        assert!(crate::sound::is_known(&s.sound_error));
    }

    /// 配置里出现未知/已下架音效 id：sanitize 应回退为该事件默认值
    #[test]
    fn sanitize_reverts_unknown_sound_ids_to_defaults() {
        let mut s = Settings::default();
        let (start, processing, error) =
            (s.sound_start.clone(), s.sound_processing.clone(), s.sound_error.clone());
        s.sound_start = "nope".into();
        s.sound_processing = "".into();
        s.sanitize();
        assert_eq!(s.sound_start, start);
        assert_eq!(s.sound_processing, processing);
        // 合法 id 原样保留
        s.sound_error = error.clone();
        s.sanitize();
        assert_eq!(s.sound_error, error);
    }

    /// 非 macOS：无同名兜底 WAV 的系统音不可发声，sanitize 回退该事件默认值（review #3）
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn sanitize_reverts_platform_unavailable_sound_ids() {
        let mut s = Settings::default();
        s.sound_start = "Hero".into();
        s.sound_error = "Frog".into();
        s.sanitize();
        assert_eq!(s.sound_start, crate::sound::DEFAULT_START, "无兜底音回退默认");
        assert_eq!(s.sound_error, crate::sound::DEFAULT_ERROR, "无兜底音回退默认");
    }

    /// macOS：系统铃声全量可选，合法选择不被 sanitize 回退
    #[cfg(target_os = "macos")]
    #[test]
    fn sanitize_keeps_platform_available_sound_ids() {
        let mut s = Settings::default();
        s.sound_start = "Glass".into();
        s.sound_error = "Frog".into();
        s.sanitize();
        assert_eq!(s.sound_start, "Glass", "macOS 上系统音都可选");
        assert_eq!(s.sound_error, "Frog");
    }

    /// 「无」是显式合法取值：sanitize 不得把它回退成默认音效
    #[test]
    fn sanitize_keeps_none_sound_ids() {
        let mut s = Settings::default();
        for id in [&mut s.sound_start, &mut s.sound_processing, &mut s.sound_error] {
            *id = NONE.into();
        }
        s.sanitize();
        for (field, id) in [
            ("sound_start", s.sound_start.as_str()),
            ("sound_processing", s.sound_processing.as_str()),
            ("sound_error", s.sound_error.as_str()),
        ] {
            assert_eq!(id, NONE, "{field} 的「无」选择不得被 sanitize 回退");
        }
    }
}
