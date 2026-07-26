import Foundation
import Testing

@testable import AppLessCore

/// The shell decisions that moved out of `ScreenHostView`, `SwitcherView`,
/// `GenOSShellView`, `WordmarkView` and `GenOSShellModel`.
@Suite struct ShellPresentationTests {

    // MARK: - Screen host

    /// RN writes `top.error || "Generation failed"` with `||`, not `??`, so an
    /// EMPTY error string falls back too. A `??` port would show a blank
    /// screen with a Retry button and no explanation.
    @Test func errorMessageFallsBackForEmptyAsWellAsMissing() {
        #expect(ScreenHostPresentation.errorMessage("rate limited") == "rate limited")
        #expect(ScreenHostPresentation.errorMessage(nil) == "Generation failed")
        #expect(ScreenHostPresentation.errorMessage("") == "Generation failed")
        // Whitespace is not empty - RN's `||` keeps it, so the port must too.
        #expect(ScreenHostPresentation.errorMessage(" ") == " ")
    }

    /// The error branch is chosen on STATUS alone: a screen that streamed some
    /// content and then failed shows the error, not the partial tree.
    @Test func screenHostStateBranchesOnStatusFirst() {
        #expect(
            ScreenHostPresentation.state(isError: true, hasRoot: true, error: "boom")
                == .error(message: "boom"))
        #expect(
            ScreenHostPresentation.state(isError: true, hasRoot: false, error: nil)
                == .error(message: "Generation failed"))
        #expect(ScreenHostPresentation.state(isError: false, hasRoot: true, error: nil) == .content)
        // Pending with nothing parsed is the skeleton…
        #expect(
            ScreenHostPresentation.state(isError: false, hasRoot: false, error: nil) == .skeleton)
        // …and a stale error string on a healthy screen changes nothing.
        #expect(
            ScreenHostPresentation.state(isError: false, hasRoot: false, error: "old") == .skeleton)
    }

    // MARK: - Switcher

    @Test func switcherPreviewNeedsAScreenContentAndATree() {
        #expect(SwitcherPresentation.showsPreview(hasScreen: true, content: "Card()", hasRoot: true))
        // Each of the three guards, alone, sends the card back to its emoji.
        #expect(
            !SwitcherPresentation.showsPreview(hasScreen: false, content: "Card()", hasRoot: true))
        #expect(!SwitcherPresentation.showsPreview(hasScreen: true, content: "", hasRoot: true))
        #expect(!SwitcherPresentation.showsPreview(hasScreen: true, content: nil, hasRoot: true))
        // Content has arrived but has not parsed into a root yet: drawing a
        // blank card here is what the guard prevents.
        #expect(
            !SwitcherPresentation.showsPreview(hasScreen: true, content: "Card(", hasRoot: false))
    }

    // MARK: - Back gesture

    /// All three thresholds, and one failing case for each - a swipe that
    /// starts too far in, one too short, and one too vertical (which is a
    /// scroll, not a back).
    @Test func backSwipeNeedsEdgeDistanceAndFlatness() {
        #expect(ShellChrome.BackGesture.isBackSwipe(startX: 5, translationX: 90, translationY: 10))
        #expect(
            !ShellChrome.BackGesture.isBackSwipe(startX: 40, translationX: 90, translationY: 10),
            "started past the edge strip")
        #expect(
            !ShellChrome.BackGesture.isBackSwipe(startX: 5, translationX: 30, translationY: 10),
            "did not travel far enough")
        #expect(
            !ShellChrome.BackGesture.isBackSwipe(startX: 5, translationX: 90, translationY: 90),
            "too vertical - that is a scroll")
        // Downward and upward wobble are both measured by magnitude.
        #expect(!ShellChrome.BackGesture.isBackSwipe(startX: 5, translationX: 90, translationY: -90))
        #expect(ShellChrome.BackGesture.isBackSwipe(startX: 5, translationX: 90, translationY: -10))
        // A right-to-left drag is never a back.
        #expect(!ShellChrome.BackGesture.isBackSwipe(startX: 5, translationX: -90, translationY: 0))
        // Exactly on a threshold does NOT qualify (strict comparisons).
        #expect(!ShellChrome.BackGesture.isBackSwipe(startX: 24, translationX: 90, translationY: 0))
        #expect(!ShellChrome.BackGesture.isBackSwipe(startX: 5, translationX: 60, translationY: 0))
        #expect(!ShellChrome.BackGesture.isBackSwipe(startX: 5, translationX: 90, translationY: 60))
    }

    // MARK: - Activity

    @Test func generatingCoversPendingAndStreamingOnly() {
        #expect(ShellActivity.isGenerating(isPending: true, isStreaming: false))
        #expect(ShellActivity.isGenerating(isPending: false, isStreaming: true))
        // Done, errored, or no top screen at all.
        #expect(!ShellActivity.isGenerating(isPending: false, isStreaming: false))
    }

    /// The chrome glyph and the chrome ACTION are two reads of one rule; this
    /// pins that they agree at the boundary, which is where a hand-written
    /// `> 1` in the view could drift from `ShellChrome.leadingButton`.
    @Test func leadingChromeIntentAgreesWithItsGlyph() {
        for depth in 0...4 {
            let intent = ShellActivity.leadingIntent(stackDepth: depth)
            let button = ShellChrome.leadingButton(stackDepth: depth)
            #expect(
                (intent == .back) == (button.iconName == "chevron-left"),
                "depth \(depth): \(intent) vs \(button.iconName)")
        }
        #expect(ShellActivity.leadingIntent(stackDepth: 0) == .home)
        #expect(ShellActivity.leadingIntent(stackDepth: 1) == .home)
        #expect(ShellActivity.leadingIntent(stackDepth: 2) == .back)
    }

    // MARK: - Tree cache

    @Test func treeCacheWantsTheTopScreenAndEverySessionsTop() {
        let wanted = ScreenTreeCache.wantedIds(
            topScreenId: "s1", sessionTopIds: ["s1", "s2", nil, "s3"])
        #expect(wanted == ["s1", "s2", "s3"])

        // No active app: the switcher still needs every session's miniature.
        #expect(
            ScreenTreeCache.wantedIds(topScreenId: nil, sessionTopIds: ["s2"]) == ["s2"])
        // Nothing running at all.
        #expect(ScreenTreeCache.wantedIds(topScreenId: nil, sessionTopIds: []).isEmpty)
        // A session with no screen yet contributes nothing, not an empty key.
        #expect(ScreenTreeCache.wantedIds(topScreenId: nil, sessionTopIds: [nil, nil]).isEmpty)
    }

    @Test func treeCacheEvictsOnlyWhatIsNoLongerWanted() {
        let stale = ScreenTreeCache.staleIds(cached: ["s1", "s2", "s3"], wanted: ["s1", "s3"])
        #expect(stale == ["s2"])
        #expect(ScreenTreeCache.staleIds(cached: ["s1"], wanted: ["s1"]).isEmpty)
        #expect(ScreenTreeCache.staleIds(cached: [], wanted: ["s1"]).isEmpty)
    }

    // MARK: - Active-screen reporting

    /// RN re-arms prefetch on `[topId, top?.status]`. Reporting on every store
    /// notification instead would restart it on every streamed token.
    @Test func activeScreenIsReportedOncePerRealChange() {
        var report = ActiveScreenReport<String>()
        var log: [Bool] = []
        for (id, status) in [
            ("s1", "pending"), ("s1", "pending"), ("s1", "streaming"),
            ("s2", "streaming"), ("s2", "streaming"),
        ] {
            log.append(report.shouldReport(id: id, status: status))
        }
        #expect(log == [true, false, true, true, false])
    }

    /// "Never reported" and "reported as nil" are different states: going Home
    /// must tell the controller there is no active screen exactly once, and a
    /// fresh model must report its first nil too.
    @Test func activeScreenDistinguishesNeverReportedFromReportedNil() {
        var fresh = ActiveScreenReport<String>()
        let firstNil = fresh.shouldReport(id: nil, status: nil)
        let secondNil = fresh.shouldReport(id: nil, status: nil)
        #expect(firstNil, "a fresh report must still announce its first nil")
        #expect(!secondNil)

        var used = ActiveScreenReport<String>()
        _ = used.shouldReport(id: "s1", status: "done")
        let wentHome = used.shouldReport(id: nil, status: nil)
        let stayedHome = used.shouldReport(id: nil, status: nil)
        let cameBack = used.shouldReport(id: "s1", status: "done")
        #expect([wentHome, stayedHome, cameBack] == [true, false, true])
    }

    // MARK: - Wordmark

    /// SVG `preserveAspectRatio="xMidYMid meet"`: uniform scale, centered
    /// remainder. The viewBox is 840x217, so a 170x44 box is height-bound.
    @Test func wordmarkFitsUniformlyAndCenters() {
        let box = AppLessWordmark.fit(into: 840, 217)
        #expect(box.scale == 1)
        #expect(box.offsetX == 0)
        #expect(box.offsetY == 0)

        // Width-bound: 400/840 < 400/217, so the scale comes from the width
        // and the leftover height is split.
        let wide = AppLessWordmark.fit(into: 400, 400)
        #expect(abs(wide.scale - 400 / 840) < 1e-12)
        #expect(wide.offsetX == 0)
        #expect(abs(wide.offsetY - (400 - 217 * (400 / 840)) / 2) < 1e-9)

        // Height-bound.
        let tallBox = AppLessWordmark.fit(into: 1680, 217)
        #expect(tallBox.scale == 1)
        #expect(tallBox.offsetX == (1680 - 840) / 2)

        // The origin is carried through, so the shape lands inside its rect.
        let offset = AppLessWordmark.fit(into: 840, 217, originX: 10, originY: 20)
        #expect(offset.offsetX == 10)
        #expect(offset.offsetY == 20)

        // A frame that has not been laid out yet must collapse, not produce a
        // NaN or an infinite scale.
        let empty = AppLessWordmark.fit(into: 0, 0)
        #expect(empty.scale == 0)
        #expect(empty.scale.isFinite)
        #expect(AppLessWordmark.fit(into: 100, 0).scale == 0)
        #expect(AppLessWordmark.fit(into: -100, 44).scale == 0)
    }
}
