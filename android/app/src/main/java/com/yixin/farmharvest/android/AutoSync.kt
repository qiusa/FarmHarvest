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
    // 手动排序序号优先（升序，越小越靠上）；同值时按创建时间倒序兜底，
    // 兼容没有 sortIndex 的历史数据。脏记录用本地序号、未脏用服务器序号，
    // 因此本机拖动后的顺序会随备份同步到其它设备。
    merged.sortWith(compareBy<CropRecord> { it.sortIndex }.thenByDescending { it.plantedAt })
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
        val base: SyncBackup
        val needsUpload: Boolean
        when (val fetched = BackupApi.fetchBackup()) {
            is FetchResult.Ok -> {
                base = fetched.backup
                needsUpload = false
            }
            // 服务器可达但没有备份文件：用本地数据重新播种，不做合并删除
            FetchResult.NotFound -> {
                base = local
                needsUpload = true
            }
            // 服务器不可达：不动本地数据，等下次触发再试
            FetchResult.Failed -> return
        }
        if (FarmStore.loadSyncChangeState(context).revision != changes.revision) {
            schedule(RETRY_DEBOUNCE_MS)
            return
        }
        val merged = mergeBackup(base, local, changes)
        if (!sameContent(merged, local)) {
            FarmStore.applySyncedData(context, merged)
        }
        if (!needsUpload && sameContent(merged, base)) return
        val payload = FarmStore.encodeBackup(merged.copy(exportedAt = System.currentTimeMillis()))
        runCatching { BackupApi.uploadBackup(payload) }
            .onSuccess {
                FarmStore.setLastUploadTimestamp(context, System.currentTimeMillis())
                FarmStore.clearSyncChanges(context, changes.revision)
            }
            .onFailure { Log.w(TAG, "上传失败：${it.message}") }
    }
}