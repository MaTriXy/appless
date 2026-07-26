import Foundation
import Testing

@testable import OpenUILang

/// The CLDR-root ASCII collation table (`StringJS.jsASCIILocaleCompare`)
/// against V8 itself.
///
/// Both READMEs used to claim "235,233 ordered pairs vs V8 localeCompare — zero
/// mismatches" from a sweep that was never committed. This is the committed
/// replacement: `spec/fixtures/generator/probes/collation-corpus.json` records
/// `Math.sign(a.localeCompare(b))` for every pair of a deterministic 700-string
/// corpus drawn from the full 0x00-0x7F alphabet, and is regenerable with
///
///     node probes/verify-collation.mjs --emit
///
/// The Kotlin sibling (`AsciiCollationTest.kt`) asserts against the SAME file,
/// so the two hand-compiled weight tables are gated against V8 and — as a
/// consequence — against each other. `probes/verify-collation.mjs` (no flags)
/// drives V8 plus both suites in one command and is wired into
/// `.github/workflows/differential-fuzz.yml`.
@Suite struct ASCIICollationTests {

    struct Corpus {
        let strings: [String]
        let signs: [Character]
        let pairCount: Int
    }

    static func load() throws -> Corpus {
        let url = FixtureCorpus.fixturesRoot
            .appendingPathComponent("generator/probes/collation-corpus.json")
            .standardizedFileURL
        let doc = try JSONDecoder().decode(JSONValue.self, from: try Data(contentsOf: url))
        guard case .object(let o) = doc,
            case .array(let rawStrings)? = o["strings"],
            case .string(let signs)? = o["signs"],
            case .number(let pairCount)? = o["pairCount"]
        else {
            throw CollationCorpusError(
                "malformed \(url.path) — run `node probes/verify-collation.mjs --emit`")
        }
        let strings: [String] = rawStrings.map {
            if case .string(let s) = $0 { return s }
            return ""
        }
        return Corpus(strings: strings, signs: Array(signs), pairCount: Int(pairCount))
    }

    struct CollationCorpusError: Error { let message: String
        init(_ m: String) { message = m }
    }

    @Test func everyASCIIPairMatchesV8() throws {
        let corpus = try Self.load()
        #expect(corpus.pairCount == corpus.strings.count * (corpus.strings.count - 1) / 2)
        #expect(corpus.signs.count == corpus.pairCount, "one sign per pair")

        var k = 0
        var mismatches = 0
        var examples = ""
        for i in corpus.strings.indices {
            for j in (i + 1)..<corpus.strings.count {
                let expected = corpus.signs[k]
                k += 1
                guard let got = jsASCIILocaleCompare(corpus.strings[i], corpus.strings[j]) else {
                    Issue.record("ASCII pair answered nil at \(i)/\(j)")
                    return
                }
                let gotSign: Character = got < 0 ? "<" : (got > 0 ? ">" : "=")
                if gotSign != expected {
                    mismatches += 1
                    if mismatches <= 5 {
                        examples +=
                            "\n  \(TreeSerializer.quote(corpus.strings[i])) vs "
                            + "\(TreeSerializer.quote(corpus.strings[j])): "
                            + "V8 \(expected), port \(gotSign)"
                    }
                }
            }
        }
        #expect(
            mismatches == 0,
            "collation mismatches vs V8 over \(corpus.pairCount) pairs:\(examples)")
    }

    /// The comparator must be a strict weak ordering on THIS alphabet: the
    /// ports hand it to `sorted(by:)` / `sortedWith`, and an inconsistent
    /// comparator there is the whole reason `@Sort` over MIXED
    /// numeric/non-numeric strings is a documented deviation. Spot-checked over
    /// the pinned adversarial prefix, where the interesting shapes live
    /// (hyphen, space, case, digits).
    @Test func comparatorIsAntisymmetricAndTransitive() throws {
        let strings = Array(try Self.load().strings.prefix(70))
        func cmp(_ a: String, _ b: String) -> Int { jsASCIILocaleCompare(a, b)! }
        func sign(_ n: Int) -> Int { n < 0 ? -1 : (n > 0 ? 1 : 0) }
        for a in strings {
            for b in strings {
                #expect(sign(cmp(a, b)) + sign(cmp(b, a)) == 0, "antisymmetry")
            }
        }
        for a in strings {
            for b in strings where cmp(a, b) <= 0 {
                for c in strings where cmp(b, c) <= 0 {
                    #expect(cmp(a, c) <= 0, "transitivity")
                }
            }
        }
    }
}
