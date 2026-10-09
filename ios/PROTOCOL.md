# 主 App ⇄ 键盘协议 v2

v2 相对 v1：新增待机方式（`config.standby`、`session.standby`）、结束原因 `pipClosed` / `bgDenied`、开始失败 `bgDenied`、`start.tapAt`。新增字段都可缺省，缺省按 v1 行为（会话按常开麦、配置按画中画）。

键盘不能录音，录音和识别都在主 App；双方只靠 App Group `group.do.j3.voicekey` 通信。键盘必须开「允许完全访问」才能读写 App Group。类型定义在 `Shared/Protocol.swift`，键盘直接复用，不要另抄一份。

## 传输

- 内容：App Group 下 `Library/Application Support/VoiceKey/*.json`，整文件原子写（`Bus.write`）。
- 信号：Darwin 通知（`Bus.post` / `Bus.observe`），不带内容，收到后去读文件。通知会合并，只当「有变化」用，不要数次数。
- 时间统一用 Unix 秒（Double）。

| 通知 | 谁发 | 含义 |
|---|---|---|
| `do.j3.voicekey.cmd` | 键盘 | `cmd.json` 有新命令 |
| `do.j3.voicekey.ping` | 键盘 | 问主 App 是否活着；主 App 收到后处理积压命令并重发 state |
| `do.j3.voicekey.state` | 主 App | `state.json` 已更新 |
| `do.j3.voicekey.config` | 双方 | `config.json` 已更新 |
| `do.j3.voicekey.keyboard` | 键盘 | `keyboard.json` 已更新 |
| `do.j3.voicekey.hotkey` | 主 App | 操作按钮 / 快捷指令「VoiceKey 说话」：正在显示且有完全访问的键盘开始或结束说话（同点麦克风）；忽略过期、未来及重复请求 |
| `do.j3.voicekey.hotkey.ack` | 键盘 | 已响应 hotkey；主 App 0.8 秒内没收到同一请求的 ack 就提示「没有在用 VoiceKey 键盘」 |

| 文件 | 写入方 | 内容 |
|---|---|---|
| `config.json` | 双方 | `Config`：渠道列表（id / 显示名 / 开关）、多渠道开关、单渠道默认、闲置分钟、上次选中、待机方式 `standby`（`pip` 画中画 / `mic` 常开麦；缺省 = `pip`，旧用户升级后也是画中画） |
| `state.json` | 主 App | `LiveState`：会话 + 当前这句话 |
| `cmd.json` | 键盘 | `CommandQueue`：最近 32 条命令 |
| `history.json` | 双方 | 最近上屏 20 条；键盘删除键上滑清空输入框时也写入（渠道记为「已清空」），主 App 写前先重读 |
| `hotkey.json` | 主 App | `HotkeyRequest`：唯一 `id` 和时刻 `at`（秒），有效期 2 秒 |
| `hotkey-ack.json` | 键盘 | 已响应的 hotkey 请求 ID；处理前写入以去重 |
| `keyboard.json` | 键盘 | `KeyboardInfo`，键盘每次出现时写；主 App 据此显示「完全访问已开」 |
| `typing.json` | 双方 | `TypingPrefs`：中文键盘用九宫格还是 26 键（键盘里切布局即改默认）；`haptics` 按键震动；`metrics` 键盘底部显示按键耗时。未开完全访问时键盘读写自己的副本 |

## 会话是否可用

键盘点麦克风前：

1. 记下 `t = now`，发 `ping`。
2. 0.5 秒内收到 `state` 且 `updatedAt >= t`：主 App 活着。
   - `session.micReady == true`（`active` 且不是「画中画待机被打断」）：直接发 `start`。
   - 否则拉起主 App。
3. 超时没回：主 App 没在跑（被杀、被系统回收或从没开过）。`state.json` 里残留的 `active: true` 不可信，拉起主 App。

键盘空闲时每 5 秒发一次 `ping` 探活，主 App 被杀后麦克风及时变空心。麦克风实心 = 主 App 活着且 `micReady`，否则空心（点了拉起主 App）。

