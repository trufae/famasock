import Foundation

struct CoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Registers every caller before accessing the pointer; shutdown joins them all.
final class DesktopCore: @unchecked Sendable {
    static let version = String(cString: famasock_version()!)
    static var statePath: String {
        ProcessInfo.processInfo.environment["FAMASOCK_STATE"] ??
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Famasock").path
    }
    static var cryptoInfo: [String: Any] {
        guard let raw = famasock_crypto_info() else { return [:] }
        defer { famasock_string_free(raw) }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8))) as? [String: Any] ?? [:]
    }
    private let handle: OpaquePointer
    private let lock = NSLock()
    private let calls = DispatchGroup()
    private var closing = false

    init(path: String = DesktopCore.statePath, name: String = "Mac") throws {
        var error: UnsafeMutablePointer<CChar>?
        let pointer = path.withCString { path in
            name.withCString { famasock_open_desktop(path, $0, &error) }
        }
        guard let pointer else {
            defer { famasock_string_free(error) }
            let raw = error.map { String(cString: $0) } ?? "Cannot start networking"
            let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            throw CoreError(message: value?["error"] as? String ?? raw)
        }
        handle = pointer
    }
    private func enter() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closing else { throw CoreError(message: "Networking is stopped") }
        calls.enter()
    }
    func command(_ value: [String: Any]) throws -> [String: Any] {
        try enter(); defer { calls.leave() }
        let bytes = try JSONSerialization.data(withJSONObject: value)
        let raw = String(decoding: bytes, as: UTF8.self).withCString { famasock_command(handle, $0) }
        defer { famasock_string_free(raw) }
        guard let raw,
              let result = try JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any] else {
            throw CoreError(message: "Invalid core response")
        }
        if let error = result["error"] as? String { throw CoreError(message: error) }
        return result["data"] as? [String: Any] ?? ["value": result["data"] ?? NSNull()]
    }
    func events(_ receive: @escaping @Sendable ([String: Any]) -> Void) {
        do { try enter() } catch { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { calls.leave() }
            while let raw = famasock_next_event(handle) {
                let data = Data(String(cString: raw).utf8)
                famasock_string_free(raw)
                if let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { receive(event) }
            }
        }
    }
    /// Off the UI thread; no caller can enter once closing begins.
    func close() {
        lock.lock()
        if closing { lock.unlock(); return }
        closing = true; lock.unlock()
        famasock_shutdown(handle)
        calls.wait()
        famasock_free(handle)
    }
}
