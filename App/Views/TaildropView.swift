import SwiftUI
import UniformTypeIdentifiers

/// Taildrop file transfer view.
/// Displays received files and provides options to accept/share them.
struct TaildropView: View {
    @EnvironmentObject var appState: AppState
    @State private var incomingFiles: [TaildropFile] = []
    @State private var isLoading: Bool = true
    @State private var error: String?
    @State private var selectedFile: TaildropFile?
    @State private var showingShareSheet: Bool = false
    @State private var showingSaveDialog: Bool = false

    private var activeIncomingTransfers: [TaildropIncomingFile] {
        appState.incomingTaildropFiles.filter { !$0.isDone }
    }
    
    var body: some View {
        List {
            if !activeIncomingTransfers.isEmpty {
                Section("Receiving") {
                    ForEach(activeIncomingTransfers) { file in
                        TaildropIncomingProgressRow(file: file)
                    }
                }
            }

            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Checking for incoming files...")
                            .foregroundColor(.secondary)
                    }
                }
            } else if let error = error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            } else if incomingFiles.isEmpty {
                Section {
                    VStack(alignment: .center, spacing: 16) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        
                        Text("No incoming files")
                            .font(.headline)
                        
                        Text("Files sent to this device via Taildrop will appear here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            } else {
                // Incoming files
                Section {
                    ForEach(incomingFiles) { file in
                        TaildropFileRow(file: file) {
                            selectedFile = file
                            showingShareSheet = true
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteIncomingFile(file)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteIncomingFile(file)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Incoming Files (\(incomingFiles.count))")
                }
            }
            
            // Send files section
            Section {
                NavigationLink(destination: TaildropSendView()) {
                    HStack {
                        Image(systemName: "arrow.up.doc")
                            .foregroundColor(.accentColor)
                        Text("Send Files")
                    }
                }
            }
            
            // Info section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Taildrop lets you transfer files between your devices.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                    }
                    
                    Label {
                        Text("Note: Resume for interrupted transfers is not supported when receiving on iOS.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Taildrop")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadIncomingFiles()
        }
        .task {
            await loadIncomingFiles()
        }
        .onChange(of: appState.taildropInboxRevision) { _ in
            Task {
                await loadIncomingFiles()
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let file = selectedFile, let url = file.localURL {
                ShareSheet(activityItems: [url])
            }
        }
    }
    
    @MainActor
    private func loadIncomingFiles() async {
        guard let vpn = appState.vpnManager else {
            error = "VPN manager not available"
            isLoading = false
            return
        }
        
        isLoading = true
        error = nil
        
        do {
            let localFiles = loadLocalIncomingFiles()
            switch try await LocalAPIClient.vpn(vpn).listTaildropFiles() {
            case .unavailable:
                incomingFiles = localFiles
            case .files(let files):
                incomingFiles = mergedIncomingFiles(localFiles: localFiles, apiFiles: files.map { TaildropFile(from: $0) })
            }
            appState.markTaildropFilesSeen()
            isLoading = false
        } catch {
            let localFiles = loadLocalIncomingFiles()
            if localFiles.isEmpty {
                self.error = "Failed to load files: \(error.localizedDescription)"
            } else {
                incomingFiles = localFiles
                appState.markTaildropFilesSeen()
            }
            isLoading = false
        }
    }

    private func mergedIncomingFiles(localFiles: [TaildropFile], apiFiles: [TaildropFile]) -> [TaildropFile] {
        var filesByName = Dictionary(uniqueKeysWithValues: localFiles.map { ($0.name, $0) })
        for file in apiFiles {
            filesByName[file.name] = file.localURL == nil ? filesByName[file.name] ?? file : file
        }
        return filesByName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func deleteIncomingFile(_ file: TaildropFile) {
        Task { @MainActor in
            do {
                if let localURL = file.localURL, FileManager.default.fileExists(atPath: localURL.path) {
                    try FileManager.default.removeItem(at: localURL)
                } else if let vpn = appState.vpnManager {
                    try await LocalAPIClient.vpn(vpn).deleteTaildropFile(name: file.name)
                }
                incomingFiles.removeAll { $0.id == file.id || $0.name == file.name }
                appState.markTaildropFilesSeen()
            } catch {
                self.error = "Failed to delete \(file.name): \(error.localizedDescription)"
            }
        }
    }

    private func loadLocalIncomingFiles() -> [TaildropFile] {
        guard let groupContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: IPCConstants.appGroupID) else {
            return []
        }
        let taildropDir = groupContainer.appendingPathComponent("taildrop", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: taildropDir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != true else { return nil }
            return TaildropFile(localURL: url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct TaildropIncomingProgressRow: View {
    let file: TaildropIncomingFile

    private var progress: Double? {
        guard let declaredSize = file.DeclaredSize,
              declaredSize > 0,
              let received = file.Received else { return nil }
        return min(Double(received) / Double(declaredSize), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.down.doc")
                    .foregroundColor(.accentColor)
                Text(file.Name)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Text(progressText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let progress {
                ProgressView(value: progress)
            } else {
                ProgressView()
            }
        }
        .padding(.vertical, 4)
    }

    private var progressText: String {
        let received = ByteCountFormatter.string(fromByteCount: file.Received ?? 0, countStyle: .file)
        guard let declaredSize = file.DeclaredSize, declaredSize > 0 else {
            return received
        }
        let total = ByteCountFormatter.string(fromByteCount: declaredSize, countStyle: .file)
        return "\(received) of \(total)"
    }
}

/// Row displaying a single Taildrop file.
struct TaildropFileRow: View {
    let file: TaildropFile
    let onShare: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: fileIcon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(formatFileSize(file.size))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let sender = file.sender {
                        Text("from \(sender)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            Button(action: onShare) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
    
    private var fileIcon: String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.fill"
        case "jpg", "jpeg", "png", "gif", "heic": return "photo"
        case "mp4", "mov", "m4v": return "video"
        case "mp3", "m4a", "wav": return "music.note"
        case "zip", "tar", "gz": return "archivebox"
        case "txt", "md": return "doc.text"
        default: return "doc"
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// View for sending files via Taildrop.
struct TaildropSendView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingFilePicker: Bool = false
    @State private var selectedPeer: PeerNode?
    @State private var selectedFileURLs: [URL] = []
    @State private var isSending: Bool = false
    @State private var sendProgress: Double = 0
    @State private var sendError: String?
    @State private var sendStatus: String?
    @State private var sendDetail: String?
    @State private var targetPeers: [PeerNode] = []
    @State private var isLoadingTargets: Bool = true
    @State private var targetError: String?
    
    private var eligiblePeers: [PeerNode] {
        targetPeers
    }
    
    var body: some View {
        List {
            // File selection
            Section {
                Button {
                    showingFilePicker = true
                } label: {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                            .foregroundColor(.accentColor)
                        Text(selectedFileURLs.isEmpty ? "Select Files" : "\(selectedFileURLs.count) file(s) selected")
                    }
                }
                
                ForEach(selectedFileURLs, id: \.absoluteString) { url in
                    HStack {
                        Image(systemName: "doc")
                            .foregroundColor(.secondary)
                        Text(url.lastPathComponent)
                            .font(.caption)
                        Spacer()
                        Button {
                            selectedFileURLs.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Files to Send")
            }
            
            // Peer selection
            Section {
                if isLoadingTargets {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Checking available devices...")
                            .foregroundColor(.secondary)
                    }
                } else if let targetError {
                    Label(targetError, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                } else if eligiblePeers.isEmpty {
                    Text("No Taildrop-capable devices available")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(eligiblePeers) { peer in
                        Button {
                            selectedPeer = peer
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.displayName)
                                        .foregroundColor(.primary)
                                    if let os = peer.os {
                                        Text(os)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedPeer?.id == peer.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Send To")
            }
            
            // Send button
            if !selectedFileURLs.isEmpty && selectedPeer != nil {
                Section {
                    Button {
                        sendFiles()
                    } label: {
                        HStack {
                            Spacer()
                            if isSending {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Sending...")
                            } else {
                                Image(systemName: "paperplane.fill")
                                Text("Send Files")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSending)
                }
                
                if isSending {
                    Section {
                        if sendProgress > 0 {
                            ProgressView(value: sendProgress)
                        } else {
                            ProgressView()
                        }
                        if let sendDetail {
                            Text(sendDetail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            if let error = sendError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            }

            if let status = sendStatus {
                Section {
                    Label(status, systemImage: "checkmark.circle")
                        .foregroundColor(.green)
                }
            }
        }
        .navigationTitle("Send Files")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingFilePicker) {
            DocumentPicker(selectedURLs: $selectedFileURLs)
        }
        .task {
            await loadTargets()
        }
    }

    @MainActor
    private func loadTargets() async {
        guard let vpn = appState.vpnManager else {
            targetError = "VPN manager not available"
            isLoadingTargets = false
            return
        }

        isLoadingTargets = true
        targetError = nil

        do {
            let targets = try await LocalAPIClient.vpn(vpn).taildropTargets()
            targetPeers = targets.map(\.peer)
            if let selectedPeer, !targetPeers.contains(where: { $0.id == selectedPeer.id }) {
                self.selectedPeer = nil
            }
        } catch {
            targetPeers = []
            selectedPeer = nil
            targetError = error.localizedDescription
        }

        isLoadingTargets = false
    }
    
    @MainActor
    private func sendFiles() {
        guard let peer = selectedPeer,
              let vpn = appState.vpnManager,
              !selectedFileURLs.isEmpty else { return }
        let filesToSend = selectedFileURLs
        
        isSending = true
        sendError = nil
        sendStatus = nil
        sendDetail = nil
        sendProgress = 0
        
        Task {
            do {
                guard eligiblePeers.contains(where: { $0.id == peer.id }) else {
                    throw TaildropError.noAvailableTarget
                }
                let totalFiles = filesToSend.count
                try await TaildropSendService.send(files: filesToSend, to: peer, vpn: vpn) { update in
                    sendProgress = max(sendProgress, update.progress)
                    sendDetail = update.detail
                }
                
                await MainActor.run {
                    isSending = false
                    sendDetail = nil
                    sendStatus = totalFiles == 1 ? "Sent \(filesToSend[0].lastPathComponent)" : "Sent \(totalFiles) files"
                    selectedFileURLs = []
                    selectedPeer = nil
                }
            } catch {
                await MainActor.run {
                    sendError = "Failed to send: \(error.localizedDescription)"
                    isSending = false
                    sendDetail = nil
                }
            }
        }
    }
}

/// Document picker for selecting files.
struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var selectedURLs: [URL]
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.selectedURLs.append(contentsOf: urls)
        }
    }
}

/// Share sheet for sharing files.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Models

/// Parsed Taildrop file for display.
struct TaildropFile: Identifiable {
    let id: String
    let name: String
    let size: Int64
    let sender: String?
    let started: Date?
    var localURL: URL?
    
    init(from response: TaildropFileResponse) {
        self.id = response.Name
        self.name = response.Name
        self.size = response.Size
        self.sender = response.Sender
        self.started = nil // Parse if needed
        self.localURL = Self.localURL(forAPIName: response.Name)
    }

    init(localURL: URL) {
        self.id = localURL.path
        self.name = localURL.lastPathComponent
        self.sender = nil
        let values = try? localURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        self.size = Int64(values?.fileSize ?? 0)
        self.started = values?.creationDate
        self.localURL = localURL
    }

    static func isSafeLocalName(_ name: String) -> Bool {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name == (name as NSString).lastPathComponent,
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil else {
            return false
        }
        return true
    }

    private static func localURL(forAPIName name: String) -> URL? {
        guard isSafeLocalName(name),
              let groupContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: IPCConstants.appGroupID) else {
            return nil
        }
        let taildropDir = groupContainer.appendingPathComponent("taildrop", isDirectory: true)
        return taildropDir.appendingPathComponent(name, isDirectory: false)
    }
}

#Preview {
    NavigationView {
        TaildropView()
            .environmentObject(AppState())
    }
}