拉起主 App：沿响应链找宿主 `UIApplication` 调 `openURL:options:completionHandler:`，URL 为 `voicekey://session?source=keyboard`（`VK.sessionURL`）。主 App 开好会话后提示用户点系统左上角「◀ 原 App」返回。**回来后不自动开始说**，要用户再点一次麦克风。

`launch` 每次主 App 进程启动都会变；键盘发现它变了，说明主 App 重启过，手上的句子作废。

## 命令（键盘 → 主 App）

用 `CommandQueue.send(op, …)` 发，它负责分配 `seq`（取 `cmd.json` 最大 seq 与 `state.ackSeq` 中较大者 + 1）、追加、截留 32 条、发通知，返回 seq。主 App 按 seq 升序处理所有大于 `ackSeq` 的命令，处理完把 `ackSeq` 写进 state。超过 30 秒的命令直接跳过；主 App 冷启动时把已有命令全部视为已处理。

| op | 参数 | 作用 |
|---|---|---|
| `start` | `channels?`、`silenceStop?`、`tapAt?` | 开一句新话；会先丢掉上一句。`channels` 省略按配置（多渠道或单渠道默认）。`silenceStop` 秒，说过话后安静这么久自动结束，省略或 0 不自动。`tapAt` 用户点麦克风的时刻，只用于日志里统计开录延迟 |
| `stop` | `utt` | 结束说话，进入定稿 |
| `continue` | `utt` | 接着说：定稿中或已完成时再录一段，拼在同一句后面（各渠道各拼各的） |
| `retry` | `utt` | 已完成且有失败渠道时，用保留的录音重新识别失败的段；`retryable == false`（录音超 3 分钟）时无效 |
| `close` | `utt` | 丢掉这句（✕、键盘收起、单渠道上屏后都可发） |
| `commit` | `utt`、`channel` | 用户选了某渠道上屏：记入最近上屏、记为下次默认选中，并关闭这句 |
| `touch` | — | 只续期闲置计时 |
| `endSession` | — | 结束会话、关麦 |

`utt` 与当前句子 id 不符的命令被忽略。除 `ping` 外，每条命令都会续期闲置计时。

## 状态（主 App → 键盘）

```jsonc
{
  "v": 2,
  "launch": "UUID",            // 主 App 进程标识
  "updatedAt": 1791400000.12,
  "ackSeq": 12,
  "session": {
    "active": true,
    "since": 1791399000,
    "expiresAt": null,         // 常开麦无操作到此时刻自动结束；画中画始终 null
    "idleMinutes": 10,
    "interrupted": false,      // 来电 / Siri / 其他录音 App 占着麦克风
    "endReason": null,         // 未开启时：user | idle | interrupted | micDenied | failed | pipClosed | bgDenied
    "endedAt": null,
    "standby": "pip"           // 本次会话实际待机方式 pip | mic；缺省（v1 主 App）按 mic
  },
  "utterance": {               // 没有句子时为 null
    "id": 7,
    "startSeq": 12,            // 发起它的 start 命令 seq，键盘用它认领
    "phase": "recording",      // recording | finalizing | done | failed
    "stopReason": null,        // user | silence | interrupted
    "silenceStop": 1.5,
    "level": 0.42,             // 输入音量 0…1，聆听中约 10Hz 刷新
    "error": null,             // phase = failed：noSession | micBusy | noChannel | bgDenied
    "retryable": true,
    "rows": [
      { "channel": "a", "name": "微信", "text": "到目前为止的整句", "state": "listening",
        "error": null, "ms": null }
    ]
  }
}
```

