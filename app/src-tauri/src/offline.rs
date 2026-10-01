//! 离线识别：仅 macOS arm64（在进程内加载安卓 ELF 引擎），其他平台禁用
use std::sync::Arc;
use voicekey_core::Engine;

pub const SUPPORTED: bool = cfg!(all(target_os = "macos", target_arch = "aarch64"));

pub fn installed() -> bool {
    false
}

pub fn engine() -> Option<Arc<dyn Engine>> {
    None
}
