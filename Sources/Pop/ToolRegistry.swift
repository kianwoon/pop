import Foundation

/// A minimal JSON tree.
///
/// Hand-rolled rather than pulled from a package: Pop carries ZERO third-party
/// dependencies, and a tool argument bag needs exactly six cases. `Codable` so a
/// tool schema can be emitted to a provider and a tool result can be read back
/// from a model's JSON arguments without any intermediate dictionary.
enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Plain-JSON object for `JSONSerialization`, which is what both provider
    /// request bodies are built with.
    var foundationObject: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map(\.foundationObject)
        case .object(let values):
            var out: [String: Any] = [:]
            for (key, value) in values { out[key] = value.foundationObject }
            return out
        }
    }

    static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Sorted-key JSON text: the byte-stable form the prefix hash is taken over.
    /// Dictionary iteration order is not stable, and a hash that changes when
    /// nothing else did would make the cache marker a liar.
    func stableString() -> String {
        switch self {
        case .string(let value):
            return "\"" + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        case .number(let value):
            // Whole numbers print without a trailing `.0`: a browser ref of 2
            // is `[2]` on the page, and the log saying `2.0` would read as a
            // different number than the one the model must use.
            if value.rounded() == value, abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .array(let values):
            return "[" + values.map { $0.stableString() }.joined(separator: ",") + "]"
        case .object(let values):
            return "{" + values.keys.sorted().map { key in
                "\"\(key)\":" + (values[key]?.stableString() ?? "null")
            }.joined(separator: ",") + "}"
        }
    }
}

/// One tool's name, one-line description, and JSON-Schema parameters.
struct ToolSchema: Sendable, Equatable {
    var name: String
    var description: String
    /// An object schema: `{"type":"object","properties":{…},"required":[…]}`.
    var parameters: JSONValue
}

/// A read-only local capability the model may invoke.
///
/// The whole surface is a value: a name, a description, a schema, and an async
/// body returning the result as plain text. A tool failure is a RETURNED string,
/// never a thrown error into the stream — the model has to read what went wrong
/// and recover, which is the whole point of feeding results back in.
struct PopTool: Sendable {
    struct Property: Sendable {
        var name: String
        var description: String
        var required: Bool
    }

    /// Whether this tool only reads, or can change the machine.
    ///
    /// Load-bearing, not documentation. `readOnly` runs SILENTLY — no card, no
    /// round trip to the user — because asking about every read would train the
    /// user to click Run without reading. `mutating` is the ONLY class that ever
    /// reaches `ApprovalGate`, whatever called it; the remote file/shell tools
    /// are the eight of that class.
    ///
    /// The trust model (the user's design verdict): Pop is the user's assistant,
    /// so the user does not approve every ON-SCREEN step. `localNav` covers the
    /// local actions — focus a tab, bring a URL forward, click a point, TYPE
    /// into a field, INCLUDING the newline send — which run WITHOUT a card; the
    /// code guards still hold (a click must land inside a visible app window,
    /// and every action is logged). The user explicitly accepted the
    /// send-autonomy trade-off: there is no send gate. `mutating` (files,
    /// shell) stays gated and remote-only.
    enum Access: String, Sendable, Equatable {
        case readOnly
        case mutating
        /// Local navigation: autonomous local input (focus a tab, open a URL,
        /// click a point, type text, send). No approval card; the click bounds
        /// guard still runs.
        case localNav
    }

    /// Whether this class must reach `ApprovalGate`. One predicate, so the gate
    /// in `execute` and the classification probe cannot disagree about what is
    /// gated. Navigation-class local actions are autonomous by the user's
    /// design; only file/shell mutation is gated.
    static func requiresApproval(_ access: Access) -> Bool {
        access == .mutating
    }

    /// Whether the ON-DEVICE brain may be given a tool of this class.
    /// Read-only capabilities plus every local action (navigation or typing);
    /// never the file-writing, shell-running class.
    static func onDeviceEligible(_ access: Access) -> Bool {
        access == .readOnly || access == .localNav
    }

    /// The one-word severity the approval card shows, per class. `bash` runs
    /// the user's real shell with their permissions, so it is always the
    /// loudest; a local action names itself because "changes files" would be
    /// a lie about a keystroke.
    var riskLabel: String {
        if let riskLabelOverride { return riskLabelOverride }
        switch access {
        case .readOnly: return "reads"
        case .mutating: return "changes files"
        case .localNav: return "controls your screen"
        }
    }

    var name: String
    var description: String
    var properties: [Property]
    var access: Access
    /// Overrides the registry-wide `perToolTimeout` for a tool that legitimately
    /// needs longer than a read. `nil` means the shared bound.
    var timeout: TimeInterval?
    /// A more specific approval-card label than the class default, for a tool
    /// whose severity the class word cannot name ("quits an app" reads truer
    /// than "changes files" on a graceful quit). `nil` keeps the class label.
    var riskLabelOverride: String? = nil
    var run: @Sendable ([String: JSONValue]) async throws -> String

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: description,
            parameters: .object([
                "type": .string("object"),
                "properties": .object(Dictionary(uniqueKeysWithValues: properties.map { property in
                    (
                        property.name,
                        JSONValue.object([
                            "type": .string("string"),
                            "description": .string(property.description)
                        ])
                    )
                })),
                "required": .array(properties.filter { $0.required }.map { .string($0.name) })
            ])
        )
    }
}

/// A tool call rejected or failed: the reason travels back to the model as text.
struct ToolFailure: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

enum ToolRegistry {
    /// Bounded because a tool result rides into the next request: an unbounded
    /// read would blow the context window rather than answer anything.
    static let readByteCap = 200 * 1024
    static let shellByteCap = 20 * 1024
    static let dirEntryCap = 200
    static let searchMatchCap = 50
    static let searchLineCap = 200
    static let shellTimeout: TimeInterval = 10
    static let perToolTimeout: TimeInterval = 15

    /// `grep_files` returns MORE than `search_files` because regex is the
    /// model's actual question ("where is this called?"), while both stay
    /// bounded because every byte rides into the next request.
    static let grepMatchCap = 200
    static let grepLineCap = 200
    /// Files VISITED before giving up. A `~` glob with a loose pattern would
    /// otherwise walk the whole account looking for a 200th match.
    static let globScanCap = 20_000
    static let globMatchCap = 200
    static let bashTimeout: TimeInterval = 30
    static let bashByteCap = 50 * 1024

    static let searchExtensions: Set<String> = [
        "txt", "md", "json", "js", "ts", "swift", "py", "sh", "csv"
    ]

    /// The ONLY shell verbs Pop will run. Read-only inspection, no pipes, no
    /// redirection: `shell` exists for the long tail, not as a second shell.
    static let shellAllowlist = [
        "date", "ls", "pwd", "whoami", "uname", "df", "du", "wc", "stat", "echo"
    ]

    /// Metacharacters that make a "single command" into a program. Rejected
    /// outright rather than parsed: no shell is invoked at all.
    static let shellForbiddenCharacters: Set<Character> = ["|", ";", "&", "$", "`", ">", "<", "\n"]

