import DeepSeekBarWidgetBridge
import DeepSeekBarWidgetShared
import Foundation

private final class BridgeStartResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<UInt16, WidgetBridge.BridgeError>?
    private let semaphore = DispatchSemaphore(value: 0)

    func receive(_ value: Result<UInt16, WidgetBridge.BridgeError>) {
        lock.lock()
        let first = result == nil
        if first { result = value }
        lock.unlock()
        if first { semaphore.signal() }
    }

    func wait() -> Result<UInt16, WidgetBridge.BridgeError>? {
        guard semaphore.wait(timeout: .now() + 6) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

func runWidgetBridgeTests() {
    print("▶ 本机 HTTP 小组件集成测试（不访问外网、不读取凭据）")
    let server = WidgetSnapshotServer(port: 0)
    let started = BridgeStartResult()
    server.start { started.receive($0) }
    guard case .success(let port) = started.wait() else {
        check(false, "本机回环服务启动")
        server.stop()
        return
    }
    check(true, "绑定 127.0.0.1 随机端口")
    defer { server.stop() }
    let completed = DispatchSemaphore(value: 0)
    Task.detached {
        defer { completed.signal() }
        do {
            let client = WidgetSnapshotClient()
            check(try await client.fetch(port: port) == nil, "首次刷新前返回空状态")
            let snapshot = WidgetSnapshot.preview()
            await withCheckedContinuation { continuation in
                server.publish(snapshot) { continuation.resume() }
            }
            check(try await client.fetch(port: port) == snapshot, "原生客户端取得服务端最新展示快照")

            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 3
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: WidgetBridge.endpoint(port: port))
            request.setValue("1", forHTTPHeaderField: "X-DeepSeekBar-Widget")
            request.setValue("https://example.com", forHTTPHeaderField: "Origin")
            let (forbidden, response) = try await session.data(for: request)
            check((response as? HTTPURLResponse)?.statusCode == 403 && forbidden.isEmpty,
                  "跨源请求被拒绝且不泄漏快照")

            let cleared = WidgetSnapshot()
            await withCheckedContinuation { continuation in
                server.publish(cleared) { continuation.resume() }
            }
            let value = try await client.fetch(port: port)
            check(value?.balance == nil && value?.usage == nil && value?.usageState == .needsSetup,
                  "清除操作使下一次请求立即看不到旧账户数据")

            let competing = WidgetSnapshotServer(port: port)
            let collision = BridgeStartResult()
            competing.start { collision.receive($0) }
            if case .failure = collision.wait() { check(true, "重复实例报告端口占用") }
            else { check(false, "重复实例应该报告端口占用") }
            competing.stop()

            await withCheckedContinuation { continuation in
                server.stop { continuation.resume() }
            }
            do {
                _ = try await client.fetch(port: port)
                check(false, "主应用退出后不应读到缓存响应")
            } catch { check(true, "服务退出后返回不可用，不复用 HTTP 缓存") }
        } catch {
            check(false, "本机通信集成测试", error.localizedDescription)
        }
    }
    check(completed.wait(timeout: .now() + 25) == .success, "本机集成测试按时完成")
}
