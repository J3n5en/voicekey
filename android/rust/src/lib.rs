//! crates/core 的 JNI 接口，对应 Kotlin 的 j3.voicekey.Native
use jni::objects::{GlobalRef, JClass, JFloatArray, JObject, JObjectArray, JString, JValue};
use jni::sys::{jboolean, jint, jlong, jstring, JNI_FALSE, JNI_TRUE};
use jni::{JNIEnv, JavaVM};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use tokio::sync::mpsc;
use voicekey_core::audio::Framer;
use voicekey_core::util::data_dir;
use voicekey_core::*;
use voicekey_wtlocal::{pack, LocalEngine};

const PARTIAL: i32 = 0;
const FINAL: i32 = 1;
const ERROR: i32 = 2;
/// 连接中断后自动重连，录音不中断；text 为提示文案
const RECONNECT: i32 = 3;

/// 断线重连的上限：次数、可回放的录音时长、回放间隔（服务端拒绝瞬间灌入）
const RETRIES: u32 = 3;
const REPLAY_MAX: usize = 60 * 50;
const REPLAY_GAP: std::time::Duration = std::time::Duration::from_millis(5);

struct Session(Mutex<Option<(mpsc::UnboundedSender<Vec<i16>>, Framer)>>);

static VM: OnceLock<JavaVM> = OnceLock::new();

fn rt() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap())
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn wtoffline_dir() -> PathBuf {
    data_dir().join("wtoffline")
}

fn engine(name: &str) -> Option<Box<dyn Engine>> {
    Some(match name {
        "doubao" => Box::new(DoubaoEngine),
        "wetype" => Box::new(WeTypeEngine::default()),
        "qwen" => Box::new(QwenEngine::default()),
        "baidu" => Box::new(BaiduEngine),
        "sogou" => Box::new(SogouEngine),
        "iflytek" => Box::new(IflyEngine),
        "chatterfly" => Box::new(ChatterflyEngine),
        "wetypeoffline" => Box::new(LocalEngine { dir: wtoffline_dir() }),
        _ => return None,
    })
}

/// 断线重连：录音未结束时连接失败，回放已录的音频再接实时流重试
struct Retry {
    engine: Box<dyn Engine>,
    sink: Arc<Sink>,
    live: mpsc::UnboundedReceiver<Vec<i16>>,
    buf: Vec<Vec<i16>>,
    attempts: u32,
}

impl Retry {
    async fn run(mut self) {
        loop {
            let (tx, rx) = mpsc::unbounded_channel();
            let feed = tokio::spawn(Self::feed(tx, std::mem::take(&mut self.buf), self.live));
            let p = self.sink.clone();
            let res = self.engine.run(rx, Box::new(move |t| p.emit(PARTIAL, t))).await;
            // 引擎返回即已丢弃 rx，feed 随即自己结束，不用 abort（abort 会丢掉缓冲）
            match res {
                Ok(t) => return self.sink.emit(FINAL, &t),
                Err(err) => {
                    let Ok((done, frames, live)) = feed.await else { return self.sink.emit(ERROR, &format!("{err:#}")) };
                    self.live = live;
                    // 用户已松手或回放不完：按原样报错，不再重试
                    if done || frames.len() > REPLAY_MAX || self.attempts >= RETRIES {
                        return self.sink.emit(ERROR, &format!("{err:#}"));
                    }
                    self.attempts += 1;
                    self.buf = frames;
                    self.sink.emit(RECONNECT, "网络中断，正在重试");
                }
            }
        }
    }

    /// 先按间隔回放缓冲，再转发实时帧；返回（录音是否已结束，期间收到的全部帧）
    async fn feed(
        tx: mpsc::UnboundedSender<Vec<i16>>,
        buf: Vec<Vec<i16>>,
        mut live: mpsc::UnboundedReceiver<Vec<i16>>,
    ) -> (bool, Vec<Vec<i16>>, mpsc::UnboundedReceiver<Vec<i16>>) {
        let mut all = buf;
        for f in &all {
            if tx.send(f.clone()).is_err() {
                return (false, all, live);
            }
            tokio::time::sleep(REPLAY_GAP).await;
        }
        while let Some(f) = live.recv().await {
            all.push(f.clone());
            if tx.send(f).is_err() {
                return (false, all, live);
            }
        }
        (true, all, live)
    }
}