- `rows[].text` 是这句话在该渠道下的完整文字（含接着说的各段），每次整句覆盖。单渠道边说边上屏时，按与上次已插入文字的公共前缀回删、补打即可。
- `rows[].state`：`listening` 聆听中、`finalizing` 定稿中、`final` 已定稿、`error` 失败（`error` 为面向用户的简短原因，如「网络不可用」「识别失败」）。只要还有一段在听或在定稿，就不会是 `final` / `error`。
- `rows[].ms`：从结束说话到该渠道定稿的耗时。
- `phase` 在所有渠道都 `final` 或 `error` 后变为 `done`；单渠道 `done` 且 `final` 时主 App 自动把结果记入最近上屏（键盘不用发 commit）。多渠道要等键盘 `commit`。
- `failed` 的处理：`noSession` 拉起主 App；`micBusy` 提示「麦克风被占用：可能正在通话或其他 App 在录音」；`noChannel` 提示去主 App 打开渠道；`bgDenied` 直接拉起主 App（主 App 本次改为常开麦）。
- `session.micReady`（计算属性，不落盘）：`active && !(standby == pip && interrupted)`。
- 认领：键盘记下 `start` 返回的 seq，等 `utterance.startSeq == seq` 时记住 `utterance.id`，之后的命令都带这个 id。

## 时序

单渠道、停顿自动结束：

```
键盘 ping ─▶ 主 App state(active)
键盘 start(silenceStop: 1.5) ─▶ state utterance{phase: recording, rows[0].text 不断更新}
   … 用户停顿 1.5 秒 …
主 App state{phase: finalizing, stopReason: silence} ─▶ state{phase: done, rows[0].state: final}
```

多渠道候选：`start` → 各行实时出字 → 用户点结束 `stop` 或点某行（键盘先 `stop`，等该行 `final` 再上屏） → `commit(channel)`。候选框开着时点麦克风＝`continue`，✕＝`close`。

## 会话规则（主 App 实现）

- 待机方式（会话页可选，默认画中画；会话中在前台切换立即生效，不结束会话）：
  - **画中画待机**：开会话时设 PlayAndRecord 类别（不激活）并打开画中画（`AVPictureInPictureController` + `AVSampleBufferDisplayLayer`），同时设为进后台自动开。启动时送一帧全透明的 4680×1 画面（参考 Typeless 日志中的宽高比），窗口高度约为 0，屏幕上看不到窗口和把手；不送帧则 `startPictureInPicture` 一直报 -1003 起不来（iPhone 13 / iOS 17.3.1 实测，iOS 18 / 26 未验证）。待机时**不激活音频会话、不跑引擎**（系统 MediaSafetyNet 为 `Mic(Cold)`，无橙点）。画中画开着时系统给 App 挂 `PIPVisible`，收到 `start` 后在后台：设类别 → `setActive(true)` → 启动引擎 → 开录；一段录音结束（`stop`、1.5 秒停顿、被打断、`close`）立即停引擎并 `setActive(false, notifyOthersOnDeactivation)`，橙点熄灭。`continue` 再按需开麦。开关步骤见 `MicPlan`。
  - **常开麦**：会话期间麦克风常开保活（橙点常亮），即 v1 行为。
- 画中画回落（都写日志，含错误码）：
  - 后台开麦失败：错误码 `!pri` 561017449 / `!int` 560557684 / `siri` 1936290409 视为被占用 → `interrupted: true`，这句 `micBusy`，键盘空心麦克风，点了拉起主 App，回前台清掉 `interrupted`；其他（如 `!rec` 561145187、`what` 2003329396）→ 这句 `bgDenied`、会话结束 `endReason: bgDenied`，键盘自动拉起主 App，本次改为常开麦。
  - 小窗被关掉、被系统收回、进后台 2 秒内没自动打开、后台时心跳发现小窗不在：结束会话 `endReason: pipClosed`。后台收到 `start` 时小窗不在：这句 `noSession` 并结束会话（`pipClosed`），键盘拉起主 App 重开小窗。
  - 前台 5 秒内打不开小窗（或系统不支持画中画）：本次会话改为常开麦。
