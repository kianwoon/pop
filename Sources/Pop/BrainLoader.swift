import Foundation

/// THE BRAIN'S THINKING, AS DATA.
///
/// The hats, the macOS automation playbook and the policies used to live as Swift
/// string literals inside `AgentLoop`. They now live in `Resources/brain.md`,
/// bundled with the app and loaded ONCE per run: the user can edit the thinking
/// without recompiling. This loader is the single source of truth for that text.
///
/// FAIL-SAFE BY CONSTRUCTION: if the file is missing or unparseable, the
/// `fallback` brain — exactly today's hardcoded strings — is served, so the
/// bytes the model receives never change because a data file went missing.
///
/// The file is found the SAME way `Resources/index.html` is (`WebResources`):
/// `Bundle.main` first (the app bundle copies `Resources/` into
/// `Contents/Resources/`), then the repo path via `#filePath` so a bare
/// `swift run`/probe binary — which has no bundle resources — still works.
enum BrainLoader {
    /// The parsed thinking.
    struct Brain: Sendable, Equatable {
        var hats: [String: String]
        var playbook: String
        var policies: [String]
        var lessons: [String]
    }

    // MARK: - Fallbacks (today's strings)

    static let fallbackHats: [String: String] = [
        "computer-use": "You are a macOS expert — a veteran field technician, the person the genius bar escalates to. Name exact panes and controls; act on screen precisely with the provided tools. Before creating anything, check what the system already provides: built-in settings panes, system assets, existing files — exhaust what exists before manufacturing anything. The on-screen context may be unrelated — the user's request decides.",
        "browser": "You are an expert web research assistant. The user's own browser (Brave, Safari, Chrome) is read with screen_read after browser_focus_tab raises the right tab; browser_read and the browser_* tools operate ONLY on Pop's own browser pane. Ground every answer in what you actually read — never present general knowledge as the user's data.",
        "files": "You are a precise file-system assistant — a meticulous archivist: read before writing; prefer read-only tools; mutating file tools need approval.",
        "web": "You are an expert research analyst. Use web_lookup and cite what you find."
    ]

    static let fallbackPlaybook = """
        [macOS automation playbook] Mac-native tasks run through apps like a \
        human: 1) app_manage open/activate the app. 2) ui_observe to list \
        actionable elements with [n] refs, or screen_read to see the pane. \
        3) act by ref (ui_ax/ui_click) so no guessed name is needed. 4) screen_read \
        after each act to verify. 5) bash is last resort — it always asks \
        approval; prefer the UI path. Settings panes load asynchronously — \
        re-read after opening.
        """

    static let fallbackPolicies: [String] = [
        "A refusal is a strategy change, announced.",
        "Never present general knowledge as the user's data.",
        "An unmeasured answer is never dressed up as a verdict.",
        "If what you read doesn't match the requested surface or content, switch reading strategy and retry — never report a mismatched read as the answer.",
        "Exhaust what exists — built-ins, system assets, existing files — before manufacturing artifacts.",
        "When no specialty fits the request, say so and proceed as a careful generalist; never fake expertise."
    ]

    static let fallbackLessons: [String] = [
        "Wallpaper swatches load asynchronously: settle and retry before reading them.",
        "System Settings acts need the app frontmost first."
    ]

    static let fallback = Brain(
        hats: fallbackHats,
        playbook: fallbackPlaybook,
        policies: fallbackPolicies,
        lessons: fallbackLessons
    )

    /// The brain, loaded ONCE per run. First access caches it.
    static let loaded: Brain = {
        if let url = locateURL(), let brain = load(from: url) {
            return brain
        }
        return fallback
    }()

    // MARK: - Public accessors

    /// The hat for a routed class. Chat (no route) and unknown classes get ""
    /// — nothing is injected, exactly as before.
    static func hat(for route: String?) -> String {
        guard let route else { return "" }
        return loaded.hats[route] ?? ""
    }

    static var playbook: String { loaded.playbook }
    static var policies: [String] { loaded.policies }
    static var lessons: [String] { loaded.lessons }

    // MARK: - Locating + parsing

    /// `Bundle.main` first, then the repo path from `#filePath`. Mirrors
    /// `WebResources.indexURL()` so both resources resolve identically in the
    /// app bundle and in a bare `swift run`/probe binary.
    static func locateURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "brain", withExtension: "md") {
            return bundled
        }
        let fromSourceTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/Pop
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Resources/brain.md")
        return FileManager.default.fileExists(atPath: fromSourceTree.path) ? fromSourceTree : nil
    }

    /// Loads and parses a brain from `url`. `nil` when the file is absent, not
    /// UTF-8, or missing the required `## Hats`/`## Playbook` sections — the
    /// caller then falls back.
    static func load(from url: URL?) -> Brain? {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return parse(text)
    }

    private enum Section { case none, hats, playbook, policies, lessons }

    /// A deliberately simple line scanner: `## section` starts a section,
    /// `### <class>` starts a hat. No nested or complex parsing — the file is
    /// data a human edits, and a lenient reader that never crashes is worth more
    /// than a strict one. Returns `nil` when no hats or no playbook were found
    /// (a corrupt file must fall back, not serve an empty brain).
    static func parse(_ text: String) -> Brain? {
        var hats: [String: String] = [:]
        var playbookLines: [String] = []
        var policies: [String] = []
        var lessons: [String] = []
        var section: Section = .none
        var currentHat: String?
        var hatLines: [String] = []

        func flushHat() {
            if let className = currentHat {
                let body = hatLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !body.isEmpty { hats[className] = body }
            }
            currentHat = nil
            hatLines = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") {
                flushHat()
                currentHat = String(trimmed.dropFirst(4))
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                continue
            }
            if trimmed.hasPrefix("## ") {
                flushHat()
                switch String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased() {
                case "hats": section = .hats
                case "playbook": section = .playbook
                case "policies": section = .policies
                case "lessons": section = .lessons
                default: section = .none
                }
                continue
            }
            guard !trimmed.isEmpty else { continue }
            switch section {
            case .hats: hatLines.append(trimmed)
            case .playbook: playbookLines.append(trimmed)
            case .policies: policies.append(trimmed)
            case .lessons: lessons.append(trimmed)
            case .none: break
            }
        }
        flushHat()

        guard !hats.isEmpty, !playbookLines.isEmpty else { return nil }
        return Brain(
            hats: hats,
            playbook: playbookLines.joined(separator: " "),
            policies: policies,
            lessons: lessons
        )
    }
}
