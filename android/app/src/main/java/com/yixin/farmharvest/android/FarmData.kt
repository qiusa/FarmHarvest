package com.yixin.farmharvest.android

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit
import java.time.format.DateTimeFormatter
import java.util.UUID

data class HarvestCycle(
    val id: String = UUID.randomUUID().toString(),
    val date: Long,
    val harvested: Boolean = false,
)

data class CropRecord(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val colorHex: String,
    val minutes: Int,
    val plantedAt: Long,
    val harvests: List<HarvestCycle>,
    val note: String? = null,
)

data class CropPreset(
    val id: String,
    val name: String,
    val colorHex: String,
    val minutes: Int,
)

data class ImportSummary(
    val recordsAdded: Int,
    val recordsOverwritten: Int,
    val recordsTotal: Int,
    val cropsAdded: Int,
    val cropsOverwritten: Int,
    val cropsTotal: Int,
    val mode: ImportMode,
) {
    val text: String
        get() = if (mode == ImportMode.REPLACE) {
            "已替换：记录 $recordsTotal 条 · 模板 $cropsTotal 个"
        } else {
            val recordPart = buildList {
                add(if (recordsAdded > 0) "新增记录 $recordsAdded 条" else "无新增记录")
                if (recordsOverwritten > 0) add("覆盖 $recordsOverwritten 条")
            }.joinToString(" · ")
            val cropPart = buildList {
                add(if (cropsAdded > 0) "新增模板 $cropsAdded 个" else "无新增模板")
                if (cropsOverwritten > 0) add("覆盖 $cropsOverwritten 个")
            }.joinToString(" ")
            "已合并：$recordPart · $cropPart"
        }
}

enum class ImportMode { MERGE, REPLACE }

object FarmStore {
    const val SOURCE_BACKUP_FILE_NAME = "FarmHarvest.json"
    const val SOURCE_BACKUP_URL = "http://192.168.200.94:10023/source/FarmHarvest.json"
    const val UPLOAD_ENDPOINT = "http://192.168.200.94:3211/api/source-files"
    const val UPLOAD_TOKEN = "93c294dc9066ad5fce4e35ad4dc008a7a87feef0465d8af7"
    private const val PREFS = "farm-harvest"
    private const val RECORDS_KEY = "records"
    private const val CROPS_KEY = "custom-crops"
    private const val HIDDEN_KEY = "hidden-builtins"
    private const val LAST_UPLOAD_KEY = "last-upload"
    private const val NOTIFICATION_PERMISSION_ASKED_KEY = "notification-permission-asked"

    private val builtins = listOf(
        CropPreset("carrot", "快速事项", "FF8C42", 20),
        CropPreset("cabbage", "常规事项", "7AC74F", 40),
        CropPreset("tomato", "专注事项", "E63946", 60),
        CropPreset("corn", "长时事项", "FFD23F", 90),
        CropPreset("potato", "短时提醒", "C08457", 30),
        CropPreset("strawberry", "日常安排", "F06595", 45),
    )
    private val cropPalette = listOf(
        "FF8C42", "7AC74F", "E63946", "FFD23F", "C08457",
        "F06595", "9B5DE5", "00BBF9", "00F5D4", "F15BB5",
    )

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun loadRecords(context: Context): List<CropRecord> = runCatching {
        val raw = prefs(context).getString(RECORDS_KEY, null) ?: return emptyList()
        parseRecords(JSONArray(raw))
    }.getOrDefault(emptyList())

    fun loadCustomCrops(context: Context): List<CropPreset> = runCatching {
        val raw = prefs(context).getString(CROPS_KEY, null) ?: return emptyList()
        parseCrops(JSONArray(raw))
    }.getOrDefault(emptyList())

    fun presets(context: Context): List<CropPreset> {
        val hidden = hiddenBuiltins(context)
        return builtins.filterNot { it.id in hidden } + loadCustomCrops(context)
    }

    fun saveRecords(context: Context, records: List<CropRecord>) {
        prefs(context).edit().putString(RECORDS_KEY, encodeRecords(records).toString()).apply()
    }

    fun addRecord(
        context: Context,
        preset: CropPreset,
        minutes: Int,
        note: String?,
        now: Long = System.currentTimeMillis(),
    ): CropRecord {
        val record = CropRecord(
            name = preset.name,
            colorHex = preset.colorHex,
            minutes = minutes,
            plantedAt = now,
            harvests = listOf(HarvestCycle(date = now + minutes.coerceAtLeast(1) * 60_000L)),
            note = note?.trim()?.takeIf(String::isNotEmpty),
        )
        saveRecords(context, listOf(record) + loadRecords(context))
        return record
    }

    fun addCustomCrop(context: Context, name: String, minutes: Int): CropPreset {
        val current = loadCustomCrops(context)
        val preset = CropPreset(
            id = UUID.randomUUID().toString(),
            name = name.trim(),
            colorHex = cropPalette[current.size % cropPalette.size],
            minutes = minutes.coerceAtLeast(1),
        )
        prefs(context).edit()
            .putString(CROPS_KEY, encodeCrops(current + preset).toString())
            .apply()
        return preset
    }