- 闲置超时仅适用于常开麦：默认 10 分钟，主 App 会话页可选 5 / 10 / 30 分钟 / 不自动；说话或定稿中不计时。到点关麦、`active` 变 false、`endReason: idle`。键盘可在 `expiresAt - now < 30` 时提醒「说话会自动续期」。画中画不因闲置结束、无到期提醒，升级后也忽略旧画中画会话的 `expiresAt`；原 `idleMinutes` 保留，切回常开麦仍有效。
- 蓝牙耳机：不走 HFP，待命和说话都用手机自带麦克风，耳机保持 A2DP 音质。
- 打断（来电、Siri、其他录音 App）：`interrupted: true`，正在说的句子按 `stopReason: interrupted` 进入定稿（画中画同时关麦）。常开麦：打断结束后自动重新拿麦克风（立即、1 秒、3 秒各试一次），都失败且在后台则结束会话（`endReason: interrupted`），键盘下次点麦克风时会拉起主 App 重开；键盘在 `interrupted` 时发 `start`，主 App 会再试一次，仍失败返回 `micBusy`。画中画：打断结束或回到前台即清掉 `interrupted`，下次录音再开麦；`interrupted` 期间键盘空心麦克风，点了拉起主 App。
- 被杀后冷启动：上次会话没到期的，主 App 一启动（包括被键盘拉起）就自动重开。
- 不做灵动岛。后台模式只用 `audio`。

## 调试

`ios/build.sh <UDID>` 出包并安装。启动参数（`devicectl device process launch … do.j3.voicekey.ios -- <args>`）：

- `-onboarded` 跳过引导；`-arm` 开会话；`-enable a,b,c` 只打开这些渠道；`-multi 0|1`；`-standby pip|mic` 待机方式
- `-fakemic` 用内置录音（后接 3 秒静音循环）代替麦克风
- `-script "start a,b 1.5;wait 6;stop;wait 6;continue;wait 4;stop;wait 6;commit b"` 按键盘方式发命令并把每步后的 state 写进日志（`start` 参数：渠道或 `-`、静音秒数）
- `-idlesec N` 把常开麦闲置超时改成 N 秒（画中画忽略）
- `-selftest` 用内置录音测全部渠道

日志同 SPIKE.md（iOS 17 设备从 App 自己容器的 `Library/Caches/log.txt` 拉）。画中画相关：`pip: active/stopped/failed`、`mic Hot in Nms (各步耗时)`、`mic Cold`、`first audio tap->rec=…ms`（点麦克风到第一块音频）、心跳 `alive … standby= mic=Cold|Hot pip=`。测延迟时不要同时开 `idevicesyslog` 全量抓日志，会把开麦拖慢到 0.5–1 秒。

键盘真机冒烟（手机须解锁，已添加 VoiceKey 键盘并开完全访问）：`xcodebuild test -project VoiceKeyIOS.xcodeproj -scheme VoiceKeyUITests -destination id=<UDID> -allowProvisioningUpdates`。用 `-fakemic` 在引导「试一试」和备忘录里点键盘，核对输入框文字与最近上屏一致、改字/移光标后停止改写、多渠道候选、会话到期提醒、无会话跳主 App（这些按 `-standby mic` 跑）。`PipStandbyUITests` 覆盖画中画：备忘录里后台开录 5 次、画中画看不见（窗口高度约为 0）、杀主 App、超过原闲置时长仍待命且无倒计时、手动结束、锁屏解锁、长待机（`TEST_RUNNER_VK_STANDBY_MIN=15`）。`-fakemic` 只替换音频数据，后台开麦流程是真的。会装上 Debug 包，测完用 `build.sh <UDID>` 换回 Release。

引导真机测试（会改设置里的键盘与完全访问开关，默认跳过）：先 `xcrun devicectl device uninstall app --device <UDID> do.j3.voicekey.ios`，再 `TEST_RUNNER_VK_ONBOARDING=1 xcodebuild test … -only-testing:VoiceKeyUITests/OnboardingUITests/testGrantAll`（逐项授权，跑完键盘、完全访问、麦克风都已打开）或 `testSkipAll`（全不授权也能走完）。每个用例前都要重新卸载。
