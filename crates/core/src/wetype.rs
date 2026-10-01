use crate::pb::{self, PBuf};
use crate::util::{data_file, now_ms, rand_lower};
use crate::ws::{self, Ws};
use crate::{opus, Audio, Engine, Partial};
use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyInit};
use anyhow::{anyhow, bail, Result};
use futures_util::SinkExt;
use md5::Md5;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::time::Duration;
use tokio::sync::Mutex;
use tokio_tungstenite::tungstenite::Message;

const PACKETS_PER_REQUEST: usize = 6;
const HOST: &str = "wetype.weixin.qq.com";
const SIGN_KEY: &str = "zN7rB3bL4pO8jW1o";
const BOOT_KEY: &[u8] = b"D4Y5U3Y2M0C0T7N4P1P7O2N6E1I2Y1U6";
const VERSION: &str = "2.2.3(657)";
const OS_TYPE: &str = "5";
const PLATFORM: &str = "2";
const DEVICE_MODEL: &str = "Mac16,12";
const CMD_DH: u64 = 2_147_483_646;
const CMD_UIN: u64 = 0x7FFF_FDFD;
const CMD_NOTIFY: u64 = 8074;
const CMD_VOICE: u64 = 4548;

/// 微信输入法云端识别（伪装 Mac 客户端）：protobuf 包 HTTP over WSS + snappy + AES-256-ECB + secp128r1 ECDH
#[derive(Default)]
pub struct WeTypeEngine {
    client: Mutex<Option<Client>>,
}

impl WeTypeEngine {
    /// 握手约 400ms，连接留着给下次用；失效则首包失败时重连重发
    async fn take(&self) -> Result<(Client, bool)> {
        if let Some(c) = self.client.lock().await.take().filter(|c| !c.dead) {
            return Ok((c, true));
        }
        Ok((Client::open().await?, false))
    }
}

struct Upload<'a> {
    c: Client,
    reused: bool,
    voice_id: String,
    total: usize,
    seq: u64,
    text: String,
    polished: String,
    partial: &'a Partial,
}

impl Upload<'_> {
    async fn send(&mut self, opus: Option<&[u8]>, seq: u64, is_end: bool) -> Result<()> {
        let pkt = VoicePacket { voice_id: &self.voice_id, opus, seq, total: self.total, is_end };
        let (text, polished) = match self.c.voice(&pkt).await {
            Ok(r) => r,
            Err(e) if !self.reused => return Err(e),
            Err(_) => {
                self.c = Client::open().await?;
                self.c.voice(&pkt).await?
            }
        };
        self.reused = false;
        if !text.is_empty() {
            (self.partial)(&text);
            self.text = text;
        }
        if !polished.is_empty() {
            self.polished = polished;
        }
        Ok(())
    }

    async fn upload(&mut self, batch: &[Vec<u8>], is_end: bool) -> Result<()> {
        self.seq += 1;
        let mut framed = Vec::new();
        if self.seq == 1 {
            framed.extend_from_slice(b"#!OPUS_RAW_V1");
            framed.extend_from_slice(&[2, 1, 0]);
        }
        for p in batch {
            framed.extend_from_slice(&[(p.len() & 0xff) as u8, (p.len() >> 8) as u8]);
            framed.extend_from_slice(p);
        }
        self.total += framed.len();
        self.send(Some(&framed), self.seq, is_end).await
    }
}

#[async_trait::async_trait]
impl Engine for WeTypeEngine {
    async fn prewarm(&self) {
        let mut slot = self.client.lock().await;
        if slot.as_ref().map_or(true, |c| c.dead) {
            *slot = Client::open().await.ok();
        }
    }

    async fn run(&self, mut audio: Audio, partial: Partial) -> Result<String> {
        let (c, reused) = self.take().await?;
        let mut up = Upload {
            c, reused,
            voice_id: uuid::Uuid::new_v4().simple().to_string(),
            total: 0, seq: 0, text: String::new(), polished: String::new(),
            partial: &partial,
        };
        let mut enc = opus::Opus::new(opus::AUDIO, 64000, 9)?;
        let mut packets: Vec<Vec<u8>> = Vec::new();
        while let Some(frame) = audio.recv().await {
            packets.push(enc.encode(&frame)?);
            if packets.len() >= PACKETS_PER_REQUEST {
                up.upload(&packets, false).await?;
                packets.clear();
            }
        }
        up.upload(&packets, true).await?;
        // 松手后以空包轮询整理过的定稿，实测首轮即返回
        for _ in 0..8 {
            if !up.polished.is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
            up.send(None, 0, true).await?;
        }
        let text = if up.polished.is_empty() { std::mem::take(&mut up.text) } else { std::mem::take(&mut up.polished) };
        *self.client.lock().await = Some(up.c);
        Ok(text)
    }
}

