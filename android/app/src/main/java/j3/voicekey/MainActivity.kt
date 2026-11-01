package j3.voicekey

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt
import org.json.JSONObject

class MainActivity : ComponentActivity() {
    private var tick by mutableIntStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val dark = isSystemInDarkTheme()
            val scheme = when {
                Build.VERSION.SDK_INT >= 31 && dark -> dynamicDarkColorScheme(this)
                Build.VERSION.SDK_INT >= 31 -> dynamicLightColorScheme(this)
                dark -> darkColorScheme()
                else -> lightColorScheme()
            }
            MaterialTheme(colorScheme = scheme) {
                Surface(Modifier.fillMaxSize()) { Screen(tick) { tick++ } }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        Keep.restore(this)
        tick++
        MicService.start(this)
        Updater.foreground = true
        Updater.check(this, manual = false)
        Updater.resumeConfirm(this)
    }

    /** 离开设置页即取消按键录制，免得全局吞键 */
    override fun onPause() {
        super.onPause()
        Updater.foreground = false
        VoiceService.instance?.let { s -> s.recorder?.let { s.recorder = null; it(null) } }
    }
}

@Composable
private fun Screen(tick: Int, refresh: () -> Unit) {
    val ctx = LocalContext.current
    val p = App.prefs
    val mic = remember(tick) { ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED }
    val a11y = remember(tick) { VoiceService.enabled(ctx) }
    val battery = remember(tick) { Keep.batteryOk(ctx) }
    val canWrite = remember(tick) { Keep.canWrite(ctx) }
    val perm = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        MicService.start(ctx)
        refresh()
    }
    var channel by remember { mutableStateOf(p.channel) }
    var multi by remember { mutableStateOf(p.multi.toSet()) }
    var streaming by remember { mutableStateOf(p.streaming) }
    var pickSend by remember { mutableStateOf(p.pickSend) }
    var silence by remember { mutableFloatStateOf(p.silence) }
    var silenceStop by remember { mutableStateOf(p.silenceStop) }
    var volumeKey by remember { mutableStateOf(p.volumeKey) }
    var holdName by remember { mutableStateOf(p.holdName) }
    var recording by remember { mutableStateOf(false) }
    DisposableEffect(recording) {
        val svc = VoiceService.instance
        if (recording) svc?.recorder = { keys ->
            recording = false
            if (keys != null) holdName = p.holdName
        }
        onDispose { if (svc?.recorder != null) svc.recorder = null }
    }
    var bubble by remember { mutableStateOf(p.bubble) }
    var bubbleAlways by remember { mutableStateOf(p.bubbleAlways) }
    var trial by remember { mutableStateOf("") }

    Column(
        Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Image(painterResource(R.drawable.ic_wave), null, Modifier.size(36.dp))
            Spacer(Modifier.width(10.dp))
            Text("VoiceKey", style = MaterialTheme.typography.headlineMedium)
        }
        Text("不用换输入法：在任意输入框里长按${holdName}或悬浮球说话，识别结果直接写进输入框。", color = MaterialTheme.colorScheme.onSurfaceVariant)

        if (!a11y) Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val c = MaterialTheme.colorScheme.onErrorContainer
                Text("无障碍服务已关闭，语音输入不可用", style = MaterialTheme.typography.titleMedium, color = c)
                Text("清理后台或强行停止 VoiceKey 后，系统会自动关掉它的无障碍服务。重新开启后，建议完成下方「后台保活」设置。", style = MaterialTheme.typography.bodySmall, color = c)
                Button({ ctx.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }) { Text("去开启") }
            }
        }

        Section("准备") {
            Step("麦克风权限", mic, "授权") {
                val list = mutableListOf(Manifest.permission.RECORD_AUDIO)
                if (Build.VERSION.SDK_INT >= 33) list += Manifest.permission.POST_NOTIFICATIONS
                perm.launch(list.toTypedArray())
            }
            Step("无障碍服务「VoiceKey 语音输入」", a11y, "去开启") {
                ctx.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            }
            if (!a11y) Hint("灰色无法开启时：系统设置 → 应用 → VoiceKey → 右上角 ⋮ → 允许受限制的设置，再回来开启。")
        }

        Section("后台保活") {
            Hint("国内系统划掉后台或一键清理会强行停止 VoiceKey，无障碍服务随之被系统关闭。")
            Step("忽略电池优化", battery, "去设置") { Keep.requestBattery(ctx) }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("允许自启动、后台运行", Modifier.weight(1f))
                OutlinedButton({ Keep.openAutoStart(ctx) }) { Text("打开") }
            }
            Hint("再在最近任务里锁定 VoiceKey（长按或下拉卡片 → 锁定），一键清理就不会杀掉它。")
            Step("打开 App 自动恢复无障碍", canWrite, "复制命令") {
                ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("VoiceKey", Keep.GRANT))
            }
            if (!canWrite) Hint("手机连电脑执行一次下面的命令，之后无障碍被关掉时，打开 VoiceKey 即自动恢复：\n${Keep.GRANT}")
        }

        Section("识别渠道") {
            Channel.entries.forEach { ch ->
                ChannelRow(ch, channel == ch) {
                    channel = ch
                    p.channel = ch
                    if (!ch.ready) WtOffline.download()
                }
            }
            Choice("多渠道（说完挑选）", "勾选的渠道同时识别，在候选框里点一条上屏。", channel == null) {
                channel = null
                p.channel = null
            }
            if (channel == null) {
                Channel.entries.forEach { ch ->
                    Row(
                        Modifier.fillMaxWidth().clickable {
                            val next = if (ch in multi) multi - ch else multi + ch
                            if (next.size >= 2) {
                                multi = next
                                p.multi = Channel.entries.filter { it in next }
                            }
                        }.padding(start = 40.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(ch in multi, null)
                        Text(ch.title + if (ch.ready) "" else "（未下载，跳过）")
                    }
                }
                Toggle("选中后自动上屏并发送", if (pickSend) "手动点选和 Jev 自动选中的候选上屏后随即发送；长按候选只上屏、可继续编辑" else "Jev 只高亮推荐的一条，你点它才上屏；手动点选也只上屏不发送", pickSend) {
                    pickSend = it
                    p.pickSend = it
                }
                JevSettings()
            }
            Offline()
        }

        Section("说话方式") {
            val volumeOnly = p.holdKeys.all { it in Keys.volume }
            Toggle("长按${holdName}说话", "仅在输入框聚焦时生效" + if (volumeOnly) "，短按仍调音量" else "", volumeKey) {
                volumeKey = it
                p.volumeKey = it
            }
            if (volumeKey) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Hint(if (recording) "按住想用的键（可多个一起按），松开即保存；返回键取消" else "可换成音量上键、耳机键、外接键盘组合等", Modifier.weight(1f))
                    if (!recording && p.holdKeys != Keys.DEFAULT) TextButton({
                        p.holdKeys = Keys.DEFAULT
                        holdName = p.holdName
                    }) { Text("恢复默认") }
                    OutlinedButton({ recording = !recording }, enabled = a11y) { Text(if (recording) "取消" else "自定义按键") }
                }
            }
            Toggle("悬浮球", "点一下说话，${if (silenceStop) "停顿后自动结束" else "再点一下结束"}；长按说话，松开结束", bubble) {
                bubble = it
                p.bubble = it
                VoiceService.instance?.refresh()
            }
            if (bubble) Toggle("始终显示悬浮球", "关闭时只在输入框聚焦时出现", bubbleAlways) {
                bubbleAlways = it
                p.bubbleAlways = it
                VoiceService.instance?.refresh()
            }
            Toggle("边说边上屏", "识别中的文字实时写入输入框，结束后按定稿修正", streaming) {
                streaming = it
                p.streaming = it
            }
            Toggle("点按说话：静音自动结束", if (silenceStop) "停顿 ${"%.1f".format(silence)} 秒视为说完" else "已关闭，需再点一次结束", silenceStop) {
                silenceStop = it
                p.silenceStop = it
            }
            if (silenceStop) Slider(silence, { silence = (it * 2).roundToInt() / 2f; p.silence = silence }, valueRange = 1f..5f, steps = 7)
        }

        Section("试一试") {
            OutlinedTextField(trial, { trial = it }, Modifier.fillMaxWidth(), placeholder = { Text("点这里，然后长按${holdName}说话") }, minLines = 3)
        }

        Section("关于与更新") { UpdateSection() }

        Hint("本项目通过分析输入法客户端协议实现，仅供学习与个人使用；语音会发送到所选厂商的服务器（离线渠道除外）。")
    }
}

