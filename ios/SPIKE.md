# iOS 可行性验证（spike）记录

2026-10-07，iPhone 16 Pro Max（iOS 26）+ iPhone 13（iOS 17.3.1），Xcode 26.5，个人团队 69GW9UBCN2 自动签名。

## 构建

```bash
ios/build.sh [UDID]   # xcframework → xcodegen → archive → ios/build/VoiceKey.ipa，给 UDID 则安装
```

启动参数（`devicectl device process launch ... do.j3.voicekey.ios -- <args>`）：`-selftest` 内置 wav 跑全部渠道；`-arm` 开后台会话；`-mictest` 录 9 秒；`-bgtest` 每 60 秒录 9 秒；`-nobt` 不走蓝牙 HFP；`-lazymic` 待命只播静音、开始时再开麦。
日志：App Group `Library/Caches/log.txt`，`devicectl device copy from --domain-type appGroupDataContainer --domain-identifier group.do.j3.voicekey --source Library/Caches/log.txt`；iOS 17 设备 devicectl 不支持 App Group 容器，App 每 30 秒镜像一份到自己容器 `Library/Caches/log.txt`（`--domain-type appDataContainer --domain-identifier do.j3.voicekey.ios`）。

## 结构

- `VoiceKeyCore/`：本地 Swift 包。`rust/` 独立 crate（自带 `[workspace]`）path 依赖 `crates/core`，打成 `VoiceKeyCoreFFI.xcframework`（C 接口见 `include/voicekey_ffi.h`），Swift 层 `RecognitionSession` 封装；推任意采样率 f32，重采样复用 core 的 `Framer`。
- `App/`：SwiftUI 主 App，`AVAudioSession(.playAndRecord, mixWithOthers)` + `AVAudioEngine` 输入 tap 常开保活，开始/停止只控制是否送入识别。
- `Keyboard/`：键盘扩展，不链接 Rust。Darwin 通知 ping/pong/start/stop/text 做信号，文字经 App Group `msg.json` 传递；按与上次文本的公共前缀回删重打。
- 无会话（ping 0.5s 无 pong）时沿响应链找宿主 `UIApplication` 调 `openURL:options:completionHandler:` 打开 `voicekey://arm`。

## 结果

| 项 | 结果 |
|---|---|
| core 交叉编译 aarch64-apple-ios | 零改动通过（cpal、audiopus_sys static、rustls、reqwest 均可） |
| 渠道（内置 wav，实时速度） | 千问、微信、讯飞、百度、豆包 OK，首字 0.6–1.3s；搜狗返回空（桌面端同样截断/空，渠道本身不稳，非 iOS 问题） |
| 豆包设备注册 | 测试机上 `log-klink.zijieapi.com` TLS 握手 EOF（疑似手机 Surge 规则拦截；Mac 直连 200）。拷入已有 did 后 WSS 识别正常 |
| 键盘内存 | phys_footprint 5.2MB 加载，峰值 9.1MB（不含 Rust） |
| 主 App 内存 | 后台待命 19–20MB（iPhone 13 为 16.6MB），前台 28MB |
| 后台识别 | App 在后台（state=2）收键盘 start，流式识别、定稿均正常 |
| 后台保活 | 麦克风常开时 backgroundTimeRemaining=∞；16 Pro Max `-bgtest` 8 分钟每分钟识别一次无中断；iPhone 13 后台待命 24 分钟以上仍存活、内存平稳。未测：通宵、来电/Siri/其他录音 App 打断 |
| 国行无线数据授权 | iPhone 13 首次启动在「允许使用无线数据」前所有请求 DNS 失败，需在主 App 首启引导时先触发联网 |
| 待命不开麦（-lazymic） | 后台起录音失败 `kAUStartIO` 2003329396，**必须常开麦克风保活**（橙点常亮） |
| 跳主 App | iOS 26 上响应链 openURL 可用，冷启动约 0.4s 内 armed |
| 回原 App | 私有 `_hostBundleID` 等在 iOS 26 均取不到（nil），无法自动返回；系统左上角有「◀ 宿主」返回按钮，需引导用户点 |
| 被杀恢复 | 键盘 ping 无响应 → 自动跳主 App 冷启动重新开会话，用户点返回后再点说话即可 |
| 权限流程 | 设置→通用→键盘→添加 VoiceKey→允许完全访问（没有完全访问拿不到 App Group）；麦克风权限只在主 App 首次开会话时弹 |
| 蓝牙 | 带 `.allowBluetoothHFP` 时连着耳机会走 HFP（16kHz），待命期间耳机音质会降为通话音质 |
