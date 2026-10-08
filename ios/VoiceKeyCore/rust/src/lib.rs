//! crates/core 的 C 接口，契约见 include/voicekey_ffi.h
#![allow(clippy::missing_safety_doc)]
use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use tokio::sync::mpsc;
use voicekey_core::audio::{self, Framer};
use voicekey_core::*;

pub type EventFn = extern "C" fn(ctx: *mut c_void, kind: i32, text: *const c_char);
pub type ReleaseFn = extern "C" fn(ctx: *mut c_void);

const PARTIAL: i32 = 0;
const FINAL: i32 = 1;
const ERROR: i32 = 2;

pub struct VKSession(Mutex<Option<(mpsc::UnboundedSender<Vec<i16>>, Framer)>>);

fn rt() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap())
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

unsafe fn engine(name: *const c_char) -> Option<Box<dyn Engine>> {
    if name.is_null() {
        return None;
    }
    Some(match CStr::from_ptr(name).to_bytes() {
        b"doubao" => Box::new(DoubaoEngine),
        b"wetype" => Box::new(WeTypeEngine::default()),
        b"qwen" => Box::new(QwenEngine::default()),
        b"baidu" => Box::new(BaiduEngine),
        b"sogou" => Box::new(SogouEngine),
        b"iflytek" => Box::new(IflyEngine),
        _ => return None,
    })
}

/// 回调目标：drop 时调用 release，保证在最后一个事件之后
struct Sink {
    on_event: EventFn,
    release: Option<ReleaseFn>,
    ctx: usize,
}

impl Sink {
    fn emit(&self, kind: i32, text: &str) {
        let c = CString::new(text.replace('\0', "")).unwrap();
        (self.on_event)(self.ctx as *mut c_void, kind, c.as_ptr());
    }
}

impl Drop for Sink {
    fn drop(&mut self) {
        if let Some(r) = self.release {
            r(self.ctx as *mut c_void);
        }
    }
}

fn spawn(e: Box<dyn Engine>, audio: Audio, sink: Sink) {
    rt().spawn(async move {
        let sink = Arc::new(sink);
        let p = sink.clone();
        match e.run(audio, Box::new(move |t| p.emit(PARTIAL, t))).await {
            Ok(t) => sink.emit(FINAL, &t),
            Err(err) => sink.emit(ERROR, &format!("{err:#}")),
        }
    });
}

#[no_mangle]
pub extern "C" fn vk_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

#[no_mangle]
pub unsafe extern "C" fn vk_session_start(
    engine_name: *const c_char,
    sample_rate: u32,
    on_event: EventFn,
    release: Option<ReleaseFn>,
    ctx: *mut c_void,
) -> *mut VKSession {
    let (Some(e), Ok(framer)) = (engine(engine_name), Framer::new(sample_rate)) else {
        return std::ptr::null_mut();
    };
    let (tx, rx) = mpsc::unbounded_channel();
    spawn(e, rx, Sink { on_event, release, ctx: ctx as usize });
    Box::into_raw(Box::new(VKSession(Mutex::new(Some((tx, framer))))))
}

#[no_mangle]
pub unsafe extern "C" fn vk_session_push(s: *const VKSession, pcm: *const f32, n: usize) {
    if s.is_null() || pcm.is_null() || n == 0 {
        return;
    }
    if let Some((tx, framer)) = lock(&(*s).0).as_mut() {
        for f in framer.push(std::slice::from_raw_parts(pcm, n)) {
            let _ = tx.send(f);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn vk_session_finish(s: *const VKSession) {
    if s.is_null() {
        return;
    }
    if let Some((tx, mut framer)) = lock(&(*s).0).take() {
        if let Some(f) = framer.flush() {
            let _ = tx.send(f);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn vk_session_free(s: *mut VKSession) {
    if !s.is_null() {
        vk_session_finish(s);
        drop(Box::from_raw(s));
    }
}

#[no_mangle]
pub unsafe extern "C" fn vk_run_file(
    engine_name: *const c_char,
    path: *const c_char,
    on_event: EventFn,
    release: Option<ReleaseFn>,
    ctx: *mut c_void,
) -> bool {
    let (Some(e), false) = (engine(engine_name), path.is_null()) else { return false };
    let sink = Sink { on_event, release, ctx: ctx as usize };
    let path = CStr::from_ptr(path).to_string_lossy();
    let _g = rt().enter();
    match audio::file_frames(&path, true) {
        Ok(a) => spawn(e, a, sink),
        Err(err) => sink.emit(ERROR, &format!("{err:#}")),
    }
    true
}

#[no_mangle]
pub unsafe extern "C" fn vk_prewarm(engine_name: *const c_char) -> bool {
    let Some(e) = engine(engine_name) else { return false };
    rt().spawn(async move { e.prewarm().await });
    true
}
