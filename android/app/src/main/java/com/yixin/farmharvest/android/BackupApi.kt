package com.yixin.farmharvest.android

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID

data class UploadResult(
    val fileName: String,
    val downloadUrl: String,
    val size: Int,
)

sealed class FetchResult {
    data class Ok(val backup: SyncBackup) : FetchResult()
    object NotFound : FetchResult()
    object Failed : FetchResult()
}

object BackupApi {
    private const val MAX_BACKUP_BYTES = 10 * 1024 * 1024
    private const val BUILD_MANAGER_HOST = "testweb.yxgames.fun"
    private const val BUILD_MANAGER_UPLOAD_ENDPOINT =
        "https://testweb.yxgames.fun/buildManage/api/upload"
    private const val BUILD_MANAGER_DOWNLOAD_PATH =
        "/buildManage/api/upload/FarmHarvest.json"
    private const val BUILD_MANAGER_UPLOAD_TOKEN =
        "50a883b7dff6e662e6a7bcd10f8d7b6733234dee9d53410b90c203a97c629623"

    fun isAllowedRemoteUrl(value: String): Boolean = runCatching {
        val uri = URI(value.trim())
        uri.scheme?.lowercase() == "https" && uri.userInfo == null
    }.getOrDefault(false)

    fun downloadBackup(value: String): ByteArray {
        require(isAllowedRemoteUrl(value)) {
            "请输入有效的 HTTPS 地址。"
        }
        val original = URI(value.trim())
        val requestUrl = if (original.host.equals("qiniu.yixin.im", ignoreCase = true)) {
            val separator = if (original.rawQuery == null) "?" else "&"
            URL(value.trim() + separator + "_farmharvest_refresh=" + UUID.randomUUID())
        } else {
            URL(value.trim())
        }
        val connection = (requestUrl.openConnection() as HttpURLConnection).apply {
            connectTimeout = 30_000
            readTimeout = 30_000
            instanceFollowRedirects = true
            useCaches = false
            setRequestProperty("Accept", "application/json")
            setRequestProperty("Cache-Control", "no-cache")
        }
        return try {
            val status = connection.responseCode
            if (status !in 200..299) error("远程服务器返回 HTTP $status。")
            connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                var total = 0
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > MAX_BACKUP_BYTES) error("备份文件超过 10 MB，已取消导入。")
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        } finally {
            connection.disconnect()
        }
    }

    fun fetchBackup(): FetchResult {
        return runCatching {
            val connection = (URL(FarmStore.BUILD_MANAGER_BACKUP_URL).openConnection() as HttpURLConnection).apply {
                connectTimeout = 30_000
                readTimeout = 30_000
                instanceFollowRedirects = true
                useCaches = false
                setRequestProperty("Accept", "application/json")
                setRequestProperty("Cache-Control", "no-cache")
            }
            try {
                val status = connection.responseCode
                if (status == 404) return FetchResult.NotFound
                if (status !in 200..299) return FetchResult.Failed
                val bytes = connection.inputStream.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    var total = 0
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_BACKUP_BYTES) error("备份文件超过 10 MB。")
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
                FetchResult.Ok(FarmStore.parseBackup(bytes))
            } finally {
                connection.disconnect()
            }
        }.getOrElse { FetchResult.Failed }
    }

    fun uploadBackup(bytes: ByteArray): UploadResult {
        val boundary = "FarmHarvest-${UUID.randomUUID()}"
        val connection = (URL(BUILD_MANAGER_UPLOAD_ENDPOINT).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 30_000
            readTimeout = 60_000
            doOutput = true
            setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
            setRequestProperty("x-upload-token", BUILD_MANAGER_UPLOAD_TOKEN)
            setRequestProperty("Accept", "application/json")
        }
        try {
            connection.outputStream.use { output ->
                output.write("--$boundary\r\n".toByteArray())
                output.write(
                    "Content-Disposition: form-data; name=\"file\"; filename=\"${FarmStore.SOURCE_BACKUP_FILE_NAME}\"\r\n"
                        .toByteArray(),
                )
                output.write("Content-Type: application/json; charset=utf-8\r\n\r\n".toByteArray())
                output.write(bytes)
                output.write("\r\n--$boundary--\r\n".toByteArray())
            }

            val status = connection.responseCode
            val responseStream = if (status in 200..299) connection.inputStream else connection.errorStream
            val responseText = responseStream?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (status != 201) {
                val detail = runCatching { JSONObject(responseText).optString("error") }
                    .getOrNull()
                    .orEmpty()
                throw IllegalStateException(uploadFailure(status, detail))
            }

            val payload = runCatching { JSONObject(responseText) }
                .getOrElse { throw IllegalStateException("服务器已接收文件，但返回内容无法识别。") }
            val fileName = payload.optString("fileName")
            val downloadUrl = payload.optString("downloadUrl")
            if (fileName.isBlank() || !isAllowedBuildManagerDownloadUrl(downloadUrl)) {
                throw IllegalStateException("文件已上传，但服务器返回的下载地址无效。")
            }
            return UploadResult(
                fileName = fileName,
                downloadUrl = downloadUrl,
                size = payload.optInt("size", bytes.size),
            )
        } finally {
            connection.disconnect()
        }
    }

    internal fun isAllowedBuildManagerDownloadUrl(value: String): Boolean = runCatching {
        val uri = URI(value)
        uri.scheme.equals("https", ignoreCase = true) &&
            uri.host.equals(BUILD_MANAGER_HOST, ignoreCase = true) &&
            (uri.port == -1 || uri.port == 443) &&
            uri.userInfo == null &&
            uri.rawQuery == null &&
            uri.rawFragment == null &&
            uri.path == BUILD_MANAGER_DOWNLOAD_PATH
    }.getOrDefault(false)

    private fun uploadFailure(status: Int, detail: String): String {
        if (detail.isNotBlank()) return "上传失败：$detail"
        val message = when (status) {
            400 -> "上传参数不合法。"
            401 -> "上传令牌无效，请核对服务端配置。"
            404 -> "公网上传接口不存在。"
            413 -> "备份文件超过服务器允许的 2 MiB 大小。"
            415 -> "服务器不接受当前文件格式。"
            503 -> "公网服务尚未配置上传令牌，上传接口当前未启用。"
            else -> "服务器返回 HTTP $status。"
        }
        return "上传失败：$message"
    }
}