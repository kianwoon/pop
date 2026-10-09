import Foundation

/// Append-only conversation log at
/// `~/Library/Application Support/Pop/transcript.jsonl`.
///
/// One JSON object per line, `{ts, role, text}`. Append-only is the point: a
/// crash mid-write costs at most the final line, and the file stays greppable
/// and diffable, which matters once a real user is looking at it.
final class TranscriptStore: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        let ts: Double
        let role: String
        let text: String
    }

    /// `POP_TRANSCRIPT_PATH` overrides the file, mirroring `SessionStore`'s
    /// `POP_SESSIONS_PATH`: a measurement run that sends a real message must be
    /// able to write its turns somewhere without ever touching the user's log.
    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["POP_TRANSCRIPT_PATH"] {
            return URL(fileURLWithPath: override, isDirectory: false)
        }
        return PopConfig.directoryURL.appendingPathComponent("transcript.jsonl")
    }

    private let url: URL
    /// All file I/O funnels through this queue: `append` can be called from the
    /// provider's stream task while `loadAll` runs from the probe's main task.
    private let queue = DispatchQueue(label: "com.pop.transcript")

    init(url: URL = TranscriptStore.defaultURL) {
        self.url = url
    }

    func append(role: ChatMessage.Role, text: String) {
        let entry = Entry(ts: Date().timeIntervalSince1970, role: role.rawValue, text: text)
        queue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                var line = try JSONEncoder().encode(entry)
                line.append(0x0A)   // JSONL: one object per line
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                    try handle.close()
                } else {
                    try line.write(to: url)
                }
            } catch {
                print("TRANSCRIPT_APPEND_ERROR error=\(error)")
                fflush(stdout)
            }
        }
    }

    func loadAll() -> [(role: String, text: String)] {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            return data
                .split(separator: 0x0A)
                .compactMap { raw -> Entry? in
                    try? decoder.decode(Entry.self, from: Data(raw))
                }
                .map { (role: $0.role, text: $0.text) }
        }
    }
}