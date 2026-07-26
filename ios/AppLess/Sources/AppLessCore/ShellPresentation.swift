//
//  ShellPresentation.swift
//  AppLessCore
//
//  The last shell decisions that were still being made inside SwiftUI bodies
//  and inside `GenOSShellModel`: which state a screen host is in, whether a
//  switcher card can show a live miniature, what counts as a back swipe, which
//  screens need a parsed tree, and when the controller needs to be told the
//  active screen changed.
//
//  `ShellChrome` already owned every number, color and string; this owns the
//  branching that consumed them.
//
//  NO SwiftUI in this file.
//

import Foundation

// MARK: - Screen host

/// `ScreenHostView`'s three states and its error copy. Port of the
/// `top.status`/`top.content` branches in `src/genos/GenOS.tsx`.
public enum ScreenHostPresentation {

    /// What the host is showing right now.
    public enum State: Sendable, Equatable {
        /// `status === "error"` - the message plus a Retry button.
        case error(message: String)
        /// Nothing has parsed yet - the pulsing skeleton.
        case skeleton
        /// A resolved tree is available; stream or done, it renders the same.
        case content
    }

    /// `top.error || "Generation failed"` - note `||`, not `??`, so an EMPTY
    /// error string falls back to the generic message too.
    public static let errorFallbackMessage = ShellChrome.ScreenHost.errorFallbackMessage

    public static func errorMessage(_ error: String?) -> String {
        guard let error, !error.isEmpty else { return errorFallbackMessage }
        return error
    }

    /// The error branch is chosen on STATUS alone: a screen that errored after
    /// streaming some content shows the error, not the partial tree.
    public static func state(isError: Bool, hasRoot: Bool, error: String?) -> State {
        if isError { return .error(message: errorMessage(error)) }
        return hasRoot ? .content : .skeleton
    }
}

// MARK: - Switcher

/// `Switcher.tsx`: a card shows a live miniature only when there is really
/// something to draw.
public enum SwitcherPresentation {

    /// `top && top.content ? <Renderer …/> : <emoji/>` - all three conditions
    /// must hold. A session whose top screen is still pending has content `""`
    /// and falls back to the emoji; so does one whose content has arrived but
    /// has not parsed into a root yet, which the RN version cannot express
    /// (it re-parses inline) and which would otherwise draw an empty card.
    public static func showsPreview(hasScreen: Bool, content: String?, hasRoot: Bool) -> Bool {
        hasScreen && !(content ?? "").isEmpty && hasRoot
    }
}

// MARK: - Back gesture

extension ShellChrome {

    /// iOS has no hardware back key, so RN's `BackHandler` table is bound to a
    /// left-edge swipe. The thresholds live here so a test can pin them and so
    /// the gesture cannot drift away from the one documented in the README.
    public enum BackGesture {
        /// How far from the leading edge a qualifying drag may start.
        public static let edgeWidth: Double = 24
        /// Minimum horizontal travel.
        public static let minimumTranslationX: Double = 60
        /// Maximum vertical wobble before it reads as a scroll instead.
        public static let maximumTranslationY: Double = 60

        /// All three tests, as `DragGesture.onEnded` applies them.
        public static func isBackSwipe(
            startX: Double,
            translationX: Double,
            translationY: Double
        ) -> Bool {
            startX < edgeWidth
                && translationX > minimumTranslationX
                && abs(translationY) < maximumTranslationY
        }
    }
}

// MARK: - Generating

/// Cross-cutting reads over a screen's status that the shell branches on.
///
/// The status type itself lives in `GenOSCore`; keeping these as predicates
/// over two booleans lets `AppLessCore` stay independent of it while still
/// owning the rule.
public enum ShellActivity {

    /// RN `generating`: `top?.status === "pending" || top?.status === "streaming"`.
    /// No top screen at all is NOT generating.
    public static func isGenerating(isPending: Bool, isStreaming: Bool) -> Bool {
        isPending || isStreaming
    }

    /// Top-left chrome: back while the stack is deeper than its root, home at
    /// the root. Same rule `ShellChrome.leadingButton` uses for the glyph, so
    /// the icon and the action cannot disagree.
    public enum LeadingIntent: Sendable, Equatable {
        case back
        case home
    }

    public static func leadingIntent(stackDepth: Int) -> LeadingIntent {
        stackDepth > 1 ? .back : .home
    }
}

// MARK: - Parsed-tree cache

/// Which screens `GenOSShellModel` must keep a parsed tree for, and when the
/// controller needs to hear about the active screen.
public enum ScreenTreeCache {

    /// The active app's top screen, plus every running session's top screen -
    /// the switcher renders live miniatures of those, so they must stay
    /// parsed. Deduplicated, because the active app is also a running one.
    public static func wantedIds(topScreenId: String?, sessionTopIds: [String?]) -> Set<String> {
        var wanted: Set<String> = []
        if let topScreenId { wanted.insert(topScreenId) }
        for id in sessionTopIds {
            if let id { wanted.insert(id) }
        }
        return wanted
    }

    /// Keys to evict from a cache keyed by screen id.
    public static func staleIds(cached: some Sequence<String>, wanted: Set<String>) -> [String] {
        cached.filter { !wanted.contains($0) }
    }
}

/// `setActiveScreen(topId)` is re-armed only on a REAL change, mirroring RN's
/// `useEffect(..., [topId, top?.status])` dependency list. Re-reporting on
/// every store notification would restart prefetch on every streamed token.
public struct ActiveScreenReport<Status: Equatable>: Equatable {
    /// Double optional on purpose: "never reported" and "reported as nil" are
    /// different, and only the first must force a report.
    private var reported: (id: String?, status: Status?)?

    public init() { reported = nil }

    /// Records the new pair and answers whether the controller must be told.
    public mutating func shouldReport(id: String?, status: Status?) -> Bool {
        if let reported, reported.id == id, reported.status == status { return false }
        reported = (id, status)
        return true
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.reported, rhs.reported) {
        case (nil, nil): return true
        case let (l?, r?): return l.id == r.id && l.status == r.status
        default: return false
        }
    }
}

// MARK: - Wordmark fitting

extension AppLessWordmark {

    /// SVG's default `preserveAspectRatio="xMidYMid meet"`: scale the viewBox
    /// uniformly to fit, then center what is left over.
    public struct Fit: Sendable, Equatable {
        public let scale: Double
        public let offsetX: Double
        public let offsetY: Double

        public init(scale: Double, offsetX: Double, offsetY: Double) {
            self.scale = scale
            self.offsetX = offsetX
            self.offsetY = offsetY
        }
    }

    /// Fit the wordmark's viewBox into a box at `(originX, originY)`.
    ///
    /// A zero-area box yields a zero scale rather than a NaN or an infinity,
    /// so a wordmark laid out before its frame is known collapses instead of
    /// painting garbage.
    public static func fit(
        into width: Double,
        _ height: Double,
        originX: Double = 0,
        originY: Double = 0
    ) -> Fit {
        guard width > 0, height > 0, viewBoxWidth > 0, viewBoxHeight > 0 else {
            return Fit(scale: 0, offsetX: originX, offsetY: originY)
        }
        let scale = Swift.min(width / viewBoxWidth, height / viewBoxHeight)
        return Fit(
            scale: scale,
            offsetX: originX + (width - viewBoxWidth * scale) / 2,
            offsetY: originY + (height - viewBoxHeight * scale) / 2)
    }
}
