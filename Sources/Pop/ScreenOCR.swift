import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

/// READS THE TEXT VISIBLE IN THE BROWSER WINDOWS ON SCREEN.
///
/// Pop's SPEC promises the user can ask about what is on their screen. This is
/// that promise, and it is deliberately narrow:
///
///  * WINDOW-SCOPED, NEVER FULL-SCREEN. Every window read here is captured
///    through `SCContentFilter(desktopIndependentWindow:)` — the same mechanism
///    `Observe.screenshot` uses, measured at ~0.30 s per window. A whole-display
///    capture would sweep in every other app's private content, so there is no
///    code path here that can do one.
///  * EVERY WINDOW OF THE ALLOWLISTED BROWSERS, not just the frontmost one.
///    A measured defect: the user asked about a message in a background browser
///    window and Pop read the frontmost window of the SAME browser instead, then
///    answered about the frontmost window's content. The user's content can be
///    in any window of any allowlisted browser, so all of them are read and
///    returned with their order, app, title and text.
///  * VISIBLE CONTENT ONLY, per window. A background TAB inside a window is not
///    visible in it, so it is not readable; the tool says so instead of
///    implying a tab is covered.
///  * AN ALLOWLIST OF BROWSERS, not per-use-case logic: the three browsers a
///    user reads pages in. It is a session detail about which apps are
///    browsers, not a decision about what the user asked.
///  * HONEST FAILURES. No browser window, no Screen Recording permission, or a
///    capture error each produce a message saying exactly that. Text is never
///    invented, guessed, or carried over from a previous call — a fabricated
///    answer about someone's screen is the one failure this type must not have.
///  * TEXT ONLY, capped. Each window's text is truncated at `textCap` and the
///    whole read at `totalTextCap`, in the same spirit as the web excerpt cap: a
///    screen's worth of text is context, not a document to paste into a prompt.
enum ScreenOCR {
    /// The browsers whose windows Pop will read. Adding a browser is a session
    /// detail, not a behavioural branch.
    static let browserBundleIDs: Set<String> = [
        "com.brave.Browser",
        "com.apple.Safari",
        "com.google.Chrome"
    ]

    /// HOW MUCH of the screen one read covers. Front-only is the DEFAULT: most
    /// of a multi-window payload is off-target, and digesting it stalls the
    /// on-device brain. `all` restores the full multi-window read; `region`
    /// re-reads one precise screen rect for a closer look.
    enum Scope: Equatable, Sendable {
        /// The frontmost allowlisted browser window only (the default).
        case front
        /// Every on-screen allowlisted browser window, front to back.
        case all
        /// A screen rectangle, clamped to the frontmost browser window's bounds.
        case region(CGRect)

        var name: String {
            switch self {
            case .front: return "front"
            case .all: return "all"
            case .region: return "region"
            }
        }
    }

    /// A window that is ON SCREEN but whose text this read did NOT include —
    /// carried as title (and order) only, so the model knows it exists without
    /// paying for its OCR. Never carries window text.
    struct OtherWindow: Sendable, Equatable {
        var order: Int
        var appName: String
        var windowTitle: String
    }

    /// The ceiling on ONE window's returned text, matching the web excerpt's
    /// spirit: enough to answer "what is this page about", not enough to bury
    /// the prompt.
    static let textCap = 3000

    /// The ceiling on the WHOLE read. Several windows at `textCap` each would
    /// bury the prompt, so once this is reached the remaining windows are not
    /// sent; `Reading.truncatedAtCap` says so rather than silently dropping
    /// them.
    static let totalTextCap = 8000

    /// ONE recognized line: its text and where it sits on screen.
    ///
    /// Vision hands back a normalized bounding box per line; discarding it (the
    /// old behaviour) left the model able to READ a page but unable to point at
    /// anything in it. `rect` is the box mapped to ABSOLUTE screen coordinates
    /// in Quartz global space (origin top-left) — the SAME space `window.frame`
    /// and `ui_click` use, so the model can click the centre of a line.
    struct RecognizedLine: Sendable, Equatable {
        var text: String
        /// Absolute screen rectangle: origin top-left, width/height in points.
        var rect: CGRect

        /// How the model reads it: the text, then the clickable centre geometry.
        /// LABELED and space-separated (`x=413 y=349 w=125 h=15`) — a
        /// comma-joined `413,349` pair read as ONE integer, which is exactly how
        /// a click at `"413,349"` reached the guard. No comma pairs here.
        var rendered: String {
            "\(text) @ x=\(Int(rect.origin.x)) y=\(Int(rect.origin.y)) "
                + "w=\(Int(rect.width)) h=\(Int(rect.height))"
        }
    }