@Composable
private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            content()
        }
    }
}

@Composable
private fun Hint(text: String, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) =
    Text(text, modifier, style = MaterialTheme.typography.bodySmall, color = color)

private data class JevRow(val addr: String, val key: String)

/** jevPool → 行列表：跳过空行、# 注释和 core 也会跳过的坏行（段数不是 2–3 或 key 为空）；alias 丢弃，地址存原文不补全 */
private fun parseJevPool(text: String): List<JevRow> =
    text.lines().map(String::trim).filter { it.isNotEmpty() && !it.startsWith("#") }.mapNotNull { line ->
        val parts = line.split('|').map(String::trim)
        if (parts.size in 2..3 && parts[1].isNotEmpty()) JevRow(parts.getOrElse(2) { "" }, parts[1]) else null
    }

/** 行列表 → 多行「别名|key|endpoint」存储格式；key 为空的行不写；别名取地址 host，地址空用 official，重名追加 -2、-3… */
private fun serializeJevPool(rows: List<JevRow>): String {
    val seen = mutableMapOf<String, Int>()
    return rows.mapNotNull { r ->
        val addr = r.addr.filterNot { it == '|' || it == '\r' || it == '\n' }.trim()
        val key = r.key.filterNot { it == '|' || it == '\r' || it == '\n' }.trim()
        if (key.isEmpty()) return@mapNotNull null
        val base = if (addr.isEmpty()) "official" else
            runCatching { java.net.URI(if ("://" in addr) addr else "https://$addr").host }.getOrNull()?.takeIf { it.isNotEmpty() } ?: "custom"
        val n = (seen[base] ?: 0) + 1
        seen[base] = n
        "${if (n == 1) base else "$base-$n"}|$key|$addr"
    }.joinToString("\n")
}

