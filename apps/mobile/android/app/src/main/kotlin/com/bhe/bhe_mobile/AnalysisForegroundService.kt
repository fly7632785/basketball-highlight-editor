package com.bhe.bhe_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class AnalysisForegroundService : Service() {
    companion object {
        const val ACTION_START = "com.bhe.bhe_mobile.ANALYSIS_START"
        const val ACTION_STOP = "com.bhe.bhe_mobile.ANALYSIS_STOP"
        private const val CHANNEL_ID = "analysis"
    private const val NOTIFICATION_ID = 1001
    private var screenWakeLock: PowerManager.WakeLock? = null
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "视频分析", NotificationManager.IMPORTANCE_LOW),
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                releaseScreenWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            else -> {
                startForeground(NOTIFICATION_ID, notification())
                acquireScreenWakeLock()
                AnalysisTaskManager.startPrepared(this)
            }
        }
        return if (AnalysisTaskManager.isRunning()) START_STICKY else START_NOT_STICKY
    }

    private fun acquireScreenWakeLock() {
        if (screenWakeLock?.isHeld == true) return
        val power = getSystemService(POWER_SERVICE) as PowerManager
        screenWakeLock = power.newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            "BHE::AnalysisScreen",
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseScreenWakeLock() {
        screenWakeLock?.let {
            if (it.isHeld) it.release()
        }
        screenWakeLock = null
    }

    override fun onDestroy() {
        releaseScreenWakeLock()
        super.onDestroy()
    }

    private fun notification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("BHE 正在分析视频")
            .setContentText("分析中，请保持应用运行以获得最佳速度")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