struct VoicePacket<'a> {
    voice_id: &'a str,
    opus: Option<&'a [u8]>,
    seq: u64,
    total: usize,
    is_end: bool,
}

#[derive(Serialize, Deserialize)]
struct Identity {
    device: String,
    uin: String,
}

struct Reply {
    status: u64,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

struct Client {
    ws: Ws,
    dead: bool,
    task: u64,
    uin: String,
    device: String,
    session_key: Option<Vec<u8>>,
    server_public: String,
    uin_token: String,
}

impl Client {
    async fn open() -> Result<Self> {
        let ws = ws::connect(&format!("wss://{HOST}/"), &[("Sec-WebSocket-Protocol", "wxws_pb")]).await?;
        let mut c = Client {
            ws, dead: false, task: 0, uin: "0".into(), device: String::new(),
            session_key: None, server_public: String::new(), uin_token: String::new(),
        };
        c.handshake().await?;
        Ok(c)
    }

    async fn handshake(&mut self) -> Result<()> {
        self.roundtrip("/timestamp", vec![], 0, "1", "").await?;
        let file = data_file("wetype.json");
        let saved: Option<Identity> = std::fs::read(&file).ok().and_then(|b| serde_json::from_slice(&b).ok());
        if let Some(s) = &saved {
            self.device = s.device.clone();
            self.uin = s.uin.clone();
            if self.exchange_key(false).await.is_err() {
                self.register().await?;
            }
        } else {
            self.register().await?;
        }
        if saved.as_ref().map_or(true, |s| s.device != self.device || s.uin != self.uin) {
            let id = Identity { device: self.device.clone(), uin: self.uin.clone() };
            let _ = std::fs::write(&file, serde_json::to_vec(&id)?);
        }
        let body = aes_enc(self.key()?, &[]);
        self.roundtrip("/api_v2", body, CMD_NOTIFY, "1", "").await?;
        Ok(())
    }

    fn key(&self) -> Result<&[u8]> {
        self.session_key.as_deref().ok_or_else(|| anyhow!("微信会话密钥缺失"))
    }

    async fn exchange_key(&mut self, need_uin: bool) -> Result<()> {
        let (k, pub_hex) = secp128r1::keypair();
        let mut req = PBuf::new().s(1, &pub_hex).s(2, &pub_hex);
        if need_uin {
            req = req.v(3, 1);
        }
        req = req.s(4, &self.device);
        if !need_uin {
            req = req.v(5, self.uin.parse().unwrap_or(0));
        }
        req = req.s(7, "").s(8, DEVICE_MODEL).s(9, "");
        let body = self.request("/oauth_pubkey_v2", aes_enc(BOOT_KEY, &req.0), CMD_DH, "").await?;
        let f = pb::parse(&aes_dec(BOOT_KEY, &body)?)?;
        let server = f.string(2).ok_or_else(|| anyhow!("微信密钥交换不完整"))?;
        let token = f.string(4);
        if need_uin && token.is_none() {
            bail!("微信密钥交换不完整");
        }
        self.session_key = Some(secp128r1::shared_x(k, &server)?.into_bytes());
        self.server_public = server;
        self.uin_token = token.unwrap_or_default();
        Ok(())
    }

    async fn register(&mut self) -> Result<()> {
        self.uin = "0".into();
        let body = format!("MAC{}{}{}", "0".repeat(17 - DEVICE_MODEL.len()), DEVICE_MODEL, rand_lower(12));
        self.device = format!("{body}{}", md5_upper(format!("{body}{SIGN_KEY}").as_bytes()));
        self.exchange_key(true).await?;
        let req = PBuf::new().s(1, &self.device).s(2, &self.server_public).s(4, &self.uin_token);
        let token = self.uin_token.clone();
        let r = self.request("/gen_uin_v2", aes_enc(self.key()?, &req.0), CMD_UIN, &token).await?;
        let issued = pb::parse(&aes_dec(self.key()?, &r)?)?.varint(2).filter(|&n| n != 0);
        self.uin = issued.ok_or_else(|| anyhow!("微信未签发 UIN"))?.to_string();
        Ok(())
    }