    /// The allowed root. `~` for the app; `POP_TOOL_ROOT` so a probe never reads
    /// the user's real files.
    static var allowedRoot: URL {
        if let override = ProcessInfo.processInfo.environment["POP_TOOL_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    /// Whether file tools may leave `allowedRoot`.
    ///
    /// The user asked for the full toolset, so this defaults to TRUE: the whole
    /// point of the assistant is being useful across the account, and a
    /// root-restricted `write_file` cannot edit the file the user actually
    /// named. Turning it off restores the sandbox.
    ///
    /// `POP_ALLOW_EXTERNAL_PATHS` overrides the config so the sandbox probe can
    /// prove the rejection path without depending on what the user last saved
    /// in Settings.
    enum PathScope: String, Sendable {
        case anywhere
        case restricted
    }

    static var pathScope: PathScope {
        if let raw = ProcessInfo.processInfo.environment["POP_ALLOW_EXTERNAL_PATHS"] {
            return raw == "0" ? .restricted : .anywhere
        }
        return (try? PopConfig.load())?.allowExternalPaths == false ? .restricted : .anywhere
    }

    static var allowsExternalPaths: Bool { pathScope == .anywhere }

    /// The tools, FIXED and ALPHABETICAL.
    ///
    /// Both properties are load-bearing. Alphabetical because the tool list is
    /// hashed into the stable prompt prefix: a registry built from a Dictionary
    /// or a Set would reorder between runs and silently invalidate the
    /// upstream prompt cache on every single turn.
    static let tools: [PopTool] = [
        PopTool(
            name: "apply_patch",
            description: """
            Apply a unified-diff patch to one file, hunk by hunk. Aborts on the \
            first hunk that does not match; nothing is written unless every hunk applied.
            """,
            properties: [
                PopTool.Property(name: "path", description: "Absolute path of the file to patch.", required: true),
                PopTool.Property(name: "patch", description: "The patch text, with @@ hunk headers.", required: true)
            ],
            access: .mutating
        ) { args in
            try applyPatch(
                to: resolveFile(argument(args, "path")),
                patch: rawArgument(args, "patch")
            )
        },

        PopTool(
            name: "bash",
            description: """
            Run a shell command with the user's own permissions. Needs one approval \
            click; bounded to \(Int(bashTimeout))s and \(bashByteCap / 1024)KB of output. \
            The working directory is the allowed root. Last resort for macOS \
            settings changes (wallpaper, appearance, sound): drive the System \
            Settings UI with ui_* tools instead — shell bypasses are opaque and \
            need approval every time.
            """,
            properties: [PopTool.Property(name: "command", description: "The command line to run.", required: true)],
            access: .mutating,
            timeout: bashTimeout
        ) { args in
            try runShell(argument(args, "command"))
        },

        // THE SURFACE BOUNDARY. These eight tools drive Pop's OWN panel webview
        // (`BrowserController.shared`); none can touch a page open in the
        // user's external browser. The measured failure: a routed Brave task
        // focused, navigated and read the user's own browser correctly, then
        // called `browser_extract` — a panel-webview tool — and pulled 117 bytes
        // from Pop's own panel instead of Brave, so the turn died with no
        // summary. The boundary must be stated WHERE THE MODEL CHOOSES TOOLS, so
        // each description carries it. The external browser is served instead by
        // `browser_focus_tab` + `browser_open_url` + `screen_read` + `ui_*`.
        PopTool(
            name: "browser_back",
            description: "Go back to the previous page in Pop's browser pane. Pop's browser pane only — for a page open in the user's own browser (Brave/Safari/Chrome), use browser_focus_tab + screen_read instead.",
            properties: [],
            access: .readOnly
        ) { _ in
            await BrowserController.shared.back()
        },

        PopTool(
            name: "browser_click",
            description: """
            Click an element on the current page by its ref from browser_read. \
            Scrolled into view first. Needs one approval click. Pop's browser \
            pane only — for a page open in the user's own browser \
            (Brave/Safari/Chrome), use browser_focus_tab + screen_read instead.
            """,
            properties: [PopTool.Property(name: "ref", description: "The [n] ref number.", required: true)],
            access: .mutating
        ) { args in
            await BrowserController.shared.click(ref: try integerArgument(args, "ref"))
        },

        PopTool(
            name: "browser_extract",
            description: """
            Pull the current page's repeated records (cards, list items) as JSON \
            rows — e.g. notifications, products, listings. Optional fields name \
            each value per record; omitted, each row is the card's visible text. \
            At most 50 rows. Pop's browser pane only — for a page open in the \
            user's own browser (Brave/Safari/Chrome), use browser_focus_tab + \
            screen_read instead.
            """,
            properties: [PopTool.Property(
                name: "fields",
                description: "Optional comma-separated field names to label each record (e.g. title,company,date). Omit to extract each repeated card's visible text.",
                required: false
            )],
            access: .readOnly
        ) { args in
            let raw = args["fields"].flatMap(ToolRegistry.stringValue) ?? ""
            var fields = raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // Omitted (or cleaned-empty) `fields` means "each card's visible
            // text": one generic `text` field, which the page script maps to the
            // row's joined text rather than a positional first cell.
            if fields.isEmpty { fields = ["text"] }
            return await BrowserController.shared.extract(fields: fields)
        },

        PopTool(
            name: "browser_navigate",
            description: """
            Load an http(s) URL in Pop's browser pane and return the page title. \
            file://, javascript: and data: are refused. Pop's browser pane only \
            — for a page open in the user's own browser (Brave/Safari/Chrome), \
            use browser_focus_tab + screen_read instead.
            """,
            properties: [PopTool.Property(name: "url", description: "Absolute http(s) URL.", required: true)],
            access: .readOnly
        ) { args in
            await BrowserController.shared.navigate(try argument(args, "url"))
        },

        PopTool(
            name: "browser_read",
            description: """
            Read the current page: its title, visible text, and a numbered list \
            of the interactive elements as [n] <tag> \"label\". The refs are the only \
            way to act on the page, and any navigation invalidates them. Pop's \
            browser pane only — for a page open in the user's own browser \
            (Brave/Safari/Chrome), use browser_focus_tab + screen_read instead.
            """,
            properties: [],
            access: .readOnly
        ) { _ in
            await BrowserController.shared.readPage()
        },

        PopTool(
            name: "browser_select_option",
            description: "Choose an option in a <select> element by its ref and option value. Pop's browser pane only — for a page open in the user's own browser (Brave/Safari/Chrome), use browser_focus_tab + screen_read instead.",
            properties: [
                PopTool.Property(name: "ref", description: "The [n] ref number.", required: true),
                PopTool.Property(name: "value", description: "The option value or visible text.", required: true)
            ],
            access: .mutating
        ) { args in
            await BrowserController.shared.selectOption(
                ref: try integerArgument(args, "ref"),
                value: try argument(args, "value")
            )
        },

        PopTool(
            name: "browser_submit",
            description: """
            Submit the page's form the way a person would, so the site's own \
            validation and handler run. Needs one approval click. Pop's browser \
            pane only — for a page open in the user's own browser \
            (Brave/Safari/Chrome), use browser_focus_tab + screen_read instead.
            """,
            properties: [],
            access: .mutating
        ) { _ in
            await BrowserController.shared.submit()
        },

        PopTool(
            name: "browser_type_field",
            description: "Type text into an input or textarea by its ref, firing the events a page listens for. Pop's browser pane only — for a page open in the user's own browser (Brave/Safari/Chrome), use browser_focus_tab + screen_read instead.",
            properties: [
                PopTool.Property(name: "ref", description: "The [n] ref number.", required: true),
                PopTool.Property(name: "text", description: "The text to type.", required: true)
            ],
            access: .mutating
        ) { args in
            await BrowserController.shared.typeField(
                ref: try integerArgument(args, "ref"),
                text: try argument(args, "text")
            )
        },

        PopTool(
            name: "edit_file",
            description: "Replace one exact, unambiguous occurrence of a string in a file.",
            properties: [
                PopTool.Property(name: "path", description: "Absolute file path.", required: true),
                PopTool.Property(name: "oldText", description: "The exact text to replace; must appear exactly once.", required: true),
                PopTool.Property(name: "newText", description: "The replacement text.", required: false)
            ],
            access: .mutating
        ) { args in
            try editFile(
                at: resolveFile(argument(args, "path")),
                oldText: rawArgument(args, "oldText"),
                newText: args["newText"].flatMap(ToolRegistry.stringValue) ?? ""
            )
        },

        PopTool(
            name: "glob_files",
            description: """
            Find files by name pattern (shell glob, e.g. `*.swift` or `Package.*`) under \
            a directory, recursively. Returns at most \\(globMatchCap) paths.
            """,
            properties: [
                PopTool.Property(name: "pattern", description: "Glob to match against each file name.", required: true),
                PopTool.Property(name: "path", description: "Directory to search, recursively.", required: true)
            ],
            access: .readOnly
        ) { args in
            try globFiles(pattern: argument(args, "pattern"), root: argument(args, "path"))
        },

        PopTool(
            name: "grep_files",
            description: """
            Search file CONTENTS with a regular expression and return file:line matches. \
            Optional glob narrows which files are read. At most \(grepMatchCap) matches.
            """,
            properties: [
                PopTool.Property(name: "pattern", description: "Regular expression to search for.", required: true),
                PopTool.Property(name: "path", description: "Directory to search, recursively.", required: true),
                PopTool.Property(name: "glob", description: "Optional glob limiting which files are searched.", required: false)
            ],
            access: .readOnly
        ) { args in
            try grepFiles(
                pattern: argument(args, "pattern"),
                root: argument(args, "path"),
                glob: args["glob"].flatMap(ToolRegistry.stringValue)
            )
        },

        PopTool(
            name: "list_dir",
            description: "List the names and sizes of the entries in a directory.",
            properties: [PopTool.Property(name: "path", description: "Absolute directory path.", required: true)],
            access: .readOnly
        ) { args in
            let dir = try resolveDirectory(argument(args, "path"))
            return listDirectory(dir)
        },

        PopTool(
            name: "screen_read",
            description: """
            Read the text currently visible in the frontmost on-screen browser \
            window (Safari, Chrome or Brave) using on-screen OCR, and list the \
            OTHER browser windows on screen by title. Use it when the user asks \
            what a page, tab or screen says. Returns the window's app, title and \
            visible text, or an explanation of why it could not be read. \
            `scope:"all"` reads EVERY browser window instead (use it only when \
            the answer is not in the front window, or the user names a window \
            you cannot see); `scope:"region"` with `rect:"x,y,w,h"` re-reads one \
            screen rect. Only VISIBLE content is read: a background TAB inside a \
            window is not visible in it. When the front window does not contain \
            what the user asks about, the next step is `browser_focus_tab` on the \
            site or app name the USER named — and if that reports no matching tab, \
            that exact query matched no tab; say so and what to open, do not give up.
            """,
            properties: [
                PopTool.Property(
                    name: "scope",
                    description: "Optional: \"front\" (default, frontmost window only), \"all\" (every browser window) or \"region\" (with rect).",
                    required: false
                ),
                PopTool.Property(
                    name: "rect",
                    description: "Optional for scope=region: the screen rect as x,y,w,h.",
                    required: false
                )
            ],
            // READ-ONLY: it reads pixels and returns text. It cannot change the
            // machine, so it must never raise an approval card — a read the user
            // is asked to approve is a read they will approve without reading.
            access: .readOnly
        ) { args in
            let scope = try screenScope(args)
            let reading = await ScreenOCR.read(scope: scope)
            // Prepend ONE identity line (frontmost app — window title (host)) so
            // the model knows WHICH tab it read; see ScreenOCR.readingIdentityLine.
            return ScreenOCR.modelFacingText(reading, identity: ScreenOCR.readingIdentityLine())
        },

        PopTool(
            name: "plan_update",
            description: """
            Show the user the plan for a MULTI-STEP request AND run it. PREFER \
            the ONE-CALL form: pass `run`, a JSON array of \
            {"label": "...", "tool": "...", "arguments": { ... }} steps in the \
            order they must happen, with each tool's COMPLETE arguments (a \
            multi-step screen or app task should use this). Pop executes every \
            step in order with no pause between them, showing the plan live, \
            then asks you ONCE to compose the answer from the results; if a step \
            fails it stops and asks you ONCE to explain the blocked step. Use \
            the `steps`/`status`/`ready` arguments only to update a plan \
            WITHOUT running it (each call REPLACES what the user sees). \
            Read-only and silent — it changes nothing on the machine by itself. \
            Answer a simple one-shot question directly and make no plan. \
            \(PlanTrace.verifyRule)
            """,
            properties: [
                PopTool.Property(
                    name: "run",
                    description: """
                    Optional whole plan to execute now: a JSON array of \
                    {"label": "...", "tool": "...", "arguments": { ... }} steps, \
                    in order. Add "see": true to a step whose RESULT you must see \
                    before the remaining steps make sense (the next step's \
                    arguments depend on it, or you must verify what is on \
                    screen). Unmarked steps execute straight through; the \
                    executor hands you every step's receipt and screen read \
                    either way.
                    """,
                    required: false
                ),
                PopTool.Property(
                    name: "steps",
                    description: "Optional new step list, `|`-separated, e.g. \"find the window | read it\".",
                    required: false
                ),
                PopTool.Property(
                    name: "status",
                    description: "Optional status changes, e.g. \"1 done, 2 running: reading\". Each entry is the step number then pending/running/done/blocked.",
                    required: false
                ),
                PopTool.Property(
                    name: "ready",
                    description: "Optional \"true\" when the final answer is complete.",
                    required: false
                )
            ],
            // READ-ONLY: it records what Pop intends to do and shows the user.
            // It cannot change the machine, so it must never raise an approval
            // card — a progress note the user must click to allow is not
            // progress.
            access: .readOnly
        ) { args in
            do {
                return try PlanTraceStore.shared.apply(
                    stepsText: args["steps"].flatMap(ToolRegistry.stringValue),
                    statusText: args["status"].flatMap(ToolRegistry.stringValue),
                    readyText: args["ready"].flatMap(ToolRegistry.stringValue)
                )
            } catch let error as PlanTrace.ParseError {
                // A malformed update is text the model reads and fixes; it is
                // never a crash and never a silently applied wrong plan.
                return "ERROR: \(error.message)"
            }
        },

        PopTool(
            name: "browser_open_url",
            description: """
            Bring a URL forward in the user's default browser (Safari, Chrome or \
            Brave, whatever is their default). Reuses the matching tab the user \
            already has open (active first, then closest path) instead of opening \
            a new one. Navigation: it changes what is on \
            screen, so it runs WITHOUT an approval card, but every action is \
            logged. Returns only what the system opener confirmed; it does not \
            tell you whether an existing tab was activated or a new one opened — \
            use `screen_read` to find out. Works on the user's own browser; \
            page CONTENT there is read with screen_read. \
            \(BrowserActions.verifyAfterActRule)
            """,
            properties: [
                PopTool.Property(
                    name: "url",
                    description: "The absolute http, https or file URL to bring forward.",
                    required: true
                )
            ],
            // localNav: navigation-class local input, so it runs autonomously and
            // the on-device brain may use it.
            access: .localNav
        ) { args in
            await BrowserActions.openURL(try argument(args, "url"))
        },

        PopTool(
            name: "browser_focus_tab",
            description: """
            Activate the browser and raise the window whose tab's URL or title \
            contains `query` (case-insensitive), across EVERY window — the way \
            to bring a buried, background-tab or minimized page to the front. \
            Among matching tabs it prefers the active tab of the front window, \
            then the earliest match. Focusing does not load a different page — to \
            reach a specific page on a site you already have open, use \
            `browser_open_url` (it navigates the existing tab in place). \
            Navigation: it raises a window and activates the browser, so it runs \
            WITHOUT an approval card, and every action is logged; it never \
            closes, navigates or edits anything. \
            Reports the window and tab it raised, or that no matching tab \
            exists, or that the browser is not running or not permitted. Prefer \
            this over any `ui_click` for reaching a buried page; then \
            `screen_read` again to confirm. Works on the user's own browser; \
            page CONTENT there is read with screen_read. \
            \(BrowserActions.verifyAfterActRule)
            """,
            properties: [
                PopTool.Property(
                    name: "query",
                    description: "Substring of the tab's URL or title, case-insensitive (e.g. a site name or URL fragment).",
                    required: true
                ),
                PopTool.Property(
                    name: "browser",
                    description: "Optional browser bundle id (one of Pop's allowlisted browsers); defaults to the user's default browser.",
                    required: false
                )
            ],
            // localNav: navigation-class local input, so it runs autonomously and
            // the on-device brain may use it.
            access: .localNav,
            // AppleScript may wait on the first-use Automation (TCC) prompt, so
            // this action gets a longer ceiling than a file read.
            timeout: 60
        ) { args in
            await TabFocus.focus(
                query: try argument(args, "query"),
                browser: args["browser"].flatMap(ToolRegistry.stringValue)
            )
        },

        PopTool(
            name: "ui_click",
            description: """
            Left-click at absolute screen coordinates, e.g. the centre of a \
            `screen_read` line: x + w/2, y + h/2 — OR pass a `ref` from \
            `ui_observe` to click an element at its own position (no coordinate \
            arithmetic, no guessed spot). Navigation: a click changes focus or \
            opens something, so it runs WITHOUT an approval card, and every \
            click is logged. It is refused outright when the point is outside \
            every on-screen app window — Pop will not click its own panel or the \
            desktop. Works on any visible app window (System Settings, apps, \
            browsers) — the human path for macOS settings changes. Read \
            `screen_read` first for the coordinates, and for a buried page \
            prefer `browser_focus_tab`. \
            \(BrowserActions.verifyAfterActRule)
            """,
            properties: [
                PopTool.Property(
                    name: "x",
                    description: "Horizontal screen coordinate (integer) from the latest `screen_read`. Omit when using `ref`.",
                    required: false
                ),
                PopTool.Property(
                    name: "y",
                    description: "Vertical screen coordinate (integer) from the latest `screen_read`. Omit when using `ref`.",
                    required: false
                ),
                PopTool.Property(
                    name: "ref",
                    description: "Optional [n] ref from ui_observe; clicks that element at its own position instead of x/y.",
                    required: false
                )
            ],
            access: .localNav
        ) { args in
            if let ref = try? integerArgument(args, "ref") {
                return await UIAct.clickObserved(ref: ref)
            }
            return await BrowserActions.click(
                x: try integerArgument(args, "x"),
                y: try integerArgument(args, "y")
            )
        },

        PopTool(
            name: "ui_type",
            description: """
            Type text into whatever currently has focus. Typing is REVERSIBLE \
            (clear the field and it is gone) and the newline that presses Return \
            is autonomous too: there is no approval card and nothing to wait \
            for, so a newline in `text` sends the message. Every keystroke is \
            logged. Click the field first with `ui_click`, then verify with \
            `screen_read`. \
            \(BrowserActions.verifyAfterActRule)
            """,
            properties: [
                PopTool.Property(
                    name: "text",
                    description: "The exact text to type. A newline presses Return, which sends the message.",
                    required: true
                )
            ],
            access: .localNav
        ) { args in
            await BrowserActions.type(try rawStringArgument(args, "text"))
        },

        PopTool(
            name: "ui_key",
            description: """
            Press one named key or a modifier combo in the frontmost app — \
            return, tab, escape, delete, space, the arrow keys, or a combo such \
            as "cmd+w" (close a tab) or "cmd+shift+t" (reopen it). MUTATING: it \
            raises an approval card before any key event is posted. Prefer \
            `ui_ax` (press an element by its accessibility title) when a control \
            can be named; use `ui_key` for keyboard shortcuts and menu keys. \
            \(BrowserActions.verifyAfterActRule)
            """,
            properties: [
                PopTool.Property(
                    name: "key",
                    description: "A named key (return, tab, escape, delete, space, up, down, left, right) or a modifier combo such as cmd+w, cmd+shift+t, alt+left.",
                    required: true
                )
            ],
            access: .mutating,
            riskLabelOverride: "presses keys"
        ) { args in
            await UIAct.pressKey(try argument(args, "key"))
        },

        PopTool(
            name: "ui_scroll",
            description: """
            Scroll a point inside an on-screen app window — by default the \
            centre of the visible app windows. MUTATING: raises an approval \
            card, and a supplied point outside every on-screen app window is \
            refused without an event. Works on any visible app window (System \
            Settings, apps, browsers) — the human path for macOS settings \
            changes. `direction` is up, down, left or right; \
            `amount` is wheel ticks (default 3). \
            \(BrowserActions.verifyAfterActRule)
            """,
            properties: [
                PopTool.Property(
                    name: "direction",
                    description: "Scroll direction: up, down, left or right.",
                    required: true
                ),
                PopTool.Property(
                    name: "amount",
                    description: "Optional wheel ticks to scroll (a positive integer); defaults to 3.",
                    required: false
                ),
                PopTool.Property(
                    name: "x",
                    description: "Optional horizontal screen coordinate to scroll at; defaults to the visible app window centre.",
                    required: false
                ),
                PopTool.Property(
                    name: "y",
                    description: "Optional vertical screen coordinate to scroll at; defaults to the visible app window centre.",
                    required: false
                )
            ],
            access: .mutating,
            riskLabelOverride: "scrolls your screen"
        ) { args in
            await UIAct.scroll(
                direction: try argument(args, "direction"),
                amount: (try? integerArgument(args, "amount")) ?? 3,
                x: try? integerArgument(args, "x"),
                y: try? integerArgument(args, "y")
            )
        },

        PopTool(
            name: "ui_ax",
            description: """
            Act on an accessibility element — the precise, coordinate-free \
            path, preferred over blind clicking. Name it either by `ref` from \
            `ui_observe` (the identity path — no guessing, and a stale ref is \
            refused) or by `title`, a case-insensitive substring of its \
            accessibility title/description. Then performs `action`: "press" \
            (click it), "setValue" (write `value` into it) or "setSelected" \
            (select it). The result names the acted element's role and title, or \
            a precise failure. MUTATING: raises an approval card. \
            Works on any visible app window (System Settings, apps, browsers) \
            — the human path for macOS settings changes.
            \(BrowserActions.verifyAfterActRule)
            """,
            properties: [
                PopTool.Property(
                    name: "action",
                    description: "One of: press, setValue, setSelected.",
                    required: true
                ),
                PopTool.Property(
                    name: "title",
                    description: "Accessibility label/title text to find, case-insensitive substring (e.g. \"Submit\"). Required unless `ref` is given.",
                    required: false
                ),
                PopTool.Property(
                    name: "value",
                    description: "The value to write; required when action is setValue.",
                    required: false
                ),
                PopTool.Property(
                    name: "ref",
                    description: "Optional [n] ref from ui_observe; acts on that element directly, with no title matching.",
                    required: false
                )
            ],
            access: .mutating,
            riskLabelOverride: "acts on a control"
        ) { args in
            await UIAct.axAction(
                action: try argument(args, "action"),
                title: args["title"].flatMap(ToolRegistry.stringValue),
                value: args["value"].flatMap(ToolRegistry.stringValue),
                ref: try? integerArgument(args, "ref")
            )
        },

        PopTool(
            name: "ui_observe",
            description: """
            List the FRONTMOST app's actionable accessibility elements, each \
            with a stable [n] ref: buttons, fields, checkboxes and menu items. \
            Read-only. Act on one with `ui_ax` (press/setValue) or `ui_click` by \
            its ref — the ref path needs no guessed title and cannot land on the \
            wrong element. Re-run after switching apps: a ref is stale once \
            another app is frontmost.
            """,
            properties: [],
            access: .readOnly
        ) { _ in
            await UIAct.observe()
        },

        PopTool(
            name: "app_manage",
            description: """
            Activate, gracefully quit, or open a macOS application by bundle id \
            or name. The human way to open or focus an app whose settings you \
            need — e.g. System Settings — before using ui_* on it. MUTATING: \
            raises an approval card — a quit asks the app to \
            close (never a force-kill). Reports the frontmost app after an \
            activation or open, or whether the app is still running after a \
            quit. \
            \(BrowserActions.verifyAfterActRule)
            """,
            properties: [
                PopTool.Property(
                    name: "action",
                    description: "One of: activate, quit, open.",
                    required: true
                ),
                PopTool.Property(
                    name: "app",
                    description: "The application's bundle id (com.apple.Safari) or its name (Safari).",
                    required: true
                )
            ],
            access: .mutating,
            // One label must cover activate AND quit AND open, so it names the
            // class of power, not one action — "quits an app" would mislabel an
            // activate card.
            riskLabelOverride: "controls another app"
        ) { args in
            await UIAct.manageApp(
                action: try argument(args, "action"),
                app: try argument(args, "app")
            )
        },

        PopTool(
            name: "list_tools",
            description: "List Pop's available tools with a one-line description of each.",
            properties: [],
            access: .readOnly
        ) { _ in
            tools
                .map { "\($0.name): \($0.description)" }
                .joined(separator: "\n")
        },

        PopTool(
            name: "read_file",
            description: "Read a UTF-8 text file and return its contents.",
            properties: [PopTool.Property(name: "path", description: "Absolute file path.", required: true)],
            access: .readOnly
        ) { args in
            let url = try resolveFile(argument(args, "path"))
            return try readFile(url)
        },

        PopTool(
            name: "search_files",
            description: "Search text files for a literal substring and return file:line matches.",
            properties: [
                PopTool.Property(name: "query", description: "Literal text to look for.", required: true),
                PopTool.Property(name: "path", description: "Directory to search, recursively.", required: true)
            ],
            access: .readOnly
        ) { args in
            try searchFiles(query: argument(args, "query"), root: argument(args, "path"))
        },

        PopTool(
            name: "shell_readonly",
            description: """
            Run one read-only inspection command. Only \(shellAllowlist.joined(separator: ", ")) \
            and `git status` are allowed; no pipes, chaining, redirection or substitution.
            """,
            properties: [PopTool.Property(name: "command", description: "The single command to run.", required: true)],
            access: .readOnly
        ) { args in
            try runReadOnlyShell(argument(args, "command"))
        },

        PopTool(
            name: "web_lookup",
            description: """
            Look something up on the web with Pop's own offscreen browser and \
            return a short excerpt plus its source. Read-only. ALWAYS performs \
            the search and answers from the page: never ask the user for missing \
            details first. The lookup automatically uses the user's location, so \
            NEVER ask for or require a location. \(WebLookup.pageQuestionRule)
            """,
            properties: [
                PopTool.Property(name: "query", description: "The natural-language question.", required: true),
                PopTool.Property(
                    name: "parameters",
                    description: "Optional extra parameters you already know (a date, a place), appended to the query.",
                    required: false
                )
            ],
            access: .readOnly
        ) { args in
            let query = try argument(args, "query")
            let extra = args["parameters"].flatMap(ToolRegistry.stringValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let full = extra.isEmpty ? query : query + " " + extra
            return await WebLookup.run(query: full).modelText
        },

        PopTool(
            name: "write_file",
            description: "Create or overwrite a file with the given content.",
            properties: [
                PopTool.Property(name: "path", description: "Absolute file path.", required: true),
                PopTool.Property(name: "content", description: "The full file content to write.", required: true)
            ],
            access: .mutating
        ) { args in
            try writeFile(
                to: resolvePath(argument(args, "path"), requireDirectory: false, mustExist: false),
                content: rawArgument(args, "content")
            )
        }
    ].sorted { $0.name < $1.name }

    static var names: [String] { tools.map(\.name) }

    /// Every declared parameter name across the registry, in fixed order.
    /// `FMRawArguments` reads generated content through this list.
    static var argumentNames: [String] {
        var seen: [String] = []
        for tool in tools {
            for property in tool.properties where !seen.contains(property.name) {
                seen.append(property.name)
            }
        }
        return seen
    }

    static func schemas() -> [ToolSchema] { tools.map(\.schema) }

    static func tool(named name: String) -> PopTool? {
        tools.first { $0.name == name }
    }

    /// OpenAI-shaped `tools` array. Built from the same fixed array, so the
    /// bytes are identical turn over turn.
    static func openAIToolsPayload() -> [[String: Any]] {
        schemas().map { schema in
            [
                "type": "function",
                "function": [
                    "name": schema.name,
                    "description": schema.description,
                    "parameters": schema.parameters.foundationObject
                ]
            ]
        }
    }

    /// Executes one tool call with a hard timeout, turning every failure mode
    /// into text the model can read. Never throws: a throwing tool would take
    /// the stream down with it.
    static func execute(
        _ call: (name: String, arguments: JSONValue),
        onActivity: @escaping @Sendable (String, Bool, String) async -> Void = { _, _, _ in }
    ) async -> String {
        guard let tool = tool(named: call.name) else {
            let message = "unknown tool '\(call.name)'; available: \(names.joined(separator: ", "))"
            await onActivity(call.name, false, message)
            return "ERROR: \(message)"
        }
        // WHOLE-PLAN EXECUTION. A `plan_update` call carrying a `run` payload
        // is not a plan note: it is the ENTIRE plan, executed here in order
        // with no model round between steps. The executor owns no provider
        // handle, so "rounds between steps" is structurally zero; the model is
        // consulted again only at the end (to compose) or on a blocked step.
        if tool.name == "plan_update", PlanRun.isRun(call.arguments) {
            let raw = call.arguments.objectValue["run"].flatMap(stringValue) ?? ""
            do {
                let steps = try PlanRun.parse(raw)
                let result = await executePlan(steps: steps, onActivity: onActivity)
                let ok = !result.hasPrefix("PLAN_EXEC_BLOCKED")
                print("TOOL_\(ok ? "OK" : "ERR") name=plan_update steps=\(steps.count) mode=exec")
                fflush(stdout)
                return result
            } catch let error as PlanRun.ParseError {
                await onActivity(tool.name, false, error.message)
                print("TOOL_ERR name=plan_update reason=run-parse")
                fflush(stdout)
                return "ERROR: \(error.message)"
            } catch {
                return "ERROR: \(error)"
            }
        }
        // THE GATE, at the single point every provider funnels through.
        //
        // It lives here rather than in the caller because FoundationModels
        // runs the loop INSIDE the session: a gate the OpenAI-shaped agent
        // loop owns would leave every on-device mutating call ungated.
        // Read-only and navigation-class tools are never asked. The predicate
        // is the SAME `requiresApproval` the classification probe asserts, so a
        // class this gate does not know about cannot slip through as ungated.
        // The arguments that will ACTUALLY run: the user's edited bag when they
        // edited it, the model's bag otherwise.
        let gated = PopTool.requiresApproval(tool.access)
        var effective = call.arguments
        if gated {
            let verdict = await ApprovalGate.shared.requestApproval(
                tool: tool.name,
                arguments: call.arguments
            )
            switch verdict {
            case .run(let approved, _):
                effective = approved
            case .deny, .timeout:
                // Fed back as ordinary tool text so the model reads WHY and
                // stops: an error the model can see is recoverable, a silent
                // refusal would just make it try the same thing again. A
                // TIMEOUT additionally carries `timeoutMarker` so the agent loop
                // can tell "the user refused" from "the user never answered" and
                // steer away from re-issuing the same kind of command.
                var text = "DENIED by user (or timed out) — do not retry this action"
                if case .timeout = verdict { text += " [\(ApprovalGate.timeoutMarker)]" }
                await onActivity(tool.name, false, text)
                print("TOOL_DENIED name=\(tool.name) verdict=\(verdict.marker)")
                fflush(stdout)
                return text
            }
        }
        let arguments = effective.objectValue
        // Arguments that can carry the user's OWN text (a file's contents) get
        // only a truncated single-line preview in the log; printing them
        // verbatim would be a transcript of the user's own data.
        if PopTool.requiresApproval(tool.access) {
            print("TOOL_CALL name=\(tool.name) args=\(ApprovalGate.preview(effective))")
        } else {
            print("TOOL_CALL name=\(tool.name) args=\(effective.stableString())")
        }
        fflush(stdout)
        let result = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    return try await tool.run(arguments)
                } catch {
                    return "ERROR: \((error as? ToolFailure)?.message ?? "\(error)")"
                }
            }
            group.addTask {
                let limit = tool.timeout ?? perToolTimeout
                try? await Task.sleep(for: .seconds(limit))
                return "ERROR: tool '\(tool.name)' timed out after \(Int(limit))s"
            }
            // The first result to arrive wins; the other task is cancelled by
            // leaving the group, so a slow tool cannot outlive the round.
            let first = await group.next() ?? "ERROR: tool produced no result"
            group.cancelAll()
            return first
        }
        let ok = !result.hasPrefix("ERROR:")
        await onActivity(tool.name, ok, result)
        print("TOOL_\(ok ? "OK" : "ERR") name=\(tool.name) bytes=\(result.utf8.count)")
        fflush(stdout)
        return result
    }

