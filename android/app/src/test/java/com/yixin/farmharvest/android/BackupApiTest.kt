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
    fun rejectsPlainHttpUrls() {
        assertFalse(BackupApi.isAllowedRemoteUrl("http://example.com/source/FarmHarvest.json"))
        assertFalse(BackupApi.isAllowedRemoteUrl("http://192.168.200.94:10023/source/FarmHarvest.json"))
        assertFalse(BackupApi.isAllowedRemoteUrl("https://user@example.com/backups/farm.json"))
    }

    @Test
    fun backupUsesTheExpectedPublicAddress() {
        assertTrue(
            FarmStore.BUILD_MANAGER_BACKUP_URL ==
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
