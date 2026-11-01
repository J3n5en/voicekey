<p align="center"><img src="docs/icon.png" width="128" alt="VoiceKey"></p>

<h1 align="center">VoiceKey</h1>

<p align="center">macOS、Windows、iOS、Android 语音输入。桌面端按住或点按快捷键说话；iOS 是带语音的中文键盘；Android 不替换输入法，识别结果写进当前输入框。</p>

<p align="center">
  <img src="docs/screenshots/pick-live.png" width="420" alt="候选框：说话时各渠道实时出字">
  <img src="docs/screenshots/pick-done.png" width="420" alt="候选框：定稿后选一条上屏">
</p>
<p align="center"><sub>多渠道候选框：说话时各渠道实时出字（左），松开后逐条定稿并显示耗时，数字键或回车选一条上屏（右）</sub></p>

## 功能

以下为 macOS / Windows。

- **多个识别渠道**：豆包、微信、千问、百度、搜狗、讯飞、Chatterfly 云端识别，以及完全本地运行的离线识别：微信离线（macOS / Windows）、豆包离线（仅 Apple 芯片 Mac）
- **多渠道候选**：勾选 2 个以上渠道同时识别，光标旁弹出候选框实时显示各渠道结果，按数字键或 ↑↓ + 回车选一条上屏；默认选中上次用的渠道
- **渠道对比**：在设置里录一段话，并排比较各渠道的结果和速度
- **长按说话**：按住快捷键开始，松开结束
- **点按说话**：自定义快捷键，点一下开始，停顿 1–5 秒自动结束，再点一下可提前结束
- **边说边上屏**：识别中的文字实时打到光标处，结束后按定稿修正；关闭后改为结束时一次性粘贴
- **麦克风选择**、开机启动、浅色 / 深色主题、应用内自动更新

## 截图

| 识别渠道 | 渠道对比 |
|---|---|
| <img src="docs/screenshots/settings.png" alt="识别渠道设置"> | <img src="docs/screenshots/compare.png" alt="渠道对比"> |

单渠道模式下，屏幕底部显示声波浮层和实时文字：

<p align="center"><img src="docs/screenshots/hud.png" width="420" alt="声波浮层"></p>

## iOS

iOS 17+ 的中文键盘（仅 iPhone）。默认 26 键全拼，可切九宫格；功能键和顶栏可以拖动调整。左上角麦克风说话。键盘本身不能录音，由主 App 在后台收音，再把文字送回键盘。