    fun updateRecord(context: Context, updated: CropRecord) {
        val current = loadRecords(context)
        val index = current.indexOfFirst { it.id == updated.id }
        if (index < 0) return
        saveRecords(context, current.toMutableList().apply { set(index, updated) })
    }

    fun setHarvested(context: Context, recordId: String, cycleId: String, harvested: Boolean) {
        val updated = loadRecords(context).map { record ->
            if (record.id != recordId) record else record.copy(
                harvests = record.harvests.map { cycle ->
                    if (cycle.id == cycleId) cycle.copy(harvested = harvested) else cycle
                },
            )
        }
        saveRecords(context, updated)
    }

    fun renew(context: Context, record: CropRecord, now: Long = System.currentTimeMillis()) {
        val cycle = HarvestCycle(date = now + record.minutes.coerceAtLeast(1) * 60_000L)
        updateRecord(context, record.copy(harvests = (record.harvests + cycle).sortedBy { it.date }))
    }

    fun deleteRecord(context: Context, recordId: String) {
        saveRecords(context, loadRecords(context).filterNot { it.id == recordId })
    }

    fun clearFinishedRecords(context: Context, now: Long = System.currentTimeMillis()) {
        saveRecords(
            context,
            loadRecords(context).filter { record ->
                record.harvests.isEmpty() || record.harvests.any { !it.harvested && it.date > now }
            },
        )
    }

    fun exportBackup(context: Context, now: Long = System.currentTimeMillis()): ByteArray {
        val hidden = hiddenBuiltins(context).sorted()
        return JSONObject()
            .put("version", 1)
            .put("exportedAt", isoDate(now))
            .put("records", encodeRecords(loadRecords(context)))
            .put("customCrops", encodeCrops(loadCustomCrops(context)))
            .put("hiddenBuiltins", JSONArray(hidden))
            .toString(2)
            .toByteArray(Charsets.UTF_8)
    }

    fun importBackup(context: Context, bytes: ByteArray, mode: ImportMode): ImportSummary {
        val backup = JSONObject(bytes.toString(Charsets.UTF_8))
        val version = backup.optInt("version", 1)
        require(version <= 1) { "备份版本 $version 高于当前 App 支持的版本" }
        val backupRecords = parseRecords(backup.optJSONArray("records") ?: JSONArray())
        val backupCrops = parseCrops(backup.optJSONArray("customCrops") ?: JSONArray())
        val backupHidden = backup.optJSONArray("hiddenBuiltins").toStringSet()
        val currentRecords = loadRecords(context)
        val currentCrops = loadCustomCrops(context)
        val currentHidden = hiddenBuiltins(context)

        val recordAdded: Int
        val recordOverwritten: Int
        val cropAdded: Int
        val cropOverwritten: Int
        if (mode == ImportMode.REPLACE) {
            saveRecords(context, backupRecords)
            prefs(context).edit()
                .putString(CROPS_KEY, encodeCrops(backupCrops).toString())
                .putString(HIDDEN_KEY, JSONArray(backupHidden.sorted()).toString())
                .apply()
            recordAdded = backupRecords.size
            recordOverwritten = 0
            cropAdded = backupCrops.size
            cropOverwritten = 0
        } else {
            val backupRecordIds = backupRecords.mapTo(mutableSetOf()) { it.id }
            val backupCropIds = backupCrops.mapTo(mutableSetOf()) { it.id }
            recordOverwritten = currentRecords.count { it.id in backupRecordIds }
            recordAdded = backupRecordIds.count { id -> currentRecords.none { it.id == id } }
            cropOverwritten = currentCrops.count { it.id in backupCropIds }
            cropAdded = backupCropIds.count { id -> currentCrops.none { it.id == id } }

            val preservedRecords = currentRecords.filterNot { it.id in backupRecordIds }
            saveRecords(
                context,
                preservedRecords + backupRecords.filter { record ->
                    preservedRecords.none { it.id == record.id }
                },
            )
            val preservedCrops = currentCrops.filterNot { it.id in backupCropIds }
            prefs(context).edit()
                .putString(
                    CROPS_KEY,
                    encodeCrops(
                        preservedCrops + backupCrops.filter { crop ->
                            preservedCrops.none { it.id == crop.id }
                        },
                    ).toString(),
                )
                .putString(HIDDEN_KEY, JSONArray((currentHidden + backupHidden).sorted()).toString())
                .apply()
        }

        return ImportSummary(
            recordsAdded = recordAdded,
            recordsOverwritten = recordOverwritten,
            recordsTotal = backupRecords.size,
            cropsAdded = cropAdded,
            cropsOverwritten = cropOverwritten,
            cropsTotal = backupCrops.size,
            mode = mode,
        )
    }

    fun lastUploadTimestamp(context: Context): Long =
        prefs(context).getLong(LAST_UPLOAD_KEY, 0L)

