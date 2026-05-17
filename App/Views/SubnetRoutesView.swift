import SwiftUI

/// Subnet Routes management view.
/// Displays routes advertised by other devices on the network.
/// Note: iOS cannot advertise subnet routes, only use routes from other devices.
struct SubnetRoutesView: View {
    @EnvironmentObject var appState: AppState
    @State private var routes: [SubnetRoute] = []
    @State private var useSubnetRoutes: Bool = true
    @State private var isLoading: Bool = true
    @State private var isSavingSubnetPreference: Bool = false
    @State private var error: String?
    
    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Loading subnet routes...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let error = error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            } else {
                Section {
                    Toggle(isOn: Binding(
                        get: { useSubnetRoutes },
                        set: { setUseSubnetRoutes($0) }
                    )) {
                        HStack {
                            Image(systemName: "network")
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            Text("Use Subnet Routes")
                        }
                    }
                    .disabled(isSavingSubnetPreference)
                } footer: {
                    Text("Route traffic for approved subnet routes through your tailnet.")
                }

                if routes.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No subnet routes available")
                                .foregroundColor(.secondary)
                            Text("Subnet routes allow you to access networks behind other devices. Routes must be advertised by another device and approved by an admin.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    // Active routes
                    let activeRoutes = routes.filter { $0.approved && $0.enabled }
                    if !activeRoutes.isEmpty {
                        Section {
                            ForEach(activeRoutes) { route in
                                SubnetRouteRow(route: route)
                            }
                        } header: {
                            Text("Active Routes")
                        } footer: {
                            Text("Traffic to these subnets is routed through your overlay network.")
                        }
                    }

                    // Pending approval
                    let pendingRoutes = routes.filter { !$0.approved }
                    if !pendingRoutes.isEmpty {
                        Section {
                            ForEach(pendingRoutes) { route in
                                SubnetRouteRow(route: route)
                            }
                        } header: {
                            Text("Pending Approval")
                        } footer: {
                            Text("These routes need admin approval in the admin console.")
                        }
                    }

                    // Disabled routes
                    let disabledRoutes = routes.filter { $0.approved && !$0.enabled }
                    if !disabledRoutes.isEmpty {
                        Section {
                            ForEach(disabledRoutes) { route in
                                SubnetRouteRow(route: route)
                            }
                        } header: {
                            Text("Disabled Routes")
                        }
                    }
                }
            }
            
            // Info section
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("About Subnet Routes")
                            .font(.subheadline)
                        Text("iOS devices can use subnet routes advertised by other devices (Linux, macOS, Windows) but cannot advertise their own routes.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                }
            }
        }
        .navigationTitle("Subnet Routes")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadRoutes()
        }
        .task {
            await loadRoutes()
        }
    }
    
    @MainActor
    private func loadRoutes() async {
        guard let vpn = appState.vpnManager else {
            error = "VPN manager not available"
            isLoading = false
            return
        }
        
        isLoading = true
        error = nil
        
        var allRoutes: [SubnetRoute] = []
        
        do {
            let client = LocalAPIClient.vpn(vpn)
            let status = try await client.status()
            let prefs = try? await client.ipnPrefs()
            let routeAll = prefs?.RouteAll ?? true

            for (peerID, peer) in status.Peer ?? [:] {
                for route in peer.PrimaryRoutes ?? [] where SubnetRoute.isSubnetRoute(route) {
                    allRoutes.append(SubnetRoute(
                        id: "\(peerID)-\(route)",
                        cidr: route,
                        advertisedBy: peer.displayName,
                        approved: true,
                        enabled: routeAll,
                        online: peer.Online ?? false,
                        active: peer.Active ?? false,
                        os: peer.OS
                    ))
                }
            }

            if allRoutes.isEmpty {
                for (peerID, peer) in status.Peer ?? [:] {
                    for route in peer.AllowedIPs ?? [] where SubnetRoute.isSubnetRoute(route) {
                        allRoutes.append(SubnetRoute(
                            id: "\(peerID)-\(route)",
                            cidr: route,
                            advertisedBy: peer.displayName,
                            approved: true,
                            enabled: routeAll,
                            online: peer.Online ?? false,
                            active: peer.Active ?? false,
                            os: peer.OS
                        ))
                    }
                }
            }
            
            useSubnetRoutes = routeAll
            routes = allRoutes.sorted {
                if $0.cidr == $1.cidr { return $0.advertisedBy < $1.advertisedBy }
                return $0.cidr < $1.cidr
            }
            isLoading = false
        } catch {
            self.error = "Failed to load routes: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func setUseSubnetRoutes(_ enabled: Bool) {
        guard !isSavingSubnetPreference, let vpn = appState.vpnManager else { return }
        let previous = useSubnetRoutes
        let previousRoutes = routes
        useSubnetRoutes = enabled
        routes = routes.map { $0.withEnabled(enabled) }
        isSavingSubnetPreference = true

        Task {
            do {
                try await LocalAPIClient.vpn(vpn).setUseSubnetRoutes(enabled)
                await MainActor.run {
                    isSavingSubnetPreference = false
                    error = nil
                }
            } catch {
                await MainActor.run {
                    useSubnetRoutes = previous
                    routes = previousRoutes
                    self.error = "Failed to update subnet route preference: \(error.localizedDescription)"
                    isSavingSubnetPreference = false
                }
            }
        }
    }
}

/// Row displaying a single subnet route.
struct SubnetRouteRow: View {
    let route: SubnetRoute
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(route.cidr)
                    .font(.system(.body, design: .monospaced))
                
                HStack(spacing: 8) {
                    if !route.advertisedBy.isEmpty {
                        Label(route.advertisedBy, systemImage: "desktopcomputer")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let os = route.os, !os.isEmpty {
                        Text(os)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    statusBadge
                }
            }
            
            Spacer()
            
            statusIcon
        }
        .padding(.vertical, 2)
    }
    
    @ViewBuilder
    private var statusBadge: some View {
        if !route.approved {
            Text("Pending")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.2))
                .foregroundColor(.orange)
                .cornerRadius(4)
        } else if !route.enabled {
            Text("Disabled")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.2))
                .foregroundColor(.gray)
                .cornerRadius(4)
        }
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        if !route.approved {
            Image(systemName: "clock")
                .foregroundColor(.orange)
        } else if !route.online {
            Text("Offline")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .foregroundColor(.secondary)
                .cornerRadius(4)
        } else if route.enabled {
            Image(systemName: route.online ? "checkmark.circle.fill" : "wifi.slash")
                .foregroundColor(route.online ? .green : .secondary)
        } else {
            Image(systemName: "xmark.circle")
                .foregroundColor(.gray)
        }
    }
}

/// Model for a subnet route.
struct SubnetRoute: Identifiable {
    let id: String
    let cidr: String
    let advertisedBy: String
    let approved: Bool
    let enabled: Bool
    let online: Bool
    let active: Bool
    let os: String?

    func withEnabled(_ enabled: Bool) -> SubnetRoute {
        SubnetRoute(id: id, cidr: cidr, advertisedBy: advertisedBy, approved: approved, enabled: enabled, online: online, active: active, os: os)
    }

    static func isSubnetRoute(_ route: String) -> Bool {
        let route = route.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !route.isEmpty,
              route != "0.0.0.0/0",
              route != "::/0",
              !route.hasPrefix("100.64.") else { return false }
        return route.contains("/")
    }
}

#Preview {
    NavigationView {
        SubnetRoutesView()
            .environmentObject(AppState())
    }
}
