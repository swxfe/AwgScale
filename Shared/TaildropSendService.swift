import Foundation

struct TaildropSendUpdate {
    let progress: Double
    let detail: String?
}

enum TaildropError: Error, LocalizedError {
    case accessDenied
    case sendFailed(String)
    case noAvailableTarget

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Cannot access the selected file"
        case .sendFailed(let message):
            return message
        case .noAvailableTarget:
            return "Selected device is no longer available for Taildrop"
        }
    }
}

enum TaildropSendService {
    @MainActor
    static func loadTargets(vpn: VPNManager) async throws -> [PeerNode] {
        let targets = try await LocalAPIClient.vpn(vpn).taildropTargets()
        return targets.map(\.peer)
    }

    @MainActor
    static func send(
        files: [URL],
        to peer: PeerNode,
        vpn: VPNManager,
        update: @escaping @MainActor (TaildropSendUpdate) -> Void
    ) async throws {
        guard !files.isEmpty else { return }

        sharedDefaults?.removeObject(forKey: IPCConstants.keyLastError)
        let client = LocalAPIClient.vpn(vpn)
        let totalFiles = files.count

        for (index, url) in files.enumerated() {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let fileName = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
            update(TaildropSendUpdate(progress: Double(index) / Double(totalFiles), detail: "Starting \(fileName)..."))

            let transferID = try await client.putTaildropFile(peerID: peer.id, fileURL: url)
            try await waitForTaildropTransfer(
                transferID: transferID,
                fileName: fileName,
                fileIndex: index,
                totalFiles: totalFiles,
                peerName: peer.displayName,
                update: update
            )
        }

        update(TaildropSendUpdate(progress: 1, detail: nil))
    }

    private static func waitForTaildropTransfer(
        transferID: String,
        fileName: String,
        fileIndex: Int,
        totalFiles: Int,
        peerName: String,
        update: @escaping @MainActor (TaildropSendUpdate) -> Void
    ) async throws {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(15 * 60)

        while Date() < deadline {
            try Task.checkCancellation()

            if let lastError = taildropLastError() {
                throw TaildropError.sendFailed(lastError)
            }

            if let transfer = outgoingTransfer(id: transferID) {
                let declaredSize = max(transfer.DeclaredSize, 1)
                let sent = max(transfer.Sent, 0)
                let fileProgress = min(Double(sent) / Double(declaredSize), 1)
                let overallProgress = (Double(fileIndex) + fileProgress) / Double(totalFiles)

                await update(TaildropSendUpdate(
                    progress: overallProgress,
                    detail: progressDetail(transfer, fileName: fileName, peerName: peerName)
                ))

                if transfer.Finished {
                    guard transfer.Succeeded, transfer.DeclaredSize == 0 || transfer.Sent >= transfer.DeclaredSize else {
                        throw TaildropError.sendFailed("\(fileName) was not fully received by \(peerName)")
                    }
                    await update(TaildropSendUpdate(progress: Double(fileIndex + 1) / Double(totalFiles), detail: nil))
                    return
                }
            } else if Date().timeIntervalSince(startedAt) > 5 {
                await update(TaildropSendUpdate(
                    progress: Double(fileIndex) / Double(totalFiles),
                    detail: "Waiting for Taildrop progress from \(peerName)..."
                ))
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        throw TaildropError.sendFailed("Timed out waiting for \(fileName) to finish sending")
    }

    private static func outgoingTransfer(id: String) -> TaildropOutgoingFile? {
        guard let outgoingStr = sharedDefaults?.string(forKey: IPCConstants.keyOutgoingFilesJSON),
              let outgoingData = outgoingStr.data(using: .utf8),
              let outgoingFiles = try? JSONDecoder().decode([TaildropOutgoingFile].self, from: outgoingData) else {
            return nil
        }
        return outgoingFiles.first { $0.transferID == id }
    }

    private static func taildropLastError() -> String? {
        guard let lastError = sharedDefaults?.string(forKey: IPCConstants.keyLastError),
              lastError.localizedCaseInsensitiveContains("taildrop") else {
            return nil
        }
        return lastError
    }

    private static func progressDetail(_ transfer: TaildropOutgoingFile, fileName: String, peerName: String) -> String {
        guard transfer.Sent > 0 else {
            return "Waiting for \(peerName) to accept \(fileName)..."
        }
        let sent = ByteCountFormatter.string(fromByteCount: transfer.Sent, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: transfer.DeclaredSize, countStyle: .file)
        return "Sending \(fileName): \(sent) of \(total)"
    }
}