- 云端渠道与桌面端相同，没有离线引擎
- 勾选多个渠道时，在键盘里对比结果再选一条上屏
- 默认画中画待机：不占麦克风，点麦克风才录音；画中画不可用时改为常开麦
- 操作按钮或快捷指令「VoiceKey 说话」：正在使用本键盘时开始，再按一次结束
- 点按说话的静音自动结束可在 1–5 秒间设置
- 拼音词库来自[雾凇拼音](https://github.com/iDvel/rime-ice)（GPL-3.0），并补了搜狗流行词和部分 AI 词

语音和与主 App 通信需要「允许完全访问」；不开也能本地打字。安装或更新后，已在跑的键盘进程不会换成新版本，需到「设置 › 通用 › 键盘 › 键盘 › VoiceKey」删除后再添加。

## Android

Android 8+（arm64）。不替换当前输入法：开启无障碍服务「VoiceKey 语音输入」后，在任意输入框长按音量下键，或点悬浮球说话，结果写入光标处。部分应用会隐藏控件树，Android 13 及以上改为经输入连接提交文字。

- 渠道：豆包、微信、千问、百度、搜狗、讯飞，以及微信离线（约 100MB，本机推理）
- 多渠道候选、边说边上屏、点按静音 1–5 秒自动结束
- 长按音量下键只在输入框聚焦时生效，短按仍调音量

国内系统清理后台会关掉无障碍。应用内有忽略电池优化、自启动和锁定最近任务的引导。

## 安装

从 [Releases](https://github.com/J3n5en/voicekey/releases) 下载桌面端安装包和 Android APK。iOS 不在 Release 里，需从源码构建。

| 系统 | 文件 |
|---|---|
| macOS 13+（Apple 芯片与 Intel 通用） | `VoiceKey-x.y.z.dmg`，打开后拖到「应用程序」 |
| Windows 10/11 x64 | `VoiceKey-x.y.z-x64-setup.exe` 或 `.msi` |
| Android 8+（arm64） | `VoiceKey-x.y.z-android.apk`，首次安装需允许浏览器或文件管理器安装未知应用 |

Android 装好后，在应用「关于与更新」里检查并更新：首次更新要允许 VoiceKey 安装未知应用，下载校验完成后在系统弹窗里确认安装。

macOS 发布包为自签名、未经 Apple 公证，首次运行前需解除隔离：

```bash
xattr -dr com.apple.quarantine /Applications/VoiceKey.app
```

之后的版本可在应用内更新（设置 → 通用，或菜单栏），无需重复上述步骤，已授予的权限也会保留。

旧版原生 Swift 实现（仅 macOS 15+）保留在 [`legacy`](https://github.com/J3n5en/voicekey/tree/legacy) 分支。

## 使用

1. 首次启动会打开引导：授予 **辅助功能**（仅 macOS，用于监听快捷键和上屏）和 **麦克风** 权限，并试说一句
2. 之后常驻菜单栏 / 系统托盘，可在托盘菜单切换渠道、暂停监听、打开设置
3. 在任意输入框中说话

| 设置项 | macOS 默认 | Windows 默认 |
|---|---|---|
| 识别渠道 | 豆包输入法 | 豆包输入法 |
| 长按快捷键 | 右 ⌥ | 右 Alt |
| 点按快捷键 | 右 ⌘ | 右 Ctrl |
| 静音自动结束 | 1.5 秒 | 1.5 秒 |
| 边说边上屏 | 开 | 开 |

单个修饰键可同时作为长按键和点按键：快速点一下为点按，按住超过 0.3 秒为长按。设为组合键的点按快捷键会被拦截，不再传给前台应用。

**离线识别**：首次选择离线渠道时下载模型，之后断网也能用。

- **微信离线**：下载微信输入法官方离线语音包（约 100MB，来自腾讯 CDN），解出模型保存在数据目录的 `wtoffline/` 下；由本项目自己实现的 int8 推理运行，不依赖官方程序，macOS 和 Windows 都可用。
- **豆包离线**（仅 Apple 芯片 Mac）：下载引擎库（约 8MB，来自本仓库 [offline-libs](https://github.com/J3n5en/voicekey/releases/tag/offline-libs) Release）和模型（约 177MB，来自字节 CDN），保存在 `~/Library/Application Support/VoiceKey/offline/`；只在用到时启动后台进程，空闲 5 分钟后自动释放。

## 从源码构建

需要 Rust（stable）、Node 22+ 和 CMake；Windows 另需 MSVC 生成工具。

```bash
cd app
npm ci
npx tauri dev                    # 开发运行
npx tauri build --bundles app    # macOS：target/release/bundle/macos/VoiceKey.app
npx tauri build                  # Windows：nsis / msi 安装包
```

- iOS（需要 Xcode 与 XcodeGen）：`ios/build.sh`，产物 `ios/build/VoiceKey.ipa`；`ios/build.sh --unsigned` 出未签名包
- Android（需要 Android NDK 与 cargo-ndk）：先 `android/build-rust.sh`，再在 `android/` 执行 `./gradlew :app:assembleRelease`
- Opus 由 `audiopus_sys` 从源码静态编译，相关环境变量见 `.cargo/config.toml`
- 打包 DMG：`Scripts/dmg.sh out.dmg path/to/VoiceKey.app app/src-tauri/icons/icon.icns`
- 命令行测试识别：`cargo run -p voicekey-core --bin vk-test -- doubao|wetype|qwen|baidu|sogou|iflytek file.wav`（WAV 需 16kHz 单声道）

## 发布

推送 `v*` 标签后，GitHub Actions 构建 macOS 通用 DMG、Windows 安装包和 Android 签名 APK，连同应用内更新所需的更新包、`latest.json`（桌面）与 `android.json`（Android）一起创建 Release：

```bash
git tag v1.0.1 && git push origin v1.0.1
```

需要的 Secrets：`TAURI_SIGNING_PRIVATE_KEY` / `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`（`npx tauri signer generate` 生成的更新签名密钥）、`MACOS_CERTIFICATE` / `MACOS_CERTIFICATE_PASSWORD`（`Scripts/gen-cert.sh` 生成的自签名证书，base64 编码的 p12）。

Android 另需 4 个 Secrets：`ANDROID_KEYSTORE_BASE64`（release keystore 用 `base64` 编码）、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。tag 构建缺任何一个都会失败，不会发出 debug 签名包。签名一旦定下就不能换，换了已装用户无法覆盖升级，只能卸载重装。

Android 的 versionCode 由标签推导：`vX.Y.Z` → `X×10000 + Y×100 + Z`（如 `v1.8.0` 为 10800），所以标签必须是 `vX.Y.Z` 形式，且 minor、patch 都不能超过 99，推出的值要大于现有的 6。应用内更新靠 versionCode 比较，新版必须比已装版本大。

## 结构

| 路径 | 内容 |
|---|---|
| `crates/core` | 识别引擎：豆包（protobuf + WebSocket）、微信（secp128r1 ECDH、AES-256-ECB、snappy）、千问（HMAC-SHA1、AES-128-CBC）；音频采集与重采样、Opus 编码 |
| `crates/platform` | 平台层：全局快捷键（CGEventTap / WH_KEYBOARD_LL）、上屏、光标位置、权限 |
| `crates/hanbao` | 离线引擎：编译 `Sources/CHanbao`，在 macOS 进程内加载安卓 ELF 引擎库 |
| `crates/wtlocal` | 微信离线引擎：解析官方 xnet 模型，FBank 特征、int8 矩阵乘（NEON / AVX2）、40 层 Transformer 推理与流式解码 |
| `app/src-tauri` | Tauri 应用：设置、快捷键状态机、会话调度、浮层窗口、托盘、离线资源下载 |
| `app/src` | Svelte 界面：设置、引导、声波浮层、候选框、渠道对比 |
| `design/` | 交互原型与渠道图标 |
| `ios/` | iOS 主 App 与键盘扩展。拼音输入、画中画待机，和键盘的协议见 `ios/PROTOCOL.md` |
| `android/` | Android 无障碍语音输入。`build-rust.sh` 把识别引擎编成 `libvoicekey.so` |

音频以 16kHz 单声道、20ms 一帧采集。识别设备身份在本机运行时生成，保存在 `~/Library/Application Support/VoiceKey/`（Windows 为 `%APPDATA%\VoiceKey\`）。

## 链接

- 安装包：[github.com/J3n5en/voicekey/releases](https://github.com/J3n5en/voicekey/releases/latest)
- 更新频道：[t.me/EnsoAI_news](https://t.me/EnsoAI_news)
- 讨论群组：[t.me/EnsoCode_Official](https://t.me/EnsoCode_Official)

## 友链

- [Linux.Do](https://linux.do/) — 与社区一起分享、讨论、关注开发进展。

## 声明

本项目通过分析输入法客户端协议实现，仅供学习与个人使用，与字节跳动、腾讯、阿里巴巴无关。接口可能随时变更或失效；语音会发送到对应厂商的服务器。
