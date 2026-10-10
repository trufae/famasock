import SwiftUI
import NetworkExtension

struct Peer: Identifiable {
    let id: String
    let name: String
    let device: String
    let connected: Bool
    let path: String?
    let policy: [String: Any]
    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
        self.id = id; self.name = name
        device = value["device"] as? String ?? "device"
        connected = value["connected"] as? Bool ?? false
        path = value["path"] as? String
        policy = value["policy"] as? [String: Any] ?? [:]
    }
}
struct Tunnel: Identifiable {
    let id: String
    let peer: String
    let kind: String
    let detail: String
}
@MainActor
final class Model: ObservableObject {
    @Published var peers: [Peer] = []
    @Published var tunnels: [Tunnel] = []
    @Published var error: String?
    @Published var ready = false
    @Published var pairing = false
    @Published var vpnStatus: NEVPNStatus = .invalid
    @Published var vpnStats = ""
    private var core: RustCore?
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var opening = false
    private var handoff = false
    private var foreground = true
    private var starting = false
    var vpnStatusText: String {
        switch vpnStatus {
        case .invalid: return "Not configured"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        @unknown default: return "Unknown status"
        }
    }
    var vpnRunning: Bool { [.connected, .connecting, .reasserting, .disconnecting].contains(vpnStatus) }

    func start() async {
        foreground = true
        guard !starting else { return }
        if observer != nil {
            vpnStatus = manager?.connection.status ?? .disconnected
            if vpnRunning { refreshVPNStats() } else { await openCore() }
            return
        }
        starting = true; defer { starting = false }
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Bundle.main.bundleIdentifier! + ".PacketTunnel" }
            vpnStatus = manager?.connection.status ?? .disconnected
            observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.vpnStatus = self.manager?.connection.status ?? .disconnected
                    if !self.vpnRunning { await self.openCore() }
                }
            }
            if !vpnRunning { await openCore() } else { refreshVPNStats() }
        } catch {
            self.error = error.localizedDescription
            await openCore()
        }
    }
    func suspend() async {
        foreground = false
        let previous = core; core = nil; ready = false
        if let previous { await Task.detached { previous.close() }.value }
    }
    func openCore() async {
        guard foreground && core == nil && !opening && !handoff && !vpnRunning else { return }
        opening = true; defer { opening = false }
        do {
            let core = try await Task.detached {
                // NEVPNStatus can change before the extension releases its state lock.
                // Retry only that handoff race, with a bounded wait; preserve other errors.
                for attempt in 0..<6 {
                    do { return try RustCore() }
                    catch {
                        guard attempt < 5, error.localizedDescription.contains("state is already in use") else { throw error }
                        try await Task.sleep(nanoseconds: UInt64(100_000_000) << attempt)
                    }
                }
                throw FamasockError(message: "VPN has not released networking yet")
            }.value
            guard foreground && !vpnRunning && !handoff else {
                await Task.detached { core.close() }.value
                return
            }
            self.core = core; ready = true
            core.events { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let text = event["error"] as? String { self.error = text }
                    await self.refresh()
                }
            }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func request(_ value: [String: Any]) async throws -> [String: Any] {
        guard let core else { throw FamasockError(message: "Stop VPN to manage foreground tunnels and peers.") }
        return try await Task.detached { try core.command(value) }.value
    }
    func run(_ command: [String: Any]) async {
        do { _ = try await request(command); await refresh() } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard core != nil else { return }
        do {
            let data = try await request(["op": "status"])
            peers = (data["peers"] as? [[String: Any]] ?? []).compactMap(Peer.init)
            tunnels = (data["tunnels"] as? [[String: Any]] ?? []).compactMap { t in
                guard let id = t["id"] as? String, let peer = t["peer"] as? String,
                      let kind = t["kind"] as? String, let detail = t["detail"] as? String else { return nil }
                return Tunnel(id: id, peer: peer, kind: kind, detail: detail)
            }
        } catch { self.error = error.localizedDescription }
    }
    func pair(_ uri: String) async {
        pairing = true; defer { pairing = false }
        do {
            _ = try await request(["op": "pair", "uri": uri.trimmingCharacters(in: .whitespacesAndNewlines), "device": "iOS"])
            await refresh()
        } catch { if error.localizedDescription != "pairing cancelled" { self.error = error.localizedDescription } }
    }
    func startVPN(peer: String, routes: [String], dns: String) async {
        guard !vpnRunning && !handoff && !opening else { return }
        handoff = true
        defer { handoff = false }
        do {
            let manager = manager ?? NETunnelProviderManager()
            let config = NETunnelProviderProtocol()
            config.providerBundleIdentifier = Bundle.main.bundleIdentifier! + ".PacketTunnel"
            config.serverAddress = "Famasock"
            config.providerConfiguration = ["peer": peer, "routes": routes, "dns": dns]
            config.disconnectOnSleep = false
            manager.protocolConfiguration = config
            manager.localizedDescription = "Famasock"
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.manager = manager
            // The extension is the sole endpoint owner while VPN is active.
            let old = core; core = nil; ready = false
            if let old { await Task.detached { old.close() }.value }
            try manager.connection.startVPNTunnel()
            vpnStatus = manager.connection.status
        } catch {
            self.error = error.localizedDescription
            handoff = false
            await openCore()
        }
    }
    func stopVPN() { manager?.connection.stopVPNTunnel() }
    func refreshVPNStats() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        do {
            try session.sendProviderMessage(Data("status".utf8)) { [weak self] data in
                guard let data else { return }
                Task { @MainActor [weak self] in
                    if let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self?.peers = (value["peers"] as? [[String: Any]] ?? []).compactMap(Peer.init)
                        let traffic = value["traffic"] as? [String: Any] ?? [:]
                        let sent = (traffic["sent"] as? NSNumber)?.int64Value ?? 0
                        let received = (traffic["received"] as? NSNumber)?.int64Value ?? 0
                        let upload = ByteCountFormatter.string(fromByteCount: sent, countStyle: .binary)
                        let download = ByteCountFormatter.string(fromByteCount: received, countStyle: .binary)
                        self?.vpnStats = "Sent \(upload) · Received \(download)"
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}
