package com.yixin.farmharvest.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupApiTest {
    @Test
    fun allowsHttpsBackupUrls() {
        assertTrue(BackupApi.isAllowedRemoteUrl("https://example.com/backups/farm.json"))
        assertTrue(BackupApi.isAllowedRemoteUrl("https://example.com/backups/farm.json?token=abc"))
    }

    @Test
    fun onlyAllowsTheConfiguredLanHttpDownloadPath() {
        assertTrue(
            BackupApi.isAllowedRemoteUrl(
                "http://192.168.200.94:10023/source/FarmHarvest.json",
            ),
        )
        assertFalse(BackupApi.isAllowedRemoteUrl("http://example.com/source/FarmHarvest.json"))
        assertFalse(BackupApi.isAllowedRemoteUrl("http://192.168.200.94:3211/source/FarmHarvest.json"))
        assertFalse(BackupApi.isAllowedRemoteUrl("http://192.168.200.94:10023/other/file.json"))
        assertFalse(BackupApi.isAllowedRemoteUrl("http://user@192.168.200.94:10023/source/a.json"))
    }
}
