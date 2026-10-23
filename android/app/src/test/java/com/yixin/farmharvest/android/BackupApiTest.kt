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

    @Test
    fun backupChannelsUseTheExpectedSharedAddresses() {
        assertTrue(BackupChannel.LAN.backupUrl == FarmStore.SOURCE_BACKUP_URL)
        assertTrue(
            BackupChannel.PUBLIC.backupUrl ==
                "https://testweb.yxgames.fun/buildManage/api/upload/FarmHarvest.json",
        )
    }

    @Test
    fun validatesThePublicUploadResponseDownloadAddress() {
        assertTrue(
            BackupApi.isAllowedBuildManagerDownloadUrl(
                "https://testweb.yxgames.fun/buildManage/api/upload/FarmHarvest.json",
            ),
        )
        assertFalse(
            BackupApi.isAllowedBuildManagerDownloadUrl(
                "https://evil.example/buildManage/api/upload/FarmHarvest.json",
            ),
        )
        assertFalse(
            BackupApi.isAllowedBuildManagerDownloadUrl(
                "https://testweb.yxgames.fun/buildManage/api/upload/another.json",
            ),
        )
        assertFalse(
            BackupApi.isAllowedBuildManagerDownloadUrl(
                "http://testweb.yxgames.fun/buildManage/api/upload/FarmHarvest.json",
            ),
        )
    }
}