    /// The whole-plan executor. It runs `steps` in order, marking the LIVE plan
    /// block as it goes (so the user watches progress) and emitting each step's
    /// own activity line. It has NO provider handle: no model round can happen
    /// between steps by construction. On the first blocked step it STOPS — the
    /// remaining steps are not attempted — and returns a `PLAN_EXEC_BLOCKED`
    /// summary so the caller can ask the model exactly once how to proceed. A
    /// fully successful run returns `PLAN_EXEC_DONE` and the model is asked once
    /// to compose the answer from the collected results.
    ///
    /// A step flagged `see` is a PER-STEP CHECKPOINT: when it completes, the run
    /// stops there and returns `PLAN_EXEC_CHECKPOINT` carrying every executed
    /// step's full result in order, so the model consults with the accumulated
    /// evidence (≈11-13 s per round against the user's endpoint makes an
    /// unconditional round-between-steps expensive; the flag makes the consult
    /// opt-in per step). Steps after a checkpoint do NOT run in this burst.
    static func executePlan(
        steps: [PlanRun.Step],
        onActivity: @escaping @Sendable (String, Bool, String) async -> Void
    ) async -> String {
        PlanTraceStore.shared.setSteps(steps.map(\.label))
        await onActivity("plan_update", true, "run: \(steps.count) step(s)")
        var collected: [String] = []
        // The RAW per-step results, kept alongside the human summary so the
        // executor can compose a verified-send receipt from what it actually
        // ran (see `PlanRun.verifiedSendConfirmation`).
        var rawResults: [String] = []
        var blocked = false
        for (offset, step) in steps.enumerated() {
            let number = offset + 1
            PlanTraceStore.shared.mark(number, status: .running)
            await onActivity("plan_update", true, "step \(number) running")
            var result = await execute((step.tool, step.arguments), onActivity: onActivity)
            // T2 MICRO-ASSIST, between the act and its verify read: a failed
            // `ui_ax` step gets ONE on-device-assisted retry with a candidate
            // title Pop already observed. Fail-open — anything other than a
            // confident, matching pick leaves `result` as the original error.
            if result.hasPrefix("ERROR:"), step.tool == "ui_ax" {
                result = await Self.assistedUIAxRetry(
                    step: step,
                    original: result,
                    onActivity: onActivity
                )
            }
            if result.hasPrefix("ERROR:") {
                let note = String(result.prefix(120))
                    .replacingOccurrences(of: "\n", with: " ")
                PlanTraceStore.shared.mark(number, status: .blocked, note: note)
                await onActivity("plan_update", true, "step \(number) blocked")
                collected.append("step \(number) (\(step.tool)) FAILED: \(String(result.prefix(400)))")
                blocked = true
                break
            }
            PlanTraceStore.shared.mark(number, status: .done)
            await onActivity("plan_update", true, "step \(number) done")
            rawResults.append(result)
            collected.append("step \(number) (\(step.tool)) ok: \(String(result.prefix(400)))")
            // THE CHECKPOINT. The model declared it must SEE this step's result
            // before the rest makes sense, so the batched run STOPS here and the
            // accumulated evidence — every executed step's FULL result, in order
            // — is handed back through the ordinary post-run path. The steps
            // after this one do NOT run in this burst; the model is consulted
            // and continues however it decides. A step ERROR still escalates
            // (the branch above fires first), so a broken step never hides
            // behind a `see` flag. A `see` on the LAST step has no "rest" to
            // stop before, so it falls through to the normal post-run handback
            // (`PLAN_EXEC_DONE`/`PLAN_EXEC_CONFIRMED`) with no extra round.
            if step.see, number < steps.count {
                let executed = rawResults.count
                print("PLAN_CHECKPOINT step=\(number) executed=\(executed) total=\(steps.count)")
                fflush(stdout)
                let handback = (0..<executed).map { index in
                    "step \(index + 1) (\(steps[index].tool)) ok: \(rawResults[index])"
                }
                return "PLAN_EXEC_CHECKPOINT:\n" + handback.joined(separator: "\n")
            }
        }
        // A COMPLETED VERIFIED SEND is confirmed from the executor's OWN
        // results — no model round between the verify step and the receipt.
        // Only the action shape gets this; a world-question plan falls through
        // to `PLAN_EXEC_DONE` and the model composes its answer as before.
        if !blocked,
           let receipt = PlanRun.verifiedSendConfirmation(steps: steps, results: rawResults) {
            return "PLAN_EXEC_CONFIRMED: \(receipt)\n" + collected.joined(separator: "\n")
        }
        let head = blocked ? "PLAN_EXEC_BLOCKED" : "PLAN_EXEC_DONE"
        return head + ":\n" + collected.joined(separator: "\n")
    }

