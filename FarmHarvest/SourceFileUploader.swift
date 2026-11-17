import Foundation

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