import Foundation
import Testing

@testable import AppLessCore

/// Parity with `spec/icon-map.md`.
///
/// The tables are re-parsed from the spec markdown on every run, so adding a
/// row to the spec without adding it to `IconMap` is a red test.
@Suite struct IconMapTests {

    private func specText() throws -> String { try Repo.text("spec/icon-map.md") }

    // MARK: - (c) every name in the spec maps

    @Test func promptVocabularyCoversAll73Names() throws {
        let rows = try MarkdownTable.rows(in: specText(), section: "2. Model-facing")
        #expect(rows.count == 73)  // spec §2: "Native renderers MUST resolve all 73."
        #expect(IconMap.promptVocabulary.count == 73)

        for row in rows {
            guard let name = row.code(0), let sfSymbol = row.code(1) else {
                throw TestError("unparsable §2 row: \(row.cells)")
            }
            #expect(IconMap.resolve(name) == .symbol(sfSymbol), "§2 \(name)")
        }
    }

    @Test func tintExtrasAreMapped() throws {
        let rows = try MarkdownTable.rows(in: specText(), section: "3. Additional")
        #expect(rows.count == 5)
        #expect(IconMap.tintExtras.count == 5)
        for row in rows {
            guard let name = row.code(0), let sfSymbol = row.code(1) else {
                throw TestError("unparsable §3 row: \(row.cells)")
            }
            #expect(IconMap.resolve(name) == .symbol(sfSymbol), "§3 \(name)")
        }
    }

    @Test func chromeIconsAreMapped() throws {
        let rows = try MarkdownTable.rows(in: specText(), section: "4. Hard-coded")
        #expect(rows.count == 10)
        #expect(IconMap.chromeIcons.count == 10)
        for row in rows {
            // §4 columns: Lucide | Where | SF Symbol | Material Symbol
            guard let name = row.code(0), let sfSymbol = row.code(2) else {
                throw TestError("unparsable §4 row: \(row.cells)")
            }
            #expect(IconMap.resolve(name) == .symbol(sfSymbol), "§4 \(name)")
        }
    }

    @Test func phosphorShellIconsAreMapped() throws {
        let rows = try MarkdownTable.rows(in: specText(), section: "5. Home-shell")
        #expect(rows.count == 23)
        #expect(IconMap.phosphorToSFSymbol.count == 23)
        for row in rows {
            // §5 columns: Phosphor | Used for | SF Symbol | Material Symbol
            guard let name = row.code(0), let sfSymbol = row.code(2) else {
                throw TestError("unparsable §5 row: \(row.cells)")
            }
            #expect(IconMap.resolvePhosphor(name) == .symbol(sfSymbol), "§5 \(name)")
        }
        // Phosphor names are a separate family - they are NOT Lucide names.
        #expect(IconMap.resolve("ChatCircle") == .placeholderDot)
    }

