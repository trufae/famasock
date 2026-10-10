import SwiftUI
@main
struct FamasockApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup {
            PeersView().environmentObject(model).task { await model.start() }
                .alert("Famasock", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                    Button("OK") { model.error = nil }
                } message: { Text(model.error ?? "") }
        }
    }
}
struct PeersView: View {
    @EnvironmentObject var model: Model
    @State private var add = false
    var body: some View {
        NavigationStack {
            List {
                if model.vpnRunning {
                    Section("VPN") {
                        Label(model.vpnStatusText, systemImage: "network.badge.shield.half.filled")
                        Button("Disconnect VPN") { model.stopVPN() }
                        Button("Transfer status") { model.refreshVPNStats() }
                        if !model.vpnStats.isEmpty { Text(model.vpnStats).font(.caption.monospaced()) }
                    }
                }
                Section("Paired devices") {
                    if model.peers.isEmpty { Text("Run famasock serve and famasock pair on your computer, then scan its QR code.").foregroundStyle(.secondary) }
                    ForEach(model.peers) { peer in
                        NavigationLink { PeerView(peerID: peer.id) } label: {
                            VStack(alignment: .leading) {
                                Label(peer.name, systemImage: peer.device == "iOS" ? "iphone" : "desktopcomputer")
                                Text(peer.connected ? "Connected · \(peer.path ?? "connecting")" : "Disconnected").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Text("Port forwarding and SOCKS run while this app is active. VPN uses the system's Packet Tunnel extension to continue in the background.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Famasock")
            .toolbar { Button { add = true } label: { Image(systemName: "qrcode.viewfinder") }.disabled(!model.ready) }
            .sheet(isPresented: $add) { AddPeerView() }
        }
    }
}
struct AddPeerView: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) var dismiss
    @State private var scan = true
    @State private var uri = ""
    @State private var confirm = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if model.pairing {
                    ProgressView("Waiting for approval on the computer…")
                    Button("Cancel pairing", role: .cancel) { Task { await model.run(["op": "cancel_pair"]) } }
                }
                else if scan {
                    ScannerView { result in
                        switch result {
                        case .success(let value): uri = value; scan = false; confirm = true
                        case .failure(let error): model.error = error.localizedDescription; scan = false
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 20))
                    Text("Scan the QR printed by famasock pair.").foregroundStyle(.secondary)
                } else {
                    TextField("famasock://pair?data=…", text: $uri, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Review invitation") { confirm = true }.disabled(!uri.hasPrefix("famasock://pair?data="))
                }
                Button(scan ? "Paste invitation instead" : "Scan QR") { scan.toggle() }.disabled(model.pairing)
            }.padding().navigationTitle("Add peer")
            .toolbar { Button("Close") { dismiss() }.disabled(model.pairing) }
            .confirmationDialog("Pair with this device?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Pair") { Task { await model.pair(uri); if model.error == nil { dismiss() } } }
            } message: { Text(invitationSummary) }
        }
    }
    private var invitationSummary: String {
        // Display only; authoritative bounded parsing/expiry checking is in Rust.
        guard uri.count < 4096, let data = uri.components(separatedBy: "?data=").last else { return "Invalid invitation" }
        let normalized = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded), let value = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else { return "The core will validate this invitation." }
        let endpoint = (value["addr"] as? [String: Any])?["id"] as? String ?? "Unknown identity"
        return "\(value["name"] as? String ?? "Device")\n\(endpoint)\nCheck the requesting identity on the computer before approving."
    }
}
struct PeerView: View {
    @EnvironmentObject var model: Model
    let peerID: String
    @State private var services: [String] = []
    @State private var rename = ""
    @State private var policy = ""
    @State private var showPolicy = false
    @State private var remove = false
    var peer: Peer? { model.peers.first { $0.id == peerID } }
    var body: some View {
        List {
            if let peer {
                Section("Connection") {
                    Text(peer.id).font(.caption.monospaced()).textSelection(.enabled)
                    Text(peer.connected ? "Connected · \(peer.path ?? "unknown")" : "Disconnected")
                    Button("Connect / refresh services") { Task { await connect() } }.disabled(!model.ready)
                    Button("Disconnect") { Task { await model.run(["op": "disconnect", "peer": peerID]) } }.disabled(!model.ready)
                }
                Section("Services") {
                    if services.isEmpty { Text("No services loaded. Grant access with famasock allow on the remote computer.").font(.footnote) }
                    ForEach(services, id: \.self) { Text($0) }
                    NavigationLink("Port forwarding") { ForwardView(peer: peerID, services: services) }.disabled(!model.ready)
                    NavigationLink("SOCKS5 proxy") { SocksView(peer: peerID) }.disabled(!model.ready)
                    NavigationLink("VPN") { VPNView(peer: peerID) }
                }
                Section("Active tunnels") {
                    ForEach(model.tunnels.filter { $0.peer == peerID }) { t in
                        VStack(alignment: .leading) {
                            Text("\(t.kind): \(t.detail)").font(.caption)
                            Button("Stop", role: .destructive) { Task { await model.run(["op": "stop", "id": t.id]) } }
                        }
                    }
                }
                Section("Device") {
                    TextField("New name", text: $rename)
                    Button("Rename") { Task { await model.run(["op": "rename", "peer": peerID, "name": rename]) } }.disabled(rename.isEmpty || !model.ready)
                    Button("Inbound permissions") {
                        policy = (try? String(data: JSONSerialization.data(withJSONObject: peer.policy, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)) ?? "{}"
                        showPolicy = true
                    }.disabled(!model.ready)
                    Button("Remove and revoke", role: .destructive) { remove = true }.disabled(!model.ready)
                }
            } else { Text("Peer removed") }
        }.navigationTitle(peer?.name ?? "Peer")
        .task { if model.ready { await connect() } }
        .confirmationDialog("Revoke this device and close its sessions?", isPresented: $remove) {
            Button("Revoke", role: .destructive) { Task { await model.run(["op": "revoke", "peer": peerID]) } }
        }
        .sheet(isPresented: $showPolicy) {
            NavigationStack {
                Form {
                    Text("These permissions control what this peer may access on this iPhone. Remote permissions must be granted on the remote device.").font(.footnote)
                    TextEditor(text: $policy).font(.caption.monospaced()).frame(minHeight: 260)
                    Button("Save permissions") {
                        Task {
                            do {
                                let value = try JSONSerialization.jsonObject(with: Data(policy.utf8))
                                await model.run(["op": "policy", "peer": peerID, "policy": value])
                                if model.error == nil { showPolicy = false }
                            } catch { model.error = error.localizedDescription }
                        }
                    }
                }.navigationTitle("Inbound permissions").toolbar { Button("Close") { showPolicy = false } }
            }
        }
    }
    func connect() async {
        do { services = try await model.request(["op": "services", "peer": peerID])["services"] as? [String] ?? []; await model.refresh() }
        catch { model.error = error.localizedDescription }
    }
}
struct ForwardView: View {
    @EnvironmentObject var model: Model
    let peer: String
    let services: [String]
    @State private var reverse = false
    @State private var port = "2222"
    @State private var service = "ssh"
    @State private var targetPort = "3000"
    var body: some View {
        Form {
            Picker("Direction", selection: $reverse) { Text("Local").tag(false); Text("Reverse").tag(true) }.pickerStyle(.segmented)
            TextField(reverse ? "Remote listening port" : "Local listening port", text: $port).keyboardType(.numberPad)
            if reverse { TextField("Local destination port", text: $targetPort).keyboardType(.numberPad) }
            else {
                TextField("Approved service name", text: $service).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !services.isEmpty { Picker("Available services", selection: $service) { ForEach(services, id: \.self) { Text($0) } } }
            }
            Button("Start forwarding") {
                Task {
                    guard let p = UInt16(port), p > 0 else { model.error = "Enter a port between 1 and 65535"; return }
                    if reverse {
                        guard let target = UInt16(targetPort), target > 0 else { model.error = "Invalid destination port"; return }
                        await model.run(["op": "reverse", "peer": peer, "port": Int(p), "target": "127.0.0.1:\(target)"])
                    } else { await model.run(["op": "forward", "peer": peer, "listen": "127.0.0.1:\(p)", "service": service]) }
                }
            }
            Text("Listeners bind to loopback. Reverse listening ports require permission on the remote peer.").font(.footnote)
        }.navigationTitle("Port forwarding")
    }
}
struct SocksView: View {
    @EnvironmentObject var model: Model
    let peer: String
    @State private var port = "1080"
    var body: some View {
        Form {
            TextField("Local port", text: $port).keyboardType(.numberPad)
            Button("Start SOCKS5") {
                Task {
                    guard let p = UInt16(port), p > 0 else { model.error = "Invalid port"; return }
                    await model.run(["op": "socks", "peer": peer, "listen": "127.0.0.1:\(p)"])
                }
            }
            Text("Only applications configured to use this SOCKS5 proxy will use it. It does not redirect all iPhone traffic. CONNECT is supported; DNS is resolved on the remote peer. The remote peer must allow the destination network and port.").font(.footnote)
        }.navigationTitle("SOCKS5")
    }
}
struct VPNView: View {
    @EnvironmentObject var model: Model
    let peer: String
    @State private var route = "192.168.1.0/24"
    @State private var dns = ""
    var body: some View {
        Form {
            LabeledContent("Status", value: model.vpnStatusText)
            Section("IPv4 split tunnel") {
                TextField("Routes, comma separated", text: $route).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Optional DNS server within allowed routes", text: $dns).keyboardType(.decimalPad)
                Text("Only approved private IPv4 routes enter the tunnel. Full tunneling and IPv6 are not yet available. The Linux peer needs a preconfigured TUN and explicit VPN permission.").font(.footnote)
            }
            if model.vpnRunning { Button("Disconnect") { model.stopVPN() } }
            else { Button("Connect VPN") { Task { await model.startVPN(peer: peer, routes: route.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, dns: dns) } } }
            Button("Transfer status") { model.refreshVPNStats() }
            Text(model.vpnStats).font(.caption.monospaced())
        }.navigationTitle("VPN")
    }
}
