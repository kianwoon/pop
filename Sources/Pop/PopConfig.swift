import Foundation
import LocalAuthentication

/// Typed view of `~/Library/Application Support/Pop/config.json`.
///
/// API keys are deliberately NOT part of this struct or that file: they come
/// from the Keychain. `pcc` selects Private Cloud Compute for the on-device
/// Foundation Models provider.
struct PopConfig: Sendable, Equatable, Codable {
    var provider: String
    var model: String
    var baseURL: String
    var temperature: Double
    /// Cloud "thinking"/reasoning control for OpenAI-compatible endpoints.
    ///
    /// Maps to z.ai's `thinking.type` request field — the documented reasoning
    /// control for GLM-4.5+ (z.ai API ref, retrieved 2026-10-09). A SEPARATE
    /// top-level `reasoning_effort` string is also accepted by z.ai and is
    /// controlled independently by `cloudReasoningEffort` below (confirmed from
    /// a live payload).
    ///
    /// Three strict values:
    ///   "disabled" (DEFAULT) — send `{"type":"disabled"}`. The speed lever:
    ///             z.ai runs thinking ON by default for GLM-4.5+, so the
    ///             explicit opt-out is what actually buys the speed.
    ///   "enabled"            — send `{"type":"enabled"}` for full reasoning.
    ///   "default"            — SEND NOTHING (maximum compatibility: an endpoint
    ///             that rejects unknown fields is left untouched).
    /// Any other value (only reachable by hand-editing config.json, since
    /// `--set-config` rejects it) is treated as "disabled".
    ///
    /// This is config-DRIVEN DATA: speed/quality is the user's tuning decision,
    /// never a hardcoded constant.
    var cloudThinking: String
    /// Cloud reasoning-effort control: the z.ai top-level `reasoning_effort`
    /// request field (OpenAI-style). Config-DRIVEN DATA, mirroring
    /// `cloudThinking` exactly.
    ///
    /// Values:
    ///   "low" (DEFAULT)  — send `"reasoning_effort":"low"` (the speed default;
    ///             the user-directed setting).
    ///   "medium"/"high"  — sent verbatim for more reasoning.
    ///   "default"        — SEND NOTHING (maximum compatibility).
    /// Any other value omits the field entirely (no bad request).
    var cloudReasoningEffort: String
    var pcc: Bool
    /// v0: observation context is prepended to every user turn.
    var contextMode: Bool

    /// May the assistant's file tools reach outside the working root?
    ///
    /// TRUE by default, which is what the user asked for: a restricted root
    /// makes `write_file` useless for the file the user actually named. It does
    /// NOT remove the approval gate — a mutating tool still needs one click
    /// either way; this only decides WHICH paths it may name.
    var allowExternalPaths: Bool

    /// A user-configured default city for web lookups, used only when Core
    /// Location is unavailable or denied. Empty means "unset": the lookup then
    /// falls back to the page's own inference, clearly labelled as a guess.
    /// Pop ships NO built-in place names — the user supplies this.
    var defaultCity: String

    /// Extra HTTP headers sent with every OpenAI-compatible request.
    ///
    /// Some vendor "coding plans" only accept the coding client's own request
    /// profile (a custom `User-Agent`, a priority header), and reject or
    /// mis-meter anything else. NEVER put an API key in here: this struct is
    /// written to config.json in plain text, while keys belong in the Keychain.
    var headers: [String: String]

    /// The hover electric-arc buzz is OPT-IN: silent until the user turns it on.
    /// The synthesized buffer already peaks at a quiet 0.25, so this is the
    /// master gate for the whole feature, not a per-play mute.
    var buzzEnabled: Bool

    /// User-facing 0...1 multiplier over the already-quiet 0.25-peak synthesized
    /// buffer. Ignored while `buzzEnabled` is false; a value outside 0...1 is
    /// clamped when applied.
    var buzzVolume: Double

    /// Optional HTTP advisory service ("jev"). DISABLED until the user
    /// configures it; the bearer token lives in the Keychain (account "jev"),
    /// NEVER here — this struct is written to config.json in plain text.
    var jevEnabled: Bool

    /// The advisory endpoint URL. Empty means "unconfigured", which the bridge
    /// treats as OFF with no network call.
    var jevEndpoint: String

    /// Optional model id passed to the advisory service; empty is fine.
    var jevModel: String

