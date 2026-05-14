import Foundation

private enum LoginFlowError: Error, LocalizedError {
    case missingPrefsResponse
    case localAPI(String)

    var errorDescription: String? {
        switch self {
        case .missingPrefsResponse:
            return "Control server preferences were not returned by LocalAPI"
        case .localAPI(let message):
            return message
        }
    }
}

private let appInstallMarkerKey = "top.yesican.tailscale.install-marker.v3"
private let appInstallIdentityKey = "top.yesican.tailscale.install-identity.v1"

private extension IpnState {
    init?(backendState: String) {
        switch backendState {
        case "NoState": self = .noState
        case "NeedsLogin": self = .needsLogin
        case "NeedsMachineAuth": self = .needsMachineAuth
        case "Stopped": self = .stopped
        case "Starting": self = .starting
        case "Running": self = .running
        default: return nil
        }
    }

}

/// App-wide state container driven by ipn.Notify events.
///
/// In the dual-process architecture:
/// - Extension receives Notify from Go backend → writes to App Group UserDefaults
/// - Extension posts Darwin notification ("state changed")
/// - App's AppState observes Darwin notification → reads from App Group UserDefaults
///
/// This replaces single-process global state with app/extension IPC state.
/// All updates must happen on @MainActor since SwiftUI observes this.
@MainActor
class AppState: ObservableObject {
    // MARK: - Published State

    @Published var ipnState: IpnState = .noState
    @Published var currentProfile: LoginProfile?
    @Published var prefs: IpnPrefs?
    @Published var selfNode: PeerNode?
    @Published var peers: [PeerNode] = []
    @Published var health: HealthState?
    @Published var lastError: String?
    @Published var isLoggingIn: Bool = false
    @Published var isAwaitingMachineAuth: Bool = false
    @Published var browseToURL: String?
    @Published var pendingWantRunning: Bool?
    @Published var isUpdatingExitNode: Bool = false
    @Published var pendingExitNodeID: String?
    @Published var pendingExitNodeAllowLANAccess: Bool?

    // MARK: - AWG State

    /// Per-peer AWG config status: normalizedHostname → hasAwgConfig
    @Published var awgPeersStatus: [String: Bool] = [:]
    /// Per-peer AWG config data: normalizedHostname → AwgPeerResult
    @Published var awgPeersData: [String: AwgPeerResult] = [:]
    /// Whether the local machine has non-default AWG config
    @Published var localAwgStatus: Bool = false
    /// Local AWG config from prefs, if present.
    @Published var currentAwgConfig: AmneziaWGPrefs?
    /// Toast-style status message for AWG operations
    @Published var awgStatusMessage: String?
    /// Hostname of peer currently being synced (nil if no sync in progress)
    @Published var awgSyncInProgress: String?
    private var isAwgOperationInProgress = false
    /// Whether AWG peers have been loaded (prevent duplicate requests)
    private var awgPeersLoaded = false
    private var awgPeersLoading = false
    private var awgLastRefresh: Date?
    private let awgRefreshInterval: TimeInterval = 30