    fun setLastUploadTimestamp(context: Context, timestamp: Long) {
        prefs(context).edit().putLong(LAST_UPLOAD_KEY, timestamp).apply()
    }

    fun wasNotificationPermissionAsked(context: Context): Boolean =
        prefs(context).getBoolean(NOTIFICATION_PERMISSION_ASKED_KEY, false)

    fun markNotificationPermissionAsked(context: Context) {
        prefs(context).edit().putBoolean(NOTIFICATION_PERMISSION_ASKED_KEY, true).apply()
    }

    private fun hiddenBuiltins(context: Context): Set<String> = runCatching {
        val raw = prefs(context).getString(HIDDEN_KEY, null) ?: return emptySet()
        JSONArray(raw).toStringSet()
    }.getOrDefault(emptySet())

    private fun parseRecords(array: JSONArray): List<CropRecord> =
        (0 until array.length()).mapNotNull { index ->
            runCatching { parseRecord(array.getJSONObject(index)) }.getOrNull()
        }

    private fun parseRecord(json: JSONObject): CropRecord {
        val harvestsJson = json.optJSONArray("harvests")
        val cycles = if (harvestsJson != null) {
            (0 until harvestsJson.length()).mapNotNull { index ->
                runCatching { parseCycle(harvestsJson.getJSONObject(index)) }.getOrNull()
            }
        } else {
            val legacyDate = json.opt("harvestAt")?.let(::parseDate)
            val extras = json.optJSONArray("extraHarvests")
            buildList {
                if (legacyDate != null) add(HarvestCycle(date = legacyDate))
                if (extras != null) {
                    for (index in 0 until extras.length()) {
                        runCatching { parseDate(extras.get(index)) }
                            .getOrNull()
                            ?.let { add(HarvestCycle(date = it)) }
                    }
                }
            }.sortedBy { it.date }
        }
        return CropRecord(
            id = json.getString("id"),
            name = json.getString("name"),
            colorHex = json.optString("colorHex", "7AC74F"),
            minutes = json.optInt("minutes", 30),
            plantedAt = parseDate(json.get("plantedAt")),
            harvests = cycles,
            note = json.optString("note").takeIf { it.isNotBlank() && it != "null" },
        )
    }

    private fun parseCycle(json: JSONObject) = HarvestCycle(
        id = json.optString("id").ifBlank { UUID.randomUUID().toString() },
        date = parseDate(json.get("date")),
        harvested = json.optBoolean("harvested", false),
    )

    private fun parseCrops(array: JSONArray): List<CropPreset> =
        (0 until array.length()).mapNotNull { index ->
            runCatching {
                val json = array.getJSONObject(index)
                CropPreset(
                    id = json.getString("id"),
                    name = json.getString("name"),
                    colorHex = json.optString("colorHex", "7AC74F"),
                    minutes = json.optInt("minutes", 30),
                )
            }.getOrNull()
        }

    private fun encodeRecords(records: List<CropRecord>) = JSONArray().apply {
        records.forEach { record ->
            put(
                JSONObject()
                    .put("id", record.id)
                    .put("name", record.name)
                    .put("colorHex", record.colorHex)
                    .put("minutes", record.minutes)
                    .put("plantedAt", isoDate(record.plantedAt))
                    .put("harvests", JSONArray().apply {
                        record.harvests.forEach { cycle ->
                            put(
                                JSONObject()
                                    .put("id", cycle.id)
                                    .put("date", isoDate(cycle.date))
                                    .put("harvested", cycle.harvested),
                            )
                        }
                    })
                    .apply { record.note?.let { put("note", it) } },
            )
        }
    }

    private fun encodeCrops(crops: List<CropPreset>) = JSONArray().apply {
        crops.forEach { crop ->
            put(
                JSONObject()
                    .put("id", crop.id)
                    .put("name", crop.name)
                    .put("colorHex", crop.colorHex)
                    .put("minutes", crop.minutes),
            )
        }
    }

    private fun parseDate(value: Any): Long = when (value) {
        is Number -> ((value.toDouble() + 978_307_200.0) * 1000.0).toLong()
        is String -> runCatching { Instant.parse(value).toEpochMilli() }
            .recoverCatching { OffsetDateTime.parse(value).toInstant().toEpochMilli() }
            .getOrThrow()
        else -> error("无效的提醒时间")
    }

    // Match Foundation's JSONEncoder.DateEncodingStrategy.iso8601 format exactly:
    // whole seconds, UTC, and no fractional seconds.
    private fun isoDate(epochMillis: Long): String =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")
            .withZone(ZoneOffset.UTC)
            .format(Instant.ofEpochMilli(epochMillis).truncatedTo(ChronoUnit.SECONDS))

    private fun JSONArray?.toStringSet(): Set<String> {
        if (this == null) return emptySet()
        return (0 until length()).mapNotNull { index ->
            runCatching { getString(index) }.getOrNull()
        }.toSet()
    }
}
