import Foundation
import FoundationModels

/// THE ON-DEVICE MICRO-ASSIST (T2 tier).
///
/// The cloud brain plans whole turns. This is the opposite end: ONE small,
/// local, jev-shaped micro-decision, consulted at most once per bounded moment,
/// and NEVER allowed to change control flow when it is unavailable. It is cheap
/// because it is on-device (no cloud round), local (no network), and fail-open
/// (any error/timeout/low-confidence → nil, and the caller keeps its existing
/// behavior).
///
/// First and only consumer: an ASSISTED pick among element titles Pop already
/// observed when a `ui_ax` step fails — replacing blind title-guessing with one
/// assisted choice. It carries no task-specific logic; it matches a step's own
/// label against candidates Pop passes in.
@available(macOS 26.0, *)
enum AppleFMMicro {
    /// One parsed micro-decision: the picked candidate and its confidence.
    struct Pick: Sendable, Equatable {
        let choice: String
        let confidence: Double
    }

    /// Hard bound on one micro call. On-device generation is local and fast;
    /// this exists only so a stuck session cannot hold a plan step.
    static let timeout: TimeInterval = 3

    /// PROBE SEAM: a scripted raw response keyed by the composed prompt, so a
    /// probe can drive `assistedPick` with no live model. `nil` in production,
    /// where the real on-device session runs. Never set outside a probe.
    static var sessionOverride: (@Sendable (String) async -> String?)?

    /// Clears the probe seam.
    static func resetSeams() { sessionOverride = nil }

    /// ONE compact question to the on-device model. No tools (`toolsEnabled`
    /// false by construction — this session is constructed tool-less), bounded,
    /// and silent on failure: returns the RAW model text, or nil when the model
    /// is unavailable / errors / times out. The caller decides what to do with
    /// the text; this never parses or acts.
    static func assess(question: String, context: String) async -> String? {
        if let override = sessionOverride {
            return await override("\(question)\n\(context)")
        }
        let availability = ProviderTestSeams.shared.availability ?? AppleFMProvider.realAvailability()
        guard availability.isAvailable else { return nil }
        let prompt = "\(question)\n\(context)"
        var options = FoundationModels.GenerationOptions()
        options.temperature = 0
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            tools: [],
            transcript: Transcript(entries: [])
        )
        return await withTaskGroup(of: Optional<String>.self) { group in
            group.addTask {
                do {
                    let response = try await session.respond(to: prompt, options: options)
                    return response.content
                } catch {
                    print("FM_MICRO error=\(error)")
                    fflush(stdout)
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Pure parse of the model's answer: `{"choice": "<title or none>",
    /// "confidence": 0..1}`. Lenient about surrounding prose (the small model
    /// sometimes wraps the object), strict about the shape: a JSON boolean is
    /// rejected where a number is required.
    static func parse(_ raw: String) -> Pick? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start <= end else { return nil }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = object["choice"] as? String,
              let number = object["confidence"] as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let confidence = number.doubleValue
        guard confidence.isFinite, (0...1).contains(confidence) else { return nil }
        return Pick(
            choice: choice.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: confidence
        )
    }

    /// THE BOUNDED CONSUMER: an assisted pick among candidate element titles.
    /// Returns the matching candidate title ONLY when the model is available,
    /// its answer parses, the confidence clears `threshold`, and the pick names
    /// one of the candidates. Otherwise nil — and the caller keeps the existing
    /// candidates error. Logs exactly one `FM_MICRO assist=hit|miss|unavailable`.
    static func assistedPick(
        intent: String,
        candidates: [String],
        threshold: Double
    ) async -> String? {
        guard !candidates.isEmpty else { return nil }
        let listing = candidates.map { "\"\($0)\"" }.joined(separator: ", ")
        let question = "Does one of these elements match the intent \"\(intent)\"? "
            + "Answer as JSON {\"choice\": \"<title or none>\", \"confidence\": 0..1}."
        let context = "Candidates: [\(listing)]"
        guard let raw = await assess(question: question, context: context) else {
            print("FM_MICRO assist=unavailable")
            fflush(stdout)
            return nil
        }
        guard let pick = parse(raw),
              pick.confidence >= threshold,
              pick.choice.caseInsensitiveCompare("none") != .orderedSame,
              let match = candidates.first(where: {
                  $0.caseInsensitiveCompare(pick.choice) == .orderedSame
              })
        else {
            print("FM_MICRO assist=miss")
            fflush(stdout)
            return nil
        }
        print("FM_MICRO assist=hit choice=\(JevBridge.sanitize(match))")
        fflush(stdout)
        return match
    }
}
