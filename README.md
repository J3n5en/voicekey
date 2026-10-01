<p align="center"><img src="docs/icon.png" width="128" alt="VoiceKey"></p>

<h1 align="center">VoiceKey</h1>

<p align="center">macOS 菜单栏语音输入：在任意输入框里按住或点按快捷键说话，识别结果直接打到光标处。</p>

## 功能

- **两个识别渠道**：豆包输入法、微信输入法云端识别，可在设置中切换
- **长按说话**：按住右 ⌥ / 右 ⌘ / 右 ⌃ / Fn 开始，松开结束
- **点按说话**：自定义快捷键（单个修饰键或任意组合键），点一下开始，停顿 1–5 秒自动结束，再点一下可提前结束
- **边说边上屏**：识别中的文字实时打到光标处，结束后按定稿修正；关闭后改为结束时一次性粘贴
- **麦克风选择**：可指定输入设备，设备断开时自动回落到系统默认
- **声波浮层**：屏幕底部显示随音量起伏的声波

## 安装

从 [Releases](https://github.com/J3n5en/voicekey/releases) 下载 `VoiceKey-x.y.z.zip` 并解压，拖到「应用程序」。

发布包为 ad-hoc 签名、未经 Apple 公证，首次运行前需解除隔离：

```bash
xattr -dr com.apple.quarantine /Applications/VoiceKey.app
```

要求 macOS 15+。通用包，Apple 芯片与 Intel 均可直接运行，无需安装任何依赖。

## 使用

1. 启动后出现在菜单栏（麦克风图标）。图标被刘海或菜单栏管理工具挡住时，再次打开 VoiceKey.app 即可弹出设置
2. 按提示授予 **辅助功能**（监听快捷键、上屏）和 **麦克风** 权限
3. 在设置中选择渠道、快捷键、麦克风，然后在任意输入框中说话

| 设置项 | 默认值 |
|---|---|
| 识别渠道 | 豆包输入法 |
| 长按快捷键 | 右 ⌥ |
| 点按快捷键 | 右 ⌘ |
| 静音自动结束 | 1.5 秒 |
| 边说边上屏 | 开 |

单个修饰键可同时作为长按键和点按键：快速点一下为点按，按住超过 0.3 秒为长按。设为组合键的点按快捷键会被 VoiceKey 拦截，不再传给前台应用。

## 从源码构建

```bash
./build.sh            # 产物在 build/VoiceKey.app（arm64 + x86_64 通用包）
```

- 只需 Xcode 命令行工具；Opus 由 `Scripts/opus.sh` 从官方源码编译为通用静态库，首次构建自动下载并校验
- 本地有 Apple Development 证书时自动用它签名，重建后系统权限不会丢失；可用 `SIGN_IDENTITY` 指定证书，`-` 为 ad-hoc
- `VERSION` / `BUILD` 环境变量设置版本号
- 调试识别链路：`build/VoiceKey.app/Contents/MacOS/VoiceKey --test doubao|wetype file.wav`

## 发布

推送 `v*` 标签后，GitHub Actions 自动构建并创建 Release：

```bash
git tag v0.2.0 && git push origin v0.2.0
```

## 实现

| 文件 | 内容 |
|---|---|
| `Doubao.swift` | 豆包：设备注册、WebSocket + protobuf 流式识别 |
| `WeType.swift` | 微信：secp128r1 ECDH、AES-256-ECB、snappy、protobuf 流式识别 |
| `Audio.swift` | AudioQueue 采集 16kHz 单声道、音量计算、设备枚举 |
| `System.swift` | 全局快捷键（CGEventTap）、上屏、HUD |
| `Core.swift` | Opus 编码、protobuf 编解码、WebSocket 封装 |
| `Scripts/icon.swift` | 生成 App 图标 |

音频以 20ms 一帧 Opus 编码后上传。识别设备身份在本机运行时生成，保存在 `~/Library/Application Support/VoiceKey/`。

## 声明

本项目通过分析输入法客户端协议实现，仅供学习与个人使用，与字节跳动、腾讯无关。接口可能随时变更或失效；语音会发送到对应厂商的服务器。