    /// Confidence floor (0...1) below which an advisory is not shown. Filtering
    /// happens at the CALLER so the parser stays pure and side-effect free.
    var jevThreshold: Double

    /// The user's STANDING approval for reversible screen acts.
    ///
    /// TRUE by default: the user asked Pop to carry an instruction end-to-end,
    /// so a click/scroll/key/ax act inside a visible app window runs
    /// without a per-act card. The toggle exists to turn it OFF. It covers ONLY
    /// `ui_click`/`ui_scroll`/`ui_key`/`ui_ax` (and `app_manage` activate/open)
    /// when their point/bounds pass `pointIsAllowed`; file writes, shell
    /// commands, typing, and quitting apps ALWAYS ask. Reversible, in-bounds,
    /// non-content-posting acts are the whole grant.
    var autoRunScreenActions: Bool

    /// The documented preset for such coding-plan endpoints.
    static func codingPlanPreset() -> [String: String] {
        ["X-Priority": "max", "User-Agent": "ZCodeX-Client: ZCode"]
    }

    static let defaults = PopConfig(
        provider: "apple-fm",
        model: "",
        baseURL: "",
        temperature: 0.7,
        cloudThinking: "disabled",
        cloudReasoningEffort: "low",
        pcc: false,
        contextMode: true,
        allowExternalPaths: true,
        defaultCity: "",
        headers: [:],
        buzzEnabled: false,
        buzzVolume: 0.7,
        jevEnabled: false,
        jevEndpoint: "",
        jevModel: "",
        jevThreshold: 0.7,
        autoRunScreenActions: true
    )

    static let directoryURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Pop", isDirectory: true)

    /// `POP_CONFIG_PATH` overrides the config file location, so a probe (or a
    /// second profile) can run against a throwaway config without touching the
    /// user's real one. Read-only concern: when unset the default path is
    /// unchanged, and the override is never written back anywhere else.
    static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["POP_CONFIG_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return directoryURL.appendingPathComponent("config.json")
    }
}

enum ConfigError: Error, CustomStringConvertible {
    case unreadable(String)

    var description: String {
        switch self {
        case .unreadable(let detail):
            return "config unreadable: \(detail)"
        }
    }
}

extension PopConfig {
    /// Loads the config, writing a defaults file first if none exists.
    ///
    /// A malformed file is NOT silently replaced (that would destroy a user's
    /// settings): it is reported and the defaults are returned in memory.
    static func load() throws -> PopConfig {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            try defaults.write()
            print("CONFIG_CREATED path=\(configURL.path)")
            fflush(stdout)
            return defaults
        }

        let data = try Data(contentsOf: configURL)
        do {
            return try Self.decodeLenient(data)
        } catch {
            print("CONFIG_INVALID error=\(error)")
            fflush(stdout)
            return defaults
        }
    }

    /// Decodes a config written by an older build: keys added since then are
    /// filled from `defaults` instead of failing the whole file.
    static func decodeLenient(_ data: Data) throws -> PopConfig {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.unreadable("config.json is not a JSON object")
        }
        if object["contextMode"] == nil { object["contextMode"] = defaults.contextMode }
        if object["pcc"] == nil { object["pcc"] = defaults.pcc }
        // Thinking is config-driven and defaults to the speed setting; a config
        // written before this key existed must decode as "disabled", never fail.
        if object["cloudThinking"] == nil { object["cloudThinking"] = defaults.cloudThinking }
        // Reasoning effort is config-driven too; an older config.json with no
        // such key decodes as the speed default rather than failing.
        if object["cloudReasoningEffort"] == nil {
            object["cloudReasoningEffort"] = defaults.cloudReasoningEffort
        }
        if object["allowExternalPaths"] == nil {
            object["allowExternalPaths"] = defaults.allowExternalPaths
        }
        // NO `voiceMode` backfill: the key is gone, and an older config.json
        // that still carries it loads fine — JSONDecoder ignores unknown keys
        // (a legacy `true` there is intentionally inert now).
        // Absent means "no default city" (fall back to page inference), not a
        // decode failure: a config written before this key existed still loads.
        if object["defaultCity"] == nil { object["defaultCity"] = defaults.defaultCity }
        // Absent means "no custom headers", not a decode failure: a config
        // written before this key existed must still load.
        if object["headers"] == nil { object["headers"] = defaults.headers }
        // Opt-in sound: a config written before the buzz existed must decode as
        // OFF, and a missing volume as the house default — never a decode failure.
        if object["buzzEnabled"] == nil { object["buzzEnabled"] = defaults.buzzEnabled }
        if object["buzzVolume"] == nil { object["buzzVolume"] = defaults.buzzVolume }
        // jev is optional: a config written before it existed must decode as
        // DISABLED with an empty endpoint — never a decode failure, and never a
        // surprise network call.
        if object["jevEnabled"] == nil { object["jevEnabled"] = defaults.jevEnabled }
        if object["jevEndpoint"] == nil { object["jevEndpoint"] = defaults.jevEndpoint }
        if object["jevModel"] == nil { object["jevModel"] = defaults.jevModel }
        if object["jevThreshold"] == nil { object["jevThreshold"] = defaults.jevThreshold }
        // A config written before the standing-approval flag existed defaults to
        // the user's stated preference: screen acts run end-to-end. Missing key
        // must never be a decode failure.
        if object["autoRunScreenActions"] == nil {
            object["autoRunScreenActions"] = defaults.autoRunScreenActions
        }
        let normalized = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(PopConfig.self, from: normalized)
    }

    func write() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.configURL, options: .atomic)
    }
}

