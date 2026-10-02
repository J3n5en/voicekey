//! 官方离线语音包（微信输入法资源 CDN）：外层签名 zip 内嵌 ime_asr_decoder_model.zip
use crate::Model;
use anyhow::{bail, Result};
use std::fs::{self, File};
use std::io;
use std::path::Path;
use zip::ZipArchive;

pub const URL: &str = "https://download.z.weixin.qq.com/publish_words/v1/ime_asr_decoder_model/20260710220526250_ime_asr_decoder_model.apk";
pub const SIZE: u64 = 102_920_639;
pub const MD5: &str = "28386481eb94ff73b28ee3949c0cf690";
const FILES: [&str; 1] = ["dict.decoder.utf8.txt"];

/// 解出模型、词表到 dir：先写同级临时目录并试加载，成功后整体改名
pub fn unpack(pack: &Path, dir: &Path) -> Result<()> {
    let tmp = dir.with_extension("tmp");
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp)?;
    let inner = tmp.join("inner.zip");
    io::copy(&mut ZipArchive::new(File::open(pack)?)?.by_name("ime_asr_decoder_model.zip")?, &mut File::create(&inner)?)?;
    let mut z = ZipArchive::new(File::open(&inner)?)?;
    for i in 0..z.len() {
        let mut e = z.by_index(i)?;
        let Some(name) = e.enclosed_name().and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned())) else { continue };
        if e.is_file() && (name.ends_with(".xnet") || FILES.contains(&name.as_str())) {
            io::copy(&mut e, &mut File::create(tmp.join(&name))?)?;
        }
    }
    drop(z);
    fs::remove_file(&inner)?;
    if !FILES.iter().all(|f| tmp.join(f).is_file()) {
        bail!("语音包内容不完整");
    }
    drop(Model::load(&tmp)?);
    let _ = fs::remove_dir_all(dir);
    fs::rename(&tmp, dir)?;
    Ok(())
}
