import Foundation

public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var date: Date
    public var text: String
    public var rawText: String?
    public var language: String?
    public var model: String

    public init(date: Date = Date(), text: String, rawText: String?, language: String?, model: String) {
        self.date = date
        self.text = text
        self.rawText = rawText
        self.language = language
        self.model = model
    }
}

/// Optional, local-only transcript history.
///
/// - Disabled by default; when disabled nothing is written and any existing file is deleted.
/// - Stored in Application Support with 0600 permissions, excluded from Time Machine backups,
///   never synced or uploaded.
@MainActor
public final class HistoryStore: ObservableObject {
    @Published public private(set) var entries: [HistoryEntry] = []
    public var isEnabled: Bool {
        didSet {
            if isEnabled { load() } else { clear() }
        }
    }
    public var retentionDays: Int = 30
    public var maxEntries: Int = 500
    public let fileURL: URL

    public init(directory: URL? = nil, enabled: Bool) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Le Blab", isDirectory: true)
        fileURL = dir.appendingPathComponent("history.json")
        isEnabled = enabled
        if enabled { load() } else { deleteFile() }
    }

    public func append(_ entry: HistoryEntry) {
        guard isEnabled, !entry.text.isEmpty else { return }
        entries.insert(entry, at: 0)
        prune()
        persist()
    }

    public func delete(_ id: HistoryEntry.ID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    public func clear() {
        entries.removeAll()
        deleteFile()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Double(max(retentionDays, 1)) * 86_400)
        entries.removeAll { $0.date < cutoff }
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { entries = []; return }
        entries = decoded
        prune()
    }

    private func persist() {
        guard isEnabled else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            Log.app.error("Couldn't save history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deleteFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
