import Foundation
import GenOSCore
import Testing

@testable import AppLessCore

/// The chrome the OS shell draws around a generated screen: which button the
/// top-left slot shows, the transition curves, the minimize-to-icon geometry,
/// the pill/toast/hint copy, and the BYOK gate's rules. Every value is pinned
/// against `src/genos/GenOS.tsx` and `src/genos/shell/*`.
@Suite struct ShellChromeTests {

    // MARK: Chrome buttons

    @Test func theLeadingButtonPopsDeeperThanTheRootAndMinimizesAtIt() {
        #expect(ShellChrome.leadingButton(stackDepth: 0) == .home)
        #expect(ShellChrome.leadingButton(stackDepth: 1) == .home)
        #expect(ShellChrome.leadingButton(stackDepth: 2) == .back)
        #expect(ShellChrome.leadingButton(stackDepth: 9) == .back)
    }

    @Test func bothChromeIconsResolveToSFSymbols() {
        #expect(ChromeLeadingButton.back.iconName == "chevron-left")
        #expect(ChromeLeadingButton.home.iconName == "house")
        #expect(ChromeLeadingButton.back.symbol == .symbol("chevron.left"))
        #expect(ChromeLeadingButton.home.symbol == .symbol("house.fill"))
        #expect(ChromeLeadingButton.back.accessibilityLabel == "Back")
        #expect(ChromeLeadingButton.home.accessibilityLabel == "Home")
    }

    // MARK: Transitions

    @Test func transitionDurationsAndStartStatesMatchRN() {
        let launch = ShellChrome.transition(.launch)
        #expect(launch.duration == 0.380)
        #expect(launch.startOpacity == 0)
        #expect(launch.startTranslateY == 34)
        #expect(launch.startScale == 0.88)
        #expect(launch.startTranslateX == 0)

        let push = ShellChrome.transition(.push)
        #expect(push.duration == 0.300)
        #expect(push.startOpacity == 0)
        #expect(push.startTranslateX == 56)
        #expect(push.startScale == 1)

        let pop = ShellChrome.transition(.pop)
        #expect(pop.duration == 0.260)
        #expect(pop.startOpacity == 0.35)
        #expect(pop.startTranslateX == -44)
        #expect(pop.startScale == 1)
    }

    @Test func everyTransitionEndsAtRest() {
        for direction in [NavDirection.launch, .push, .pop] {
            let geometry = ShellChrome.transition(direction)
            #expect(geometry.opacity(at: 1) == 1)
            #expect(geometry.translateX(at: 1) == 0)
            #expect(geometry.translateY(at: 1) == 0)
            #expect(geometry.scale(at: 1) == 1)
        }
    }

    @Test func transitionProgressIsClampedAndLinearBetweenTheStops() {
        let launch = ShellChrome.transition(.launch)
        #expect(launch.translateY(at: 0) == 34)
        #expect(launch.translateY(at: 0.5) == 17)
        // RN clamps by default - no overshoot past either end.
        #expect(launch.translateY(at: -3) == 34)
        #expect(launch.scale(at: 4) == 1)
    }

    @Test func theStandardEasingIsTheRNBezier() {
        let easing = ShellChrome.standardEasing
        #expect(easing.x1 == 0.22)
        #expect(easing.y1 == 1)
        #expect(easing.x2 == 0.32)
        #expect(easing.y2 == 1)
    }

    // MARK: Minimize

