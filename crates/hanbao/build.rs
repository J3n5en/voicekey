//! 离线识别 worker：在进程内加载安卓 arm64 ELF 引擎，仅 macOS arm64 编译
fn main() {
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    if os != "macos" || arch != "aarch64" {
        return;
    }
    let dir = std::path::Path::new("../../Sources/CHanbao");
    let files = ["elfload.c", "harness.c", "shims.c"];
    for f in files {
        println!("cargo:rerun-if-changed={}", dir.join(f).display());
    }
    cc::Build::new()
        .files(files.iter().map(|f| dir.join(f)))
        .include(dir.join("include"))
        .include(dir)
        .opt_level(2)
        .flag("-Wno-unused-function")
        .warnings(false)
        .compile("hanbao");
}
