import Foundation

/// A completed time entry that failed to sync to Toggl and is kept locally so the
/// tracked time isn't lost. The user can re-add it later in the Toggl web view.
struct PendingEntry: Codable, Identifiable {
    let id: UUID
    let description: String
    let projectId: Int?
    let start: Date
    let end: Date

    var durationSeconds: Int { max(0, Int(end.timeIntervalSince(start))) }

    var durationText: String {
        let s = durationSeconds
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// Disk-backed store for unsynced entries (JSON in Application Support/Tracki).
final class PendingEntryStore {
    private let fileURL: URL
    private(set) var entries: [PendingEntry] = []

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Tracki", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("pending-entries.json")
        load()
    }

    func add(_ entry: PendingEntry) {
        entries.append(entry)
        persist()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder.iso.decode([PendingEntry].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder.iso.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
