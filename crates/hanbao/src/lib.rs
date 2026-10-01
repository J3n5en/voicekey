/// 运行离线识别 worker（stdin/stdout JSON-lines），返回退出码；非 macOS arm64 恒返回 1
pub fn run_worker(model: &str, libdir: &str) -> i32 {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        use std::ffi::{c_char, c_int, CString};
        extern "C" {
            fn hanbao_main(argc: c_int, argv: *mut *mut c_char) -> c_int;
        }
        std::env::set_var("HB_LIBDIR", libdir);
        let args: Vec<CString> = ["VoiceKey", "--pipe", model].iter().map(|s| CString::new(*s).unwrap()).collect();
        let mut argv: Vec<*mut c_char> = args.iter().map(|s| s.as_ptr() as *mut c_char).collect();
        argv.push(std::ptr::null_mut());
        unsafe { hanbao_main(3, argv.as_mut_ptr()) }
    }
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    {
        let _ = (model, libdir);
        1
    }
}