/** 多渠道定稿后用 Jev 评出最佳一条自动上屏；配置存本机，测试结果在回调里回主线程 */
@Composable
private fun JevSettings() {
    val p = App.prefs
    val main = remember { Handler(Looper.getMainLooper()) }
    var mode by remember { mutableStateOf(p.jevMode) }
    var key by remember { mutableStateOf(p.jevKey) }
    var endpoint by remember { mutableStateOf(p.jevEndpoint) }
    var model by remember { mutableStateOf(p.jevModel) }
    val rows = remember { mutableStateListOf<JevRow>().apply { addAll(parseJevPool(p.jevPool).ifEmpty { listOf(JevRow("", "")) }) } }
    val saveRows = { p.jevPool = serializeJevPool(rows) }
    var testing by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<Pair<Boolean, String>?>(null) }
    val problem = if (mode == "off") null else Native.jevCheck(p.jevConfig())

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("智能选择（Jev）", style = MaterialTheme.typography.titleSmall)
        Choice("关闭", "说完后在候选框里自己挑。", mode == "off") {
            mode = "off"
            p.jevMode = "off"
        }
        Choice("官方格式", "填一个 API Key，说完后自动选出最佳一条上屏。", mode == "official") {
            mode = "official"
            p.jevMode = "official"
        }
        Choice("自定义格式", "多组地址和密钥，一组用不了自动换下一组。", mode == "yce") {
            mode = "yce"
            p.jevMode = "yce"
        }
        if (mode == "official") {
            OutlinedTextField(
                key, { key = it; p.jevKey = it }, Modifier.fillMaxWidth(),
                label = { Text("API Key") }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
            )
            OutlinedTextField(
                endpoint, { endpoint = it; p.jevEndpoint = it }, Modifier.fillMaxWidth(),
                label = { Text("端点（可留空）") }, placeholder = { Text("https://api.typesafe.ai") }, singleLine = true,
            )
            Hint("可只填域名，自动补全为 …/v1/systemone；以 /decisions 结尾按 decisions 协议发送")
            OutlinedTextField(
                model, { model = it; p.jevModel = it }, Modifier.fillMaxWidth(),
                label = { Text("模型（可留空）") }, placeholder = { Text("jev-latest") }, singleLine = true,
            )
        }
        if (mode == "yce") {
            rows.forEachIndexed { i, r ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        OutlinedTextField(
                            r.addr, { rows[i] = r.copy(addr = it); saveRows() }, Modifier.fillMaxWidth(),
                            label = { Text("地址") }, placeholder = { Text("https://api.typesafe.ai") }, singleLine = true,
                        )
                        OutlinedTextField(
                            r.key, { rows[i] = r.copy(key = it); saveRows() }, Modifier.fillMaxWidth(),
                            label = { Text("密钥") }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                        )
                    }
                    TextButton({ rows.removeAt(i); if (rows.isEmpty()) rows.add(JevRow("", "")); saveRows() }) { Text("删除") }
                }
            }
            TextButton({ rows.add(JevRow("", "")) }) { Text("添加一组") }
            Hint("从上到下依次尝试，一组用不了自动换下一组；地址可留空（用官方端点），只填域名会自动补全为 …/v1/systemone，以 /decisions 结尾按 decisions 协议发送")
        }
        if (mode != "off") {
            problem?.let { Hint(it, color = MaterialTheme.colorScheme.error) }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Hint("仅多渠道模式生效；只把转写文字发给 Jev，不发渠道名；密钥只存本机", Modifier.weight(1f))
                OutlinedButton({
                    testing = true
                    result = null
                    Native.jevTest(p.jevConfig()) { kind, text ->
                        main.post {
                            testing = false
                            result = if (kind == Native.FINAL) {
                                runCatching {
                                    val o = JSONObject(text)
                                    true to "选中第 ${o.getInt("index") + 1} 条：${o.getString("text")} · ${o.getLong("ms")}ms · ${o.getString("alias")} · ${o.getString("key")}"
                                }.getOrElse { false to text }
                            } else {
                                false to text
                            }
                        }
                    }
                }, enabled = !testing && problem == null) { Text(if (testing) "测试中…" else "测试") }
            }
            result?.let { (ok, text) -> Hint(text, color = if (ok) Color(0xFF2E9E5B) else MaterialTheme.colorScheme.error) }
        } else {
            Hint("仅多渠道模式生效；只把转写文字发给 Jev，不发渠道名；密钥只存本机")
        }
    }
}