    @Test func combinedTableIs88Names() {
        #expect(IconMap.lucideToSFSymbol.count == 88)  // 73 + 5 + 10
        #expect(
            Set(IconMap.lucideToSFSymbol.keys)
                == Set(IconMap.promptVocabulary.keys)
                    .union(IconMap.tintExtras.keys)
                    .union(IconMap.chromeIcons.keys))
        // No name is mapped twice with a different symbol.
        for (name, symbol) in IconMap.tintExtras {
            #expect(IconMap.promptVocabulary[name] == nil, "\(name) duplicated across §2/§3")
            #expect(IconMap.lucideToSFSymbol[name] == symbol)
        }
        // Every mapped name resolves; no empty symbol slipped in.
        for (name, symbol) in IconMap.lucideToSFSymbol {
            #expect(!symbol.isEmpty, "\(name) maps to an empty symbol")
            #expect(IconMap.resolve(name).symbolName == symbol)
        }
    }

    // MARK: - Unknown-name degradation (spec §1)

    @Test func unknownNamesHitThePlaceholderDot() {
        for name in [
            "definitely-not-an-icon", "", "   ", "Sparkle", "abacus",
            "🙂", "chevron-sideways", "wifi-off",
        ] {
            #expect(IconMap.resolve(name) == .placeholderDot, "\(name) should fall back")
            #expect(IconMap.resolve(name).isFallback)
            #expect(IconMap.resolve(name).symbolName == nil)
        }
        // The fallback is a dot, not a substitute glyph or a hidden row.
        #expect(IconResolution.placeholderDot.symbolName == nil)
        #expect(CdsMetrics.Size.placeholderDot == 8)
        #expect(CdsMetrics.Size.placeholderDotRadius == 4)
        #expect(CdsMetrics.Size.placeholderDotOpacity == 0.6)
    }

    /// `kebabToPascal` (icons.tsx L10-15) splits on `[-_ ]+`, so these forms are
    /// all the same icon.
    @Test func nameNormalizationMatchesKebabToPascal() {
        #expect(IconMap.normalize("credit-card") == "credit-card")
        #expect(IconMap.normalize("credit_card") == "credit-card")
        #expect(IconMap.normalize("credit card") == "credit-card")
        #expect(IconMap.normalize("  Credit-Card  ") == "credit-card")
        #expect(IconMap.normalize("credit__card") == "credit-card")

        for variant in ["credit-card", "credit_card", "credit card", "Credit-Card"] {
            #expect(IconMap.resolve(variant) == .symbol("creditcard.fill"), "\(variant)")
        }
    }

    // MARK: - Badge tinting (spec §1, "must be ported byte-exact")

    @Test func handPickedTintsWin() throws {
        #expect(IconMap.badgeColors.count == 9)
        #expect(IconMap.iconTintTable.count == 32)
        #expect(IconMap.iconTint("wifi").raw == "#0a84ff")
        #expect(IconMap.iconTint("WiFi").raw == "#0a84ff")  // lower-cased first
        #expect(IconMap.iconTint("credit-card").raw == "#34c759")
        #expect(IconMap.iconTint("volume-2").raw == "#ff2d55")
        #expect(IconMap.iconTint("camera").raw == "#8e8e93")  // not a BADGE_COLOR

        // Every hand-picked tint matches the spec's §1 prose list, which spells
        // them as `<name> \`<hex>\`` pairs.
        let spec = try specText()
        for (name, hex) in IconMap.iconTintTable {
            #expect(spec.contains("\(name) `\(hex)`"), "§1 tint for \(name) drifted")
        }
    }

    /// Values produced by the JS reference expression
    /// `h = (h * 31 + charCodeAt(i)) | 0; BADGE_COLORS[Math.abs(h) % 9]`
    /// (run against node 22 to generate these expectations).
    @Test func hashedTintsMatchTheJSOracle() {
        #expect(IconMap.iconTint("dumbbell").raw == "#ff2d55")           // h = -2134774807
        #expect(IconMap.iconTint("pizza").raw == "#af52de")              // h =  106683528
        #expect(IconMap.iconTint("zap").raw == "#ff3b30")                // h =     120361
        #expect(IconMap.iconTint("unknown-icon-name").raw == "#ff2d55")  // h =  -96502372
        #expect(IconMap.iconTint("café").raw == "#5e5ce6")               // h =    3045921
        #expect(IconMap.iconTint("a").raw == "#ff2d55")                  // h =         97
        #expect(IconMap.iconTint("").raw == "#0a84ff")                   // h = 0 -> index 0

        // Every result is a member of BADGE_COLORS, and nothing traps on the
        // Int32.min magnitude edge.
        let palette = Set(IconMap.badgeColors.map(\.raw))
        for i in 0..<2000 {
            let tint = IconMap.iconTint("fuzz-\(i)-icon")
            #expect(palette.contains(tint.raw) || tint.raw == "#8e8e93")
        }
    }
}
