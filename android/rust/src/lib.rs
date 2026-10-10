//! crates/core 的 JNI 接口，对应 Kotlin 的 j3.voicekey.Native
use jni::objects::{GlobalRef, JClass, JFloatArray, JObject, JString, JValue};
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
        "wetypeoffline" => Box::new(LocalEngine { dir: wtoffline_dir() }),
        _ => return None,
    })
}

fn string(env: &mut JNIEnv, s: &JString) -> Option<String> {
    env.get_string(s).ok().map(Into::into)
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
        let sink = Arc::new(Sink(cb));
        let p = sink.clone();
        match e.run(rx, Box::new(move |t| p.emit(PARTIAL, t))).await {
            Ok(t) => sink.emit(FINAL, &t),
            Err(err) => sink.emit(ERROR, &format!("{err:#}")),
        }
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