fn string(env: &mut JNIEnv, s: &JString) -> Option<String> {
    env.get_string(s).ok().map(Into::into)
}

/// 从 String 对象数组逐个取出内容，任一元素取不出返回 None
fn strings(env: &mut JNIEnv, arr: &JObjectArray) -> Option<Vec<String>> {
    let len = env.get_array_length(arr).ok()?;
    let mut out = Vec::with_capacity(len.max(0) as usize);
    for i in 0..len {
        let e = env.get_object_array_element(arr, i).ok()?;
        out.push(string(env, &JString::from(e))?);
    }
    Some(out)
}

/// 回调 Listener.onEvent(kind, text)，在 Rust 工作线程上调用
struct Sink(GlobalRef);

impl Sink {
    fn emit(&self, kind: i32, text: &str) {
        let Some(vm) = VM.get() else { return };
        let Ok(mut env) = vm.attach_current_thread_as_daemon() else { return };
        if let Ok(s) = env.new_string(text) {
            let _ = env.call_method(&self.0, "onEvent", "(ILjava/lang/String;)V", &[JValue::Int(kind), JValue::Object(&s)]);
            let _ = env.delete_local_ref(s);
        }
        if env.exception_check().unwrap_or(false) {
            let _ = env.exception_clear();
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_j3_voicekey_Native_init(mut env: JNIEnv, _: JClass, dir: JString) {
    if let Ok(vm) = env.get_java_vm() {
        let _ = VM.set(vm);
    }
    if let Some(d) = string(&mut env, &dir) {
        util::set_data_dir(PathBuf::from(d));
    }
}

#[no_mangle]
pub extern "system" fn Java_j3_voicekey_Native_start(
    mut env: JNIEnv,
    _: JClass,
    name: JString,
    rate: jint,
    listener: JObject,
) -> jlong {
    let Some(e) = string(&mut env, &name).and_then(|n| engine(&n)) else { return 0 };
    let (Ok(framer), Ok(cb)) = (Framer::new(rate as u32), env.new_global_ref(listener)) else { return 0 };
    let (tx, rx) = mpsc::unbounded_channel();
    rt().spawn(async move {
        Retry { engine: e, sink: Arc::new(Sink(cb)), live: rx, buf: Vec::new(), attempts: 0 }.run().await;
    });
    Box::into_raw(Box::new(Session(Mutex::new(Some((tx, framer)))))) as jlong
}

#[no_mangle]
pub unsafe extern "system" fn Java_j3_voicekey_Native_push(env: JNIEnv, _: JClass, h: jlong, pcm: JFloatArray, n: jint) {
    let Some(s) = (h as *const Session).as_ref() else { return };
    let mut buf = vec![0f32; n.max(0) as usize];
    if buf.is_empty() || env.get_float_array_region(&pcm, 0, &mut buf).is_err() {
        return;
    }
    if let Some((tx, framer)) = lock(&s.0).as_mut() {
        for f in framer.push(&buf) {
            let _ = tx.send(f);
        }
    }
}

#[no_mangle]
pub unsafe extern "system" fn Java_j3_voicekey_Native_finish(_: JNIEnv, _: JClass, h: jlong) {
    let Some(s) = (h as *const Session).as_ref() else { return };
    if let Some((tx, mut framer)) = lock(&s.0).take() {
        if let Some(f) = framer.flush() {
            let _ = tx.send(f);
        }
    }
}

/// 未 finish 则先 finish，不影响进行中的识别和回调
#[no_mangle]
pub unsafe extern "system" fn Java_j3_voicekey_Native_free(env: JNIEnv, c: JClass, h: jlong) {
    if h != 0 {
        Java_j3_voicekey_Native_finish(env, c, h);
        drop(Box::from_raw(h as *mut Session));
    }
}

#[no_mangle]
pub extern "system" fn Java_j3_voicekey_Native_prewarm(mut env: JNIEnv, _: JClass, name: JString) {
    if let Some(e) = string(&mut env, &name).and_then(|n| engine(&n)) {
        rt().spawn(async move { e.prewarm().await });
    }
}

#[no_mangle]
pub extern "system" fn Java_j3_voicekey_Native_wtofflineReady(_: JNIEnv, _: JClass) -> jboolean {
    if wtoffline_dir().is_dir() { JNI_TRUE } else { JNI_FALSE }
}

/// 解包微信离线语音包，成功返回 null，失败返回错误信息
#[no_mangle]
pub extern "system" fn Java_j3_voicekey_Native_wtofflineUnpack(mut env: JNIEnv, _: JClass, apk: JString) -> jstring {
    let Some(apk) = string(&mut env, &apk) else { return std::ptr::null_mut() };
    match pack::unpack(apk.as_ref(), &wtoffline_dir()) {
        Ok(()) => std::ptr::null_mut(),
        Err(e) => env.new_string(format!("{e:#}")).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut()),
    }
}

#[no_mangle]
pub extern "system" fn Java_j3_voicekey_Native_wtofflineInfo(env: JNIEnv, _: JClass) -> jstring {
    env.new_string(format!("{}\n{}\n{}", pack::URL, pack::SIZE, pack::MD5)).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut())
}

/// Jev 智能选择配置自检：可用返回 null，不可用返回原因
#[no_mangle]
pub extern "system" fn Java_j3_voicekey_Native_jevCheck(mut env: JNIEnv, _: JClass, config: JString) -> jstring {
    let reason = match string(&mut env, &config) {
        Some(c) => jev::Config::from_json(&c).targets().err(),
        None => Some("参数错误".to_string()),
    };
    match reason {
        Some(r) => env.new_string(r).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut()),
        None => std::ptr::null_mut(),
    }
}