    /// What ONE window yielded. `order` is 0 for the frontmost window of the
    /// allowlisted apps and rises front to back, following the window server's
    /// z-order (`CGWindowListCopyWindowInfo`), NOT `SCShareableContent`'s
    /// enumeration order — measured not to be front-to-back.
    struct WindowReading: Sendable {
        var order: Int = 0
        var appName: String = ""
        var windowTitle: String = ""
        var text: String = ""
        /// The recognized lines with their absolute screen rectangles, in
        /// reading order. `text` is these rendered and joined; the lines are
        /// kept so a caller can sample coordinates without re-parsing.
        var lines: [RecognizedLine] = []
        /// The window's frame in Quartz global screen coordinates (origin
        /// top-left). Carried so the model can COMPUTE a click target for
        /// `ui_click` instead of guessing at pixels — and so the click guard
        /// and the read agree about where the windows are, because both come
        /// from this one enumeration.
        var frame: CGRect = .zero

        /// `x=… y=… w=… h=…`, integers, as the model reads them. Labeled for the
        /// same reason a line is: a comma-joined pair round-trips as one number.
        var boundsText: String {
            "x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) "
                + "w=\(Int(frame.width)) h=\(Int(frame.height))"
        }
    }

    /// What one read found. A `Reading` with no `failure` and no windows is
    /// impossible by construction: windows are appended only with text, so a
    /// caller cannot read an empty success as if it had read something.
    struct Reading: Sendable {
        var windows: [WindowReading] = []
        var failure: String = ""
        /// Windows whose capture succeeded but whose OCR recognized nothing —
        /// an image with no legible words. Counted, never read as "the page was
        /// about nothing".
        var skippedEmpty = 0
        /// Windows left unread because `totalTextCap` was already reached.
        var truncatedAtCap = false
        var windowScoped = true
        /// Windows on screen whose text this read did NOT include. Rendered as
        /// the titles-only header so the model always knows what else exists.
        var otherWindows: [OtherWindow] = []
        /// Lines removed by the diet: empty, shorter than 2 characters, or pure
        /// punctuation/symbols. Counted, never silently discarded.
        var droppedLines = 0
        /// Consecutive duplicate lines collapsed by the diet.
        var collapsedLines = 0
        /// The scope that produced this read, for the log line.
        var scopeName = "front"

        var succeeded: Bool { failure.isEmpty }

        /// The frontmost window's reading, for callers that only want the first.
        var frontmost: WindowReading? { windows.first }
    }

    /// Reads the screen at `scope`, defaulting to the FRONT window only, and
    /// logs one line per read so the payload diet is visible in the log:
    /// `SCREEN_READ_SCOPE=… BYTES=… LINES=… DROPPED=…`.
    ///
    /// `readOverride` is a TEST seam (`nil` in production): the walkthrough
    /// probe scripts a deterministic read so the loop's journey can be measured
    /// without depending on whatever window is actually on screen.
    static var readOverride: (@Sendable (Scope) async -> Reading)?

    static func read(
        bundleIDs: Set<String> = browserBundleIDs,
        titleHint: String? = nil,
        scope: Scope = .front
    ) async -> Reading {
        let reading: Reading
        if let readOverride {
            reading = await readOverride(scope)
        } else {
            reading = await performRead(bundleIDs: bundleIDs, titleHint: titleHint, scope: scope)
        }
        let payloadBytes = modelFacingText(reading).utf8.count
        let lineCount = reading.windows.reduce(0) { $0 + $1.lines.count }
        // The front window of what was ACTUALLY read, remembered for the send
        // card's target. This is the read path (both the real one and the test
        // seam), so a card names the window as READ, never as intended.
        if let front = reading.windows.first { recordFrontTitle(front.windowTitle) }
        print("SCREEN_READ_SCOPE=\(scope.name) BYTES=\(payloadBytes) LINES=\(lineCount) DROPPED=\(reading.droppedLines)")
        fflush(stdout)
        return reading
    }