    /// T2 ASSISTED RETRY for a failed `ui_ax` step.
    ///
    /// When a `ui_ax` step misses, ask the on-device model ONCE whether one of
    /// the elements Pop already observed matches the step's own label. A
    /// confident pick retries the SAME step with that title (no ref); anything
    /// else — no observation, model unavailable, low confidence, no match, a
    /// still-failing retry — returns the ORIGINAL error unchanged. Bounded (one
    /// retry), fail-open, and task-agnostic: it uses only the step label and the
    /// candidates, never any per-app knowledge.
    @available(macOS 26.0, *)
    static func assistedUIAxRetry(
        step: PlanRun.Step,
        original: String,
        onActivity: @escaping @Sendable (String, Bool, String) async -> Void
    ) async -> String {
        let titles = (UIAct.lastObservation?.elements ?? [])
            .map(\.title)
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let candidates = titles.filter { seen.insert($0.lowercased()).inserted }
        guard !candidates.isEmpty else { return original }
        let threshold = (try? PopConfig.load())?.jevThreshold ?? 0.7
        guard let pick = await AppleFMMicro.assistedPick(
            intent: step.label,
            candidates: candidates,
            threshold: threshold
        ) else { return original }
        var arguments = step.arguments.objectValue
        arguments["title"] = .string(pick)
        arguments.removeValue(forKey: "ref")
        let retry = await execute((step.tool, .object(arguments)), onActivity: onActivity)
        return retry.hasPrefix("ERROR:") ? original : retry
    }

