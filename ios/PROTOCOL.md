# 主 App ⇄ 键盘协议 v1

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

| 文件 | 写入方 | 内容 |
|---|---|---|
| `config.json` | 双方 | `Config`：渠道列表（id / 显示名 / 开关）、多渠道开关、单渠道默认、闲置分钟、上次选中 |
| `state.json` | 主 App | `LiveState`：会话 + 当前这句话 |
| `cmd.json` | 键盘 | `CommandQueue`：最近 32 条命令 |
| `history.json` | 双方 | 最近上屏 20 条；键盘删除键上滑清空输入框时也写入（渠道记为「已清空」），主 App 写前先重读 |
| `keyboard.json` | 键盘 | `KeyboardInfo`，键盘每次出现时写；主 App 据此显示「完全访问已开」 |
| `typing.json` | 双方 | `TypingPrefs`：中文键盘用九宫格还是 26 键（键盘里切布局即改默认）；`haptics` 按键震动；`metrics` 键盘底部显示按键耗时。未开完全访问时键盘读写自己的副本 |

## 会话是否可用

键盘点麦克风前：

1. 记下 `t = now`，发 `ping`。
2. 0.5 秒内收到 `state` 且 `updatedAt >= t`：主 App 活着。
   - `session.active == true`：直接发 `start`。
   - `session.active == false`：拉起主 App。
3. 超时没回：主 App 没在跑（被杀、被系统回收或从没开过）。`state.json` 里残留的 `active: true` 不可信，拉起主 App。

拉起主 App：沿响应链找宿主 `UIApplication` 调 `openURL:options:completionHandler:`，URL 为 `voicekey://session?source=keyboard`（`VK.sessionURL`）。主 App 开好会话后提示用户点系统左上角「◀ 原 App」返回。**回来后不自动开始说**，要用户再点一次麦克风。

`launch` 每次主 App 进程启动都会变；键盘发现它变了，说明主 App 重启过，手上的句子作废。

## 命令（键盘 → 主 App）

用 `CommandQueue.send(op, …)` 发，它负责分配 `seq`（取 `cmd.json` 最大 seq 与 `state.ackSeq` 中较大者 + 1）、追加、截留 32 条、发通知，返回 seq。主 App 按 seq 升序处理所有大于 `ackSeq` 的命令，处理完把 `ackSeq` 写进 state。超过 30 秒的命令直接跳过；主 App 冷启动时把已有命令全部视为已处理。

| op | 参数 | 作用 |
|---|---|---|
| `start` | `channels?`、`silenceStop?` | 开一句新话；会先丢掉上一句。`channels` 省略按配置（多渠道或单渠道默认）。`silenceStop` 秒，说过话后安静这么久自动结束，省略或 0 不自动 |
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
  "v": 1,
  "launch": "UUID",            // 主 App 进程标识
  "updatedAt": 1791400000.12,
  "ackSeq": 12,
  "session": {
    "active": true,
    "since": 1791399000,
    "expiresAt": 1791400600,   // 无操作到这个时刻自动结束；null = 不自动或未开
    "idleMinutes": 10,
    "interrupted": false,      // 来电 / Siri / 其他录音 App 占着麦克风
    "endReason": null,         // 未开启时：user | idle | interrupted | micDenied | failed
    "endedAt": null
  },
  "utterance": {               // 没有句子时为 null
    "id": 7,
    "startSeq": 12,            // 发起它的 start 命令 seq，键盘用它认领
    "phase": "recording",      // recording | finalizing | done | failed
    "stopReason": null,        // user | silence | interrupted
    "silenceStop": 1.5,
    "level": 0.42,             // 输入音量 0…1，聆听中约 10Hz 刷新
    "error": null,             // phase = failed：noSession | micBusy | noChannel
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
- `failed` 的处理：`noSession` 拉起主 App；`micBusy` 提示「麦克风被占用：可能正在通话或其他 App 在录音」；`noChannel` 提示去主 App 打开渠道。
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

- 会话期间麦克风常开保活（系统橙点常亮）；不开麦的待命方式在后台起不来（见 SPIKE.md）。
- 闲置超时：默认 10 分钟，主 App 会话页可选 5 / 10 / 30 分钟 / 不自动；说话或定稿中不计时。到点关麦、`active` 变 false、`endReason: idle`。键盘可在 `expiresAt - now < 30` 时提醒「说话会自动续期」。
- 蓝牙耳机：不走 HFP，待命和说话都用手机自带麦克风，耳机保持 A2DP 音质。
- 打断（来电、Siri、其他录音 App）：`interrupted: true`，正在说的句子按 `stopReason: interrupted` 进入定稿；打断结束后自动重新拿麦克风（立即、1 秒、3 秒各试一次）。都失败且在后台则结束会话（`endReason: interrupted`），键盘下次点麦克风时会拉起主 App 重开。键盘在 `interrupted` 时发 `start`，主 App 会再试一次，仍失败返回 `micBusy`。
- 被杀后冷启动：上次会话没到期的，主 App 一启动（包括被键盘拉起）就自动重开。
- 第一版不做灵动岛和画中画保活。

## 调试

`ios/build.sh <UDID>` 出包并安装。启动参数（`devicectl device process launch … do.j3.voicekey.ios -- <args>`）：

- `-onboarded` 跳过引导；`-arm` 开会话；`-enable a,b,c` 只打开这些渠道；`-multi 0|1`
- `-fakemic` 用内置录音（后接 3 秒静音循环）代替麦克风
- `-script "start a,b 1.5;wait 6;stop;wait 6;continue;wait 4;stop;wait 6;commit b"` 按键盘方式发命令并把每步后的 state 写进日志（`start` 参数：渠道或 `-`、静音秒数）
- `-idlesec N` 把闲置超时改成 N 秒
- `-selftest` 用内置录音测全部渠道

日志同 SPIKE.md（iOS 17 设备从 App 自己容器的 `Library/Caches/log.txt` 拉）。

键盘真机冒烟（手机须解锁，已添加 VoiceKey 键盘并开完全访问）：`xcodebuild test -project VoiceKeyIOS.xcodeproj -scheme VoiceKeyUITests -destination id=<UDID> -allowProvisioningUpdates`。用 `-fakemic` 在引导「试一试」和备忘录里点键盘，核对输入框文字与最近上屏一致、改字/移光标后停止改写、多渠道候选、会话到期提醒、无会话跳主 App。会装上 Debug 包，测完用 `build.sh <UDID>` 换回 Release。