    /// The read itself. `scope` decides WHICH windows are OCR'd: the front one
    /// (default), all of them, or one clamped screen rect. Windows that are on
    /// screen but NOT read ride back as titles-only `otherWindows` so the model
    /// always knows what else exists without paying for its text.
    private static func performRead(
        bundleIDs: Set<String>,
        titleHint: String?,
        scope: Scope
    ) async -> Reading {
        // 1. PERMISSION, checked before anything is captured. Without it the
        // capture returns black, and OCR of a black image is empty text that
        // would read as "the page had no words" — a lie. So this is a typed
        // failure with the place to fix it.
        guard CGPreflightScreenCaptureAccess() else {
            return Reading(failure: """
                Screen Recording permission is not granted, so no window can be \
                read. Grant it in System Settings → Privacy & Security → Screen \
                Recording (Pop's Settings window has the row), then ask again.
                """, scopeName: scope.name)
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            return Reading(failure: "could not enumerate on-screen windows: \(error.localizedDescription)", scopeName: scope.name)
        }

        // WHY a read comes back empty must be legible from the log alone: the
        // total windows the system enumerated, how many were owned by an
        // allowlisted browser, and how many were dropped. Without these a bare
        // "no browser window is on screen" has no diagnosable cause.
        let allWindows = content.windows
        let browserOwned = allWindows.filter { window in
            guard let owner = window.owningApplication?.bundleIdentifier else { return false }
            return bundleIDs.contains(owner)
        }.count

        let candidates = orderFrontToBack(selectWindows(
            in: content,
            bundleIDs: bundleIDs,
            titleHint: titleHint
        ))
        guard !candidates.isEmpty else {
            let counts = emptyReadReason(
                total: allWindows.count,
                browserOwned: browserOwned,
                candidates: 0,
                skippedEmpty: 0
            )
            print("SCREEN_OCR_NO_WINDOWS \(counts) bundle_ids=\(bundleIDs.sorted().joined(separator: ","))")
            fflush(stdout)
            return Reading(failure: """
                no browser window is on screen right now \
                (looked for \(bundleIDs.sorted().joined(separator: ", "))). \
                \(counts).
                """, scopeName: scope.name)
        }

        // WHICH windows this read OCRs. `front` reads only the frontmost one and
        // reports the rest as titles; `all` reads every one; `region` reads the
        // frontmost window cropped to the requested rect (clamped to its
        // bounds), with an honest failure when the rect misses it entirely.
        //
        // The chosen front is logged with the window-server id, so a stale front
        // (a read that did not track a raise) is diagnosable from the log alone.
        if let front = candidates.first {
            print("SCREEN_OCR_FRONT id=\(front.windowID) title=\(front.title ?? "") "
                + "candidates=\(candidates.count) scope=\(scope.name)")
            fflush(stdout)
        }
        func other(_ index: Int, _ window: SCWindow) -> OtherWindow {
            OtherWindow(
                order: index,
                appName: window.owningApplication?.applicationName ?? "unknown app",
                windowTitle: window.title ?? ""
            )
        }

        var targets: [(index: Int, window: SCWindow, crop: CGRect?)] = []
        var otherWindows: [OtherWindow] = []
        switch scope {
        case .front:
            targets = [(0, candidates[0], nil)]
            otherWindows = candidates.dropFirst().enumerated().map { other($0.offset + 1, $0.element) }
        case .all:
            targets = candidates.enumerated().map { ($0.offset, $0.element, nil) }
        case .region(let requested):
            let front = candidates[0]
            let clamped = requested.intersection(front.frame)
            guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
                let frame = front.frame
                return Reading(failure: """
                    the requested region (\(Int(requested.origin.x)),\(Int(requested.origin.y)) \
                    \(Int(requested.width))×\(Int(requested.height))) does not intersect the \
                    frontmost browser window (bounds \(Int(frame.origin.x)),\(Int(frame.origin.y)) \
                    \(Int(frame.width))×\(Int(frame.height))).
                    """, scopeName: scope.name)
            }
            targets = [(0, front, clamped)]
            otherWindows = candidates.dropFirst().enumerated().map { other($0.offset + 1, $0.element) }
        }

        // 2. EACH TARGET WINDOW, capped per window and in total. A `region`
        // target OCRs only the cropped rect; its coordinates map back onto that
        // rect, so a line the model clicks is where it actually sits on screen.
        var readings: [WindowReading] = []
        var total = 0
        var skippedEmpty = 0
        var truncated = false
        var droppedLines = 0
        var collapsedLines = 0