    async fn voice(&mut self, p: &VoicePacket<'_>) -> Result<(String, String)> {
        let mut inner = PBuf::new().s(2, p.voice_id);
        if let Some(o) = p.opus.filter(|o| !o.is_empty()) {
            inner = inner.b(4, o);
        }
        inner = inner.v(5, 5);
        if p.is_end {
            inner = inner.v(6, 1);
        }
        inner = inner.v(7, p.seq);
        if p.total > 0 {
            inner = inner.v(11, p.total as u64);
        }
        inner = inner.v(22, 1).v(23, 1).v(24, 1);
        let outer = PBuf::new().m(1, inner);
        let body = aes_enc(self.key()?, &snappy::compress(&outer.0));
        let r = self.roundtrip("/api_v2", body, CMD_VOICE, "2", "").await?;
        if r.status != 200 || r.body.is_empty() {
            bail!("微信语音请求失败 {}", r.status);
        }
        let mut plain = aes_dec(self.key()?, &r.body)?;
        if r.headers.get("Kb-CompressionType").or(r.headers.get("CompressionType")).map(String::as_str) == Some("2") {
            plain = snappy::decompress(&plain)?;
        }
        let top = pb::parse(&plain)?;
        let f = pb::parse(top.bytes(1).unwrap_or(&plain))?;
        Ok((f.string(4).unwrap_or_default(), f.string(14).unwrap_or_default()))
    }

    async fn request(&mut self, path: &str, body: Vec<u8>, cmd: u64, token: &str) -> Result<Vec<u8>> {
        let r = self.roundtrip(path, body, cmd, "1", token).await?;
        if r.status != 200 || r.body.is_empty() {
            bail!("微信 {path} 状态 {}", r.status);
        }
        Ok(r.body)
    }

    async fn roundtrip(&mut self, path: &str, body: Vec<u8>, cmd: u64, compress: &str, token: &str) -> Result<Reply> {
        let r = self.roundtrip_inner(path, body, cmd, compress, token).await;
        if r.is_err() {
            self.dead = true;
        }
        r
    }

    /// 一条 WSS 上严格一问一答
    async fn roundtrip_inner(&mut self, path: &str, body: Vec<u8>, cmd: u64, compress: &str, token: &str) -> Result<Reply> {
        let (dh, gen_uin) = (cmd == CMD_DH, cmd == CMD_UIN);
        if !(dh || gen_uin) {
            self.task += 1;
        }
        let task_id = if dh || gen_uin { cmd } else { self.task };
        let trace = rand_lower(16);
        let md5 = md5_upper(&body);
        let ts = now_ms().to_string();
        let signed: Vec<String> = if dh {
            vec![OS_TYPE.into(), VERSION.into(), PLATFORM.into(), ts.clone(), md5.clone(), trace.clone(), cmd.to_string()]
        } else if gen_uin {
            vec![OS_TYPE.into(), VERSION.into(), PLATFORM.into(), ts.clone(), md5.clone(), token.into(), trace.clone(), cmd.to_string()]
        } else {
            vec![OS_TYPE.into(), VERSION.into(), PLATFORM.into(), cmd.to_string(), "0".into(), ts.clone(), md5.clone(),
                 self.uin.clone(), trace.clone(), task_id.to_string()]
        };
        let sign = hex::encode_upper(Sha256::digest(format!("{}{SIGN_KEY}", signed.concat())));

        let mut headers: Vec<(String, String)> = Vec::new();
        if !token.is_empty() {
            headers.push(("Kb-GenUinToken".into(), token.into()));
        }
        headers.push(("Kb-Uin".into(), self.uin.clone()));
        if dh || gen_uin {
            headers.push(("Kb-DeviceCodeRestrictionV2".into(), "1".into()));
        }
        if !dh {
            if let Some(k) = &self.session_key {
                headers.push(("Kb-SharedKeySuffix".into(), String::from_utf8_lossy(&k[k.len() - 4..]).into()));
            }
            headers.push(("Kb-CmdId".into(), cmd.to_string()));
            headers.push(("Kb-SubCmdId".into(), "0".into()));
        }
        for (k, v) in [
            ("Kb-OsType", OS_TYPE), ("Kb-Version", VERSION), ("Kb-SystemVersion", "27.0.0"),
            ("Kb-PackageType", "3"), ("Use_DebugNet", "0"), ("Kb-TimeStamp", &ts), ("Kb-BodyMd5", &md5),
            ("Kb-TraceId", &trace), ("Kb-TaskId", &task_id.to_string()), ("Kb-Scene", "2"),
            ("Kb-Sign", &sign), ("Content-Length", &body.len().to_string()),
            ("Kb-CompressionType", compress), ("Content-Type", "application/octet-stream"), ("HOST", HOST),
        ] {
            headers.push((k.into(), v.into()));
        }
        let mut http = PBuf::new().s(1, "POST").s(3, path).s(4, "");
        for (k, v) in &headers {
            http = http.kv(5, k, v);
        }
        http = http.b(6, &body);
        let frame = PBuf::new().v(1, 0).v(2, 0).v(3, task_id).m(5, http);
        self.ws.send(Message::Binary(frame.0.into())).await?;

        let raw = ws::recv(&mut self.ws, Duration::from_secs(15)).await?;
        let fields = match pb::parse(&raw)?.bytes(4) {
            Some(b) => pb::parse(b)?,
            None => pb::Fields(vec![]),
        };
        let mut out = HashMap::new();
        for (f, v) in &fields.0 {
            let pb::Val::Bytes(d) = v else { continue };
            if *f == 5 {
                continue;
            }
            let Ok(kv) = pb::parse(d) else { continue };
            if let (Some((_, pb::Val::Bytes(k))), Some((_, pb::Val::Bytes(v)))) = (kv.0.first(), kv.0.get(1)) {
                out.insert(String::from_utf8_lossy(k).into_owned(), String::from_utf8_lossy(v).into_owned());
            }
        }
        Ok(Reply { status: fields.varint(2).unwrap_or(0), headers: out, body: fields.bytes(5).unwrap_or_default().to_vec() })
    }
}

fn md5_upper(d: &[u8]) -> String {
    hex::encode_upper(Md5::digest(d))
}

fn aes_enc(key: &[u8], data: &[u8]) -> Vec<u8> {
    ecb::Encryptor::<aes::Aes256>::new(key.into()).encrypt_padded_vec_mut::<Pkcs7>(data)
}

fn aes_dec(key: &[u8], data: &[u8]) -> Result<Vec<u8>> {
    ecb::Decryptor::<aes::Aes256>::new(key.into())
        .decrypt_padded_vec_mut::<Pkcs7>(data)
        .map_err(|_| anyhow!("AES 解密失败"))
}

mod snappy {
    use crate::pb::{read_varint, uvarint};
    use anyhow::{bail, Result};

