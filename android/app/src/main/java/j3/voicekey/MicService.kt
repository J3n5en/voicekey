package j3.voicekey

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/** 麦克风类型前台服务：在前台启动后，App 退到后台仍可录音 */
class MicService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "语音待命", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_mic)
            .setContentTitle("VoiceKey 待命中")
            .setContentText("长按音量下键或悬浮球说话")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            else startForeground(1, n)
            running = true
        } catch (e: Exception) {
            Log.w(TAG, "startForeground", e)
            running = false
            stopSelf()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        private const val TAG = "VoiceKey"
        private const val CHANNEL = "mic"

        @Volatile
        var running = false
            private set

        fun start(ctx: Context) {
            if (running || ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) return
            runCatching { ctx.startForegroundService(Intent(ctx, MicService::class.java)) }
                .onFailure { Log.w(TAG, "startForegroundService", it) }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, MicService::class.java))
        }
    }
}
