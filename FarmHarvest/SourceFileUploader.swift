import Foundation
import Security

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

/// Stores the production upload token in the platform Keychain rather than in
/// app preferences or the source tree.
enum BuildManagerUploadCredentialStore {
    private static let service = "com.yixin.farmharvest.build-manager-upload"
    private static let account = "server-upload-token"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(key as CFDictionary, [
            kSecValueData as String: data
        ] as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = key
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw keychainError(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw keychainError(updateStatus)
        }
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "无法安全保存上传令牌（Keychain 错误 \(status)）。"
        ])
    }
}

/// Client for the production build-management server's fixed-token upload API.
enum BuildManagerBackupUploader {
    static let endpointString = "https://testweb.yxgames.fun/buildManage/api/upload"

    private struct SuccessResponse: Decodable {
        var fileName: String
        var size: Int
        var downloadUrl: String
    }

    private struct ErrorResponse: Decodable {
        var error: String?
    }

    static func uploadBackup(data: Data, token: String) async throws -> BuildManagerUploadResult {
        guard !token.isEmpty, let endpoint = URL(string: endpointString) else {
            throw uploadError("上传地址或上传令牌无效。")
        }

        let boundary = "FarmHarvest-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"FarmHarvest.json\"\r\n".utf8))
        body.append(Data("Content-Type: application/json; charset=utf-8\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "x-upload-token")
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
              components.host?.lowercased() == "testweb.yxgames.fun",
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        let pathPrefix = "/buildManage/api/upload/"
        guard components.path.hasPrefix(pathPrefix) else { return nil }
        let fileName = String(components.path.dropFirst(pathPrefix.count))
        let uuidFileNamePattern = #"^[\da-f]{8}-[\da-f]{4}-4[\da-f]{3}-[89ab][\da-f]{3}-[\da-f]{12}\.json$"#
        return fileName.range(of: uuidFileNamePattern, options: [.regularExpression, .caseInsensitive]) == nil
            ? nil
            : url
    }

    private static func failureMessage(status: Int, detail: String?) -> String {
        if let detail, !detail.isEmpty {
            return "上传失败：\(detail)"
        }
        let message: String
        switch status {
        case 400: message = "上传参数不合法。"
        case 401: message = "上传令牌无效，请核对管理员提供的令牌。"
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
