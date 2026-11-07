//! 需要登录的渠道：手动粘贴，或在内置网页窗口登录后自动读取登录 Cookie，校验通过才保存
use crate::settings::Channel;
use std::collections::HashMap;
use std::time::{Duration, Instant};
use tauri::webview::Cookie;
use tauri::{AppHandle, Emitter, Manager, Url, WebviewUrl, WebviewWindowBuilder};
use voicekey_core::account::Login;

fn login(ch: Channel) -> Result<&'static Login, String> {
    ch.login().ok_or_else(|| "该渠道不需要登录".into())
}

/// 网页 Cookie 是否属于登录域或其子域（domain() 已去掉开头的点）
fn on_site(c: &Cookie, domain: &str) -> bool {
    c.domain().is_some_and(|d| d == domain || d.ends_with(&format!(".{domain}")))
}

/// 各登录渠道是否已登录，给设置页显示
pub fn status() -> HashMap<Channel, bool> {
    Channel::engines().into_iter().filter_map(|ch| Some((ch, ch.login()?.has()))).collect()
}

pub async fn save(app: &AppHandle, ch: Channel, input: &str) -> Result<(), String> {
    let login = login(ch)?;
    let cookie = login.pick(input).map_err(|e| e.to_string())?;
    (login.check)(&cookie).await.map_err(|e| e.to_string())?;
    login.set(&cookie).map_err(|e| format!("保存登录 Cookie 失败：{e}"))?;
    let _ = app.emit("accounts", status());
    Ok(())
}

/// 删除保存的登录 Cookie，并尽量清掉内置登录窗口留下的网页登录状态，下次登录从头开始。
/// 要在后台线程调用：Windows 上在主线程或同步命令里读写网页 Cookie 会死锁
pub fn logout(app: &AppHandle, ch: Channel) {
    let Some(login) = ch.login() else { return };
    let _ = login.set("");
    if let Some(w) = app.webview_windows().into_values().next() {
        for c in w.cookies().unwrap_or_default().into_iter().filter(|c| on_site(c, login.domain)) {
            let _ = w.delete_cookie(c);
        }
    }
    let _ = app.emit("accounts", status());
}

/// 打开官方登录页，每秒读一次登录域的 Cookie，校验通过即保存并关窗
pub fn open(app: &AppHandle, ch: Channel) -> Result<(), String> {
    let login = login(ch)?;
    let label = format!("login-{}", login.id);
    if let Some(w) = app.get_webview_window(&label) {
        let _ = w.set_focus();
        return Ok(());
    }
    let w = WebviewWindowBuilder::new(app, &label, WebviewUrl::External(Url::parse(login.page).map_err(|e| e.to_string())?))
        .title(format!("登录{}（完成后自动关闭）", ch.title()))
        .inner_size(480.0, 720.0)
        .center()
        .build()
        .map_err(|e| e.to_string())?;
    let _ = w.set_focus();
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut last = String::new();
        let mut tried = Instant::now();
        loop {
            tokio::time::sleep(Duration::from_secs(1)).await;
            // 窗口被关掉就停止
            let Some(w) = app.get_webview_window(&label) else { return };
            // 在后台线程读，理由同 logout。不用 cookies_for_url：macOS 上它只返回域名与主机名完全相同的 Cookie，
            // 漏掉写在 .qianwen.com 这类父域上的登录 Cookie
            let Ok(cookies) = w.cookies() else { continue };
            let header = cookies.iter().filter(|c| on_site(c, login.domain)).map(|c| format!("{}={}", c.name(), c.value())).collect::<Vec<_>>().join("; ");
            let Ok(picked) = login.pick(&header) else { continue };
            // 同一组登录 Cookie 校验失败（如断网）时每 5 秒重试一次
            if picked == last && tried.elapsed() < Duration::from_secs(5) {
                continue;
            }
            last = picked;
            tried = Instant::now();
            if save(&app, ch, &last).await.is_ok() {
                let _ = w.close();
                crate::ui::show_settings(&app);
                return;
            }
        }
    });
    Ok(())
}