    /// Model rounds the executor takes BETWEEN steps. The executor holds no
    /// provider handle, so this is structurally 0; it is exposed (never
    /// incremented) so a probe can assert the property rather than assume it.
    static let executorModelRoundsBetweenSteps = 0

    // MARK: - Sandbox

    /// Resolves a model-supplied path, applying the CURRENT path scope.
    ///
    /// Symlinks are resolved BEFORE the containment test, not after: a symlink
    /// inside the root pointing at `/etc/passwd` is the obvious escape, and
    /// comparing the unresolved path would wave it through.
    ///
    /// With `allowExternalPaths` on (the default) the containment test is
    /// skipped and ANY absolute or `~`-relative path is accepted. That is the
    /// user's explicit choice; what still holds in that mode is the rule that
    /// mutating tools cannot run without an approval click.
    static func resolve(_ rawPath: String, requireDirectory: Bool) throws -> URL {
        let resolved = try resolvePath(rawPath, requireDirectory: requireDirectory, mustExist: true)
        if requireDirectory, !isDirectory(resolved) {
            throw ToolFailure(message: "not a directory: \(resolved.path)")
        }
        return resolved
    }

    /// The path algebra the mutating tools need: a file being WRITTEN does not
    /// exist yet, so `resolve` (which requires existence) cannot be its gate.
    static func resolvePath(
        _ rawPath: String,
        requireDirectory: Bool,
        mustExist: Bool
    ) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolFailure(message: "path is empty")
        }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else {
            throw ToolFailure(message: "path '\(trimmed)' is not absolute; pass an absolute path or one starting with ~")
        }
        let expanded = trimmed.hasPrefix("~")
            ? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(trimmed.dropFirst()))
            : URL(fileURLWithPath: trimmed)
        let standardized = expanded.standardizedFileURL
        // A path that does not exist yet cannot be symlink-resolved; its
        // standardized form is what containment is judged on.
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        if !allowsExternalPaths {
            let root = allowedRoot.resolvingSymlinksInPath().standardizedFileURL
            let inside = resolved.path == root.path
                || resolved.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
            guard inside else {
                throw ToolFailure(
                    message: "path '\(trimmed)' resolves outside the allowed root (\(root.path)); Pop only reaches inside it"
                )
            }
        }
        if mustExist, !FileManager.default.fileExists(atPath: resolved.path) {
            throw ToolFailure(message: "no such file: \(resolved.path)")
        }
        if requireDirectory, !isDirectory(resolved) {
            throw ToolFailure(message: "not a directory: \(resolved.path)")
        }
        return resolved
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func resolveFile(_ rawPath: String) throws -> URL {
        let url = try resolvePath(rawPath, requireDirectory: false, mustExist: true)
        guard !isDirectory(url) else {
            throw ToolFailure(message: "not a file: \(url.path)")
        }
        return url
    }

    static func resolveDirectory(_ rawPath: String) throws -> URL {
        try resolvePath(rawPath, requireDirectory: true, mustExist: true)
    }

    // MARK: - Tools

    static func argument(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key] else {
            throw ToolFailure(message: "missing required argument '\(key)'")
        }
        let text: String
        switch value {
        case .string(let raw): text = raw
        case .number(let raw): text = String(raw)
        case .bool(let raw): text = raw ? "true" : "false"
        case .null: throw ToolFailure(message: "argument '\(key)' is null")
        default:
            throw ToolFailure(message: "argument '\(key)' must be a string")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolFailure(message: "argument '\(key)' is empty")
        }
        return trimmed
    }

    /// The RAW string argument, with NO trimming. `ui_type` needs this: its
    /// newline is a Return keypress — the send — so trimming it away (as
    /// `argument` does for every other tool) would silently turn a send into a
    /// no-op. Emptiness is still refused.
    static func rawStringArgument(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key], case .string(let raw) = value else {
            throw ToolFailure(message: "missing or non-string required argument '\(key)'")
        }
        guard !raw.isEmpty else {
            throw ToolFailure(message: "argument '\(key)' is empty")
        }
        return raw
    }

    /// Parses the `screen_read` scope. Defaults to `.front`; a `region` scope
    /// needs a `rect`. An unknown scope or a missing/invalid rect is a typed
    /// failure the model reads and fixes, never a silently different read.
    static func screenScope(_ args: [String: JSONValue]) throws -> ScreenOCR.Scope {
        let raw = (args["scope"].flatMap(stringValue) ?? "front")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "", "front":
            return .front
        case "all":
            return .all
        case "region":
            guard let rect = screenRect(args["rect"]) else {
                throw ToolFailure(message: "scope \"region\" needs rect as x,y,w,h")
            }
            return .region(rect)
        default:
            throw ToolFailure(message: "unknown scope \"\(raw)\"; use front, all or region")
        }
    }

    /// Parses a screen rect from either a JSON array `[x,y,w,h]` or a string
    /// `"x,y,w,h"`. Returns nil unless exactly four numbers are present.
    static func screenRect(_ value: JSONValue?) -> CGRect? {
        guard let value else { return nil }
        let numbers: [Double]
        switch value {
        case .array(let items):
            numbers = items.compactMap { item in
                if case .number(let number) = item { return number }
                if case .string(let text) = item { return Double(text) }
                return nil
            }
        case .string(let text):
            numbers = text
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "x" || $0 == "X" })
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        case .number(let number):
            numbers = [number]
        default:
            return nil
        }
        guard numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// THE EXPECTED COORDINATE FORMAT, quoted verbatim in every rejection so the
    /// model can fix itself. The payload labels coordinates (`x=413 y=349`); a
    /// comma pair is never valid here.
    static let coordinateFormatHint =
        "x=<int> y=<int> screen coordinates from the latest screen_read"

    /// A screen-coordinate integer, parsed LENIENTLY but HONESTLY.
    ///
    /// A number, or a string such as `"413"` or `"x=413"`, is accepted. A comma
    /// pair such as `"413,349"` is AMBIGUOUS — it could be one coordinate with a
    /// thousands separator or an x,y pair — so it is REJECTED with the expected
    /// format rather than guess-split, which is exactly the confusion that
    /// wasted a click.
    static func integerArgument(_ args: [String: JSONValue], _ key: String) throws -> Int {
        let value = args[key]
        let raw: String
        switch value {
        case .number(let number):
            return try validateCoordinate(Int(number), key: key, raw: String(number))
        case .string(let text): raw = text
        case .bool: throw ToolFailure(message: "argument '\(key)' must be a number")
        case .null: throw ToolFailure(message: "argument '\(key)' is null")
        default: throw ToolFailure(message: "argument '\(key)' must be a number")
        }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leading `x=`/`y=` label, so a labeled value is unambiguous.
        if let equals = trimmed.firstIndex(of: "=") {
            let label = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            if label.count <= 2, label.allSatisfy({ $0.isLetter }) {
                trimmed = trimmed[trimmed.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        // A comma, or more than one whitespace-separated token, is ambiguous:
        // refuse rather than split a pair into a single coordinate.
        let ambiguous = trimmed.contains(",")
            || trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).count > 1
        guard !ambiguous, let parsed = Int(trimmed) else {
            throw ToolFailure(message: Self.coordinateRejection(key: key, raw: raw))
        }
        return try validateCoordinate(parsed, key: key, raw: raw)
    }

    private static func validateCoordinate(_ value: Int?, key: String, raw: String) throws -> Int {
        guard let value, value > 0 else {
            throw ToolFailure(message: coordinateRejection(key: key, raw: raw))
        }
        return value
    }

    private static func coordinateRejection(key: String, raw: String) -> String {
        """
        argument '\(key)' is not a clean integer, got '\(raw)'. Pass \
        \(coordinateFormatHint) — a bare integer like 413, never a comma pair.
        """
    }

    /// An argument value that may legitimately be multi-line and must NOT be
    /// trimmed: `write_file` writing a trailing newline, or a patch body, are
    /// different documents when the last byte changes. Still refuses an empty
    /// value, which is always a model mistake rather than an intent.
    static func rawArgument(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key] else {
            throw ToolFailure(message: "missing required argument '\(key)'")
        }
        let text: String
        switch value {
        case .string(let raw): text = raw
        case .number(let raw): text = String(raw)
        case .bool(let raw): text = raw ? "true" : "false"
        default:
            throw ToolFailure(message: "argument '\(key)' must be a string")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolFailure(message: "argument '\(key)' is empty")
        }
        return text
    }

    /// Optional string argument: `nil` for absent OR null, the raw string
    /// otherwise. Never trims — see `rawArgument`.
    static func stringValue(_ value: JSONValue) -> String? {
        if case .string(let raw) = value { return raw }
        return nil
    }

    /// Optional list-of-strings argument. Accepts a JSON array (the
    /// OpenAI-shaped path) or a delimited string (the on-device FoundationModels
    /// path, whose arguments are all strings). Returns `nil` for absent/null, an
    /// empty list for a present-but-empty value. Entries are trimmed and blanks
    /// dropped.
    static func stringList(_ value: JSONValue) -> [String]? {
        let raw: [String]
        switch value {
        case .array(let values):
            raw = values.compactMap { item in
                if case .string(let s) = item { return s }
                return nil
            }
        case .string(let s):
            raw = s.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" }).map(String.init)
        case .null:
            return nil
        case .number(let n):
            raw = [String(n)]
        case .bool(let b):
            raw = [b ? "true" : "false"]
        case .object:
            return nil
        }
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func readFile(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.count <= readByteCap {
            return String(decoding: data, as: UTF8.self)
        }
        let head = String(decoding: data.prefix(readByteCap), as: UTF8.self)
        return head
            + "\n\n[truncated: \(data.count) bytes total, showing first \(readByteCap)]"
    }

    static func listDirectory(_ url: URL) -> String {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return "ERROR: cannot read directory \(url.path)"
        }
        let rows = entries
            .map { entry -> String in
                let values = try? entry.resourceValues(forKeys: Set(keys))
                let isDirectory = values?.isDirectory ?? false
                let size = values?.fileSize ?? 0
                return isDirectory ? "\(entry.lastPathComponent)/" : "\(entry.lastPathComponent)\t\(size)"
            }
            .sorted()
        let shown = rows.prefix(dirEntryCap)
        var text = shown.joined(separator: "\n")
        if rows.count > dirEntryCap {
            text += "\n[truncated: \(rows.count) entries, showing first \(dirEntryCap)]"
        }
        return text.isEmpty ? "(empty directory)" : text
    }

    static func searchFiles(query: String, root rawPath: String) throws -> String {
        let root = try resolveDirectory(rawPath)
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return "ERROR: cannot enumerate \(root.path)"
        }
        var matches: [String] = []
        for case let fileURL as URL in walker {
            if matches.count >= searchMatchCap { break }
            guard searchExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            // A symlink out of the root must not become a read path.
            guard fileURL.resolvingSymlinksInPath().path.hasPrefix(
                allowedRoot.resolvingSymlinksInPath().path
            ) else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  data.count <= readByteCap,
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains(query) else { continue }
                let trimmed = line.count > searchLineCap ? String(line.prefix(searchLineCap)) + "…" : line
                matches.append("\(fileURL.path):\(number + 1): \(trimmed)")
                if matches.count >= searchMatchCap { break }
            }
        }
        if matches.isEmpty { return "no matches for '\(query)' under \(root.path)" }
        var text = matches.joined(separator: "\n")
        if matches.count >= searchMatchCap {
            text += "\n[stopped at \(searchMatchCap) matches]"
        }
        return text
    }

    // MARK: - Search (read-only)

    /// Filename glob. `fnmatch` rather than a hand-rolled matcher: the shell
    /// already agreed on what `*.swift` means, and Pop must not invent a
    /// second dialect the model would get wrong.
    static func matchesGlob(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }

    static func globFiles(pattern: String, root rawPath: String) throws -> String {
        let root = try resolveDirectory(rawPath)
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return "ERROR: cannot enumerate \(root.path)"
        }
        var matches: [String] = []
        var scanned = 0
        for case let fileURL as URL in walker {
            scanned += 1
            if scanned > globScanCap { break }
            guard matchesGlob(pattern, fileURL.lastPathComponent) else { continue }
            matches.append(fileURL.path)
            if matches.count >= globMatchCap { break }
        }
        if matches.isEmpty { return "no files matching '\(pattern)' under \(root.path)" }
        var text = matches.joined(separator: "\n")
        if matches.count >= globMatchCap {
            text += "\n[stopped at \(globMatchCap) matches]"
        } else if scanned > globScanCap {
            text += "\n[stopped after scanning \(globScanCap) files]"
        }
        return text
    }

    /// Regex content search. An invalid pattern is a model mistake, so the
    /// failure text names it rather than silently matching nothing.
    static func grepFiles(pattern: String, root rawPath: String, glob: String?) throws -> String {
        let root = try resolveDirectory(rawPath)
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            throw ToolFailure(message: "invalid regular expression '\(pattern)': \(error)")
        }
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return "ERROR: cannot enumerate \(root.path)"
        }
        var matches: [String] = []
        var scanned = 0
        search: for case let fileURL as URL in walker {
            scanned += 1
            if scanned > globScanCap { break }
            if let glob, !matchesGlob(glob, fileURL.lastPathComponent) { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  data.count <= readByteCap,
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, options: [], range: range) {
                let (lineStart, lineEnd) = text.lineBounds(aroundUTF16: match.range.location)
                let lineNumber = text[..<lineStart].reduce(into: 1) { count, character in
                    if character == "\n" { count += 1 }
                }
                let line = String(text[lineStart..<lineEnd])
                    .trimmingCharacters(in: .whitespaces)
                let clipped = line.count > grepLineCap ? String(line.prefix(grepLineCap)) + "\u{2026}" : line
                matches.append("\(fileURL.path):\(lineNumber): \(clipped)")
                if matches.count >= grepMatchCap { break search }
            }
        }
        if matches.isEmpty { return "no matches for /\(pattern)/ under \(root.path)" }
        var text = matches.joined(separator: "\n")
        if matches.count >= grepMatchCap {
            text += "\n[stopped at \(grepMatchCap) matches]"
        } else if scanned > globScanCap {
            text += "\n[stopped after scanning \(globScanCap) files]"
        }
        return text
    }

    // MARK: - Mutation (always behind the approval gate)

    static func writeFile(to url: URL, content: String) throws -> String {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
        print("WROTE path=\(url.path) bytes=\(content.utf8.count)")
        fflush(stdout)
        return "wrote \(content.utf8.count) bytes to \(url.path)"
    }

    /// Exactly-one-occurrence replacement. An edit that matches zero times is
    /// a typo; one that matches many times would silently rewrite code the
    /// user never looked at. Both are refused rather than guessed.
    static func editFile(at url: URL, oldText: String, newText: String) throws -> String {
        let original = try String(contentsOf: url, encoding: .utf8)
        let occurrences = original.components(separatedBy: oldText).count - 1
        guard occurrences > 0 else {
            throw ToolFailure(message: "oldText not found in \(url.path); nothing changed")
        }
        guard occurrences == 1 else {
            throw ToolFailure(
                message: "oldText appears \(occurrences) times in \(url.path); include more surrounding "
                    + "context so the edit is unambiguous"
            )
        }
        let updated = original.replacingOccurrences(of: oldText, with: newText)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        print("EDITED path=\(url.path) bytes=\(updated.utf8.count)")
        fflush(stdout)
        return "replaced 1 occurrence in \(url.path)"
    }

    /// Unified diff, applied hunk by hunk.
    ///
    /// ABORTS on the first hunk that does not match and writes nothing: a
    /// half-applied patch is the failure mode that costs the user an afternoon.
    /// The whole file is written once, at the end, from the in-memory result.
    static func applyPatch(to url: URL, patch: String) throws -> String {
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        var trailingNewline = false
        if lines.last == "" {
            lines.removeLast()
            trailingNewline = true
        }

        var hunks: [[(marker: Character, text: String)]] = []
        var current: [(marker: Character, text: String)] = []
        var sawHeader = false
        for raw in patch.components(separatedBy: "\n") {
            if raw.hasPrefix("@@") {
                sawHeader = true
                if !current.isEmpty { hunks.append(current) }
                current = []
                continue
            }
            guard sawHeader else {
                // `---`/`+++`/`diff --git`/`index` preamble: not hunks.
                continue
            }
            if raw.isEmpty { continue }
            guard let marker = raw.first, " +-".contains(marker) else {
                throw ToolFailure(message: "malformed patch line: '\(raw.prefix(60))'")
            }
            current.append((marker, String(raw.dropFirst())))
        }
        if !current.isEmpty { hunks.append(current) }
        guard !hunks.isEmpty else {
            throw ToolFailure(message: "patch contains no @@ hunk headers")
        }

        var cursor = 0
        for (index, hunk) in hunks.enumerated() {
            let old = hunk.filter { $0.marker == " " || $0.marker == "-" }.map(\.text)
            let new = hunk.filter { $0.marker == " " || $0.marker == "+" }.map(\.text)
            var found = -1
            // Prefer the first match at or after the cursor, then fall back to
            // a full search: a hand-written patch often has stale line numbers.
            if lines.count >= old.count {
                for start in cursor...(lines.count - old.count) where Array(lines[start..<(start + old.count)]) == old {
                    found = start
                    break
                }
            }
            if found < 0 {
                for start in 0...(max(0, lines.count - old.count))
                where Array(lines[start..<(start + old.count)]) == old {
                    found = start
                    break
                }
            }
            guard found >= 0 else {
                throw ToolFailure(
                    message: "patch aborted at hunk \(index + 1)/\(hunks.count): context not found in "
                        + "\(url.path); nothing was written"
                )
            }
            lines.replaceSubrange(found..<(found + old.count), with: new)
            cursor = found + new.count
        }

        var output = lines.joined(separator: "\n")
        if trailingNewline { output += "\n" }
        try output.write(to: url, atomically: true, encoding: .utf8)
        print("PATCHED path=\(url.path) hunks=\(hunks.count) bytes=\(output.utf8.count)")
        fflush(stdout)
        return "applied \(hunks.count) hunk(s) to \(url.path)"
    }

    /// The user's real shell, bounded.
    ///
    /// This is the only tool that hands a string to a shell interpreter, and it
    /// runs with the user's own permissions — so the approval card IS the gate
    /// and there is deliberately NO allowlist here. `shell_readonly` is the
    /// allowlisted tool; the two are not merged because their risk is not
    /// comparable.
    static func runShell(_ command: String) throws -> String {
        let root = allowedRoot
        // A `cd` that leaves the root is refused up front. This is a statement
        // of intent, not a sandbox: the approval card is what gates the run,
        // and pretending otherwise would be dishonest.
        for token in cdTargets(command) where !isInsideRoot(token) {
            throw ToolFailure(
                message: "rejected: 'cd \(token)' leaves the working root (\(root.path))"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw ToolFailure(message: "cannot run shell: \(error)")
        }
        let deadline = Date().addingTimeInterval(bashTimeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            print("BASH_EXIT=timeout")
            fflush(stdout)
            throw ToolFailure(message: "command timed out after \(Int(bashTimeout))s")
        }
        let code = process.terminationStatus
        print("BASH_EXIT=\(code)")
        fflush(stdout)
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if text.utf8.count <= bashByteCap { return text }
        return String(text.prefix(bashByteCap))
            + "\n[truncated at \(bashByteCap) bytes, exit \(code)]"
    }

    /// Every path-looking token that follows a `cd` in a command line.
    static func cdTargets(_ command: String) -> [String] {
        var targets: [String] = []
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        for (index, word) in words.enumerated() where word == "cd" && index + 1 < words.count {
            targets.append(words[index + 1])
        }
        return targets
    }

    static func isInsideRoot(_ path: String) -> Bool {
        // A relative `cd` starts at the working directory, which IS the root.
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return true }
        if allowsExternalPaths { return true }
        let expanded = path.hasPrefix("~")
            ? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst()))
            : URL(fileURLWithPath: path)
        let resolved = expanded.standardizedFileURL.resolvingSymlinksInPath()
        let root = allowedRoot.resolvingSymlinksInPath()
        return resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")
    }

    /// Runs ONE allowlisted command with no shell involved.
    ///
    /// `Process` is invoked with the executable and arguments directly, so
    /// nothing is ever handed to `/bin/sh`. The metacharacter rejection is a
    /// second, honest belt on top of that: a string containing `|` is rejected
    /// with a message naming the rule rather than silently passing through.
    static func runReadOnlyShell(_ command: String) throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bad = trimmed.first(where: { shellForbiddenCharacters.contains($0) }) {
            throw ToolFailure(
                message: "rejected: '\(bad)' is not allowed in shell_readonly "
                    + "(no pipes, chaining, redirection, substitution or newlines)"
            )
        }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first else {
            throw ToolFailure(message: "rejected: empty command")
        }
        let verb = head
        var rest = Array(parts.dropFirst())
        // `git status` is the only two-word verb on the allowlist.
        if verb == "git" {
            guard rest.first == "status" else {
                throw ToolFailure(message: "rejected: only `git status` is allowed, got `git \(rest.first ?? "")`")
            }
            rest = Array(rest.dropFirst())
        }
        guard shellAllowlist.contains(verb) else {
            throw ToolFailure(
                message: "rejected: '\(verb)' is not on the allowlist "
                    + "(\(shellAllowlist.joined(separator: ", ")), git status)"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [verb] + rest
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw ToolFailure(message: "cannot run '\(verb)': \(error)")
        }
        let deadline = Date().addingTimeInterval(shellTimeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            throw ToolFailure(message: "'\(trimmed)' timed out after \(Int(shellTimeout))s")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        if text.utf8.count <= shellByteCap { return text }
        return String(text.prefix(shellByteCap))
            + "\n[truncated at \(shellByteCap) bytes]"
    }
}