    /// 上行只发字面量块
    pub fn compress(data: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        uvarint(&mut out, data.len() as u64);
        for chunk in data.chunks(60) {
            out.push(((chunk.len() - 1) << 2) as u8);
            out.extend_from_slice(chunk);
        }
        out
    }

    pub fn decompress(buf: &[u8]) -> Result<Vec<u8>> {
        let mut i = 0;
        let length = read_varint(buf, &mut i)? as usize;
        let mut out: Vec<u8> = Vec::with_capacity(length);
        let byte = |i: &mut usize| -> Result<usize> {
            if *i >= buf.len() {
                bail!("snappy 截断");
            }
            *i += 1;
            Ok(buf[*i - 1] as usize)
        };
        let copy = |out: &mut Vec<u8>, off: usize, n: usize| -> Result<()> {
            if off == 0 || off > out.len() || out.len() + n > length {
                bail!("snappy 复制越界");
            }
            for _ in 0..n {
                out.push(out[out.len() - off]);
            }
            Ok(())
        };
        while i < buf.len() {
            let tag = byte(&mut i)?;
            match tag & 3 {
                0 => {
                    let mut n = tag >> 2;
                    if n >= 60 {
                        let width = n - 59;
                        n = 0;
                        for k in 0..width {
                            n |= byte(&mut i)? << (8 * k);
                        }
                    }
                    n += 1;
                    if i + n > buf.len() || out.len() + n > length {
                        bail!("snappy 字面量越界");
                    }
                    out.extend_from_slice(&buf[i..i + n]);
                    i += n;
                }
                1 => {
                    let lo = byte(&mut i)?;
                    copy(&mut out, ((tag >> 5) << 8) | lo, ((tag >> 2) & 7) + 4)?;
                }
                2 => {
                    let off = byte(&mut i)? | (byte(&mut i)? << 8);
                    copy(&mut out, off, (tag >> 2) + 1)?;
                }
                _ => {
                    let mut off = 0;
                    for k in 0..4 {
                        off |= byte(&mut i)? << (8 * k);
                    }
                    copy(&mut out, off, (tag >> 2) + 1)?;
                }
            }
        }
        if out.len() != length {
            bail!("snappy 长度不符");
        }
        Ok(out)
    }
}

/// secp128r1（常见密码库不带此曲线，手写）
mod secp128r1 {
    use anyhow::{anyhow, Result};
    use rand::Rng;

