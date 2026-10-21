package com.yixin.farmharvest.android

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import android.content.Context
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FarmStoreImportTest {
    private val context: Context
        get() = ApplicationProvider.getApplicationContext()

    @Before
    fun clearLocalData() {
        context.getSharedPreferences("farm-harvest", Context.MODE_PRIVATE)
            .edit().clear().commit()
    }

    @After
    fun clearAfterTest() {
        clearLocalData()
    }

    @Test
    fun importsIosIso8601BackupAndLegacySingleCycleRecords() {
        val backup = """
            {
              "version": 1,
              "exportedAt": "2026-10-21T02:00:00Z",
              "records": [
                {
                  "id": "multi",
                  "name": "常规事项",
                  "colorHex": "7AC74F",
                  "minutes": 40,
                  "plantedAt": "2026-10-21T01:00:00Z",
                  "harvests": [
                    {"id": "cycle-1", "date": "2026-10-21T01:40:00Z", "harvested": true},
                    {"id": "cycle-2", "date": "2026-10-21T02:00:00Z", "harvested": false}
                  ],
                  "note": "测试备注"
                },
                {
                  "id": "legacy",
                  "name": "旧格式",
                  "colorHex": "FF8C42",
                  "minutes": 20,
                  "plantedAt": "2026-10-21T00:00:00Z",
                  "harvestAt": "2026-10-21T00:20:00Z",
                  "extraHarvests": ["2026-10-21T00:40:00Z"]
                }
              ],
              "customCrops": [
                {"id": "custom-1", "name": "自定义", "colorHex": "9B5DE5", "minutes": 25}
              ],
              "hiddenBuiltins": ["carrot"]
            }
        """.trimIndent().toByteArray()

        val summary = FarmStore.importBackup(context, backup, ImportMode.REPLACE)
        val records = FarmStore.loadRecords(context)

        assertEquals(2, summary.recordsTotal)
        assertEquals(2, records.size)
        assertEquals(2, records.first { it.id == "multi" }.harvests.size)
        assertTrue(records.first { it.id == "multi" }.harvests.first().harvested)
        assertEquals("测试备注", records.first { it.id == "multi" }.note)
        assertEquals(2, records.first { it.id == "legacy" }.harvests.size)
        assertEquals(1, FarmStore.loadCustomCrops(context).size)
        assertTrue(FarmStore.presets(context).none { it.id == "carrot" })
    }

    @Test
    fun mergeKeepsLocalOnlyRecordsAndOverwritesMatchingIds() {
        val preset = CropPreset("carrot", "快速事项", "FF8C42", 20)
        val imported = FarmStore.addRecord(context, preset, 20, "from backup", 1_800_000_000_000L)
        val backup = FarmStore.exportBackup(context, 1_800_000_000_100L)
        val localOnly = FarmStore.addRecord(context, preset, 30, "local only", 1_800_000_010_000L)

        val summary = FarmStore.importBackup(context, backup, ImportMode.MERGE)
        val merged = FarmStore.loadRecords(context)

        assertEquals(1, summary.recordsOverwritten)
        assertTrue(merged.any { it.id == imported.id && it.note == "from backup" })
        assertTrue(merged.any { it.id == localOnly.id })
    }
}
