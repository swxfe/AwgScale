import SwiftUI

/// DNS Settings view (read-only display).
/// Shows the current DNS configuration from the overlay network.
struct DNSSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var dnsConfig: DNSConfig?
    @State private var useTailscaleDNS: Bool = true
    @State private var isLoading: Bool = true
    @State private var isSavingDNSPreference: Bool = false
    @State private var error: String?
    
    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Loading DNS configuration...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let error = error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            } else if let config = dnsConfig {
                Section {
                    Toggle(isOn: Binding(
                        get: { useTailscaleDNS },
                        set: { setUseTailscaleDNS($0) }
                    )) {
                        HStack {
                            Image(systemName: "network")
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            Text("Use Tailscale DNS")
                        }
                    }
                    .disabled(isSavingDNSPreference)
                } footer: {
                    Text("Use DNS settings from your tailnet, including MagicDNS and split DNS routes.")
                }

                // MagicDNS status
                Section {
                    HStack {
                        Text("MagicDNS")
                        Spacer()
                        if config.magicDNSEnabled {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Enabled")
                                    .foregroundColor(.green)
                            }
                        } else {
                            Text("Disabled")
                                .foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    Text("MagicDNS assigns DNS names to your devices automatically.")
                }
                
                // DNS suffix
                if let suffix = config.magicDNSSuffix, !suffix.isEmpty {
                    Section {
                        DNSInfoRow(label: "DNS Suffix", value: suffix, copyable: true)
                    } header: {
                        Text("Tailnet Domain")
                    }
                }
                
                // Global resolvers
                if !config.resolvers.isEmpty {
                    Section {
                        ForEach(config.resolvers, id: \.self) { resolver in
                            DNSInfoRow(label: "Resolver", value: resolver, copyable: true)
                        }
                    } header: {
                        Text("Global Resolvers")
                    } footer: {
                        Text("DNS queries are sent to these resolvers.")
                    }
                }
                
                // Fallback resolvers
                if !config.fallbackResolvers.isEmpty {
                    Section {
                        ForEach(config.fallbackResolvers, id: \.self) { resolver in
                            DNSInfoRow(label: "Fallback", value: resolver, copyable: true)
                        }
                    } header: {
                        Text("Fallback Resolvers")
                    } footer: {
                        Text("Used when primary resolvers are unavailable.")
                    }
                }
                
                // Routes (split DNS)
                if !config.routes.isEmpty {
                    Section {
                        ForEach(config.routes.sorted(by: { $0.key < $1.key }), id: \.key) { domain, resolvers in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(domain)
                                    .font(.body)
                                ForEach(resolvers, id: \.self) { resolver in
                                    Text(resolver)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Split DNS Routes")
                    } footer: {
                        Text("Queries for these domains are routed to specific resolvers.")
                    }
                }
                
                // Search domains
                if !config.searchDomains.isEmpty {
                    Section {
                        ForEach(config.searchDomains, id: \.self) { domain in
                            Text(domain)
                        }
                    } header: {
                        Text("Search Domains")
                    } footer: {
                        Text("These domains are appended when resolving short hostnames.")
                    }
                }

                if !config.certDomains.isEmpty {
                    Section {
                        ForEach(config.certDomains, id: \.self) { domain in
                            DNSInfoRow(label: "Certificate", value: domain, copyable: true)
                        }
                    } header: {
                        Text("Certificate Domains")
                    } footer: {
                        Text("The control plane can assist DNS-01 certificate challenges for these names.")
                    }
                }

                if !config.extraRecords.isEmpty {
                    Section {
                        ForEach(config.extraRecords) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.name)
                                HStack(spacing: 8) {
                                    Text(record.type)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .cornerRadius(4)
                                    Text(record.value)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Extra DNS Records")
                    }
                }

                if !config.exitNodeFilteredSuffixes.isEmpty {
                    Section {
                        ForEach(config.exitNodeFilteredSuffixes, id: \.self) { suffix in
                            DNSInfoRow(label: "Filtered", value: suffix, copyable: true)
                        }
                    } header: {
                        Text("Exit Node DNS Filters")
                    } footer: {
                        Text("An exit node DNS proxy should not answer these suffixes.")
                    }
                }
                
                // Managed DNS toggle info
                Section {
                    HStack {
                        Text("Tailnet DNS Active")
                        Spacer()
                        Text(useTailscaleDNS && config.hasManagedDNS ? "Yes" : "No")
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("DNS settings are managed by your network admin in the control plane.")
                }
            } else {
                Section {
                    Text("No DNS configuration available")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("DNS Settings")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadDNSConfig()
        }
        .task {
            await loadDNSConfig()
        }
    }
    
    @MainActor
    private func loadDNSConfig() async {
        guard let vpn = appState.vpnManager else {
            error = "VPN manager not available"
            isLoading = false
            return
        }
        
        isLoading = true
        error = nil
        
        do {
            let client = LocalAPIClient.vpn(vpn)
            let config = try await client.dnsConfig()
            let prefs = try? await client.ipnPrefs()

            useTailscaleDNS = prefs?.CorpDNS ?? true
            dnsConfig = DNSConfig(from: config)
            isLoading = false
        } catch {
            self.error = "Failed to load DNS config: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func setUseTailscaleDNS(_ enabled: Bool) {
        guard !isSavingDNSPreference, let vpn = appState.vpnManager else { return }
        let previous = useTailscaleDNS
        useTailscaleDNS = enabled
        isSavingDNSPreference = true

        Task {
            do {
                let client = LocalAPIClient.vpn(vpn)
                try await client.setUseTailscaleDNS(enabled)
                let config = try await client.dnsConfig()
                await MainActor.run {
                    dnsConfig = DNSConfig(from: config)
                    isSavingDNSPreference = false
                    error = nil
                }
            } catch {
                await MainActor.run {
                    useTailscaleDNS = previous
                    self.error = "Failed to update DNS preference: \(error.localizedDescription)"
                    isSavingDNSPreference = false
                }
            }
        }
    }
}

/// Row displaying a DNS info item with optional copy functionality.
struct DNSInfoRow: View {
    let label: String
    let value: String
    var copyable: Bool = false
    @State private var showCopied: Bool = false
    
    var body: some View {
        Button {
            if copyable {
                UIPasteboard.general.string = value
                showCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showCopied = false
                }
            }
        } label: {
            HStack {
                Text(label)
                    .foregroundColor(.secondary)
                Spacer()
                if showCopied {
                    Text("Copied!")
                        .foregroundColor(.green)
                        .font(.caption)
                } else {
                    Text(value)
                        .foregroundColor(.primary)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!copyable)
    }
}

// MARK: - DNS Config Models

/// Parsed DNS configuration for display.
struct DNSConfig {
    let resolvers: [String]
    let fallbackResolvers: [String]
    let routes: [String: [String]]
    let searchDomains: [String]
    let certDomains: [String]
    let extraRecords: [DNSRecordDisplay]
    let exitNodeFilteredSuffixes: [String]
    let magicDNSEnabled: Bool
    let magicDNSSuffix: String?
    let hasManagedDNS: Bool
    
    init(from response: DNSConfigResponse) {
        let resolvers = response.Resolvers?.compactMap { $0.Addr } ?? []
        let nameservers = response.Nameservers ?? []
        self.resolvers = resolvers.isEmpty ? nameservers : resolvers
        self.fallbackResolvers = response.FallbackResolvers?.compactMap { $0.Addr } ?? []
        
        var routesMap: [String: [String]] = [:]
        if let routes = response.Routes {
            for (domain, entries) in routes {
                let addrs = entries?.compactMap { $0.Addr } ?? []
                if !addrs.isEmpty {
                    routesMap[domain] = addrs
                }
            }
        }
        self.routes = routesMap
        
        self.searchDomains = response.Domains ?? []
        self.certDomains = response.CertDomains ?? []
        self.extraRecords = (response.ExtraRecords ?? []).compactMap(DNSRecordDisplay.init)
        self.exitNodeFilteredSuffixes = response.ExitNodeFilteredSet ?? []
        self.magicDNSEnabled = response.Proxied ?? false
        self.magicDNSSuffix = response.Domains?.first
        self.hasManagedDNS = magicDNSEnabled || !self.resolvers.isEmpty || !routesMap.isEmpty || !fallbackResolvers.isEmpty || !searchDomains.isEmpty || !certDomains.isEmpty || !extraRecords.isEmpty
    }
}

struct DNSRecordDisplay: Identifiable {
    let id: String
    let name: String
    let type: String
    let value: String

    init?(_ response: DNSConfigResponse.DNSRecord) {
        guard let name = response.Name, !name.isEmpty,
              let value = response.Value, !value.isEmpty else { return nil }
        self.name = name
          self.type = response.recordType?.isEmpty == false ? response.recordType! : "A/AAAA"
        self.value = value
        self.id = "\(name)|\(type)|\(value)"
    }
}

#Preview {
    NavigationView {
        DNSSettingsView()
            .environmentObject(AppState())
    }
}
