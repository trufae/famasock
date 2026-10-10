import NetworkExtension
import Foundation

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let work = DispatchQueue(label: "famasock.packet.control")
    private var core: RustCore?
    private var sessionID: String?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        work.async { [self] in
            do {
                guard let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
                      let peer = config["peer"] as? String, let routes = config["routes"] as? [String] else {
                    throw FamasockError(message: "Missing peer or routes")
                }
                let core = try RustCore(); self.core = core
                let info = try core.command(["op": "vpn_start", "peer": peer, "routes": routes])
                guard let id = info["id"] as? String, let local = info["local_ip"] as? String,
                      let remote = info["remote_ip"] as? String else { throw FamasockError(message: "Invalid VPN negotiation") }
                sessionID = id
                let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remote)
                let ipv4 = NEIPv4Settings(addresses: [local], subnetMasks: ["255.255.255.255"])
                ipv4.includedRoutes = try routes.map(Self.route)
                // No default route or includeAllNetworks: public Iroh UDP and relay
                // sockets remain outside this private IPv4 split tunnel.
                settings.ipv4Settings = ipv4
                settings.mtu = 1100
                if let dns = config["dns"] as? String, !dns.isEmpty {
                    guard routes.contains(where: { Self.contains($0, dns) }) else { throw FamasockError(message: "DNS server must be inside an allowed route") }
                    let dnsSettings = NEDNSSettings(servers: [dns])
                    dnsSettings.matchDomains = [""]
                    settings.dnsSettings = dnsSettings
                }
                setTunnelNetworkSettings(settings) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.work.async { core.close(); self.core = nil; self.sessionID = nil; completionHandler(error) }
                        return
                    }
                    self.readPackets(core: core, id: id)
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        while let packet = core.receivePacket(session: id) {
                            self?.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
                        }
                        self?.work.async { [weak self] in
                            guard let self, self.sessionID == id else { return }
                            self.sessionID = nil; self.core = nil; core.close()
                            self.cancelTunnelWithError(FamasockError(message: "Peer disconnected. Reconnect VPN to create a new session."))
                        }
                    }
                    completionHandler(nil)
                }
            } catch {
                core?.close(); core = nil; sessionID = nil; completionHandler(error)
            }
        }
    }
    private func readPackets(core: RustCore, id: String) {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.work.async {
                guard self.sessionID == id else { return }
                for (packet, proto) in zip(packets, protocols) where proto.int32Value == AF_INET {
                    _ = core.sendPacket(session: id, data: packet)
                }
                self.readPackets(core: core, id: id)
            }
        }
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        work.async { [self] in
            sessionID = nil
            core?.close(); core = nil
            setTunnelNetworkSettings(nil) { _ in completionHandler() }
        }
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        work.async { [self] in
            guard let core, let id = sessionID else { completionHandler?(nil); return }
            let status = try? core.command(["op": "status"])
            let stats = try? core.command(["op": "vpn_stats", "id": id])
            let value: [String: Any] = ["peers": status?["peers"] ?? [], "traffic": stats ?? [:]]
            completionHandler?(try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        }
    }
    private static func ip(_ value: String) -> UInt32? {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for p in parts { guard let byte = UInt8(p) else { return nil }; result = result << 8 | UInt32(byte) }
        return result
    }
    private static func contains(_ cidr: String, _ address: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), (1...32).contains(bits),
              let net = ip(String(parts[0])), let addr = ip(address) else { return false }
        let mask = UInt32.max << (32 - bits)
        return net & mask == addr & mask
    }
    private static func route(_ cidr: String) throws -> NEIPv4Route {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), (1...32).contains(bits), let net = ip(String(parts[0])) else {
            throw FamasockError(message: "Invalid IPv4 route: \(cidr)")
        }
        let mask = UInt32.max << (32 - bits)
        func dotted(_ value: UInt32) -> String { [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".") }
        return NEIPv4Route(destinationAddress: dotted(net & mask), subnetMask: dotted(mask))
    }
}
