import Foundation

struct SourceUploadResult {
    var fileName: String
    var localPath: String
    var downloadURL: URL
    var size: Int
}

struct BuildManagerUploadResult {
    var fileName: String
    var downloadURL: URL
    var size: Int
}

/// Client for the production build-management server's fixed-token upload API.
enum BuildManagerBackupUploader {
    private static let host = "testweb.yxgames.fun"
    private static let downloadPath = "/buildManage/api/upload/FarmHarvest.json"
    static let endpointString = "https://\(host)/buildManage/api/upload"
    /// 服务端覆盖同名文件，所以这个固定地址上永远是最新一份备份。
    static let backupURLString = "https://\(host)\(downloadPath)"
    private static let uploadToken = "50a883b7dff6e662e6a7bcd10f8d7b6733234dee9d53410b90c203a97c629623"
    private static let fixedFileName = "FarmHarvest.json"

    private struct SuccessResponse: Decodable {
        var fileName: String
        var size: Int
        var downloadUrl: String
    }

    private struct ErrorResponse: Decodable {
        var error: String?
    }

    static func uploadBackup(data: Data) async throws -> BuildManagerUploadResult {
        guard let endpoint = URL(string: endpointString) else {
            throw uploadError("上传地址无效。")
        }

        let boundary = "FarmHarvest-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fixedFileName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/json; charset=utf-8\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(uploadToken, forHTTPHeaderField: "x-upload-token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (responseData, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw uploadError("上传服务器没有返回有效的 HTTP 响应。")
        }
        guard httpResponse.statusCode == 201 else {
            let payload = try? JSONDecoder().decode(ErrorResponse.self, from: responseData)
            throw uploadError(failureMessage(status: httpResponse.statusCode, detail: payload?.error))
        }

        let payload: SuccessResponse
        do {
            payload = try JSONDecoder().decode(SuccessResponse.self, from: responseData)
        } catch {
            throw uploadError("服务器已接收文件，但返回内容无法识别。")
        }
        guard let downloadURL = validatedDownloadURL(payload.downloadUrl) else {
            throw uploadError("文件已上传，但服务器返回的下载地址无效。")
        }

        return BuildManagerUploadResult(
            fileName: payload.fileName,
            downloadURL: downloadURL,
            size: payload.size
        )
    }