    type Point = Option<(u128, u128)>;

    const P: u128 = 0xFFFF_FFFD_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
    const A: u128 = 0xFFFF_FFFD_FFFF_FFFF_FFFF_FFFF_FFFF_FFFC;
    const N: u128 = 0xFFFF_FFFE_0000_0000_75A3_0D1B_9038_A115;
    const G: Point = Some((0x161F_F752_8B89_9B2D_0C28_607C_A52C_5B86, 0xCF5A_C839_5BAF_EB13_C02D_A292_DDED_7A83));

    fn mul_wide(a: u128, b: u128) -> (u128, u128) {
        let m = u64::MAX as u128;
        let (a1, a0, b1, b0) = (a >> 64, a & m, b >> 64, b & m);
        let (p00, p01, p10, p11) = (a0 * b0, a0 * b1, a1 * b0, a1 * b1);
        let mid = (p00 >> 64) + (p01 & m) + (p10 & m);
        let lo = (p00 & m) | (mid << 64);
        let hi = p11 + (p01 >> 64) + (p10 >> 64) + (mid >> 64);
        (hi, lo)
    }

    /// p = 2^128 - 2^97 - 1，故 2^128 ≡ 2^97 + 1
    fn mul(x: u128, y: u128) -> u128 {
        let (mut hi, mut lo) = mul_wide(x, y);
        let fold: u128 = (1 << 97) + 1;
        while hi != 0 {
            let (h2, l2) = mul_wide(hi, fold);
            let (s, carry) = lo.overflowing_add(l2);
            lo = s;
            hi = h2 + carry as u128;
        }
        while lo >= P {
            lo -= P;
        }
        lo
    }

    fn add(x: u128, y: u128) -> u128 {
        let (s, o) = x.overflowing_add(y);
        if o || s >= P { s.wrapping_sub(P) } else { s }
    }

    fn sub(x: u128, y: u128) -> u128 {
        if x >= y { x - y } else { x.wrapping_add(P.wrapping_sub(y)) }
    }

    fn inverse(x: u128) -> u128 {
        let (mut r, mut b, mut e) = (1u128, x % P, P - 2);
        while e > 0 {
            if e & 1 == 1 {
                r = mul(r, b);
            }
            b = mul(b, b);
            e >>= 1;
        }
        r
    }

    fn add_points(p1: Point, p2: Point) -> Point {
        let Some((x1, y1)) = p1 else { return p2 };
        let Some((x2, y2)) = p2 else { return p1 };
        if x1 == x2 && add(y1, y2) == 0 {
            return None;
        }
        let slope = if x1 == x2 && y1 == y2 {
            mul(add(mul(3, mul(x1, x1)), A), inverse(mul(2, y1)))
        } else {
            mul(sub(y2, y1), inverse(sub(x2, x1)))
        };
        let x3 = sub(sub(mul(slope, slope), x1), x2);
        Some((x3, sub(mul(slope, sub(x1, x3)), y1)))
    }

    fn multiply(mut k: u128, point: Point) -> Point {
        let (mut r, mut addend) = (None, point);
        while k > 0 {
            if k & 1 == 1 {
                r = add_points(r, addend);
            }
            addend = add_points(addend, addend);
            k >>= 1;
        }
        r
    }

    fn hex(v: u128) -> String {
        format!("{v:032X}")
    }

    pub fn keypair() -> (u128, String) {
        loop {
            let k = rand::thread_rng().gen_range(1..N);
            if let Some((x, y)) = multiply(k, G) {
                return (k, format!("04{}{}", hex(x), hex(y)));
            }
        }
    }

    /// 共享点 x 坐标的大写 hex（32 字符，直接作 AES-256 密钥）
    pub fn shared_x(k: u128, public: &str) -> Result<String> {
        let bad = || anyhow!("微信服务端公钥无效");
        if public.len() != 66 || !public.starts_with("04") {
            return Err(bad());
        }
        let x = u128::from_str_radix(&public[2..34], 16).map_err(|_| bad())?;
        let y = u128::from_str_radix(&public[34..], 16).map_err(|_| bad())?;
        let (sx, _) = multiply(k, Some((x, y))).ok_or_else(bad)?;
        Ok(hex(sx))
    }
}