        for target in targets {
            let window = target.window
            let appName = window.owningApplication?.applicationName ?? "unknown app"
            let title = window.title ?? ""

            let fullImage: CGImage
            do {
                fullImage = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window),
                    configuration: captureConfiguration(for: window.frame)
                )
            } catch {
                // One uncapturable window must not discard the others; it is
                // counted the same way an empty OCR is.
                skippedEmpty += 1
                print("SCREEN_OCR_WINDOW_SKIPPED order=\(target.index) title=\(title) reason=capture-failed")
                fflush(stdout)
                continue
            }

            // For a region read, crop the captured window to the clamped rect so
            // only that rect is recognized; the mapping frame becomes the rect.
            var image = fullImage
            var mappingFrame = window.frame
            if let crop = target.crop {
                if let (cropped, _) = cropImage(fullImage, windowFrame: window.frame, to: crop) {
                    image = cropped
                    mappingFrame = crop
                } else {
                    // Crop unavailable: fall back to the window image and filter
                    // every line to the rect below, so the region is never wider
                    // than asked for.
                    mappingFrame = window.frame
                }
            }

            let rawLines: [RawLine]
            do {
                rawLines = try recognize(image)
            } catch {
                skippedEmpty += 1
                print("SCREEN_OCR_WINDOW_SKIPPED order=\(target.index) title=\(title) reason=ocr-failed")
                fflush(stdout)
                continue
            }

            if rawLines.isEmpty {
                skippedEmpty += 1
                print("SCREEN_OCR_WINDOW_SKIPPED order=\(target.index) title=\(title) reason=no-text")
                fflush(stdout)
                continue
            }

            // Map each normalized line box to ABSOLUTE screen coordinates using
            // THIS target's mapping frame, so a coordinate the model clicks is
            // the same space `ui_click` validates against. A region read then
            // keeps only lines that actually fall inside the requested rect.
            var mapped = rawLines.map { raw in
                RecognizedLine(text: raw.text, rect: absoluteRect(for: raw.box, in: mappingFrame))
            }
            if let crop = target.crop {
                mapped = mapped.filter {
                    $0.rect.intersects(crop) || crop.insetBy(dx: -1, dy: -1).contains(
                        CGPoint(x: $0.rect.midX, y: $0.rect.midY)
                    )
                }
            }

            // THE DIET, paid by every scope: no answerless lines, no consecutive
            // duplicates. Counted so the removal is measured, not assumed.
            let dieted = diet(mapped)
            droppedLines += dieted.dropped
            collapsedLines += dieted.collapsed
            if dieted.kept.isEmpty {
                skippedEmpty += 1
                print("SCREEN_OCR_WINDOW_SKIPPED order=\(target.index) title=\(title) reason=no-readable-text")
                fflush(stdout)
                continue
            }

            // The per-window cap first, then whatever is left of the total cap.
            // Lines are kept WHOLE (text + coordinates) so a truncation never
            // severs a line from its coordinates.
            let room = totalTextCap - total
            let cap = min(textCap, max(0, room))
            if cap <= 0 {
                truncated = true
                break
            }
            var kept: [RecognizedLine] = []
            var used = 0
            for line in dieted.kept {
                let cost = line.rendered.count + (kept.isEmpty ? 0 : 1)
                if used + cost > cap { break }
                kept.append(line)
                used += cost
            }
            // A single line longer than the whole cap still keeps its
            // coordinates: trim only the text, never the geometry.
            if kept.isEmpty {
                kept.append(trimmedToFit(dieted.kept[0], cap: cap))
            }
            if kept.count < dieted.kept.count { truncated = true }

            let windowText = kept.map(\.rendered).joined(separator: "\n")
            total += windowText.count
            print("SCREEN_OCR_LINES=\(kept.count) order=\(target.index) title=\(title)")
            fflush(stdout)
            readings.append(
                WindowReading(
                    order: target.index,
                    appName: appName,
                    windowTitle: title,
                    text: windowText,
                    lines: kept,
                    frame: window.frame
                )
            )
            if total >= totalTextCap {
                truncated = true
                break
            }
        }

        // A read that captured windows but recognized nothing anywhere is not a
        // success: saying "I read your windows and they were blank" is more
        // honest than handing back zero windows as if that were the answer.
        if readings.isEmpty {
            let counts = emptyReadReason(
                total: allWindows.count,
                browserOwned: browserOwned,
                candidates: candidates.count,
                skippedEmpty: skippedEmpty
            )
            print("SCREEN_OCR_NO_WINDOWS \(counts) bundle_ids=\(bundleIDs.sorted().joined(separator: ","))")
            fflush(stdout)
            return Reading(
                failure: """
                    \(skippedEmpty) browser window(s) were on screen but no text \
                    could be recognized in them. \(counts).
                    """,
                skippedEmpty: skippedEmpty,
                scopeName: scope.name
            )
        }

        return Reading(
            windows: readings,
            skippedEmpty: skippedEmpty,
            truncatedAtCap: truncated,
            otherWindows: otherWindows,
            droppedLines: droppedLines,
            collapsedLines: collapsedLines,
            scopeName: scope.name
        )
    }

    /// ONE identity line naming what a `screen_read` is about to read: the
    /// frontmost app, its window title, and (for a browser) the page host.
    ///
    /// WHY: `screen_read`'s result must say WHICH tab/URL it read, or the model
    /// cannot tell look-alike tabs apart (feed vs notifications) and thrashes —
    /// the measured failure. Uses `Observe`'s existing cheap AX/NSWorkspace
    /// probes (`frontmostApp`/`windowTitle`/`browserURL`); NO new capture and no
    /// OCR, so it adds no screenshot cost. Empty when the app is unreadable.
    static func readingIdentityLine() -> String {
        let (bundleID, name) = Observe.frontmostApp()
        let title = Observe.windowTitle(bundleID: bundleID)
        let titleText = (title == "nil" || title.isEmpty) ? "(untitled)" : title
        var line = "reading: \(name) — \(titleText)"
        if let raw = Observe.browserURL(bundleID: bundleID),
           let host = URL(string: raw)?.host, !host.isEmpty {
            line += " (\(host))"
        }
        return line
    }

    /// The text the model is handed: which window each block came from, then the
    /// text. Provenance is in the payload on purpose, so the model can say what
    /// it is looking at instead of asserting knowledge it cannot have, and the
    /// closing text is the same one principle the model answers by.
    ///
    /// `identity` (optional) is ONE line naming what is about to be read — the
    /// frontmost app, its window title and (for a browser) the host. WHY: the
    /// model cannot tell look-alike tabs apart (a LinkedIn FEED vs its
    /// NOTIFICATIONS page) from OCR text alone, and the measured failure was
    /// exactly that thrash — re-focusing and re-reading without ever knowing
    /// which tab was in front. It is prepended, and every existing body line is
    /// kept unchanged.
    static func modelFacingText(_ reading: Reading, identity: String? = nil) -> String {
        if !reading.succeeded {
            return "SCREEN READ FAILED: \(reading.failure)"
        }
        var lines: [String] = []
        if let identity, !identity.isEmpty { lines.append(identity) }
        lines += [
            "Screen text read from \(reading.windows.count) on-screen browser window(s), frontmost first.",
            "Each line below is `text @ x=… y=… w=… h=…` — x,y is the line's top-left in ABSOLUTE screen coordinates (Quartz, origin top-left), w,h its size in points. Click the center (x + w/2, y + h/2) of a line to act on it.",
            "Only VISIBLE content is read: a background TAB inside a window is not visible in it."
        ]
        // THE CHEAP HEADER: the other on-screen browser windows, titles only
        // (≤300 bytes), so the model always knows what else exists without
        // paying for its OCR text.
        if let header = otherWindowsHeader(reading.otherWindows) {
            lines.append("")
            lines.append(header)
        }
        for window in reading.windows {
            lines.append("")
            lines.append("--- window \(window.order + 1) of \(reading.windows.count) ---")
            lines.append("App: \(window.appName)")
            lines.append("Window title: \(window.windowTitle.isEmpty ? "(untitled)" : window.windowTitle)")
            lines.append("Screen bounds (x=… y=… w=… h=…): \(window.boundsText)")
            lines.append("")
            lines.append(window.text)
        }
        if reading.skippedEmpty > 0 {
            lines.append("")
            lines.append("(\(reading.skippedEmpty) other browser window(s) on screen had no readable text and are not shown.)")
        }
        if reading.truncatedAtCap {
            lines.append("")
            lines.append("(More browser windows are on screen; the read stopped at its \(totalTextCap)-character text cap.)")
        }
        lines.append("")
        lines.append(Self.routingPrinciple)
        return lines.joined(separator: "\n")
    }

    /// THE CHEAP HEADER: the OTHER on-screen browser windows, titles and order
    /// only — never their OCR text. Hard-capped at 300 bytes so it can never
    /// become the payload it exists to avoid.
    static func otherWindowsHeader(_ others: [OtherWindow]) -> String? {
        guard !others.isEmpty else { return nil }
        var header = "Other browser window(s) on screen (titles only, not read): "
        var added = 0
        for other in others {
            let entry = "\(other.order + 1)) \(other.windowTitle.isEmpty ? "(untitled)" : other.windowTitle)"
            let separator = added == 0 ? "" : "; "
            if header.utf8.count + separator.utf8.count + entry.utf8.count > 280 {
                header += separator + "…"
                break
            }
            header += separator + entry
            added += 1
        }
        while header.utf8.count > 300, !header.isEmpty { header.removeLast() }
        return header
    }

    /// THE DIET, paid by every scope. Drops lines that carry no answer — empty,
    /// shorter than two characters, or pure punctuation/symbols (a bare `< >` or
    /// a separator rule) — and collapses runs of consecutive duplicate lines to
    /// their LAST occurrence, keeping that occurrence's coordinates. Returns the
    /// kept lines and counts, so the removal is measured rather than assumed.
    static func diet(_ lines: [RecognizedLine]) -> (kept: [RecognizedLine], dropped: Int, collapsed: Int) {
        var kept: [RecognizedLine] = []
        var dropped = 0
        var collapsed = 0
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count < 2 {
                dropped += 1
                continue
            }
            let hasAnswerCharacter = trimmed.unicodeScalars.contains {
                CharacterSet.alphanumerics.contains($0)
            }
            if !hasAnswerCharacter {
                dropped += 1
                continue
            }
            if let last = kept.last, last.text == line.text {
                kept[kept.count - 1] = line
                collapsed += 1
                continue
            }
            kept.append(line)
        }
        return (kept, dropped, collapsed)
    }

    /// Crops a captured window image to a screen rect. The image is the window's
    /// point size times the display's backing scale, origin top-left like the
    /// window frame, so the rect maps straightforwardly to pixels. Returns the
    /// cropped image and the screen rect it now represents.
    static func cropImage(
        _ image: CGImage,
        windowFrame: CGRect,
        to screenCrop: CGRect
    ) -> (CGImage, CGRect)? {
        let scale = NSScreen.screens.first { $0.frame.intersects(windowFrame) }?
            .backingScaleFactor ?? 1
        let local = CGRect(
            x: (screenCrop.minX - windowFrame.minX) * scale,
            y: (screenCrop.minY - windowFrame.minY) * scale,
            width: screenCrop.width * scale,
            height: screenCrop.height * scale
        ).integral
        guard local.width >= 1, local.height >= 1,
              let cropped = image.cropping(to: local) else { return nil }
        return (cropped, screenCrop)
    }

    /// THE RAISER PREFERENCE — one guidance sentence, carrying the QUERY LOGIC.
    /// `browser_focus_tab` finds the target the user NAMED; it is not a second
    /// read of what is already in front, and a miss is reported as an exact
    /// fact, never handed back as vague work. Deterministic, not pixel guessing.
    static let raiserPreferenceClause = """
        When the front window doesn't contain what the user asks about, call \
        `browser_focus_tab` with the site or app name from the USER'S MESSAGE \
        (they say 'whatsapp' → query `whatsapp`) — never the front window's own \
        title; if no tab matches, the honest answer is that no such tab is open \
        and what to open — nothing vague, no handing the work back.
        """

    /// The user-word → query example carried by the raiser sentence, parsed out
    /// so the seam probe can drive its scripted model from the SAME guidance the
    /// real model receives. No site name is hardcoded in a test; `nil` when the
    /// example is absent.
    static func focusQueryExample() -> (userWord: String, query: String)? {
        let clause = raiserPreferenceClause
        guard let sayOpen = clause.range(of: "they say '"),
              let sayClose = clause[sayOpen.upperBound...].firstIndex(of: "'")
        else { return nil }
        let userWord = String(clause[sayOpen.upperBound..<sayClose])
        guard let queryOpen = clause.range(of: "query `", range: sayClose..<clause.endIndex),
              let queryClose = clause[queryOpen.upperBound...].firstIndex(of: "`")
        else { return nil }
        let query = String(clause[queryOpen.upperBound..<queryClose])
        guard !userWord.isEmpty, !query.isEmpty else { return nil }
        return (userWord, query)
    }

    /// THE DOMAIN WALL — one sentence replacing the old source-hop clause. A
    /// screen question is answered only from screen sources; a world question
    /// only from `web_lookup`. Crossing domains is always wrong, so "use another
    /// source" stops at the question's own domain. No topic or site is named.
    static let domainBoundaryClause = """
        Never stop halfway WITHIN the question's domain: a screen/tab/app \
        question is answered only from screen sources — if the tab isn't visible \
        or the needed content isn't found, say exactly that; world questions \
        only from `web_lookup`; never answer a screen question from the web or a \
        world question from the screen.
        """

    /// THE ONE PRINCIPLE — the whole of Pop's perception/routing guidance,
    /// stated once. There is deliberately no second rule: the old screen-first,
    /// mismatch-honesty and failure-stop phrasings are folded in here and
    /// deleted, because stacking rules degrades the small on-device model. No
    /// app, site or task is named.
    /// THE DATE-ANCHORING INVARIANT. One ground-truth sentence, no case rule:
    /// the clock line injected at send time is the ONLY "today"; a date read on
    /// a web page or recalled from memory is never "today", and an event is
    /// upcoming only if it falls after the clock line's date.
    static let todayAnchorClause = """
        The clock line is the only source of "today" — filter upcoming/past \
        against it; dates on web pages or in memory are never "today".
        """

    static let routingPrinciple = """
        Answer the question by the best means available. World knowledge \
        (weather, prices, travel, facts, news) goes to `web_lookup` directly — \
        the screen is not consulted. Things on the user's screen, their tabs, \
        or their logged-in apps use `screen_read` first. \
        \(raiserPreferenceClause) \
        \(domainBoundaryClause) \
        \(todayAnchorClause)
        """

    /// THE ACT-ON-VISIBLE RULE — one operational sentence: perception carries
    /// line geometry, so acting on what was read is locating the line and
    /// clicking its centre. No site, task or control is named. Kept because the
    /// principle has no principle-level replacement for the coordinate act.
    static let actOnVisibleRule = """
        ACT-ON-VISIBLE: to act on visible content — open a chat, press a button, \
        select an item — find the target line in the LATEST `screen_read` output \
        and `ui_click` the center (x + w/2, y + h/2) of the target line's \
        coordinates, then `screen_read` again to verify the result before the \
        next step or the final answer.
        """

    /// The reason counts carried by an empty read's failure text and printed to
    /// the log, so the next empty `screen_read` is diagnosable without a
    /// reproduction. No per-use-case wording: four counts, always the same ones.
    static func emptyReadReason(
        total: Int,
        browserOwned: Int,
        candidates: Int,
        skippedEmpty: Int
    ) -> String {
        "total_windows=\(total) allowlisted_browser_windows=\(browserOwned) "
            + "candidate_windows=\(candidates) skipped_empty_ocr=\(skippedEmpty)"
    }

    // MARK: - Vision

    /// One recognition result BEFORE mapping: the text and Vision's normalized
    /// box (origin bottom-left, both axes 0…1). Kept separate from the absolute
    /// `RecognizedLine` so the frame mapping lives in one place.
    struct RawLine: Sendable {
        var text: String
        var box: CGRect
    }

    /// Accurate recognition, languages left to Vision's own list rather than
    /// pinned to English: the page on screen is whatever language the user reads.
    ///
    /// The per-line `boundingBox` is KEPT — that geometry is what lets the model
    /// point at a line instead of merely quoting it.
    private static func recognize(_ image: CGImage) throws -> [RawLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation -> RawLine? in
            guard let best = observation.topCandidates(1).first else { return nil }
            return RawLine(text: best.string, box: observation.boundingBox)
        }
    }

    /// Maps a normalized Vision box onto a window's absolute screen frame.
    ///
    /// Vision's box is normalized with its origin BOTTOM-LEFT, so the vertical
    /// axis is flipped: the box's TOP (`maxY`) becomes the screen `y`. The
    /// result is the Quartz-space rectangle `ui_click` accepts.
    static func absoluteRect(for box: CGRect, in frame: CGRect) -> CGRect {
        let x = frame.minX + box.minX * frame.width
        let width = box.width * frame.width
        let y = frame.minY + (1 - box.maxY) * frame.height
        let height = box.height * frame.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Keeps a line's coordinates when its TEXT alone exceeds the cap: trims the
    /// text so the rendered `text @ x=… y=… w=… h=…` fits, and never drops the geometry.
    private static func trimmedToFit(_ line: RecognizedLine, cap: Int) -> RecognizedLine {
        let suffixLength = line.rendered.count - line.text.count
        let allowance = max(0, cap - suffixLength)
        var copy = line
        copy.text = String(line.text.prefix(allowance))
        return copy
    }

    // MARK: - Selection

    /// EVERY on-screen window of an allowlisted app, in the window server's
    /// front-to-back order (see `orderFrontToBack`). Selection is ownership plus
    /// a size floor — nothing about what the user asked, so no window of the
    /// user's own browsers is preferred or excluded for content reasons.
    ///
    /// A `titleHint` is a TEST seam, not a shipped path: the shipped call
    /// passes none, so ownership is the only criterion. ScreenCaptureKit
    /// reports some windows with NO owning application (its own probe found
    /// Pop's own panel that way), and a probe that owns its window needs to
    /// name it.
    private static func selectWindows(
        in content: SCShareableContent,
        bundleIDs: Set<String>,
        titleHint: String?
    ) -> [SCWindow] {
        content.windows.filter { window in
            let owner = window.owningApplication?.bundleIdentifier
            let owned = owner.map { bundleIDs.contains($0) } ?? false
            let named = titleHint.map { window.title == $0 } ?? false
            return (owned || named)
                && window.frame.width > 40
                && window.frame.height > 40
        }
    }

    /// The window server's TRUE front-to-back order, as a window-id rank.
    ///
    /// `SCShareableContent` enumerates windows in an order that is NOT z-order —
    /// MEASURED live: its first browser candidate was a background window while
    /// the on-screen front window was another, so `candidates[0]` was not
    /// frontmost. `CGWindowListCopyWindowInfo` is documented front-to-back, so it
    /// is the only correct source for "which window is in front".
    private static func frontRankByWindowID() -> [CGWindowID: Int] {
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        var rank: [CGWindowID: Int] = [:]
        var next = 0
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0 else { continue }
            let number = entry[kCGWindowNumber as String] as? Int ?? 0
            guard number != 0 else { continue }
            let id = CGWindowID(number)
            if rank[id] == nil {
                rank[id] = next
                next += 1
            }
        }
        return rank
    }

    /// Orders windows front to back by the window server's z-order, stable for any
    /// window the server did not list (ranked last, in their given order). This is
    /// what makes `candidates[0]` actually frontmost and `scope:"all"` truly front
    /// to back — the enumeration order it replaced never was.
    private static func orderFrontToBack(_ windows: [SCWindow]) -> [SCWindow] {
        let rank = frontRankByWindowID()
        return windows.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.windowID] ?? Int.max
            let right = rank[rhs.element.windowID] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// The front window's title from the MOST RECENT successful read, so an
    /// approval card can name the window a send will land in — AS READ, not as
    /// the model intended. Lock-guarded: reads happen off the main actor.
    private static let lastFrontTitleLock = NSLock()
    private static var lastFrontTitleStorage = ""
    static func recordFrontTitle(_ title: String) {
        lastFrontTitleLock.lock()
        lastFrontTitleStorage = title
        lastFrontTitleLock.unlock()
    }
    static func lastFrontWindowTitle() -> String {
        lastFrontTitleLock.lock(); defer { lastFrontTitleLock.unlock() }
        return lastFrontTitleStorage
    }

    /// The allowlisted apps' window frames, for the BROWSER-specific read
    /// surface. Exposed so `BrowserActions` bounds a browser read by the SAME
    /// enumeration `screen_read` reports: one source of truth about where the
    /// browser windows are, rather than two that could disagree.
    static func allowedWindowFrames(in content: SCShareableContent) -> [CGRect] {
        selectWindows(in: content, bundleIDs: browserBundleIDs, titleHint: nil)
            .map(\.frame)
    }

    /// The bundle id Pop ships as. Its own panel is Pop's UI, never a
    /// computer-use target.
    static let ownBundleID = "com.pop.app"

    /// Whether a window is part of the COMPUTER-USE act surface: any on-screen
    /// APP window except Pop's own panel. A window with no owning application
    /// (the desktop, an unattributable surface) is not a target either.
    ///
    /// WHY this is pure: the act surface widens from browsers-only to every app
    /// on screen, so the ONE thing that must stay excluded — Pop's own panel —
    /// has to be provable without standing up ScreenCaptureKit.
    static func isActTarget(
        ownerBundleID: String?,
        frame: CGRect,
        excluding: Set<String> = [ownBundleID]
    ) -> Bool {
        guard let owner = ownerBundleID, !owner.isEmpty else { return false }
        guard !excluding.contains(owner) else { return false }
        return frame.width > 40 && frame.height > 40
    }

    /// EVERY on-screen app window's frame except Pop's own panel, from the SAME
    /// enumeration `screen_read` uses. This is the widened computer-use act
    /// surface: a human acts on the apps on their screen, not only browsers —
    /// the browser-only allowlist made System Settings acts structurally
    /// impossible (measured: "change the wallpaper" degraded into seven gated
    /// shell attempts).
    static func visibleWindowFrames(
        in content: SCShareableContent,
        excluding: Set<String> = [ownBundleID]
    ) -> [CGRect] {
        content.windows
            .filter {
                isActTarget(
                    ownerBundleID: $0.owningApplication?.bundleIdentifier,
                    frame: $0.frame,
                    excluding: excluding
                )
            }
            .map(\.frame)
    }

    /// The output size must be REQUESTED from the window's point size times the
    /// display's backing scale. With only `showsCursor` set, ScreenCaptureKit
    /// clamps to a default 1920x1080 whatever the window's real size — measured
    /// in `Observe`, and repeated here so the two captures cannot disagree.
    private static func captureConfiguration(for windowFrame: CGRect) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.showsCursor = false
        let scale = NSScreen.screens.first { $0.frame.intersects(windowFrame) }?
            .backingScaleFactor ?? 1
        config.width = max(1, Int(windowFrame.width * scale))
        config.height = max(1, Int(windowFrame.height * scale))
        return config
    }
}