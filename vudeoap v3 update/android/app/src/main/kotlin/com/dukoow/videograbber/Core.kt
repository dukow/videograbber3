package com.dukoow.videograbber

import android.app.Application
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import java.util.concurrent.ConcurrentHashMap

/** Initializes the yt-dlp + ffmpeg engine exactly once for the whole process. */
object YtEngine {
    @Volatile
    private var initialized = false

    @Synchronized
    fun ensureInit(app: Application) {
        if (!initialized) {
            YoutubeDL.getInstance().init(app)
            FFmpeg.getInstance().init(app)
            initialized = true
        }
    }
}

/**
 * In-process progress bus. The DownloadService pushes job updates here;
 * MainActivity forwards them to Flutter through an EventChannel.
 * Also keeps the latest state of every job so the UI can restore itself
 * after the app is reopened while downloads keep running in the service.
 */
object DownloadBus {
    @Volatile
    var listener: ((Map<String, Any?>) -> Unit)? = null

    val jobs = ConcurrentHashMap<String, ConcurrentHashMap<String, Any?>>()

    fun update(id: String, fields: Map<String, Any?>) {
        val job = jobs.getOrPut(id) { ConcurrentHashMap() }
        for ((k, v) in fields) {
            if (v != null) job[k] = v
        }
        val snapshot = HashMap<String, Any?>(job)
        snapshot["id"] = id
        listener?.invoke(snapshot)
    }

    fun snapshotAll(): List<Map<String, Any?>> =
        jobs.entries.map { (id, job) ->
            val m = HashMap<String, Any?>(job)
            m["id"] = id
            m
        }
}
