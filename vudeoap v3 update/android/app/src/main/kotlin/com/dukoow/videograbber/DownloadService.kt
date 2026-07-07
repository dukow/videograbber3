package com.dukoow.videograbber

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Foreground service that owns every download.
 *
 * This is the fix for "2 hour video never finishes":
 *  - runs as a FOREGROUND service with a persistent notification, so Android
 *    does not kill it when the screen turns off or the app is swiped away
 *  - holds a partial wake lock + high-perf wifi lock for the whole download
 *  - yt-dlp runs with --continue + heavy retries, so a dropped connection
 *    resumes from where it stopped instead of starting over
 *  - downloads are queued and executed one at a time (stable on mobile data)
 */
class DownloadService : Service() {

    companion object {
        const val ACTION_ENQUEUE = "com.dukoow.videograbber.ENQUEUE"
        const val ACTION_CANCEL = "com.dukoow.videograbber.CANCEL"
        const val CHANNEL_ID = "downloads"
        const val NOTIF_ID = 1001

        private const val mobileUA =
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val pending = AtomicInteger(0)
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ENQUEUE -> {
                val id = intent.getStringExtra("id") ?: return START_NOT_STICKY
                val url = intent.getStringExtra("url") ?: return START_NOT_STICKY
                val quality = intent.getStringExtra("quality") ?: "720"
                val referer = intent.getStringExtra("referer")
                val title = intent.getStringExtra("title") ?: url

                pending.incrementAndGet()
                goForeground("Queued: $title")
                acquireLocks()

                DownloadBus.update(
                    id,
                    mapOf(
                        "status" to "queued",
                        "url" to url,
                        "title" to title,
                        "quality" to quality,
                        "progress" to -1.0,
                        "error" to ""
                    )
                )

                executor.submit { runJob(id, url, quality, referer, title) }
            }

            ACTION_CANCEL -> {
                val id = intent.getStringExtra("id") ?: return START_NOT_STICKY
                try {
                    YoutubeDL.getInstance().destroyProcessById(id)
                } catch (_: Throwable) {
                }
                DownloadBus.update(id, mapOf("status" to "cancelled"))
            }
        }
        return START_NOT_STICKY
    }

    private fun runJob(id: String, url: String, quality: String, referer: String?, title: String) {
        DownloadBus.update(id, mapOf("status" to "downloading", "progress" to 0.0))
        updateNotification("Downloading: $title", 0)

        try {
            YtEngine.ensureInit(application)

            val outDir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "VideoGrabber"
            )
            if (!outDir.exists()) outDir.mkdirs()

            val request = YoutubeDLRequest(url)
            request.addOption("--no-playlist")
            request.addOption("--no-mtime")

            // ===== THE LONG-VIDEO FIXES =====
            request.addOption("--continue")                    // resume partial files
            request.addOption("--retries", "20")               // retry whole download
            request.addOption("--fragment-retries", "50")      // retry HLS fragments
            request.addOption("--socket-timeout", "30")
            request.addOption("--concurrent-fragments", "8")   // 8x faster HLS
            request.addOption("--no-check-certificates")       // drama sites w/ bad SSL
            // ================================

            if (!referer.isNullOrEmpty()) {
                request.addOption("--referer", referer)
                request.addOption("--user-agent", mobileUA)
                request.addOption("--add-header", "Origin:" + originOf(referer))
            }

            if (quality == "mp3") {
                request.addOption("-x")
                request.addOption("--audio-format", "mp3")
                request.addOption("--audio-quality", "0")
                request.addOption("-o", "${outDir.absolutePath}/%(title).80s.%(ext)s")
            } else {
                request.addOption(
                    "-f",
                    "bestvideo[height<=$quality]+bestaudio/best[height<=$quality]/best"
                )
                request.addOption("--merge-output-format", "mp4")
                request.addOption("-o", "${outDir.absolutePath}/%(title).80s_${quality}p.%(ext)s")
            }

            YoutubeDL.getInstance().execute(request, id) { progress, etaSeconds, _ ->
                val p = if (progress < 0) 0f else progress
                DownloadBus.update(
                    id,
                    mapOf("status" to "downloading", "progress" to p.toDouble(), "eta" to etaSeconds)
                )
                updateNotification("Downloading: $title", p.toInt())
            }

            DownloadBus.update(
                id,
                mapOf("status" to "done", "progress" to 100.0, "path" to outDir.absolutePath)
            )
            notifyFinished("Finished: $title")
        } catch (e: Throwable) {
            val msg = e.message ?: e.toString()
            val cancelled = DownloadBus.jobs[id]?.get("status") == "cancelled" ||
                    msg.contains("interrupted", ignoreCase = true)
            if (cancelled) {
                DownloadBus.update(id, mapOf("status" to "cancelled"))
            } else {
                DownloadBus.update(id, mapOf("status" to "failed", "error" to msg.take(400)))
                notifyFinished("Failed: $title")
            }
        } finally {
            if (pending.decrementAndGet() <= 0) {
                releaseLocks()
                stopForeground(STOP_FOREGROUND_DETACH)
                stopSelf()
            }
        }
    }

    private fun originOf(referer: String): String = try {
        val u = java.net.URL(referer)
        "${u.protocol}://${u.host}"
    } catch (_: Throwable) {
        referer
    }

    // ---------- locks ----------

    private fun acquireLocks() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "videograbber:download")
                .apply { setReferenceCounted(false); acquire(6 * 60 * 60 * 1000L) } // up to 6h
        }
        if (wifiLock == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "videograbber:wifi")
                .apply { setReferenceCounted(false); acquire() }
        }
    }

    private fun releaseLocks() {
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Throwable) {}
        try { wifiLock?.let { if (it.isHeld) it.release() } } catch (_: Throwable) {}
        wakeLock = null
        wifiLock = null
    }

    // ---------- notifications ----------

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW
            )
            ch.description = "Video download progress"
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(ch)
        }
    }

    private fun buildNotification(text: String, progress: Int): Notification {
        val openIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Video Grabber")
            .setContentText(text)
            .setContentIntent(openIntent)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
        if (progress in 0..100) b.setProgress(100, progress, progress == 0)
        return b.build()
    }

    private fun goForeground(text: String) {
        val notif = buildNotification(text, 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun updateNotification(text: String, progress: Int) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification(text, progress))
    }

    private fun notifyFinished(text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Video Grabber")
            .setContentText(text)
            .setAutoCancel(true)
        nm.notify(System.currentTimeMillis().toInt(), b.build())
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }
}
