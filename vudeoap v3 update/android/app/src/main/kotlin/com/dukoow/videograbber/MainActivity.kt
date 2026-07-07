package com.dukoow.videograbber

import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

    private val methodChannelName = "video_grabber/downloader"
    private val progressChannelName = "video_grabber/progress"

    private val mobileUA =
        "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var sharedUrl: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            sharedUrl = intent.getStringExtra(Intent.EXTRA_TEXT)
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, progressChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    DownloadBus.listener = { update ->
                        mainHandler.post { sink?.success(update) }
                    }
                }

                override fun onCancel(args: Any?) {
                    DownloadBus.listener = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "getSharedUrl" -> {
                        result.success(sharedUrl)
                        sharedUrl = null
                    }

                    // Restore job states after app reopen (service keeps running)
                    "getJobs" -> result.success(DownloadBus.snapshotAll())

                    "getInfo" -> {
                        val url = call.argument<String>("url") ?: run {
                            result.error("NO_URL", "URL is required", null)
                            return@setMethodCallHandler
                        }
                        val referer = call.argument<String>("referer")
                        thread {
                            try {
                                YtEngine.ensureInit(application)
                                val request = YoutubeDLRequest(url)
                                request.addOption("--no-playlist")
                                request.addOption("--no-check-certificates")
                                if (!referer.isNullOrEmpty()) {
                                    request.addOption("--referer", referer)
                                    request.addOption("--user-agent", mobileUA)
                                }
                                val info = YoutubeDL.getInstance().getInfo(request)
                                val map = hashMapOf<String, Any?>(
                                    "title" to info.title,
                                    "thumbnail" to info.thumbnail,
                                    "duration" to info.duration,
                                    "uploader" to info.uploader
                                )
                                mainHandler.post { result.success(map) }
                            } catch (e: Throwable) {
                                mainHandler.post {
                                    result.error("INFO_ERROR", e.message ?: e.toString(), null)
                                }
                            }
                        }
                    }

                    // Downloads now go through the foreground service (the big fix)
                    "download" -> {
                        val id = call.argument<String>("id")
                            ?: System.currentTimeMillis().toString()
                        val url = call.argument<String>("url") ?: run {
                            result.error("NO_URL", "URL is required", null)
                            return@setMethodCallHandler
                        }
                        val i = Intent(this, DownloadService::class.java).apply {
                            action = DownloadService.ACTION_ENQUEUE
                            putExtra("id", id)
                            putExtra("url", url)
                            putExtra("quality", call.argument<String>("quality") ?: "720")
                            putExtra("referer", call.argument<String>("referer"))
                            putExtra("title", call.argument<String>("title") ?: url)
                        }
                        ContextCompat.startForegroundService(this, i)
                        result.success(id)
                    }

                    "cancel" -> {
                        val id = call.argument<String>("id") ?: run {
                            result.error("NO_ID", "id required", null)
                            return@setMethodCallHandler
                        }
                        val i = Intent(this, DownloadService::class.java).apply {
                            action = DownloadService.ACTION_CANCEL
                            putExtra("id", id)
                        }
                        startService(i)
                        result.success(true)
                    }

                    // Ask Android to stop battery-killing us during long downloads
                    "requestBatteryExemption" -> {
                        try {
                            val pm = getSystemService(POWER_SERVICE) as PowerManager
                            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                                val i = Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName")
                                )
                                startActivity(i)
                                result.success(false)
                            } else {
                                result.success(true)
                            }
                        } catch (e: Throwable) {
                            result.success(false)
                        }
                    }

                    "updateEngine" -> {
                        thread {
                            try {
                                YtEngine.ensureInit(application)
                                customUpdateYtdlp()
                                mainHandler.post { result.success(true) }
                            } catch (e1: Throwable) {
                                try {
                                    YoutubeDL.getInstance().updateYoutubeDL(
                                        application,
                                        YoutubeDL.UpdateChannel.STABLE
                                    )
                                    mainHandler.post { result.success(true) }
                                } catch (e2: Throwable) {
                                    mainHandler.post {
                                        result.error(
                                            "UPDATE_ERROR",
                                            (e1.message ?: e1.toString()) + " | " +
                                                    (e2.message ?: e2.toString()),
                                            null
                                        )
                                    }
                                }
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun customUpdateYtdlp() {
        val direct = URL("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp")
        var conn = direct.openConnection() as HttpURLConnection
        conn.connectTimeout = 30000
        conn.readTimeout = 180000
        conn.instanceFollowRedirects = true

        var redirects = 0
        while (conn.responseCode in 300..399 && redirects < 5) {
            val loc = conn.getHeaderField("Location") ?: break
            conn.disconnect()
            conn = URL(loc).openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 180000
            redirects++
        }
        if (conn.responseCode !in 200..299) {
            throw RuntimeException("Download failed with HTTP ${conn.responseCode}")
        }

        val tmp = File.createTempFile("yt-dlp-new", null, cacheDir)
        conn.inputStream.use { input ->
            tmp.outputStream().use { output -> input.copyTo(output) }
        }
        conn.disconnect()

        if (tmp.length() < 500_000) {
            tmp.delete()
            throw RuntimeException("Downloaded file too small, aborting")
        }

        val ytdlpDir = File(
            File(applicationContext.noBackupFilesDir, YoutubeDL.baseName),
            YoutubeDL.ytdlpDirName
        )
        if (ytdlpDir.exists()) ytdlpDir.deleteRecursively()
        ytdlpDir.mkdirs()
        tmp.copyTo(File(ytdlpDir, YoutubeDL.ytdlpBin), overwrite = true)
        tmp.delete()

        YoutubeDL.getInstance().init_ytdlp(applicationContext, ytdlpDir)
    }
}