/// Jev 智能选择：评出最佳候选转写，成功回调 FINAL（Picked JSON），失败回调 ERROR（原因），恰好一次
#[no_mangle]
pub extern "system" fn Java_j3_voicekey_Native_jevPick(
    mut env: JNIEnv,
    _: JClass,
    config: JString,
    texts: JObjectArray,
    listener: JObject,
) {
    let Ok(cb) = env.new_global_ref(listener) else { return };
    let sink = Arc::new(Sink(cb));
    let (Some(c), Some(texts)) = (string(&mut env, &config), strings(&mut env, &texts)) else {
        return sink.emit(ERROR, "参数错误");
    };
    let cfg = jev::Config::from_json(&c);
    rt().spawn(async move {
        match jev::pick(&cfg, &texts).await {
            Ok(p) => sink.emit(FINAL, &p.to_json()),
            Err(e) => sink.emit(ERROR, &e.to_string()),
        }
    });
}

/// Jev 测试：用内置示例转写真打一次，成功回调 FINAL（Tested JSON），失败回调 ERROR（原因），恰好一次
#[no_mangle]
pub extern "system" fn Java_j3_voicekey_Native_jevTest(
    mut env: JNIEnv,
    _: JClass,
    config: JString,
    listener: JObject,
) {
    let Ok(cb) = env.new_global_ref(listener) else { return };
    let sink = Arc::new(Sink(cb));
    let Some(c) = string(&mut env, &config) else {
        return sink.emit(ERROR, "参数错误");
    };
    let cfg = jev::Config::from_json(&c);
    rt().spawn(async move {
        match jev::test(&cfg).await {
            Ok(t) => sink.emit(FINAL, &t.to_json()),
            Err(e) => sink.emit(ERROR, &e.to_string()),
        }
    });
}
