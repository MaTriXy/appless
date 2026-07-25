import Foundation
import Testing

@testable import AppLessCore

/// Parity with `src/genos/ui/cupertino/theme.ts`.
///
/// Every assertion cites the RN line it pins, so a drift diff points straight
/// at the TypeScript source.
@Suite struct TokensTests {

    // MARK: - (b) sample token values, byte-exact against the RN theme

    @Test func lightTokensMatchCdsLight() {
        let t = CdsTheme.light
        #expect(t.bg.raw == "#f2f2f7")                      // theme.ts L32
        #expect(t.group.raw == "#ffffff")                   // theme.ts L33
        #expect(t.ink.raw == "#101013")                     // theme.ts L34
        #expect(t.ink2.raw == "rgba(60,60,67,0.6)")         // theme.ts L35
        #expect(t.ink3.raw == "rgba(60,60,67,0.3)")         // theme.ts L36
        #expect(t.sep.raw == "rgba(60,60,67,0.15)")         // theme.ts L37
        #expect(t.fill.raw == "rgba(120,120,128,0.14)")     // theme.ts L38
        #expect(t.tint.raw == "#007aff")                    // theme.ts L39
        #expect(t.green.raw == "#34c759")                   // theme.ts L40
        #expect(t.red.raw == "#ff3b30")                     // theme.ts L41
        #expect(t.bubble.raw == "#e9e9eb")                  // theme.ts L42
        #expect(t.chromeBg.raw == "rgba(255,255,255,0.9)")  // theme.ts L43
        #expect(t.chromeInk.raw == "#1c1c1e")               // theme.ts L44
        #expect(t.chromeBorder.raw == "rgba(0,0,0,0.08)")   // theme.ts L45
        #expect(t.dark == false)                            // theme.ts L47
    }

    @Test func darkTokensMatchCdsDark() {
        let t = CdsTheme.dark
        #expect(t.bg.raw == "#000000")                        // theme.ts L51
        #expect(t.group.raw == "#1c1c1e")                     // theme.ts L52
        #expect(t.ink.raw == "#f5f5f7")                       // theme.ts L53
        #expect(t.ink2.raw == "rgba(235,235,245,0.62)")       // theme.ts L54
        #expect(t.ink3.raw == "rgba(235,235,245,0.3)")        // theme.ts L55
        #expect(t.sep.raw == "rgba(84,84,88,0.55)")           // theme.ts L56
        #expect(t.fill.raw == "rgba(120,120,128,0.22)")       // theme.ts L57
        #expect(t.tint.raw == "#0a84ff")                      // theme.ts L58
        #expect(t.green.raw == "#34c759")                     // theme.ts L59
        #expect(t.red.raw == "#ff3b30")                       // theme.ts L60
        #expect(t.bubble.raw == "#26262a")                    // theme.ts L61
        #expect(t.chromeBg.raw == "rgba(58,58,66,0.92)")      // theme.ts L62
        #expect(t.chromeInk.raw == "#ffffff")                 // theme.ts L63
        #expect(t.chromeBorder.raw == "rgba(255,255,255,0.16)")  // theme.ts L64
        #expect(t.dark == true)                               // theme.ts L66
    }