/// Keychain access for provider API keys.
///
/// Service `com.pop.app`, account = provider name. A Keychain that would put
/// up an interactive prompt must never block a headless probe, so the read runs
/// off the main thread under a hard 10 s deadline; on expiry the caller proceeds
/// with an empty key and the `KEYCHAIN_TIMEOUT` marker tells the log why.
enum KeychainStore {
    static let service = "com.pop.app"
    static let timeout: TimeInterval = 10

    /// TEST OBSERVABILITY: how many times this process has read the Keychain.
    /// The M9 on-device probe asserts an on-device turn touched NOTHING here —
    /// "no credentials" is a measured claim, not an assumption.
    private static let readCounter = Counter()
    static var readCount: Int { readCounter.value }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Returns the stored secret, or `nil` when absent, blocked, or timed out.
    static func apiKey(for account: String) -> String? {
        readCounter.bump()
        // `SecItemCopyMatching` is a blocking call that can trigger a UI prompt;
        // it must not run on the main thread, hence the queue hop. A DispatchGroup
        // gives a real timed wait — no shared mutable state to race on.
        let group = DispatchGroup()
        let box = ResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            box.value = readSecret(account: account)
            group.leave()
        }
        group.enter()

        guard group.wait(timeout: .now() + timeout) == .success else {
            print("KEYCHAIN_TIMEOUT service=\(service) account=\(account) after=\(Int(timeout))s")
            fflush(stdout)
            return nil
        }
        return box.value
    }

    /// Single-assignment box so the worker thread's result can cross back
    /// without a data race (`DispatchGroup.wait` is the synchronisation edge).
    private final class ResultBox: @unchecked Sendable {
        var value: String?
    }

    enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)

        var description: String {
            switch self {
            case .unexpectedStatus(let status):
                return "SecItem status \(status)"
            }
        }
    }

    /// Writes (or replaces) the API key for a provider. UI interaction is
    /// suppressed here too, so a locked keychain fails fast instead of
    /// putting a modal in front of the user.
    @discardableResult
    static func setAPIKey(_ secret: String, for account: String) -> Result<Void, Error> {
        do {
            try writeSecret(secret, account: account)
            return .success(())
        } catch {
            print("KEYCHAIN_WRITE_ERROR account=\(account) error=\(error)")
            fflush(stdout)
            return .failure(error)
        }
    }

    /// Removes a stored key. Absent is success: the desired end state holds.
    @discardableResult
    static func deleteAPIKey(for account: String) -> Result<Void, Error> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return .success(())
        }
        return .failure(KeychainError.unexpectedStatus(status))
    }

    private static func writeSecret(_ secret: String, account: String) throws {
        let context = LAContext()
        context.interactionNotAllowed = true

        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(secret.utf8)

        // Update first: SecItemAdd fails with a duplicate error for an existing
        // item, which is the common case on a re-save.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var insert = identity
        insert[kSecValueData as String] = data
        insert[kSecUseAuthenticationContext as String] = context
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    private static func readSecret(account: String) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Never show the user a secret in the UI; an inaccessible key is
            // reported as absent rather than silently blocking.
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8)
        else {
            if status != errSecItemNotFound {
                print("KEYCHAIN_ERROR account=\(account) status=\(status)")
                fflush(stdout)
            }
            return nil
        }
        return secret
    }
}