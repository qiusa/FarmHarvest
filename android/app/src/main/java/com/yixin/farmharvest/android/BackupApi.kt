package com.yixin.farmharvest.android

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID

data class SourceUploadResult(
    val fileName: String,
    val localPath: String,
    val downloadUrl: String,
    val size: Int,
)

enum class BackupChannel(
    val label: String,
    val backupUrl: String,
    val description: String,
    val reachabilityHint: String,
) {
    LAN(
        label = "局域网",
        backupUrl = FarmStore.SOURCE_BACKUP_URL,
        description = "走自建共享目录，同一局域网内的设备互传；离开这个网络就连不上。",
        reachabilityHint = "需与共享目录在同一局域网",
    ),
    PUBLIC(
        label = "公网",
        backupUrl = FarmStore.BUILD_MANAGER_BACKUP_URL,
        description = "走公网 HTTPS，任何网络都能存取；服务器上只保留最新一份备份。",
        reachabilityHint = "任何网络均可下载",
    ),
}

object BackupApi {
    private const val MAX_BACKUP_BYTES = 10 * 1024 * 1024
    private const val DOWNLOAD_HOST = "192.168.200.94"
    private const val DOWNLOAD_PORT = 10023
    private const val BUILD_MANAGER_HOST = "testweb.yxgames.fun"
    private const val BUILD_MANAGER_UPLOAD_ENDPOINT =
        "https://testweb.yxgames.fun/buildManage/api/upload"
    private const val BUILD_MANAGER_DOWNLOAD_PATH =
        "/buildManage/api/upload/FarmHarvest.json"
    private const val BUILD_MANAGER_UPLOAD_TOKEN =
        "50a883b7dff6e662e6a7bcd10f8d7b6733234dee9d53410b90c203a97c629623"

    fun isAllowedRemoteUrl(value: String): Boolean = runCatching {
        val uri = URI(value.trim())
        val scheme = uri.scheme?.lowercase() ?: return false
        val host = uri.host?.lowercase() ?: return false
        when {
            scheme == "https" -> uri.userInfo == null
            scheme == "http" &&
                host == DOWNLOAD_HOST &&
                uri.port == DOWNLOAD_PORT &&
                uri.userInfo == null &&
                uri.rawQuery == null &&
                uri.rawFragment == null -> {
                val parts = uri.path.split('/').filter(String::isNotEmpty)
                parts.size == 2 && parts[0] == "source" &&
                    parts[1] != "." && parts[1] != ".." && '\\' !in parts[1]
            }
            else -> false
        }
    }.getOrDefault(false)

    fun downloadBackup(value: String): ByteArray {
        require(isAllowedRemoteUrl(value)) {
            "请输入有效的 HTTPS 地址，或上传接口返回的局域网下载地址。"
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

    fun uploadBackup(bytes: ByteArray): SourceUploadResult {
        return uploadLanBackup(bytes)
    }

    fun uploadBackup(bytes: ByteArray, channel: BackupChannel): SourceUploadResult =
        when (channel) {
            BackupChannel.LAN -> uploadLanBackup(bytes)
            BackupChannel.PUBLIC -> uploadPublicBackup(bytes)
        }

    private fun uploadLanBackup(bytes: ByteArray): SourceUploadResult {
        val boundary = "FarmHarvest-${UUID.randomUUID()}"
        val connection = (URL(FarmStore.UPLOAD_ENDPOINT).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 30_000
            readTimeout = 600_000
            doOutput = true
            setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
            setRequestProperty("x-upload-token", FarmStore.UPLOAD_TOKEN)
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
            val localPath = payload.optString("localPath")
            val downloadUrl = validatedDownloadUrl(payload.optString("url").takeIf(String::isNotBlank), localPath)
                ?: throw IllegalStateException("文件已上传，但服务器返回的下载地址无效。")
            return SourceUploadResult(
                fileName = fileName,
                localPath = localPath,
                downloadUrl = downloadUrl,
                size = payload.optInt("size", bytes.size),
            )
        } finally {
            connection.disconnect()
        }
    }

    private fun uploadPublicBackup(bytes: ByteArray): SourceUploadResult {
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
                throw IllegalStateException(publicUploadFailure(status, detail))
            }

            val payload = runCatching { JSONObject(responseText) }
                .getOrElse { throw IllegalStateException("服务器已接收文件，但返回内容无法识别。") }
            val fileName = payload.optString("fileName")
            val downloadUrl = payload.optString("downloadUrl")
            if (fileName.isBlank() || !isAllowedBuildManagerDownloadUrl(downloadUrl)) {
                throw IllegalStateException("文件已上传，但服务器返回的下载地址无效。")
            }
            return SourceUploadResult(
                fileName = fileName,
                localPath = BUILD_MANAGER_DOWNLOAD_PATH,
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

    private fun validatedDownloadUrl(responseUrl: String?, localPath: String): String? {
        if (responseUrl != null && isAllowedLocalDownloadUrl(responseUrl)) return responseUrl
        val parts = localPath.split('/')
        if (parts.size != 2 || parts[0] != "source" ||
            parts[1].isBlank() || parts[1] == "." || parts[1] == ".." || '\\' in parts[1]
        ) return null
        return "http://$DOWNLOAD_HOST:$DOWNLOAD_PORT/$localPath"
            .takeIf(::isAllowedLocalDownloadUrl)
    }

    private fun isAllowedLocalDownloadUrl(value: String): Boolean = runCatching {
        val uri = URI(value)
        uri.scheme.equals("http", ignoreCase = true) &&
            uri.host.equals(DOWNLOAD_HOST, ignoreCase = true) &&
            uri.port == DOWNLOAD_PORT &&
            uri.userInfo == null &&
            uri.rawQuery == null &&
            uri.rawFragment == null &&
            uri.path.split('/').filter(String::isNotEmpty).let { parts ->
                parts.size == 2 && parts[0] == "source" &&
                    parts[1] != "." && parts[1] != ".." && '\\' !in parts[1]
            }
    }.getOrDefault(false)

    private fun uploadFailure(status: Int, detail: String): String {
        if (detail.isNotBlank()) return "上传失败：$detail"
        val message = when (status) {
            400 -> "文件名或上传参数不合法。"
            401 -> "上传令牌无效，请核对服务端配置。"
            404 -> "上传接口不存在，请联系管理员检查服务版本。"
            408 -> "上传超时或传输中断，请检查网络后重试。"
            413 -> "备份文件超过服务器允许的大小。"
            415 -> "服务器不接受当前文件格式。"
            429 -> "上传服务繁忙，请稍后重试。"
            503 -> "上传服务尚未配置令牌或未启用。"
            else -> "服务器返回 HTTP $status。"
        }
        return "上传失败：$message"
    }

    private fun publicUploadFailure(status: Int, detail: String): String {
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