extension String {
    /// The character range of the line containing a UTF-16 offset. Needed
    /// because `NSRegularExpression` speaks UTF-16 offsets while `String`
    /// indexes are grapheme clusters; converting once here keeps the grep
    /// line-number arithmetic out of the tool body.
    func lineBounds(aroundUTF16 offset: Int) -> (start: String.Index, end: String.Index) {
        let view = utf16
        let base = view.startIndex
        let clamped = min(max(0, offset), max(0, view.count - 1))
        var start = base
        for _ in 0..<clamped { start = view.index(after: start) }
        var end = start
        while start > base, view[view.index(before: start)] != 0x0A {
            start = view.index(before: start)
        }
        while end < view.endIndex, view[end] != 0x0A {
            end = view.index(after: end)
        }
        return (start, end)
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue] {
        if case .object(let value) = self { return value }
        return [:]
    }
}

/// Records the first tool outcome reported during a call. A class with a lock
/// rather than a captured `var`: the activity callback runs inside a concurrent
/// task, and mutating a captured variable there is a Swift 6 data race.
final class ActivityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ToolRoundOutcome?

    func set(_ outcome: ToolRoundOutcome) {
        lock.lock()
        defer { lock.unlock() }
        if stored == nil { stored = outcome }
    }

    var value: ToolRoundOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
