package com.yixin.farmharvest.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoSyncMergeTest {
    private fun record(
        id: String,
        name: String = id,
        plantedAt: Long = 1_000L,
        note: String? = null,
        minutes: Int = 30,
    ) = CropRecord(
        id = id,
        name = name,
        colorHex = "7AC74F",
        minutes = minutes,
        plantedAt = plantedAt,
        harvests = listOf(HarvestCycle(id = "$id-c1", date = plantedAt + 60_000L)),
        note = note,
    )

    private fun preset(id: String, name: String = id) =
        CropPreset(id = id, name = name, colorHex = "FF8C42", minutes = 20)

    private fun backup(
        records: List<CropRecord>,
        crops: List<CropPreset> = emptyList(),
        hidden: Set<String> = emptySet(),
        exportedAt: Long = 1_000L,
    ) = SyncBackup(exportedAt, records, crops, hidden)

    @Test
    fun firstRunMarksAllExistingLocalDataDirty() {
        val state = initialSyncState(
            listOf(record("a"), record("b")),
            listOf(preset("c1")),
            setOf("carrot"),
        )
        assertEquals(setOf("a", "b"), state.dirtyRecordIDs)
        assertTrue(state.customCropsDirty)
        assertTrue(state.hiddenBuiltinsDirty)
        assertEquals(0, state.revision)
    }

    @Test
    fun firstRunWithEmptyLocalMarksNothingDirty() {
        val state = initialSyncState(emptyList(), emptyList(), emptySet())
        assertTrue(state.dirtyRecordIDs.isEmpty())
        assertFalse(state.customCropsDirty)
        assertFalse(state.hiddenBuiltinsDirty)
    }

    @Test
    fun dirtyRecordWinsOverServerVersion() {
        val base = backup(listOf(record("a", note = "server")))
        val local = backup(listOf(record("a", note = "local")))
        val merged = mergeBackup(base, local, SyncChangeState(dirtyRecordIDs = setOf("a")))
        assertEquals("local", merged.records.single().note)
    }

    @Test
    fun dirtyTombstoneRemovesServerRecord() {
        val base = backup(listOf(record("a"), record("b")))
        val local = backup(listOf(record("b")))
        val merged = mergeBackup(base, local, SyncChangeState(dirtyRecordIDs = setOf("a")))
        assertEquals(listOf("b"), merged.records.map { it.id })
    }

    @Test
    fun nonDirtyRecordFollowsServerUpdate() {
        val base = backup(listOf(record("a", note = "server-new")))
        val local = backup(listOf(record("a", note = "local-old")))
        val merged = mergeBackup(base, local, SyncChangeState())
        assertEquals("server-new", merged.records.single().note)
    }

    @Test
    fun nonDirtyRecordAbsentOnServerIsDeletedLocally() {
        val base = backup(listOf(record("b")))
        val local = backup(listOf(record("a"), record("b")))
        val merged = mergeBackup(base, local, SyncChangeState())
        assertEquals(listOf("b"), merged.records.map { it.id })
    }

    @Test
    fun cropsAndHiddenFollowTheirDirtyFlags() {
        val base = backup(emptyList(), listOf(preset("server-crop")), setOf("carrot"))
        val local = backup(emptyList(), listOf(preset("local-crop")), setOf("tomato"))
        val clean = mergeBackup(base, local, SyncChangeState())
        assertEquals(listOf("server-crop"), clean.customCrops.map { it.id })
        assertEquals(setOf("carrot"), clean.hiddenBuiltins)
        val dirty = mergeBackup(
            base,
            local,
            SyncChangeState(customCropsDirty = true, hiddenBuiltinsDirty = true),
        )
        assertEquals(listOf("local-crop"), dirty.customCrops.map { it.id })
        assertEquals(setOf("tomato"), dirty.hiddenBuiltins)
    }

    @Test
    fun mergedRecordsSortByPlantedAtDescending() {
        val base = backup(listOf(record("old", plantedAt = 10), record("new", plantedAt = 90)))
        val local = backup(listOf(record("mid", plantedAt = 50)))
        val merged = mergeBackup(base, local, SyncChangeState(dirtyRecordIDs = setOf("mid")))
        assertEquals(listOf("new", "mid", "old"), merged.records.map { it.id })
    }

    @Test
    fun unchangedSaveDoesNotBumpRevisionOrDirty() {
        val records = listOf(record("a"))
        val state = SyncChangeState(revision = 3, dirtyRecordIDs = setOf("x"))
        assertNull(trackedRecordSave(state, records, records))
    }

    @Test
    fun changedAndRemovedRecordsBecomeDirty() {
        val old = listOf(record("a"), record("b"), record("c"))
        val new = listOf(record("a", note = "edited"), record("c"))
        val state = SyncChangeState(revision = 3)
        val next = trackedRecordSave(state, old, new)!!
        assertEquals(setOf("a", "b"), next.dirtyRecordIDs)
        assertEquals(4, next.revision)
    }

    @Test
    fun clearOnlyAppliesToMatchingRevision() {
        val state = SyncChangeState(revision = 5, dirtyRecordIDs = setOf("a"), customCropsDirty = true)
        assertNull(clearedSyncChanges(state, 4))
        val cleared = clearedSyncChanges(state, 5)!!
        assertTrue(cleared.dirtyRecordIDs.isEmpty())
        assertFalse(cleared.customCropsDirty)
        assertEquals(5, cleared.revision)
    }

    @Test
    fun sameContentIgnoresOrderAndExportedAt() {
        val a = backup(listOf(record("a"), record("b")), listOf(preset("c")), exportedAt = 1)
        val b = backup(listOf(record("b"), record("a")), listOf(preset("c")), exportedAt = 999)
        assertTrue(sameContent(a, b))
    }

    @Test
    fun sameContentDetectsFieldChanges() {
        val a = backup(listOf(record("a", note = "x")))
        val b = backup(listOf(record("a", note = "y")))
        assertFalse(sameContent(a, b))
        assertFalse(sameContent(a, backup(listOf(record("a", minutes = 45)))))
    }

    @Test
    fun reseedMergeOfLocalOverItselfKeepsLocalContent() {
        val local = backup(listOf(record("a"), record("b")), listOf(preset("c")), setOf("carrot"))
        val state = initialSyncState(local.records, local.customCrops, local.hiddenBuiltins)
        val merged = mergeBackup(local, local, state)
        assertTrue(sameContent(merged, local))
    }
}