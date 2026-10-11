import Foundation
import Security
import UIKit

struct FamasockError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Owns the C handle and joins all in-flight calls before freeing it.
final class RustCore: @unchecked Sendable {
    static let version = String(cString: famasock_version())
    static let cryptoInfo: [String: Any] = {
        let raw = famasock_crypto_info()
        defer { famasock_string_free(raw) }
        let data = Data(String(cString: raw).utf8)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }()
    private let handle: OpaquePointer
    private let lock = NSLock()
    private let calls = DispatchGroup()
    private var closing = false

    static var stateURL: URL {
        get throws {
            guard let group = Bundle.main.object(forInfoDictionaryKey: "FamasockAppGroup") as? String,
                  let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                throw FamasockError(message: "App Group unavailable. Install an app signed with the Famasock entitlements.")
            }
            return root.appendingPathComponent("State", isDirectory: true)
        }
    }
    static func saveVPNError(_ message: String?) {
        guard let root = try? stateURL else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let value: [String: Any] = ["error": message ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: value) {
            try? data.write(to: root.appendingPathComponent("vpn-error.json"), options: .atomic)
        }
    }
    static var vpnError: String? {
        guard let root = try? stateURL, let data = try? Data(contentsOf: root.appendingPathComponent("vpn-error.json")),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = value["error"] as? String, !error.isEmpty else { return nil }
        return error
    }
    static func saveForwards(_ commands: [[String: Any]]) throws {
        let root = try stateURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: commands).write(to: root.appendingPathComponent("vpn-forwards.json"), options: .atomic)
    }
    static var savedForwards: [[String: Any]] {
        guard let root = try? stateURL, let data = try? Data(contentsOf: root.appendingPathComponent("vpn-forwards.json")),
              let commands = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return commands
    }
    private static func identity() throws -> Data {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FamasockKeychainGroup") as? String else {
            throw FamasockError(message: "Missing Keychain access group")
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Famasock identity", kSecAttrAccount as String: "iroh/1",
            kSecAttrAccessGroup as String: group]
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw FamasockError(message: "Keychain unavailable (\(status))") }
        var data = Data(count: 32)
        let randomStatus = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw FamasockError(message: "Cannot create identity") }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        if added == errSecDuplicateItem { return try identity() }
        guard added == errSecSuccess else { throw FamasockError(message: "Cannot save identity (\(added))") }
        return data
    }
    init() throws {
        let path = try Self.stateURL.path
        let key = try Self.identity()
        var error: UnsafeMutablePointer<CChar>?
        let pointer = key.withUnsafeBytes { bytes in
            path.withCString { path in
                // UIDevice.name can contain more than the protocol's 64-byte name limit.
                "iPhone".withCString { name in famasock_open(path, name, bytes.bindMemory(to: UInt8.self).baseAddress, &error) }
            }
        }
        guard let pointer else {
            let raw = error.map { String(cString: $0) } ?? "Cannot start networking"
            let detail = raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let message = detail?["error"] as? String ?? raw
            famasock_string_free(error)
            throw FamasockError(message: message)
        }
        handle = pointer
    }
    private func enter() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closing else { throw FamasockError(message: "Networking is stopped") }
        calls.enter()
    }
    func command(_ value: [String: Any]) throws -> [String: Any] {
        try enter(); defer { calls.leave() }
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let json = String(data: data, encoding: .utf8) else { throw FamasockError(message: "Invalid command") }
        let raw = json.withCString { famasock_command(handle, $0) }
        defer { famasock_string_free(raw) }
        guard let raw, let bytes = String(cString: raw).data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw FamasockError(message: "Invalid core response")
        }
        if let error = result["error"] as? String { throw FamasockError(message: error) }
        if let body = result["data"] as? [String: Any] { return body }
        return ["value": result["data"] ?? NSNull()]
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
    func sendPacket(session: String, data: Data) -> Bool {
        do { try enter() } catch { return false }
        defer { calls.leave() }
        return session.withCString { session in
            data.withUnsafeBytes { b in famasock_send_packet(handle, session, b.bindMemory(to: UInt8.self).baseAddress, data.count) == 0 }
        }
    }
    func receivePacket(session: String) -> Data? {
        do { try enter() } catch { return nil }
        defer { calls.leave() }
        var bytes = [UInt8](repeating: 0, count: 65_535)
        let count = session.withCString { id in
            bytes.withUnsafeMutableBufferPointer { buffer in
                famasock_receive_packet(handle, id, buffer.baseAddress, buffer.count)
            }
        }
        return count > 0 ? Data(bytes.prefix(Int(count))) : nil
    }
    /// Must run off the main thread. No new calls can enter after this point.
    func close() {
        lock.lock()
        if closing { lock.unlock(); return }
        closing = true; lock.unlock()
        famasock_shutdown(handle)
        calls.wait()
        famasock_free(handle)
    }
}