    private static func validatedDownloadURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == host,
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path == downloadPath else {
            return nil
        }
        return url
    }

    private static func failureMessage(status: Int, detail: String?) -> String {
        if let detail, !detail.isEmpty {
            return "上传失败：\(detail)"
        }
        let message: String
        switch status {
        case 400: message = "上传参数不合法。"
        case 401: message = "上传令牌无效，请核对服务端配置。"
        case 404: message = "生产环境上传接口不存在。"
        case 413: message = "备份文件超过服务器允许的 2 MiB 大小。"
        case 415: message = "服务器不接受当前文件格式。"
        case 503: message = "生产服务尚未配置 SERVER_UPLOAD_TOKEN，上传接口当前未启用。"
        default: message = "服务器返回 HTTP \(status)。"
        }
        return "上传失败：\(message)"
    }

    private static func uploadError(_ message: String) -> NSError {
        NSError(domain: "FarmHarvest.BuildManagerUpload", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}

/// Source-file API client. This source is included in the Mac and iOS apps,
/// but intentionally not in the widget extension.
enum SourceFileUploader {
    private static let endpointString = "http://192.168.200.94:3211/api/source-files"
    private static let uploadToken = "93c294dc9066ad5fce4e35ad4dc008a7a87feef0465d8af7"
    private static let fixedFileName = "FarmHarvest.json"
    private static let downloadHost = "192.168.200.94"
    private static let downloadPort = 10023

    private struct SuccessResponse: Decodable {
        var fileName: String
        var localPath: String
        var url: String?
        var size: Int
    }

    private struct ErrorResponse: Decodable {
        var error: String?
    }

    static func uploadBackup(data: Data) async throws -> SourceUploadResult {
        guard let endpoint = URL(string: endpointString) else {
            throw uploadError("上传地址无效。")
        }

        let boundary = "FarmHarvest-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fixedFileName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/json; charset=utf-8\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(uploadToken, forHTTPHeaderField: "x-upload-token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (responseData, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw uploadError("上传服务器没有返回有效的 HTTP 响应。")
        }
        guard httpResponse.statusCode == 201 else {
            let payload = try? JSONDecoder().decode(ErrorResponse.self, from: responseData)
            throw uploadError(failureMessage(status: httpResponse.statusCode, detail: payload?.error))
        }

        let payload: SuccessResponse
        do {
            payload = try JSONDecoder().decode(SuccessResponse.self, from: responseData)
        } catch {
            throw uploadError("服务器已接收文件，但返回内容无法识别。")
        }
        guard let downloadURL = validatedDownloadURL(responseURL: payload.url, localPath: payload.localPath) else {
            throw uploadError("文件已上传，但服务器返回的下载地址无效。")
        }
        return SourceUploadResult(
            fileName: payload.fileName,
            localPath: payload.localPath,
            downloadURL: downloadURL,
            size: payload.size
        )
    }

    private static func validatedDownloadURL(responseURL: String?, localPath: String) -> URL? {
        if let responseURL,
           let url = URL(string: responseURL),
           isAllowedDownloadURL(url) {
            return url
        }

        let components = localPath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "source",
              !components[1].isEmpty,
              components[1] != ".",
              components[1] != "..",
              !components[1].contains("\\") else {
            return nil
        }

        var urlComponents = URLComponents()
        urlComponents.scheme = "http"
        urlComponents.host = downloadHost
        urlComponents.port = downloadPort
        urlComponents.path = "/\(localPath)"
        guard let url = urlComponents.url, isAllowedDownloadURL(url) else { return nil }
        return url
    }

    private static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              url.host?.lowercased() == downloadHost,
              url.port == downloadPort,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        return components.count == 2
            && components[0] == "source"
            && components[1] != "."
            && components[1] != ".."
            && !components[1].contains("\\")
    }

    private static func failureMessage(status: Int, detail: String?) -> String {
        if let detail, !detail.isEmpty {
            return "上传失败：\(detail)"
        }
        let message: String
        switch status {
        case 400: message = "文件名或上传参数不合法。"
        case 401: message = "上传令牌无效，请核对服务端配置。"
        case 404: message = "上传接口不存在，请联系管理员检查服务版本。"
        case 408: message = "上传超时或传输中断，请检查网络后重试。"
        case 413: message = "备份文件超过服务器允许的大小。"
        case 415: message = "服务器不接受当前文件格式。"
        case 429: message = "上传服务繁忙，请稍后重试。"
        case 503: message = "上传服务尚未配置令牌或未启用。"
        default: message = "服务器返回 HTTP \(status)。"
        }
        return "上传失败：\(message)"
    }

    private static func uploadError(_ message: String) -> NSError {
        NSError(domain: "FarmHarvest.SourceUpload", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}

/// 备份同步通道。两条通道语义一致：上传覆盖固定地址上的那一份，导入从同一地址下载。
/// 只被 Mac 与 iOS 主 App 编译，Widget 不含此文件。
enum BackupChannel: String, CaseIterable, Identifiable {
    case lan = "局域网"
    case wan = "公网"

    var id: String { rawValue }

    /// 备份所在的固定地址：上传写入它，导入也从它读取。
    var backupURLString: String {
        switch self {
        case .lan: return CropStore.sourceBackupURLString
        case .wan: return BuildManagerBackupUploader.backupURLString
        }
    }

    var summary: String {
        switch self {
        case .lan: return "走自建共享目录，同一局域网内的 Mac 与 iPhone 互传最快；离开这个网络就连不上。"
        case .wan: return "走公网 HTTPS，任何网络都能存取；服务器上只保留最新一份备份。"
        }
    }

    var icon: String {
        switch self {
        case .lan: return "wifi"
        case .wan: return "globe"
        }
    }

    /// 导入前的可达性提示
    var reachabilityHint: String {
        switch self {
        case .lan: return "需与共享目录在同一局域网"
        case .wan: return "任何网络均可下载"
        }
    }
}
