package j3.voicekey

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.widget.Toast

/** 国内系统清后台会强行停止 App，系统随之关掉无障碍：引导加白名单，有权限时打开 App 自动恢复 */
object Keep {
    const val GRANT = "adb shell pm grant do.j3.voicekey android.permission.WRITE_SECURE_SETTINGS"

    private val autoStart = listOf(
        "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
        "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
        "com.huawei.systemmanager" to "com.huawei.systemmanager.optimize.process.ProtectActivity",
        "com.hihonor.systemmanager" to "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
        "com.oplus.safecenter" to "com.oplus.safecenter.permission.startup.StartupAppListActivity",
        "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
        "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
        "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
        "com.iqoo.secure" to "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
        "com.meizu.safe" to "com.meizu.safe.permission.SmartBGActivity",
        "com.samsung.android.lool" to "com.samsung.android.sm.battery.ui.BatteryActivity",
    )

    fun canWrite(ctx: Context) =
        ctx.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    /** 无障碍被关掉时写回开启列表，返回是否做了恢复 */
    fun restore(ctx: Context): Boolean {
        if (VoiceService.enabled(ctx) || !canWrite(ctx)) return false
        val r = ctx.contentResolver
        val me = ComponentName(ctx, VoiceService::class.java).flattenToString()
        val list = Settings.Secure.getString(r, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
            .split(':').filter { it.isNotBlank() && it != "null" }
        return try {
            Settings.Secure.putString(r, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, (list + me).joinToString(":"))
            Settings.Secure.putInt(r, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
            Toast.makeText(ctx, "已自动恢复无障碍服务", Toast.LENGTH_SHORT).show()
            true
        } catch (_: SecurityException) {
            false
        }
    }

    fun batteryOk(ctx: Context) =
        ctx.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(ctx.packageName)

    fun requestBattery(ctx: Context) = open(
        ctx,
        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${ctx.packageName}")),
        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
    )

    /** 各家自启动/后台管理页，都打不开时退到应用详情 */
    fun openAutoStart(ctx: Context) = open(
        ctx,
        *autoStart.map { (p, c) -> Intent().setClassName(p, c) }.toTypedArray(),
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}")),
    )

    private fun open(ctx: Context, vararg intents: Intent) {
        for (i in intents) {
            try {
                ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            } catch (_: Exception) {
            }
        }
    }
}
