import Foundation

/// A loopback-only, read-only display protocol, independent of App Groups and Keychain.
public enum WidgetBridge {
    public static let port: UInt16 = 47924
    public static let maximumResponseBytes = 1_048_576

    public static func endpoint(port: UInt16 = port) -> URL {
        URL(string: "http://127.0.0.1:\(port)/v1/snapshot")!
    }

    public static func accepts(_ request: String, port: UInt16 = port) -> Bool {
        guard request.utf8.count <= 8192,
              let terminator = request.range(of: "\r\n\r\n"),
              terminator.upperBound == request.endIndex else { return false }
        // CRLF is one Swift Character, so do not trim the delimiter with dropLast(4).
        let lines = request[..<terminator.lowerBound].components(separatedBy: "\r\n")
        guard lines.first == "GET /v1/snapshot HTTP/1.1" else { return false }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":"),
                  !line.hasPrefix(" "), !line.hasPrefix("\t") else { return false }
            let name = String(line[..<separator]).lowercased()
            guard headers[name] == nil else { return false }
            headers[name] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        // The custom header prevents browser subresource reads; Origin/Host also reject rebinding.
        return (headers["host"] == "127.0.0.1:\(port)" || headers["host"] == "localhost:\(port)")
            && headers["x-deepseekbar-widget"] == "1"
            && headers["origin"] == nil
            && headers["transfer-encoding"] == nil
            && (headers["content-length"] == nil || headers["content-length"] == "0")
    }

    public static func decode(_ data: Data, now: Date = Date()) throws -> WidgetSnapshot {
        guard data.count <= maximumResponseBytes else { throw BridgeError.invalidResponse }
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        guard snapshot.version == WidgetSnapshot.currentVersion,
              snapshot.generatedAt <= now.addingTimeInterval(60) else { throw BridgeError.invalidResponse }
        return snapshot
    }

    public enum BridgeError: LocalizedError {
        case unavailable, invalidResponse

        public var errorDescription: String? {
            switch self {
            case .unavailable: return "无法连接主应用，请打开 DeepSeekBar。"
            case .invalidResponse: return "小组件数据无法识别，请更新并重新打开主应用。"
            }
        }
    }
}

public struct WidgetSnapshotClient: Sendable {
    public init() {}

    public func fetch(port: UInt16 = WidgetBridge.port) async throws -> WidgetSnapshot? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: WidgetBridge.endpoint(port: port))
        request.setValue("1", forHTTPHeaderField: "X-DeepSeekBar-Widget")
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw WidgetBridge.BridgeError.invalidResponse }
        if response.statusCode == 204 { return nil }
        guard response.statusCode == 200 else { throw WidgetBridge.BridgeError.unavailable }
        return try WidgetBridge.decode(data)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
