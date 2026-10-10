package j3.voicekey

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
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
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

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
    var silence by remember { mutableFloatStateOf(p.silence) }
    var volumeKey by remember { mutableStateOf(p.volumeKey) }
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
        Text("不用换输入法：在任意输入框里长按音量下键或悬浮球说话，识别结果直接写进输入框。", color = MaterialTheme.colorScheme.onSurfaceVariant)

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
            }
            Offline()
        }

        Section("说话方式") {
            Toggle("长按音量下键说话", "仅在输入框聚焦时生效，短按仍调音量", volumeKey) {
                volumeKey = it
                p.volumeKey = it
            }
            Toggle("悬浮球", "点一下说话，停顿后自动结束；长按说话，松开结束", bubble) {
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
            Text("点按说话：静音 ${"%.1f".format(silence)} 秒自动结束")
            Slider(silence, { silence = (it * 2).roundToInt() / 2f; p.silence = silence }, valueRange = 1f..5f, steps = 7)
        }

        Section("试一试") {
            OutlinedTextField(trial, { trial = it }, Modifier.fillMaxWidth(), placeholder = { Text("点这里，然后长按音量下键说话") }, minLines = 3)
        }

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
private fun Hint(text: String) = Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

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
private fun Toggle(title: String, desc: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { onChange(!value) }, verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title)
            Hint(desc)
        }
        Switch(value, onChange)
    }
}