    @Test func minimizeAimsTheScreenAtTheHomeIconGrid() {
        // winH 800, top inset 47 → -(400 - 277) = -123.
        #expect(
            ShellChrome.Minimize.endTranslateY(windowHeight: 800, topInset: 47) == -123)
        #expect(ShellChrome.Minimize.translateY(at: 0, windowHeight: 800, topInset: 47) == 0)
        #expect(
            ShellChrome.Minimize.translateY(at: 0.5, windowHeight: 800, topInset: 47) == -61.5)
    }

    @Test func aShortWindowNeverAnimatesDownward() {
        // winH/2 (200) is already above the grid offset - clamped at 0.
        #expect(ShellChrome.Minimize.endTranslateY(windowHeight: 400, topInset: 47) == 0)
        #expect(ShellChrome.Minimize.endTranslateY(windowHeight: 0, topInset: 0) == 0)
    }

    @Test func minimizeScaleAndOpacityFollowTheRNRamps() {
        #expect(ShellChrome.Minimize.duration == 0.360)
        #expect(ShellChrome.Minimize.scale(at: 0) == 1)
        #expect(abs(ShellChrome.Minimize.scale(at: 1) - 0.08) < 1e-12)
        // opacity: [0, 0.8, 1] → [1, 0.85, 0] - it holds, then drops fast.
        #expect(ShellChrome.Minimize.opacity(at: 0) == 1)
        #expect(abs(ShellChrome.Minimize.opacity(at: 0.4) - 0.925) < 1e-9)
        #expect(abs(ShellChrome.Minimize.opacity(at: 0.8) - 0.85) < 1e-9)
        #expect(abs(ShellChrome.Minimize.opacity(at: 0.9) - 0.425) < 1e-9)
        #expect(ShellChrome.Minimize.opacity(at: 1) == 0)
    }

    @Test func piecewiseInterpolationClampsOutsideItsInputRange() {
        let input = [0.0, 0.8, 1.0]
        let output = [1.0, 0.85, 0.0]
        #expect(ShellChrome.interpolate(-1, inputRange: input, outputRange: output) == 1)
        #expect(ShellChrome.interpolate(2, inputRange: input, outputRange: output) == 0)
        // A malformed range is returned unchanged rather than trapping.
        #expect(ShellChrome.interpolate(0.5, inputRange: [0], outputRange: [1]) == 0.5)
    }

    // MARK: Pill, toast, hint

    @Test func theGeneratingPillSaysWhichPhaseItIsIn() {
        #expect(ShellChrome.generatingLabel(searching: false) == "materializing…")
        #expect(ShellChrome.generatingLabel(searching: true) == "searching the web…")
    }

    @Test func toastDurationMatchesTheRuntimeConstant() {
        #expect(ShellChrome.Toast.visibleSeconds == 2.8)
        #expect(ShellChrome.Toast.visibleSeconds * 1000 == GenOSConstants.toastMs)
    }

    @Test func theOneTimeHintShowsForSixSecondsAndNamesBothGestures() {
        #expect(ShellChrome.Hint.visibleSeconds == 6)
        #expect(ShellChrome.Hint.lines == ["‹ top-left: back / home", "top-right ⧉ : recent apps"])
    }

    @Test func theSkeletonIsThreeBlocks() {
        #expect(ShellChrome.Skeleton.blocks.count == 3)
        #expect(ShellChrome.Skeleton.blocks[0].height == 30)
        #expect(ShellChrome.Skeleton.blocks[0].widthFraction == 0.55)
        #expect(ShellChrome.Skeleton.blocks[1].height == 150)
        #expect(ShellChrome.Skeleton.blocks[2].height == 188)
        #expect(ShellChrome.Skeleton.blocks.allSatisfy { $0.radius > 0 })
    }

    // MARK: Home screen

    @Test func theAskBarOnlySubmitsNonBlankText() {
        #expect(ShellChrome.Home.submission("  order dinner  ") == "order dinner")
        #expect(ShellChrome.Home.submission("   ") == nil)
        #expect(ShellChrome.Home.submission("") == nil)
        #expect(ShellChrome.Home.hasSendableText("  x ") == true)
        #expect(ShellChrome.Home.hasSendableText("\t\n") == false)
    }

    @Test func theSendGlyphResolvesThroughTheIconMap() {
        #expect(IconMap.resolvePhosphor(ShellChrome.Home.sendIconPhosphor) == .symbol("arrow.up"))
    }

    @Test func theCloseBadgeLabelNamesItsApp() {
        #expect(ShellChrome.Home.closeAccessibilityLabel("Trip Planner") == "Close Trip Planner")
    }

    @Test func everyShellColorTokenParses() {
        let colors: [CdsColor] = [
            ShellChrome.Chrome.shadowColor, ShellChrome.Hint.background, ShellChrome.Hint.ink,
            ShellChrome.Pill.background, ShellChrome.Pill.ink, ShellChrome.Pill.shadowColor,
            ShellChrome.Toast.background, ShellChrome.Toast.ink, ShellChrome.Toast.shadowColor,
            ShellChrome.ScreenHost.gradientLightStart, ShellChrome.ScreenHost.retryBackground,
            ShellChrome.ScreenHost.retryInk, ShellChrome.Skeleton.fill, ShellChrome.Home.scrim,
            ShellChrome.Home.taglineInk, ShellChrome.Home.tileLabelInk,
            ShellChrome.Home.tileLabelShadow, ShellChrome.Home.closeBadgeBackground,
            ShellChrome.Home.glassFill, ShellChrome.Home.glassBorder, ShellChrome.Home.glassShadow,
            ShellChrome.Home.suggestionInk, ShellChrome.Home.askInk,
            ShellChrome.Home.askPlaceholderInk, ShellChrome.Home.sendButtonBackground,
            ShellChrome.Home.sendButtonInk, ShellChrome.Switcher.backdrop,
            ShellChrome.Switcher.closeButtonFill, ShellChrome.Switcher.ink,
            ShellChrome.Switcher.emptyInk, ShellChrome.KeyGate.accent, AppLessWordmark.fill,
        ] + ShellChrome.Home.backdropStops
        for color in colors {
            #expect(color.isParsed, "unparsable shell color token \(color.raw)")
        }
    }

    // MARK: Switcher

    @Test func switcherPreviewsRenderAtFullPhoneSizeAndScaleDown() {
        #expect(ShellChrome.Switcher.cardWidth == 188)
        #expect(ShellChrome.Switcher.cardHeight == 400)
        #expect(ShellChrome.Switcher.previewScale == 0.5)
        // RN: PREVIEW_W = CARD_W * 2, PREVIEW_H = CARD_H * 2.
        #expect(ShellChrome.Switcher.previewWidth == 376)
        #expect(ShellChrome.Switcher.previewHeight == 800)
    }

    // MARK: Key gate

    @Test func theKeyGateNeedsTenNonBlankCharacters() {
        #expect(ShellChrome.KeyGate.isSubmittable("csk-123456") == true)  // exactly 10
        #expect(ShellChrome.KeyGate.isSubmittable("  csk-123456  ") == true)
        #expect(ShellChrome.KeyGate.isSubmittable("csk-12345") == false)  // 9
        #expect(ShellChrome.KeyGate.isSubmittable("          ") == false)
        #expect(ShellChrome.KeyGate.isSubmittable("") == false)
    }

    @Test func theKeyGateIsUpOnlyWhenTheKeyIsMissingOrRejected() {
        #expect(ShellChrome.KeyGate.isPresented(.missing) == true)
        #expect(ShellChrome.KeyGate.isPresented(.rejected) == true)
        #expect(ShellChrome.KeyGate.isPresented(.loading) == false)
        #expect(ShellChrome.KeyGate.isPresented(.present) == false)
        #expect(ShellChrome.KeyGate.showsRejectedNotice(.rejected) == true)
        #expect(ShellChrome.KeyGate.showsRejectedNotice(.missing) == false)
    }

    @Test func theStartButtonReportsItsSavingState() {
        #expect(ShellChrome.KeyGate.buttonLabel(saving: false) == "Start")
        #expect(ShellChrome.KeyGate.buttonLabel(saving: true) == "Starting…")
    }

    // MARK: Drift guards against the RN source

    @Test func theRNShellStillDeclaresThePortedCopy() throws {
        let genos = try Repo.text("src/genos/GenOS.tsx")
        #expect(genos.contains("\"searching the web…\" : \"materializing…\""))
        #expect(genos.contains("‹ top-left: back / home"))
        #expect(genos.contains("top-right ⧉ : recent apps"))
        #expect(genos.contains("setTimeout(() => setShowHint(false), 6000)"))
        #expect(genos.contains("setTimeout(() => setToast(null), 2800)"))
        #expect(genos.contains("Easing.bezier(0.22, 1, 0.32, 1)"))
        #expect(genos.contains("outputRange: [1, 0.85, 0]"))
        #expect(genos.contains("outputRange: [1, 0.08]"))
        #expect(genos.contains("insets.top + 230"))

        let home = try Repo.text("src/genos/shell/HomeScreen.tsx")
        #expect(home.contains("Ask for anything…"))
        #expect(home.contains("Just ask."))

        let switcher = try Repo.text("src/genos/shell/Switcher.tsx")
        #expect(switcher.contains("No open apps"))
        #expect(switcher.contains("const CARD_W = 188"))
        #expect(switcher.contains("const CARD_H = 400"))

        let gate = try Repo.text("src/genos/shell/KeyGate.tsx")
        #expect(gate.contains("value.trim().length >= 10"))
        #expect(gate.contains(ShellChrome.KeyGate.rejectedNotice))
        #expect(gate.contains(ShellChrome.KeyGate.signupLabel))
        #expect(gate.contains(ShellChrome.KeyGate.signupURL))
    }
}
