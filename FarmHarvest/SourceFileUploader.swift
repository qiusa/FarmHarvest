import Foundation

struct SourceUploadResult {
    var fileName: String
    var localPath: String
    var downloadURL: URL
    var size: Int
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