    /// Reference to VPNManager for IPC. Set by TailscaleApp at launch.
    weak var vpnManager: VPNManager?
    private let loginBackend = AppLoginBackend()
    private var isCompletingAppLogin = false
    private var loginCompletionPollTask: Task<Void, Never>?
    private var loginMayRequireMachineAuth = false
    private var loginBrowserWasPresented = false

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.1"
    }

    var hasVisibleSession: Bool {
        currentProfile != nil || selfNode != nil || !peers.isEmpty || pendingWantRunning != nil || awgSyncInProgress != nil || isAwgOperationInProgress || isUpdatingExitNode
    }

    var shouldShowLoginView: Bool {
        !hasVisibleSession && (ipnState == .noState || ipnState == .needsLogin || ipnState == .needsMachineAuth)
    }

    var effectiveExitNodeID: String? {
        pendingExitNodeID ?? prefs?.ExitNodeID
    }

    var effectiveExitNodeAllowLANAccess: Bool {
        pendingExitNodeAllowLANAccess ?? prefs?.ExitNodeAllowLANAccess ?? false
    }

    func effectiveVPNIsActive(systemActive: Bool) -> Bool {
        pendingWantRunning ?? systemActive
    }

    private var hasBackendSnapshot: Bool {
        currentProfile != nil || selfNode != nil || !peers.isEmpty
    }

    private var isBackendTransitionInProgress: Bool {
        pendingWantRunning != nil || awgSyncInProgress != nil || isAwgOperationInProgress || isUpdatingExitNode
    }

    private var isPreservingSnapshotForBackendTransition: Bool {
        hasBackendSnapshot && (pendingWantRunning == true || awgSyncInProgress != nil || isAwgOperationInProgress || isUpdatingExitNode)
    }

    private var isAppLoginBackendExpected: Bool {
        isLoggingIn || isAwaitingMachineAuth || loginMayRequireMachineAuth
    }

    private var shouldProtectExistingSessionFromLoginStart: Bool {
        hasBackendSnapshot || vpnManager?.isTunnelActive == true || isBackendTransitionInProgress
    }

    private var canShowMachineAuthDuringLogin: Bool {
        loginMayRequireMachineAuth || loginBrowserWasPresented || !isLoggingIn
    }

    // MARK: - Initialization

    init() {
        resetPersistedStateAfterFreshInstallIfNeeded()

        // Load initial state from App Group
        loadSharedState()

        // Observe Darwin notifications from Extension
        observeDarwinNotification(IPCConstants.notifyStateChanged) { [weak self] in
            Task { @MainActor in
                self?.loadSharedState()
            }
        }
    }

    // MARK: - Shared State Reading (from App Group UserDefaults)

    private func resetPersistedStateAfterFreshInstallIfNeeded() {
        let defaults = UserDefaults.standard
        let currentIdentity = currentInstallIdentity()
        let storedIdentity = defaults.string(forKey: appInstallIdentityKey)
        let shouldReset = !defaults.bool(forKey: appInstallMarkerKey) || storedIdentity != currentIdentity
        guard shouldReset else { return }

        clearSharedLoginState()
        clearPersistedGoState()
        defaults.set(true, forKey: appInstallMarkerKey)
        defaults.set(currentIdentity, forKey: appInstallIdentityKey)
        defaults.synchronize()
    }

    private func currentInstallIdentity() -> String {
        [
            NSHomeDirectory(),
            sharedContainerURL?.path ?? "",
        ].joined(separator: "|")
    }

    private func resetStaleLoginState() {
        loginCompletionPollTask?.cancel()
        loginCompletionPollTask = nil
        loginBackend.stop()
        guard !shouldProtectExistingSessionFromLoginStart else { return }
        clearSharedLoginState()
        clearPersistedGoState()
        clearInMemorySessionState()
    }

    private var shouldResumeLoginBackendOnForeground: Bool {
        isLoggingIn || isAwaitingMachineAuth || loginMayRequireMachineAuth
    }

    private func clearSharedLoginState() {
        guard let defaults = sharedDefaults else { return }
        let keys = [
            IPCConstants.keyPrefsJSON,
            IPCConstants.keyNetMapJSON,
            IPCConstants.keyBrowseToURL,
            IPCConstants.keyLoginFinished,
            IPCConstants.keyHealthJSON,
            IPCConstants.keySelfNodeJSON,
            IPCConstants.keyLastError,
            IPCConstants.keyTunnelHasDefaultRoute,
            IPCConstants.keyCurrentProfileID,
        ]
        keys.forEach { defaults.removeObject(forKey: $0) }
        defaults.set(IpnState.needsLogin.rawValue, forKey: IPCConstants.keyIPNState)
        defaults.synchronize()
        postDarwinNotification(IPCConstants.notifyStateChanged)
    }

    private func clearInMemorySessionState() {
        ipnState = .needsLogin
        clearBackendSnapshotState()
        lastError = nil
        browseToURL = nil
        isLoggingIn = false
        isAwaitingMachineAuth = false
        isCompletingAppLogin = false
        loginMayRequireMachineAuth = false
        loginBrowserWasPresented = false
        pendingWantRunning = nil
        isUpdatingExitNode = false
        pendingExitNodeID = nil
        pendingExitNodeAllowLANAccess = nil
        isAwgOperationInProgress = false
    }

    private func clearBackendSnapshotState() {
        currentProfile = nil
        prefs = nil
        selfNode = nil
        peers = []
        health = nil
        awgPeersStatus = [:]
        awgPeersData = [:]
        localAwgStatus = false
        currentAwgConfig = nil
        awgStatusMessage = nil
        awgSyncInProgress = nil
        isAwgOperationInProgress = false
        awgPeersLoaded = false
        awgPeersLoading = false
        awgLastRefresh = nil
        isUpdatingExitNode = false
        pendingExitNodeID = nil
        pendingExitNodeAllowLANAccess = nil
    }

    private func shouldClearBackendSnapshot(for state: IpnState) -> Bool {
        state.clearsBackendSnapshot && !isPreservingSnapshotForBackendTransition
    }

    private func updateCachedPrefs(
        wantRunning: Bool? = nil,
        exitNodeID: String? = nil,
        exitNodeAllowLANAccess: Bool? = nil
    ) {
        prefs = IpnPrefs(
            WantRunning: wantRunning ?? prefs?.WantRunning,
            ExitNodeID: exitNodeID ?? prefs?.ExitNodeID,
            ExitNodeAllowLANAccess: exitNodeAllowLANAccess ?? prefs?.ExitNodeAllowLANAccess,
            ControlURL: prefs?.ControlURL,
            Hostname: prefs?.Hostname
        )
    }

    /// Read state written by the Packet Tunnel Extension.
    func loadSharedState() {
        guard let defaults = sharedDefaults else { return }

        // ipn.State
        let stateRaw = defaults.integer(forKey: IPCConstants.keyIPNState)
        var clearsBackendSnapshot = false
        if let state = IpnState(rawValue: stateRaw) {
            ipnState = state
            clearsBackendSnapshot = shouldClearBackendSnapshot(for: state)
            if clearsBackendSnapshot {
                clearBackendSnapshotState()
            }
        }

        // Prefs
        if !clearsBackendSnapshot,
           let prefsStr = defaults.string(forKey: IPCConstants.keyPrefsJSON),
           let prefsData = prefsStr.data(using: .utf8) {
            prefs = try? JSONDecoder().decode(IpnPrefs.self, from: prefsData)
        }

        // NetMap
        if !clearsBackendSnapshot,
           let netMapStr = defaults.string(forKey: IPCConstants.keyNetMapJSON),
           let netMapData = netMapStr.data(using: .utf8) {
            if let netMap = try? JSONDecoder().decode(NetworkMap.self, from: netMapData) {
                updatePeers(from: netMap)
            }
        }

        // BrowseToURL (login)
        let newBrowseURL = defaults.string(forKey: IPCConstants.keyBrowseToURL)
        if newBrowseURL != browseToURL {
            browseToURL = newBrowseURL
        }
        if newBrowseURL != nil {
            loginBrowserWasPresented = true
        }

        // LoginFinished
        if defaults.bool(forKey: IPCConstants.keyLoginFinished) {
            isLoggingIn = false
            browseToURL = nil
            defaults.removeObject(forKey: IPCConstants.keyLoginFinished)
            finishAppLogin()
        }

        // Health
        if !clearsBackendSnapshot,
           let healthStr = defaults.string(forKey: IPCConstants.keyHealthJSON),
           let healthData = healthStr.data(using: .utf8) {
            if let health = try? JSONDecoder().decode(HealthState.self, from: healthData) {
                self.health = visibleHealth(from: health)
            }
        }

        // Last error
        lastError = defaults.string(forKey: IPCConstants.keyLastError)
    }

    // MARK: - Notify Processing (direct, for Extension-side use)

    /// Process an ipn.Notify JSON payload from Go backend.
    func handleNotify(_ data: Data) {
        do {
            let notify = try JSONDecoder().decode(IpnNotify.self, from: data)
            applyNotify(notify)
        } catch {
            lastError = "Failed to decode notification: \(error.localizedDescription)"
        }
    }

    private func applyNotify(_ notify: IpnNotify, fromLoginBackend: Bool = false) {
        var clearsBackendSnapshot = false
        if let stateInt = notify.State, let state = IpnState(rawValue: stateInt) {
            ipnState = state
            clearsBackendSnapshot = shouldClearBackendSnapshot(for: state)
            if clearsBackendSnapshot {
                clearBackendSnapshotState()
            }
            if state == .needsMachineAuth && fromLoginBackend && canShowMachineAuthDuringLogin {
                isAwaitingMachineAuth = true
                startLoginCompletionPolling()
            }
        }

        if !clearsBackendSnapshot, let prefs = notify.Prefs {
            self.prefs = prefs
        }

        if !clearsBackendSnapshot, let netMap = notify.NetMap {
            updatePeers(from: netMap)
        }

        if let url = notify.BrowseToURL {
            browseToURL = url
            loginBrowserWasPresented = true
        }

        if notify.LoginFinished != nil {
            isLoggingIn = false
            browseToURL = nil
            finishAppLogin()
        }

        if !clearsBackendSnapshot,
           let health = notify.Health,
           !fromLoginBackend || vpnManager?.isTunnelActive == true {
            self.health = visibleHealth(from: health)
        }
    }

    private var shouldSuppressTransientLoginStateHealthWarning: Bool {
        hasVisibleSession && (ipnState == .noState || ipnState == .starting || isBackendTransitionInProgress)
    }

    private func visibleHealth(from health: HealthState) -> HealthState {
        guard shouldSuppressTransientLoginStateHealthWarning,
              let warnings = health.Warnings,
              !warnings.isEmpty else {
            return health
        }

        let filteredWarnings = warnings.filter { code, state in
            code != "login-state" && state.WarnableCode != "login-state"
        }
        return HealthState(Warnings: filteredWarnings)
    }

    private func updatePeers(from netMap: NetworkMap) {
        var allPeers: [PeerNode] = []

        // Self node
        if let selfData = netMap.SelfNode {
            let userProfile = selfData.UserID.flatMap { uid in
                netMap.UserProfiles?[String(uid)]
            }
            let self_ = PeerNode(from: selfData, isSelf: true, userProfile: userProfile)
            selfNode = self_
            allPeers.append(self_)
        }

        // Peer nodes
        if let peerNodes = netMap.Peers {
            for peerData in peerNodes {
                let userProfile = peerData.UserID.flatMap { uid in
                    netMap.UserProfiles?[String(uid)]
                }
                allPeers.append(PeerNode(from: peerData, isSelf: false, userProfile: userProfile))
            }
        }

        peers = allPeers

    }

    private func callActiveLocalAPI(method: String, endpoint: String, body: Data? = nil, timeout: Int = 30000) async throws -> IPCResponse {
        if let vpn = vpnManager, vpn.isTunnelActive {
            return try await vpn.callLocalAPI(method: method, endpoint: endpoint, body: body, timeout: timeout)
        }

        if isBackendTransitionInProgress {
            throw LoginFlowError.localAPI("VPN backend is restarting")
        }

        if loginBackend.isRunning {
            guard isAppLoginBackendExpected else {
                loginBackend.stop()
                throw LoginFlowError.localAPI("VPN backend is not active")
            }
            return try await loginBackend.callLocalAPI(method: method, endpoint: endpoint, body: body, timeout: timeout)
        }

        guard isAppLoginBackendExpected || !hasBackendSnapshot else {
            throw LoginFlowError.localAPI("VPN backend is not active")
        }

        try await ensureAppBackendReadyForControlPlane()
        return try await loginBackend.callLocalAPI(method: method, endpoint: endpoint, body: body, timeout: timeout)
    }

    private func ensureAppBackendReadyForControlPlane() async throws {
        if loginBackend.isRunning { return }
        guard isAppLoginBackendExpected || !hasBackendSnapshot else {
            throw LoginFlowError.localAPI("VPN backend is not active")
        }

        try await loginBackend.start { [weak self] data in
            self?.handleLoginBackendNotify(data)
        }

        guard let backendState = await loginBackendState() else {
            loginBackend.stop()
            throw LoginFlowError.localAPI("No active backend")
        }

        ipnState = backendState
        switch backendState {
        case .needsLogin, .noState:
            loginBackend.stop()
            throw LoginFlowError.localAPI("No active backend")
        case .needsMachineAuth:
            loginBackend.stop()
            throw LoginFlowError.localAPI("Machine authorization pending")
        default:
            isAwaitingMachineAuth = false
            loginMayRequireMachineAuth = false
            await fetchCurrentProfileFromLoginBackend()
        }
    }

    // MARK: - User Actions (via VPNManager IPC)

    /// Start interactive login flow without enabling the system VPN tunnel.
    /// Login runs a temporary in-app Go backend so the browser auth flow can
    /// complete before the user chooses to turn Tailscale on.
    func startLogin(controlURL: String = "") {
        guard !isLoggingIn else { return }
        guard !shouldProtectExistingSessionFromLoginStart else {
            lastError = "Already signed in. Disconnect or log out before starting a new login."
            return
        }

        loginBackend.stop()
        clearSharedLoginState()
        clearPersistedGoState()
        loginCompletionPollTask?.cancel()
        loginCompletionPollTask = nil
        isLoggingIn = true
        isAwaitingMachineAuth = false
        loginMayRequireMachineAuth = !controlURL.isEmpty
        loginBrowserWasPresented = false
        lastError = nil

        Task {
            do {
                try await loginBackend.start { [weak self] data in
                    self?.handleLoginBackendNotify(data)
                }
            } catch {
                lastError = "Login backend failed to start: \(describeError(error))"
                isLoggingIn = false
                return
            }

            await setLoginBackendWantRunning(false)

            // If a custom control URL is provided, set it before login
            if !controlURL.isEmpty {
                do {
                    let prefs = MaskedPrefs.setControlURL(controlURL)
                    let updatedPrefsData = try await editLoginBackendPrefs(prefs)
                    try await startLoginBackend(updatePrefsData: updatedPrefsData)
                } catch {
                    lastError = "Failed to set control server: \(describeError(error))"
                    isLoggingIn = false
                    loginBackend.stop()
                    return
                }
            }

            do {
                let resp = try await loginBackend.startLoginInteractive()
                if let error = resp.error {
                    lastError = "Login request failed: \(error)"
                    isLoggingIn = false
                    loginBackend.stop()
                }
            } catch {
                lastError = "Login request failed: \(describeError(error))"
                isLoggingIn = false
                loginBackend.stop()
            }
        }
    }

    private func editLoginBackendPrefs(_ prefs: MaskedPrefs) async throws -> Data {
        let endpoint = "/localapi/v0/prefs"
        let body = try JSONEncoder().encode(prefs)
        let resp = try await loginBackend.callLocalAPI(method: "PATCH", endpoint: endpoint, body: body)
        return try resp.bodyData(endpoint: endpoint)
    }

    private func startLoginBackend(updatePrefsData: Data) async throws {
        let endpoint = "/localapi/v0/start"
        let updatePrefs = try JSONSerialization.jsonObject(with: updatePrefsData)
        let body = try JSONSerialization.data(withJSONObject: ["UpdatePrefs": updatePrefs])
        let resp = try await loginBackend.callLocalAPI(method: "POST", endpoint: endpoint, body: body, readBody: false)
        try resp.requireSuccess(endpoint: endpoint)
    }

    private func describeError(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = [nsError.localizedDescription]
        parts.append("domain=\(nsError.domain)")
        parts.append("code=\(nsError.code)")
        if !nsError.userInfo.isEmpty {
            parts.append("userInfo=\(nsError.userInfo)")
        }
        parts.append("debug=\(String(reflecting: error))")
        return parts.joined(separator: "; ")
    }

    private func handleLoginBackendNotify(_ data: Data) {
        do {
            let notify = try JSONDecoder().decode(IpnNotify.self, from: data)
            applyNotify(notify, fromLoginBackend: true)
        } catch {
            lastError = "Failed to decode notification: \(error.localizedDescription)"
        }
    }

    func loginBrowserDidDismiss() {
        loginBrowserWasPresented = true
        browseToURL = nil
        if loginMayRequireMachineAuth {
            isAwaitingMachineAuth = true
            ipnState = .needsMachineAuth
        }
        startLoginCompletionPolling()
    }

    private func finishAppLogin() {
        guard loginBackend.isRunning else {
            fetchCurrentProfile()
            return
        }
        guard !isCompletingAppLogin else { return }

        loginCompletionPollTask?.cancel()
        loginCompletionPollTask = nil
        isCompletingAppLogin = true
        Task {
            let backendState = await loginBackendState()
            if (backendState == .needsMachineAuth && canShowMachineAuthDuringLogin) ||
                (loginMayRequireMachineAuth && (backendState == .needsLogin || backendState == .noState)) {
                ipnState = .needsMachineAuth
                isAwaitingMachineAuth = true
                isCompletingAppLogin = false
                startLoginCompletionPolling()
                return
            }

            await fetchCurrentProfileFromLoginBackend()
            var finalBackendState = backendState
            if finalBackendState == nil {
                finalBackendState = await loginBackendState()
            }
            if let finalBackendState = finalBackendState {
                ipnState = finalBackendState
            }
            loginBackend.stop()
            isAwaitingMachineAuth = false
            loginMayRequireMachineAuth = false
            loginBrowserWasPresented = false
            isLoggingIn = false
            isCompletingAppLogin = false
        }
    }

    func resumeAppBackendIfNeeded(vpnActive: Bool) {
        guard !vpnActive,
              !loginBackend.isRunning,
              !isLoggingIn,
              shouldResumeLoginBackendOnForeground,
              !isBackendTransitionInProgress else { return }

        Task {
            do {
                try await loginBackend.start { [weak self] data in
                    self?.handleLoginBackendNotify(data)
                }
            } catch {
                return
            }

            guard let backendState = await loginBackendState() else {
                loginBackend.stop()
                return
            }

            ipnState = backendState

            switch backendState {
            case .needsLogin, .noState:
                loginBackend.stop()
            case .needsMachineAuth:
                guard isLoggingIn || loginMayRequireMachineAuth else {
                    resetStaleLoginState()
                    return
                }
                isAwaitingMachineAuth = true
                startLoginCompletionPolling()
            default:
                isAwaitingMachineAuth = false
                loginMayRequireMachineAuth = false
                await fetchCurrentProfileFromLoginBackend()
            }
        }
    }

    func foregroundResume(vpnActive: Bool) {
        if vpnActive {
            loginCompletionPollTask?.cancel()
            loginCompletionPollTask = nil
            isLoggingIn = false
            browseToURL = nil
            loginBackend.stop()
            Task {
                await refreshTunnelStatus()
            }
            return
        }

        guard !isBackendTransitionInProgress else {
            loginBackend.stop()
            return
        }

        guard shouldResumeLoginBackendOnForeground else {
            loginBackend.stop()
            return
        }

        resumeAppBackendIfNeeded(vpnActive: false)
    }

    func refreshTunnelStatus() async {
        guard let vpn = vpnManager else { return }
        let endpoint = "/localapi/v0/status"

        do {
            let resp = try await vpn.callLocalAPI(method: "GET", endpoint: endpoint, timeout: 3000)
            let bodyData = try resp.bodyData(endpoint: endpoint)
            guard let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                return
            }

            if let backendState = json["BackendState"] as? String,
               let state = IpnState(backendState: backendState) {
                ipnState = state
            }

            if ipnState != .needsLogin && ipnState != .noState {
                await fetchCurrentProfileFromVPNBackend()
            }

            lastError = nil
        } catch {
            // The tunnel can be connecting when the app first becomes active.
        }
    }

    private func startLoginCompletionPolling() {
        guard loginCompletionPollTask == nil else { return }

        loginCompletionPollTask = Task { [weak self] in
            guard let self else { return }

            for _ in 0..<120 {
                guard !Task.isCancelled,
                      self.loginBackend.isRunning,
                      self.isLoggingIn || self.ipnState == .needsMachineAuth else { break }

                if await self.loginBackendHasCompletedLogin() {
                    self.browseToURL = nil
                    self.finishAppLogin()
                    return
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            if !Task.isCancelled {
                self.loginCompletionPollTask = nil
            }
        }
    }

    private func loginBackendHasCompletedLogin() async -> Bool {
        guard let backendState = await loginBackendState() else { return false }

        switch backendState {
        case .needsLogin, .noState, .needsMachineAuth:
            return false
        default:
            return true
        }
    }

    private func loginBackendState() async -> IpnState? {
        guard let status = await loginBackendStatusJSON(),
              let backendState = status["BackendState"] as? String else {
            return nil
        }

        return IpnState(backendState: backendState)
    }

    private func loginBackendStatusJSON(timeout: Int = 3000) async -> [String: Any]? {
        let endpoint = "/localapi/v0/status"
        do {
            let resp = try await loginBackend.callLocalAPI(method: "GET", endpoint: endpoint, timeout: timeout)
            let bodyData = try resp.bodyData(endpoint: endpoint)
            guard let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                return nil
            }

            return json
        } catch {
            return nil
        }
    }

    func refreshMachineAuthStatus() async -> Bool {
        if loginBackend.isRunning {
            guard let backendState = await loginBackendState() else { return false }
            ipnState = backendState

            switch backendState {
            case .needsMachineAuth:
                isAwaitingMachineAuth = true
                return false
            case .needsLogin, .noState:
                return false
            default:
                isLoggingIn = false
                isAwaitingMachineAuth = false
                loginMayRequireMachineAuth = false
                browseToURL = nil
                finishAppLogin()
                return true
            }
        }

        loadSharedState()
        return ipnState != .needsMachineAuth
    }

    func loadMachineAuthDeviceInfo() async -> (hostname: String, nodeKey: String?)? {
        if loginBackend.isRunning,
           let status = await loginBackendStatusJSON(),
           let selfStatus = status["Self"] as? [String: Any] {
            return (
                hostname: selfStatus["HostName"] as? String ?? "Unknown",
                nodeKey: selfStatus["PublicKey"] as? String
            )
        }

        guard let vpn = vpnManager else { return nil }
        let endpoint = "/localapi/v0/status"

        do {
            let resp = try await vpn.callLocalAPI(method: "GET", endpoint: endpoint)
            let bodyData = try resp.bodyData(endpoint: endpoint)
            guard let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let selfStatus = json["Self"] as? [String: Any] else { return nil }

            return (
                hostname: selfStatus["HostName"] as? String ?? "Unknown",
                nodeKey: selfStatus["PublicKey"] as? String
            )
        } catch {
            return nil
        }
    }

    private func setLoginBackendWantRunning(_ wantRunning: Bool) async {
        do {
            let endpoint = "/localapi/v0/prefs"
            let prefs = MaskedPrefs.setWantRunning(wantRunning)
            let body = try JSONEncoder().encode(prefs)
            let resp = try await loginBackend.callLocalAPI(method: "PATCH", endpoint: endpoint, body: body)
            try resp.requireSuccess(endpoint: endpoint)
        } catch {
            lastError = "Failed to update login preferences: \(error.localizedDescription)"
        }
    }

    private func waitForBackendReady(_ vpn: VPNManager) async -> String? {
        var lastReadinessError = vpn.lastError

        for _ in 0..<25 {
            let status = vpn.updateStatusFromConnection()
            if status == .connected || status == .reasserting {
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        for _ in 0..<75 {
            if let extensionError = sharedDefaults?.string(forKey: IPCConstants.keyLastError), !extensionError.isEmpty {
                lastReadinessError = extensionError
            }

            do {
                let resp = try await vpn.callLocalAPI(
                    method: "GET",
                    endpoint: "/localapi/v0/status",
                    timeout: 1000
                )
                if resp.error == nil {
                    return nil
                }
                lastReadinessError = resp.error
            } catch {
                lastReadinessError = error.localizedDescription
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        return lastReadinessError ?? "timed out waiting for LocalAPI"
    }

    private func waitForBackendRunning(_ vpn: VPNManager, requireNetMap: Bool = false) async -> String? {
        var lastState = "Starting"
        let tolerateTransientUnauthenticated = hasBackendSnapshot || isBackendTransitionInProgress
        let transientUnauthenticatedDeadline = Date().addingTimeInterval(12)

        for _ in 0..<100 {
            do {
                let resp = try await vpn.callLocalAPI(
                    method: "GET",
                    endpoint: "/localapi/v0/status",
                    timeout: 1000
                )
                let bodyData = try resp.bodyData(endpoint: "/localapi/v0/status")
                if let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                   let backendState = json["BackendState"] as? String {
                    lastState = backendState
                    if let state = IpnState(backendState: backendState) {
                        ipnState = state
                    }
                    switch backendState {
                    case "Running":
                        if !requireNetMap || statusHasNetworkMap(json) {
                            return nil
                        }
                        lastState = "Running without network map"
                    case "NeedsLogin":
                        if tolerateTransientUnauthenticated && Date() < transientUnauthenticatedDeadline {
                            break
                        }
                        return "login is required"
                    case "NeedsMachineAuth":
                        if tolerateTransientUnauthenticated && Date() < transientUnauthenticatedDeadline {
                            break
                        }
                        isAwaitingMachineAuth = true
                        return "machine authorization is pending"
                    default:
                        break
                    }
                }
            } catch {
                lastState = error.localizedDescription
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        return "timed out waiting for backend to run; last state: \(lastState)"
    }

    private func statusHasNetworkMap(_ status: [String: Any]) -> Bool {
        if let selfStatus = status["Self"] as? [String: Any], !selfStatus.isEmpty {
            return true
        }
        if let peers = status["Peer"] as? [String: Any], !peers.isEmpty {
            return true
        }
        return false
    }

    private func waitForVPNStopped(_ vpn: VPNManager) async {
        for _ in 0..<25 {
            let status = vpn.updateStatusFromConnection()
            if status != .connected && status != .connecting && status != .reasserting && status != .disconnecting {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Log out and clear all state.
    func logout() {
        loginCompletionPollTask?.cancel()
        loginCompletionPollTask = nil
        clearInMemorySessionState()
        clearSharedLoginState()
        loginBackend.stop()

        Task {
            if let vpn = vpnManager {
                _ = try? await vpn.callLocalAPI(method: "POST", endpoint: "/localapi/v0/logout")
                vpn.disconnect()
                await waitForVPNStopped(vpn)
            }

            clearSharedLoginState()
            clearPersistedGoState()
            clearInMemorySessionState()
        }
    }

    func cancelLogin() {
        logout()
    }

    /// Toggle VPN on/off via prefs edit.
    func setWantRunning(_ wantRunning: Bool) {
        guard let vpn = vpnManager else { return }
        guard pendingWantRunning != wantRunning else { return }

        pendingWantRunning = wantRunning
        updateCachedPrefs(wantRunning: wantRunning)

        Task {
            defer { pendingWantRunning = nil }

            do {
                let endpoint = "/localapi/v0/prefs"
                lastError = nil

                if !wantRunning {
                    if vpn.isTunnelActive {
                        Task {
                            do {
                                let prefs = MaskedPrefs.setWantRunning(false)
                                let body = try JSONEncoder().encode(prefs)
                                let resp = try await vpn.callLocalAPI(method: "PATCH", endpoint: endpoint, body: body, timeout: 1000)
                                try resp.requireSuccess(endpoint: endpoint)
                            } catch {
                                NSLog("Ignoring WantRunning=false persistence during VPN stop: \(error)")
                            }
                        }
                    }
                    vpn.disconnect()
                    loginBackend.stop()
                    ipnState = .stopped
                    return
                }

                ipnState = .starting
                sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)
                sharedDefaults?.set(IpnState.starting.rawValue, forKey: IPCConstants.keyIPNState)
                loginCompletionPollTask?.cancel()
                loginCompletionPollTask = nil
                loginBackend.stop()

                try await vpn.connectTunnel()
                if let readinessError = await waitForBackendReady(vpn) {
                    throw VPNError.backendNotReady(readinessError)
                }

                let prefs = MaskedPrefs.setWantRunning(true)
                let body = try JSONEncoder().encode(prefs)
                let resp = try await vpn.callLocalAPI(method: "PATCH", endpoint: endpoint, body: body)
                try resp.requireSuccess(endpoint: endpoint)

                if let runningError = await waitForBackendRunning(vpn) {
                    throw VPNError.backendNotReady(runningError)
                }
                await refreshTunnelStatus()
            } catch {
                lastError = "Failed to update preferences: \(error.localizedDescription)"
                if wantRunning {
                    vpn.disconnect()
                    if shouldClearSessionAfterVPNStartFailure(error) {
                        clearBackendSnapshotState()
                        ipnState = .needsLogin
                    } else if ipnState == .needsLogin || ipnState == .noState {
                        ipnState = .stopped
                    }
                } else {
                    vpn.disconnect()
                    loginBackend.stop()
                    ipnState = .stopped
                }
            }
        }
    }

    private func shouldClearSessionAfterVPNStartFailure(_ error: Error) -> Bool {
        guard case VPNError.backendNotReady(let message) = error else { return false }
        let lowercased = message.lowercased()
        return lowercased.contains("login is required") || lowercased.contains("machine authorization")
    }

    /// Fetch the current login profile from the backend.
    func fetchCurrentProfile() {
        guard let vpn = vpnManager else { return }
        let endpoint = "/localapi/v0/profiles/current"

        Task {
            do {
                let resp = try await vpn.callLocalAPI(method: "GET", endpoint: endpoint)
                currentProfile = try resp.decodedBody(LoginProfile.self, endpoint: endpoint)
            } catch {
                // Profile fetch is best-effort; don't show error to user
            }
        }
    }

    private func fetchCurrentProfileFromVPNBackend() async {
        guard let vpn = vpnManager else { return }
        let endpoint = "/localapi/v0/profiles/current"

        do {
            let resp = try await vpn.callLocalAPI(method: "GET", endpoint: endpoint)
            currentProfile = try resp.decodedBody(LoginProfile.self, endpoint: endpoint)
        } catch {
            // Profile fetch is best-effort; the tunnel status is authoritative for routing.
        }
    }

    private func fetchCurrentProfileFromLoginBackend() async {
        let endpoint = "/localapi/v0/profiles/current"
        do {
            let resp = try await loginBackend.callLocalAPI(method: "GET", endpoint: endpoint)
            currentProfile = try resp.decodedBody(LoginProfile.self, endpoint: endpoint)
        } catch {
            // Profile fetch is best-effort; login state has already been saved by the backend.
        }
    }

    // MARK: - AWG Sync

    /// Load AWG config status for all peers via awg-sync-peers endpoint.
    func loadAwgPeersStatus() {
        refreshAwgStatus(showMessages: true, force: true)
    }

    /// Load local machine AWG configuration status from prefs.
    func loadLocalAwgStatus() {
        refreshAwgStatus(showMessages: true, force: true)
    }

    func refreshAwgStatus(showMessages: Bool = true, force: Bool = true) {
        guard !peers.isEmpty else { return }
        guard !isBackendTransitionInProgress else { return }
        if vpnManager?.isTunnelActive != true && hasBackendSnapshot {
            return
        }
        if !force, awgPeersLoaded, let awgLastRefresh,
           Date().timeIntervalSince(awgLastRefresh) < awgRefreshInterval {
            return
        }
        guard !awgPeersLoading else { return }

        awgPeersLoading = true
        Task {
            let loadedPeers = await loadAwgPeersStatusOnce(showMessages: showMessages)
            _ = await loadLocalAwgStatusOnce(showMessages: showMessages)
            if loadedPeers {
                awgPeersLoaded = true
                awgLastRefresh = Date()
            }
            awgPeersLoading = false
        }
    }

    private func loadAwgPeersStatusOnce(showMessages: Bool) async -> Bool {
        let endpoint = "/localapi/v0/awg-sync-peers"
        do {
            let resp = try await callActiveLocalAPI(method: "GET", endpoint: endpoint)
            let awgPeers = try resp.decodedBody([AwgPeerResult].self, endpoint: endpoint)

            var statusMap: [String: Bool] = [:]
            var dataMap: [String: AwgPeerResult] = [:]

            for peer in awgPeers {
                for key in awgKeyCandidates(peer.nodeKey) {
                    statusMap[key] = (statusMap[key] == true) || peer.hasAwgConfig
                    dataMap[key] = preferredAwgPeer(existing: dataMap[key], new: peer)
                }
                for key in peerKeyCandidates(peer.hostname) {
                    statusMap[key] = (statusMap[key] == true) || peer.hasAwgConfig
                    dataMap[key] = preferredAwgPeer(existing: dataMap[key], new: peer)
                }
            }

            mergeAwgPeerStatus(statusMap: statusMap, dataMap: dataMap)

            if showMessages {
                let awgCount = awgPeers.filter(\.hasAwgConfig).count
                let total = awgPeers.count
                if total > 0 {
                    awgStatusMessage = awgCount > 0
                        ? "Found \(awgCount)/\(total) peers with AWG config"
                        : "Checked \(total) peers, no AWG config found"
                } else {
                    awgStatusMessage = "No peers found"
                }
            }
            return true
        } catch {
            if showMessages {
                awgStatusMessage = "Failed to get AWG config info: \(error.localizedDescription)"
            }
            return false
        }
    }

    private func loadLocalAwgStatusOnce(showMessages: Bool) async -> Bool {
        let endpoint = "/localapi/v0/prefs"
        do {
            let resp = try await callActiveLocalAPI(method: "GET", endpoint: endpoint)
            let prefs = try resp.decodedBody(LocalPrefs.self, endpoint: endpoint)
            currentAwgConfig = prefs.AmneziaWG
            localAwgStatus = currentAwgConfig?.hasNonDefaultValues == true
            return true
        } catch {
            if !isBackendTransitionInProgress {
                localAwgStatus = false
                currentAwgConfig = nil
            }
            if showMessages {
                awgStatusMessage = "Failed to get local AWG status: \(error.localizedDescription)"
            }
            return false
        }
    }

    func refreshLocalAwgStatusNow(showMessages: Bool = true) async {
        _ = await loadLocalAwgStatusOnce(showMessages: showMessages)
    }

    /// Load AWG status once per session when the network map is available.
    func loadAwgStatusIfNeeded() {
        guard !peers.isEmpty else { return }
        refreshAwgStatus(showMessages: false, force: false)
    }

    func refreshAwgStatusForTunnelChange() {
        guard !peers.isEmpty else { return }
        refreshAwgStatus(showMessages: false, force: true)
    }

    func peerHasAwgConfig(_ peer: PeerNode) -> Bool {
        if peer.isCurrentDevice {
            return localAwgStatus
        }
        return awgData(for: peer)?.hasAwgConfig == true
    }

    /// Sync AWG config from a remote peer to the local machine.
    func syncAwgConfigFromPeer(_ peer: PeerNode, timeout: Int = 10) {
        let hostname = peer.displayName

        // Verify peer has AWG config
        let peerData = awgData(for: peer)

        if let peerData, !peerData.hasAwgConfig {
            awgStatusMessage = "Peer \(hostname) has no AWG config"
            return
        }

        let fullNodeKey = fullNodeKeyForAwgSync(peer: peer, peerData: peerData)

        guard let nodeKey = fullNodeKey, !nodeKey.isEmpty else {
            awgStatusMessage = "Cannot find nodeKey for peer \(hostname)"
            return
        }

        awgSyncInProgress = hostname
        isAwgOperationInProgress = true

        Task {
            defer {
                awgSyncInProgress = nil
                isAwgOperationInProgress = false
            }

            do {
                let endpoint = "/localapi/v0/awg-sync-apply"
                let vpn = try await ensureVPNBackendReadyForAwgSync()
                let request = AwgSyncApplyRequest(nodeKey: nodeKey, timeout: timeout)
                let body = try JSONEncoder().encode(request)
                let resp = try await vpn.callLocalAPI(method: "POST", endpoint: endpoint, body: body)
                let appliedConfig = try resp.decodedBody(AmneziaWGPrefs.self, endpoint: endpoint)
                currentAwgConfig = appliedConfig
                localAwgStatus = appliedConfig.hasNonDefaultValues
                awgStatusMessage = "AWG config from \(hostname) applied, restarting VPN..."
                let restarted = await autoReconnectForAwgConfig()
                _ = await loadLocalAwgStatusOnce(showMessages: false)
                if restarted {
                    awgStatusMessage = "AWG config from \(hostname) applied successfully"
                }
            } catch {
                awgStatusMessage = parseAwgApplyError(error.localizedDescription, hostname: hostname)
            }
        }
    }

    func clearAwgStatusMessage() {
        awgStatusMessage = nil
    }

    func applyManualAwgConfig(_ config: AmneziaWGPrefs) async throws {
        isAwgOperationInProgress = true
        defer { isAwgOperationInProgress = false }

        let prefs = MaskedPrefs.setAmneziaWG(config)
        let body = try JSONEncoder().encode(prefs)
        awgStatusMessage = config.hasNonDefaultValues ? "Applying AWG config..." : "Clearing AWG config..."

        let vpn = try await ensureVPNBackendReadyForAwgSync()
        let resp = try await vpn.callLocalAPI(method: "PATCH", endpoint: "/localapi/v0/prefs", body: body)
        try resp.requireSuccess(endpoint: "/localapi/v0/prefs")

        currentAwgConfig = config
        localAwgStatus = config.hasNonDefaultValues

        let restarted = await autoReconnectForAwgConfig()

        _ = await loadLocalAwgStatusOnce(showMessages: false)

        if !restarted {
            throw LoginFlowError.localAPI(awgStatusMessage ?? "VPN restart failed")
        }

        awgStatusMessage = config.hasNonDefaultValues ? "AWG config applied successfully" : "AWG config cleared"
    }

    // MARK: - AWG Helpers

    private func autoReconnectForAwgConfig() async -> Bool {
        guard let vpn = vpnManager else { return false }
        let wasAwgOperationInProgress = isAwgOperationInProgress
        isAwgOperationInProgress = true
        defer {
            if !wasAwgOperationInProgress {
                isAwgOperationInProgress = false
            }
        }

        vpn.disconnect()
        for _ in 0..<25 {
            _ = vpn.updateStatusFromConnection()
            if !vpn.isTunnelActive { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        do {
            try await vpn.connectTunnel()
            if let readinessError = await waitForBackendReady(vpn) {
                awgStatusMessage = "AWG config applied but VPN restart failed: \(readinessError)"
                return false
            }
            if let runningError = await waitForBackendRunning(vpn) {
                awgStatusMessage = "AWG config applied but VPN restart failed: \(runningError)"
                return false
            }
            await refreshTunnelStatus()
            return true
        } catch {
            awgStatusMessage = "AWG config applied but VPN restart failed: \(error.localizedDescription)"
            return false
        }
    }

    private func ensureVPNBackendReadyForAwgSync() async throws -> VPNManager {
        guard let vpn = vpnManager else {
            throw LoginFlowError.localAPI("VPN manager not available")
        }

        lastError = nil
        awgStatusMessage = "Preparing VPN for AWG sync..."
        loginBackend.stop()

        try await vpn.connectTunnel()
        if let readinessError = await waitForBackendReady(vpn) {
            throw VPNError.backendNotReady(readinessError)
        }
        awgStatusMessage = "Waiting for VPN network map..."
        if let runningError = await waitForBackendRunning(vpn, requireNetMap: true) {
            throw VPNError.backendNotReady(runningError)
        }
        await refreshTunnelStatus()
        return vpn
    }

    private func peerKeyCandidates(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let short = trimmed.components(separatedBy: ".").first ?? trimmed
        return uniqueAwgKeys([
            trimmed,
            trimmed.lowercased(),
            short,
            short.lowercased(),
        ])
    }

    private func awgKeyCandidates(_ value: String?) -> [String] {
        guard let value = value, !value.isEmpty else { return [] }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("nodekey:") ? String(trimmed.dropFirst("nodekey:".count)) : trimmed
        let withoutBrackets = withoutPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var candidates = [trimmed, trimmed.lowercased(), withoutPrefix, withoutPrefix.lowercased(), withoutBrackets, withoutBrackets.lowercased()]
        if withoutBrackets.count >= 5 {
            let short = String(withoutBrackets.prefix(5))
            candidates.append(short)
            candidates.append(short.lowercased())
            candidates.append("[\(short)]")
            candidates.append("[\(short.lowercased())]")
        }
        return uniqueAwgKeys(candidates)
    }

    private func uniqueAwgKeys(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private func awgData(for peer: PeerNode) -> AwgPeerResult? {
        let candidates = awgKeyCandidates(peer.nodeKey)
            + peerKeyCandidates(peer.hostname)
            + peerKeyCandidates(peer.displayName)
            + peerKeyCandidates(peer.normalizedHostname)
            + peerKeyCandidates(peer.computedName)
            + peerKeyCandidates(peer.hostinfoHostname)
        return candidates.lazy.compactMap { self.awgPeersData[$0] }.first
    }

    private func fullNodeKeyForAwgSync(peer: PeerNode, peerData: AwgPeerResult?) -> String? {
        let targetKey = peer.normalizedHostname
        let matchingPeerNodeKey = peers.first(where: {
            $0.normalizedHostname == targetKey
        })?.nodeKey

        let candidates = [
            peer.nodeKey,
            matchingPeerNodeKey,
            peerData?.nodeKey,
        ]

        return candidates.compactMap { $0 }
            .first { !$0.isEmpty && $0.hasPrefix("nodekey:") }
            ?? candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    private func responseErrorMessage(_ response: IPCResponse) -> String {
        if let bodyPreview = response.bodyPreview() {
            return bodyPreview
        }
        return response.error ?? "Unknown error (status \(response.statusCode))"
    }

    private func preferredAwgPeer(existing: AwgPeerResult?, new: AwgPeerResult) -> AwgPeerResult {
        guard let existing = existing else { return new }
        if new.hasAwgConfig && !existing.hasAwgConfig {
            return new
        }
        return existing
    }

    private func mergeAwgPeerStatus(statusMap: [String: Bool], dataMap: [String: AwgPeerResult]) {
        for (key, value) in statusMap {
            awgPeersStatus[key] = (awgPeersStatus[key] == true) || value
        }
        for (key, peer) in dataMap {
            awgPeersData[key] = preferredAwgPeer(existing: awgPeersData[key], new: peer)
        }
    }

    private func parseAwgApplyError(_ message: String, hostname: String) -> String {
        if message.contains("405") || message.contains("only POST allowed") {
            return "Request method error"
        } else if message.contains("403") || message.contains("access denied") {
            return "Access denied"
        } else if message.contains("404") || message.contains("peer not found") {
            return "Peer \(hostname) not found or offline"
        } else if message.contains("409") || message.contains("no Amnezia-WG config") {
            return "Peer \(hostname) has no AWG config"
        } else if message.contains("500") {
            if message.contains("no netmap available") {
                return "Network map unavailable"
            } else if message.contains("failed to fetch config") {
                return "Cannot fetch config from peer"
            } else if message.contains("failed to apply config") {
                return "Config apply failed"
            }
            return "Server error: \(message)"
        } else if message.contains("timeout") || message.contains("Timeout") {
            return "Operation timeout, please retry"
        }
        return "AWG config apply failed: \(message)"
    }

    // MARK: - Exit Node
    // Note: iOS does not support running AS an exit node (only using exit nodes).
    // See: https://tailscale.com/kb/1103/exit-nodes

    /// Set the exit node to use for routing traffic.
    func setExitNode(_ peer: PeerNode) {
        guard !isUpdatingExitNode else { return }

        let previousPrefs = prefs
        let targetID = peer.id
        isUpdatingExitNode = true
        pendingExitNodeID = targetID
        updateCachedPrefs(exitNodeID: targetID)
        lastError = nil
        sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)

        Task {
            defer {
                isUpdatingExitNode = false
                pendingExitNodeID = nil
            }

            do {
                let endpoint = "/localapi/v0/prefs"
                var maskedPrefs = MaskedPrefs()
                maskedPrefs.ExitNodeID = targetID
                maskedPrefs.ExitNodeIDSet = true
                let body = try JSONEncoder().encode(maskedPrefs)
                let vpn = try await ensureVPNBackendRunningForExitNode()
                let resp = try await vpn.callLocalAPI(method: "PATCH", endpoint: endpoint, body: body)
                try resp.requireSuccess(endpoint: endpoint)
                _ = try await waitForVPNPrefs(vpn, description: "exit node selection") { prefs in
                    (prefs.ExitNodeID ?? "") == targetID
                }
                try await waitForTunnelDefaultRoute(enabled: true)
                lastError = nil
            } catch {
                prefs = previousPrefs
                lastError = "Failed to set exit node: \(error.localizedDescription)"
            }
        }
    }

    /// Clear the current exit node (stop using any exit node).
    func clearExitNode() {
        guard !isUpdatingExitNode else { return }

        let previousPrefs = prefs
        isUpdatingExitNode = true
        pendingExitNodeID = ""
        updateCachedPrefs(exitNodeID: "")
        lastError = nil
        sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)

        Task {
            defer {
                isUpdatingExitNode = false
                pendingExitNodeID = nil
            }

            do {
                let endpoint = "/localapi/v0/prefs"
                var maskedPrefs = MaskedPrefs()
                maskedPrefs.ExitNodeID = ""
                maskedPrefs.ExitNodeIDSet = true
                let body = try JSONEncoder().encode(maskedPrefs)
                let vpn = try await ensureVPNBackendRunningForExitNode()
                let resp = try await vpn.callLocalAPI(method: "PATCH", endpoint: endpoint, body: body)
                try resp.requireSuccess(endpoint: endpoint)
                _ = try await waitForVPNPrefs(vpn, description: "exit node clearing") { prefs in
                    (prefs.ExitNodeID ?? "").isEmpty
                }
                try await waitForTunnelDefaultRoute(enabled: false)
                lastError = nil
            } catch {
                prefs = previousPrefs
                lastError = "Failed to clear exit node: \(error.localizedDescription)"
            }
        }
    }

    /// Set allow LAN access when using exit node.
    func setExitNodeAllowLANAccess(_ allow: Bool) {
        guard !isUpdatingExitNode else { return }

        let previousPrefs = prefs
        isUpdatingExitNode = true
        pendingExitNodeAllowLANAccess = allow
        updateCachedPrefs(exitNodeAllowLANAccess: allow)
        lastError = nil
        sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)

        Task {
            defer {
                isUpdatingExitNode = false
                pendingExitNodeAllowLANAccess = nil
            }

            do {
                let endpoint = "/localapi/v0/prefs"
                var maskedPrefs = MaskedPrefs()
                maskedPrefs.ExitNodeAllowLANAccess = allow
                maskedPrefs.ExitNodeAllowLANAccessSet = true
                let body = try JSONEncoder().encode(maskedPrefs)
                let vpn = try await ensureVPNBackendRunningForExitNode()
                let resp = try await vpn.callLocalAPI(method: "PATCH", endpoint: endpoint, body: body)
                try resp.requireSuccess(endpoint: endpoint)
                _ = try await waitForVPNPrefs(vpn, description: "exit node LAN access") { prefs in
                    (prefs.ExitNodeAllowLANAccess ?? false) == allow
                }
                lastError = nil
            } catch {
                prefs = previousPrefs
                lastError = "Failed to update LAN access setting: \(error.localizedDescription)"
            }
        }
    }

    private func refreshPrefsFromActiveBackend(timeout: Int = 3000) async {
        let endpoint = "/localapi/v0/prefs"
        do {
            let resp = try await callActiveLocalAPI(method: "GET", endpoint: endpoint, timeout: timeout)
            prefs = try resp.decodedBody(IpnPrefs.self, endpoint: endpoint)
        } catch {
            // Notify updates from the backend will refresh prefs shortly.
        }
    }

    private func ensureVPNBackendRunningForExitNode() async throws -> VPNManager {
        guard let vpn = vpnManager else {
            throw LoginFlowError.localAPI("VPN manager not available")
        }

        loginBackend.stop()
        try await vpn.connectTunnel()
        if let readinessError = await waitForBackendReady(vpn) {
            throw VPNError.backendNotReady(readinessError)
        }
        if let runningError = await waitForBackendRunning(vpn) {
            throw VPNError.backendNotReady(runningError)
        }
        await refreshTunnelStatus()
        return vpn
    }

    private func waitForVPNPrefs(
        _ vpn: VPNManager,
        description: String,
        matches: (IpnPrefs) -> Bool
    ) async throws -> IpnPrefs {
        let endpoint = "/localapi/v0/prefs"
        var lastPrefsError: String?

        for _ in 0..<30 {
            do {
                let resp = try await vpn.callLocalAPI(method: "GET", endpoint: endpoint, timeout: 1000)
                let currentPrefs = try resp.decodedBody(IpnPrefs.self, endpoint: endpoint)
                prefs = currentPrefs
                if matches(currentPrefs) {
                    return currentPrefs
                }
            } catch {
                lastPrefsError = error.localizedDescription
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        if let lastPrefsError {
            throw LoginFlowError.localAPI("Timed out waiting for \(description): \(lastPrefsError)")
        }
        throw LoginFlowError.localAPI("Timed out waiting for \(description)")
    }

    private func waitForTunnelDefaultRoute(enabled: Bool) async throws {
        guard let defaults = sharedDefaults else {
            throw LoginFlowError.localAPI("App Group state is not available")
        }

        for _ in 0..<40 {
            defaults.synchronize()
            if defaults.bool(forKey: IPCConstants.keyTunnelHasDefaultRoute) == enabled {
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        throw LoginFlowError.localAPI(enabled
            ? "Default route did not become active"
            : "Default route did not clear")
    }

    // Note: setRunAsExitNode removed - iOS does not support advertising as an exit node.
}