@Composable
private fun Step(title: String, done: Boolean, action: String, onClick: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(if (done) "✓" else "•", color = if (done) Color(0xFF2E9E5B) else MaterialTheme.colorScheme.error)
        Spacer(Modifier.width(10.dp))
        Text(title, Modifier.weight(1f))
        if (!done) Button(onClick) { Text(action) }
    }
}

@Composable
private fun ChannelRow(ch: Channel, selected: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected, null)
        Spacer(Modifier.width(8.dp))
        Image(painterResource(ch.logo), null, Modifier.size(32.dp).clip(RoundedCornerShape(8.dp)))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(ch.title)
            Hint(ch.desc)
        }
    }
}

@Composable
private fun Choice(title: String, desc: String, selected: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected, null)
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(title)
            Hint(desc)
        }
    }
}

@Composable
private fun Offline() {
    if (WtOffline.ready) return
    val progress = WtOffline.progress
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        when {
            progress != null -> {
                Text("微信离线模型下载中 ${(progress * 100).roundToInt()}%")
                LinearProgressIndicator({ progress }, Modifier.fillMaxWidth())
            }
            else -> Row(verticalAlignment = Alignment.CenterVertically) {
                Text("微信离线模型（约 100MB）未下载", Modifier.weight(1f))
                OutlinedButton(WtOffline::download) { Text("下载") }
            }
        }
        WtOffline.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}

@Composable
private fun UpdateSection() {
    val ctx = LocalContext.current
    val (code, name) = remember { Updater.currentVersion(ctx) }
    val st = Updater.state
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("当前版本 $name（$code）", Modifier.weight(1f))
            val busy = st == Updater.State.Checking || st is Updater.State.Downloading || st == Updater.State.Installing
            OutlinedButton({ Updater.check(ctx, true) }, enabled = !busy) { Text(if (st == Updater.State.Checking) "检查中…" else "检查更新") }
        }
        when (st) {
            is Updater.State.Available -> {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("新版本 ${st.m.versionName}", Modifier.weight(1f))
                    Button({ Updater.install(ctx) }) { Text("更新") }
                }
                if (!ctx.packageManager.canRequestPackageInstalls()) Hint("首次更新需允许 VoiceKey 安装未知应用")
            }
            is Updater.State.Downloading -> {
                Text("下载中 ${(st.progress * 100).roundToInt()}%")
                LinearProgressIndicator({ st.progress }, Modifier.fillMaxWidth())
            }
            Updater.State.Installing -> Row(verticalAlignment = Alignment.CenterVertically) {
                Text("等待系统安装确认", Modifier.weight(1f))
                OutlinedButton({ Updater.showConfirm(ctx) }, enabled = Updater.confirm != null) { Text("继续安装") }
            }
            Updater.State.Latest -> Text("已是最新版本")
            is Updater.State.Error -> Text(st.msg, color = MaterialTheme.colorScheme.error)
            else -> {}
        }
    }
}

@Composable
private fun Toggle(title: String, desc: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { onChange(!value) }, verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title)
            Hint(desc)
        }
        Switch(value, onChange)
    }
}
