//! 平台相关能力：全局键盘钩子、模拟输入、光标位置、权限

#[cfg(target_os = "macos")]
mod mac;
#[cfg(target_os = "macos")]
use mac as imp;
#[cfg(windows)]
mod win;
#[cfg(windows)]
use win as imp;

pub use imp::{caret, front_app, inject_key, paste, secure_input, start_hook, FrontApp};

pub const CTRL: u8 = 1;
pub const ALT: u8 = 2;
pub const SHIFT: u8 = 4;
pub const META: u8 = 8;
pub const FN: u8 = 16;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyKind {
    Down,
    Up,
    /// 修饰键状态变化，true 为按下
    Modifier(bool),
}

#[derive(Clone, Debug)]
pub struct KeyEvent {
    pub kind: KeyKind,
    /// 平台原生键码（macOS virtual keycode / Windows VK）
    pub code: u32,
    /// 事件发生时按住的修饰键（CTRL|ALT|SHIFT|META|FN）
    pub mods: u8,
    pub repeat: bool,
    /// 按键产生的字符（仅 Down 事件，用于显示快捷键名）
    pub chars: Option<String>,
}

/// 返回 true 表示吞掉该事件
pub type HookFn = Box<dyn FnMut(&KeyEvent) -> bool + Send>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Special {
    Escape,
    Enter,
    Up,
    Down,
    Digit(u8),
}

pub use imp::keys::{hold_keys, is_function_key, modifier, special};

/// 长按说话可选的修饰键
pub struct HoldKey {
    pub id: &'static str,
    pub code: u32,
    pub name: &'static str,
}

pub fn key_name(e: &KeyEvent) -> String {
    if let Some((_, n)) = modifier(e.code) {
        return n.into();
    }
    imp::keys::special_name(e.code)
        .map(String::from)
        .or_else(|| e.chars.as_ref().map(|c| c.trim().to_uppercase()).filter(|c| !c.is_empty()))
        .unwrap_or_else(|| format!("#{}", e.code))
}

/// 修饰键前缀，如 ⌃⌥⇧⌘ / Ctrl+Alt+Shift+Win+
pub fn mods_prefix(m: u8) -> String {
    let mut s = String::new();
    let table: &[(u8, &str)] = if cfg!(target_os = "macos") {
        &[(CTRL, "⌃"), (ALT, "⌥"), (SHIFT, "⇧"), (META, "⌘")]
    } else {
        &[(CTRL, "Ctrl+"), (ALT, "Alt+"), (SHIFT, "Shift+"), (META, "Win+")]
    };
    for (f, n) in table {
        if m & f != 0 {
            s.push_str(n);
        }
    }
    s
}

#[derive(Clone, Copy, Debug)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    /// true：物理像素（Windows）；false：逻辑点（macOS）
    pub physical: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MicStatus {
    Granted,
    Denied,
    Undetermined,
}

/// 系统权限（Windows 无需授权，恒为已授权）
pub mod perm {
    pub use crate::imp::perm::*;
}

/// 边说边上屏：与已打出的文本比对，退格删掉分歧部分再补打新内容（不经剪贴板）
#[derive(Default)]
pub struct Typer {
    typed: Vec<char>,
    done: bool,
}

impl Typer {
    pub fn update(&mut self, text: &str) {
        if self.done {
            return;
        }
        let next: Vec<char> = text.chars().collect();
        let common = self.typed.iter().zip(&next).take_while(|(a, b)| a == b).count();
        imp::backspace(self.typed.len() - common);
        let tail: String = next[common..].iter().collect();
        if !tail.is_empty() {
            imp::type_text(&tail);
        }
        self.typed = next;
    }

    pub fn finish(&mut self) {
        self.done = true;
    }
}
