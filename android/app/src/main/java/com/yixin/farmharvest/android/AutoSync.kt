package com.yixin.farmharvest.android

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.Executors

fun mergeBackup(base: SyncBackup, local: SyncBackup, changes: SyncChangeState): SyncBackup {
    val localById = local.records.associateBy { it.id }
    val merged = base.records.toMutableList()
    for (id in changes.dirtyRecordIDs) {
        merged.removeAll { it.id == id }
        localById[id]?.let { merged.add(it) }
    }
    merged.sortByDescending { it.plantedAt }
    return SyncBackup(
        exportedAt = base.exportedAt,
        records = merged,
        customCrops = if (changes.customCropsDirty) local.customCrops else base.customCrops,
        hiddenBuiltins = if (changes.hiddenBuiltinsDirty) local.hiddenBuiltins else base.hiddenBuiltins,
    )
}

fun sameContent(a: SyncBackup, b: SyncBackup): Boolean =
    a.records.associateBy { it.id } == b.records.associateBy { it.id } &&
        a.customCrops.associateBy { it.id } == b.customCrops.associateBy { it.id } &&
        a.hiddenBuiltins == b.hiddenBuiltins

object AutoSync {
    private const val TAG = "FarmHarvestAutoSync"
    private const val CHANGE_DEBOUNCE_MS = 2_000L
    private const val FOREGROUND_DEBOUNCE_MS = 1_000L
    private const val RETRY_DEBOUNCE_MS = 1_000L
    private const val TIMER_INTERVAL_MS = 300_000L

    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private var started = false
    private var appContext: Context? = null
    private var pending: Runnable? = null

    private val dataChangeListener = { schedule(CHANGE_DEBOUNCE_MS) }
    private val timerRunnable = object : Runnable {
        override fun run() {
            schedule(0)
            handler.postDelayed(this, TIMER_INTERVAL_MS)
        }
    }

    fun start(context: Context) {
        if (started) return
        started = true
        appContext = context.applicationContext
        FarmStore.addDataChangeListener(dataChangeListener)
        handler.postDelayed(timerRunnable, TIMER_INTERVAL_MS)
        schedule(FOREGROUND_DEBOUNCE_MS)
    }

    fun onForeground() {
        if (started) schedule(FOREGROUND_DEBOUNCE_MS)
    }

    fun schedule(delayMs: Long) {
        pending?.let { handler.removeCallbacks(it) }
        val runnable = Runnable {
            pending = null
            executor.execute { syncOnce() }
        }
        pending = runnable
        handler.postDelayed(runnable, delayMs)
    }

    private fun syncOnce() {
        val context = appContext ?: return
        val changes = FarmStore.loadSyncChangeState(context)
        val local = FarmStore.snapshot(context)
        val lan = BackupApi.fetchBackup(BackupChannel.LAN)
        val wan = BackupApi.fetchBackup(BackupChannel.PUBLIC)
        val backups = listOfNotNull(
            (lan as? FetchResult.Ok)?.backup,
            (wan as? FetchResult.Ok)?.backup,
        )
        val hasNotFound = lan is FetchResult.NotFound || wan is FetchResult.NotFound
        val base = backups.maxByOrNull { it.exportedAt }
            ?: if (hasNotFound) local else return
        if (FarmStore.loadSyncChangeState(context).revision != changes.revision) {
            schedule(RETRY_DEBOUNCE_MS)
            return
        }
        val merged = mergeBackup(base, local, changes)
        if (!sameContent(merged, local)) {
            FarmStore.applySyncedData(context, merged)
        }
        val needsUpload = hasNotFound || backups.isEmpty() || !sameContent(merged, base)
        if (!needsUpload) return
        val payload = FarmStore.encodeBackup(merged.copy(exportedAt = System.currentTimeMillis()))
        var anySuccess = false
        for (channel in BackupChannel.entries) {
            runCatching { BackupApi.uploadBackup(payload, channel) }
                .onSuccess {
                    anySuccess = true
                    FarmStore.setLastUploadTimestamp(context, channel, System.currentTimeMillis())
                }
                .onFailure { Log.w(TAG, "${channel.label}上传失败：${it.message}") }
        }
        if (anySuccess) {
            FarmStore.clearSyncChanges(context, changes.revision)
        }
    }
}