    @Test func chartPalettesMatch() {
        // theme.ts L46
        #expect(CdsTheme.light.chartPalette.map(\.raw)
            == ["#0A84FF", "#C2410C", "#15803D", "#BF5AF2", "#FF375F", "#0891B2"])
        // theme.ts L65
        #expect(CdsTheme.dark.chartPalette.map(\.raw)
            == ["#3B82F6", "#D97706", "#16A34A", "#A855F7", "#F43F5E", "#0284C7"])
        #expect(CdsTheme.light.chartPalette.count == 6)
        #expect(CdsTheme.dark.chartPalette.count == 6)
    }

    /// Belt and braces: re-read theme.ts and confirm every literal the port
    /// claims actually appears there, so a hand edit to Tokens.swift cannot
    /// invent a color.
    @Test func everyTokenLiteralAppearsInTheRNSource() throws {
        let source = try Repo.text("src/genos/ui/cupertino/theme.ts")
        for theme in [CdsTheme.light, CdsTheme.dark] {
            for (name, color) in theme.colorsByName {
                #expect(
                    source.contains("\"\(color.raw)\""),
                    "\(name) = \(color.raw) is not in cupertino/theme.ts")
            }
            for color in theme.chartPalette {
                #expect(source.contains("\"\(color.raw)\""), "\(color.raw) not in theme.ts")
            }
        }
        // The RN interface declares 14 scalar color tokens + chartPalette + dark.
        #expect(CdsTheme.colorTokenNames.count == 14)
        #expect(Set(CdsTheme.light.colorsByName.keys) == Set(CdsTheme.colorTokenNames))
    }

    // MARK: - Decoding

    @Test func colorsDecodeToTheRightComponents() {
        for theme in [CdsTheme.light, CdsTheme.dark] {
            for (name, color) in theme.colorsByName {
                #expect(color.isParsed, "\(name) = \(color.raw) failed to decode")
            }
            for color in theme.chartPalette {
                #expect(color.isParsed, "\(color.raw) failed to decode")
            }
        }

        // #f2f2f7 -> (242, 242, 247), opaque. theme.ts L32
        let bg = CdsTheme.light.bg
        #expect(bg.bytes == (242, 242, 247))
        #expect(bg.alpha == 1)
        #expect(bg.hex8 == "#f2f2f7ff")

        // rgba(60,60,67,0.6) -> 0-255 channels, 0-1 alpha. theme.ts L35
        let ink2 = CdsTheme.light.ink2
        #expect(ink2.bytes == (60, 60, 67))
        #expect(abs(ink2.alpha - 0.6) < 1e-12)
        #expect(abs(ink2.red - 60.0 / 255.0) < 1e-12)

        // Dark separator keeps its 0.55 alpha. theme.ts L56
        #expect(abs(CdsTheme.dark.sep.alpha - 0.55) < 1e-12)
        #expect(CdsTheme.dark.sep.bytes == (84, 84, 88))

        // Uppercase hex in the chart palette decodes the same as lowercase.
        #expect(CdsTheme.light.chartPalette[0].bytes == (10, 132, 255))  // #0A84FF
        #expect(CdsTheme.light.chartPalette[0].hex8 == CdsTheme.dark.tint.hex8)  // #0a84ff

        // Unparsable input never traps.
        let bogus = CdsColor("not-a-color")
        #expect(bogus.isParsed == false)
        #expect(bogus.raw == "not-a-color")
    }

    /// Port of `useCds()` - theme.ts L69-71.
    @Test func resolveFollowsColorScheme() {
        #expect(CdsTheme.resolve(isDark: true) == CdsTheme.dark)
        #expect(CdsTheme.resolve(isDark: false) == CdsTheme.light)
        #expect(CdsTheme.resolve(isDark: true).dark == true)
        #expect(CdsTheme.resolve(isDark: false).dark == false)
    }

    // MARK: - Metrics

    @Test func metricsMatchTheCupertinoRenderers() {
        #expect(CdsMetrics.Radius.group == 14)              // components.tsx L314
        #expect(CdsMetrics.Radius.iconBadge == 7)           // components.tsx L41
        #expect(CdsMetrics.Radius.field == 12)              // forms.tsx L33
        #expect(CdsMetrics.Radius.media == 16)              // components.tsx L468
        #expect(CdsMetrics.Radius.bubble == 18)             // components.tsx L555
        #expect(CdsMetrics.Radius.bubbleTail == 6)          // components.tsx L557
        #expect(CdsMetrics.Spacing.cardGap == 15)           // components.tsx L56
        #expect(CdsMetrics.Size.iconBadge == 29)            // components.tsx L38
        #expect(CdsMetrics.Size.toggleTrackWidth == 47)     // components.tsx L257
        #expect(CdsMetrics.Size.placeholderDot == 8)        // spec/icon-map.md §1
        #expect(CdsMetrics.Size.placeholderDotOpacity == 0.6)
    }

    /// `TEXT_STYLES` - components.tsx L93-103.
    @Test func textContentStyleTable() {
        let table = CdsMetrics.Typography.textContent
        #expect(table.count == 5)
        #expect(table["small"] == .init(fontSize: 12.5, lineHeight: 18))
        #expect(table["default"] == .init(fontSize: 15, lineHeight: 22))
        #expect(table["large"] == .init(fontSize: 17, lineHeight: 24))
        #expect(table["small-heavy"] == .init(fontSize: 13, lineHeight: 19, fontWeight: .semibold))
        #expect(
            table["large-heavy"]
                == .init(fontSize: 20, lineHeight: 26, fontWeight: .bold, letterSpacing: -0.3))

        // Missing / unknown `style` falls back to `default` (components.tsx L108).
        #expect(CdsMetrics.Typography.textContentStyle(nil) == table["default"])
        #expect(CdsMetrics.Typography.textContentStyle("nonsense") == table["default"])
        #expect(CdsMetrics.Typography.textContentStyle("large") == table["large"])
    }

    @Test func headerTypographyMatchesRN() {
        // components.tsx L67-71 / L80-83
        #expect(CdsMetrics.Typography.headerSubtitle
            == .init(fontSize: 12, fontWeight: .semibold, letterSpacing: 0.6))
        #expect(CdsMetrics.Typography.headerTitle
            == .init(fontSize: 56, lineHeight: 60, fontWeight: .light, letterSpacing: -1.5))
        #expect(CdsMetrics.FontWeight.semibold.rawValue == "600")
        #expect(CdsMetrics.FontWeight.light.numericValue == 300)
    }

    /// `SELECT_SIZES` - forms.tsx L95-99.
    @Test func selectSizeTable() {
        let sizes = CdsMetrics.Typography.selectSizes
        #expect(sizes.count == 3)
        #expect(sizes["small"]?.paddingVertical == 8)
        #expect(sizes["small"]?.fontSize == 13)
        #expect(sizes["medium"]?.paddingVertical == 12)
        #expect(sizes["medium"]?.fontSize == 15)
        #expect(sizes["large"]?.paddingVertical == 15)
        #expect(sizes["large"]?.fontSize == 17)
    }
}
