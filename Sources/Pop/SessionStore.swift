import Foundation

/// Multi-session conversation persistence at
/// `~/Library/Application Support/Pop/sessions/`.
///
/// Shape:
///   sessions/index.json          — `[{id, title, createdAt, updatedAt, turnCount}]`
///   sessions/<id>.jsonl          — one `{ts, role, text}` line per turn
///
/// One file per session, because "resume this conversation" is the whole point:
/// a single append-only file cannot be split back apart without rewriting it.
/// The index is written whole on every change — it is a few dozen short records,
/// and a partially written index is the only thing that could lose a session.
///
/// `POP_SESSIONS_PATH` overrides the root so a probe never touches real user
/// data. Read-only concern: when unset the default path is unchanged.
final class SessionStore: @unchecked Sendable {
    struct Session: Codable, Equatable {
        let id: String
        var title: String
        let createdAt: Double
        var updatedAt: Double
        var turnCount: Int

        /// Compact wall-clock string, precomputed so the page can show
        /// "15:04" / "yesterday" without parsing anything.
        var stamp: String { Self.stampFormatter.string(from: Date(timeIntervalSince1970: updatedAt)) }

        private static let stampFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MMM d, HH:mm"
            return f
        }()
    }

    static var rootURL: URL {
        if let override = ProcessInfo.processInfo.environment["POP_SESSIONS_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return PopConfig.directoryURL.appendingPathComponent("sessions", isDirectory: true)
    }

    static func defaultRoot() -> URL { rootURL }

    /// Titles are the first user message, so the list is scannable. 48 chars is
    /// what fits the menu without wrapping.
    static let titleLimit = 48
    static let untitled = "Untitled"

    private let root: URL
    /// `append` can arrive from the provider's stream task while a probe reads
    /// the index from the main task; all file I/O funnels through one queue.
    private let queue = DispatchQueue(label: "com.pop.sessions")

    init(root: URL = SessionStore.rootURL) {
        self.root = root
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private func transcriptURL(_ id: String) -> URL { root.appendingPathComponent("\(id).jsonl") }

    // MARK: - Index

    private func readIndex() -> [Session] {
        guard let data = try? Data(contentsOf: indexURL),
              let sessions = try? JSONDecoder().decode([Session].self, from: data)
        else { return [] }
        return sessions
    }

    private func writeIndex(_ sessions: [Session]) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("SESSIONS_INDEX_ERROR error=\(error)")
            fflush(stdout)
        }
    }

    // MARK: - API

    /// Newest first: the list is a recency list, so ordering IS the feature.
    func sessions() -> [Session] {
        queue.sync { readIndex().sorted { lhs, rhs in
            lhs.updatedAt == rhs.updatedAt ? lhs.createdAt > rhs.createdAt : lhs.updatedAt > rhs.updatedAt
        } }
    }

    @discardableResult
    func startSession() -> Session {
        queue.sync {
            let now = Date().timeIntervalSince1970
            let session = Session(
                id: UUID().uuidString,
                title: Self.untitled,
                createdAt: now,
                updatedAt: now,
                turnCount: 0
            )
            var all = readIndex()
            all.append(session)
            writeIndex(all)
            return session
        }
    }

    /// Appends one turn to a session's own transcript, then refreshes its
    /// index record. Both writes happen inside one queue sync so a reader can
    /// never see a count that disagrees with the file.
    func append(_ entry: TranscriptStore.Entry, to id: String) {
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                var line = try JSONEncoder().encode(entry)
                line.append(0x0A)   // JSONL: one object per line
                let url = transcriptURL(id)
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                    try handle.close()
                } else {
                    try line.write(to: url)
                }
            } catch {
                print("SESSIONS_APPEND_ERROR error=\(error)")
                fflush(stdout)
            }
            updateMetadataLocked(id, role: entry.role, text: entry.text)
        }
    }

    /// The FULL turn list for a session, oldest first. The caller decides how
    /// much of it reaches a model; the transcript itself is never truncated.
    func turns(for id: String) -> [(role: String, text: String)] {
        queue.sync {
            guard let data = try? Data(contentsOf: transcriptURL(id)) else { return [] }
            let decoder = JSONDecoder()
            return data
                .split(separator: 0x0A)
                .compactMap { raw -> TranscriptStore.Entry? in
                    try? decoder.decode(TranscriptStore.Entry.self, from: Data(raw))
                }
                .map { (role: $0.role, text: $0.text) }
        }
    }

    /// Recomputes `turnCount` from the file (never trusted incrementally) and
    /// stamps `updatedAt`. The title is fixed on the first USER message and
    /// left alone afterwards, so a conversation's label cannot drift mid-chat.
    func updateTitleTurnCount(_ id: String) {
        queue.sync { updateMetadataLocked(id, role: nil, text: nil) }
    }

    private func updateMetadataLocked(_ id: String, role: String?, text: String?) {
        var all = readIndex()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        let count = turnsLocked(id).count
        let untitled = all[index].title == Self.untitled
        if untitled, let role, role == ChatMessage.Role.user.rawValue, let text {
            let candidate = Self.title(from: text)
            if !candidate.isEmpty { all[index].title = candidate }
        }
        all[index].turnCount = count
        all[index].updatedAt = Date().timeIntervalSince1970
        writeIndex(all)
    }

    private func turnsLocked(_ id: String) -> [(role: String, text: String)] {
        guard let data = try? Data(contentsOf: transcriptURL(id)) else { return [] }
        let decoder = JSONDecoder()
        return data
            .split(separator: 0x0A)
            .compactMap { raw -> TranscriptStore.Entry? in
                try? decoder.decode(TranscriptStore.Entry.self, from: Data(raw))
            }
            .map { (role: $0.role, text: $0.text) }
    }

    static func title(from text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return "" }
        return flat.count > titleLimit ? String(flat.prefix(titleLimit)) + "…" : flat
    }

    func deleteSession(_ id: String) {
        queue.sync {
            try? FileManager.default.removeItem(at: transcriptURL(id))
            writeIndex(readIndex().filter { $0.id != id })
        }
    }
}