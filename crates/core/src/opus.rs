use anyhow::{bail, Result};
use audiopus_sys as ffi;

pub const VOIP: i32 = 2048;
pub const AUDIO: i32 = 2049;

pub struct Opus {
    enc: *mut ffi::OpusEncoder,
    buf: Vec<u8>,
}

unsafe impl Send for Opus {}

impl Opus {
    pub fn new(application: i32, bitrate: i32, complexity: i32) -> Result<Self> {
        let mut err = 0;
        let enc = unsafe { ffi::opus_encoder_create(16000, 1, application, &mut err) };
        if enc.is_null() || err != 0 {
            bail!("Opus 编码器创建失败");
        }
        unsafe {
            ffi::opus_encoder_ctl(enc, ffi::OPUS_SET_BITRATE_REQUEST as i32, bitrate);
            ffi::opus_encoder_ctl(enc, ffi::OPUS_SET_COMPLEXITY_REQUEST as i32, complexity);
        }
        Ok(Self { enc, buf: vec![0; 4000] })
    }

    /// 百度输入法：20ms CBR 32kbps + final_range 校验头
    pub fn baidu() -> Result<Self> {
        let o = Self::new(AUDIO, 32000, 10)?;
        unsafe {
            ffi::opus_encoder_ctl(o.enc, ffi::OPUS_SET_VBR_REQUEST, 0);
        }
        Ok(o)
    }

    pub fn encode(&mut self, pcm: &[i16]) -> Result<Vec<u8>> {
        let n = unsafe {
            ffi::opus_encode(self.enc, pcm.as_ptr(), pcm.len() as i32, self.buf.as_mut_ptr(), self.buf.len() as i32)
        };
        if n <= 0 {
            bail!("Opus 编码失败 {n}");
        }
        Ok(self.buf[..n as usize].to_vec())
    }

    /// BE32(len) + BE32(OPUS_GET_FINAL_RANGE) + opus
    pub fn encode_bd(&mut self, pcm: &[i16]) -> Result<Vec<u8>> {
        let n = unsafe {
            ffi::opus_encode(self.enc, pcm.as_ptr(), pcm.len() as i32, self.buf.as_mut_ptr(), self.buf.len() as i32)
        };
        if n <= 0 {
            bail!("Opus 编码失败 {n}");
        }
        let mut range: u32 = 0;
        unsafe {
            ffi::opus_encoder_ctl(self.enc, ffi::OPUS_GET_FINAL_RANGE_REQUEST, &mut range);
        }
        let mut v = Vec::with_capacity(8 + n as usize);
        v.extend_from_slice(&(n as u32).to_be_bytes());
        v.extend_from_slice(&range.to_be_bytes());
        v.extend_from_slice(&self.buf[..n as usize]);
        Ok(v)
    }
}

impl Drop for Opus {
    fn drop(&mut self) {
        unsafe { ffi::opus_encoder_destroy(self.enc) }
    }
}
