import Foundation
import Testing

/// Counts behavioral scenarios (test functions) in this suite and prints the
/// summary line required by the phase gate.
///
/// TAMPER-PROOFING (review nit): a naive textual scan counts any line whose
/// trimmed prefix is "@Test" - including tests disabled inside /* */ block
/// comments or quoted in string literals. Swift Testing does not portably
/// expose a runtime test registry to cross-check against (test discovery
/// lives in toolchain-internal metadata sections), so the chosen hardening,
/// per the review's accepted alternative, is:
///   1. the scan runs on sanitized source: // line comments and (nested)
///      /* */ block comments are stripped, and the CONTENTS of string
///      literals ("...", multiline \"\"\"...\"\"\", raw #"..."#) are blanked,
///      so neither a commented-out nor a quoted @Test can ever count;
///   2. this file embeds a block-commented-out @Test fixture (below) and a
///      per-file self-check asserts it is NOT counted;
///   3. `commentedOutTestsAreNotCounted` exercises the sanitizer against
///      line-comment, inline-block, multi-line-block, nested-block, and
///      string-literal fixtures.
/// Known sanitizer limits (documented, none occur at a position that could
/// begin a line with the marker): multi-# raw strings, and interpolations
/// that themselves contain quotes or comment markers - a desync there is
/// self-healing because single-line string mode resets at end of line.
private enum SourceScan {
    private enum Mode {
        case code
        case lineComment
        case blockComment(depth: Int)
        case singleLineString
        case multilineString
        case rawString
    }

    /// Returns `source` with comments removed and string-literal contents
    /// blanked. Every "\n" survives, so line-prefix scanning still works on
    /// the sanitized text.
    static func sanitize(_ source: String) -> String {
        let chars = Array(source)
        var out = ""
        out.reserveCapacity(chars.count)
        var mode = Mode.code
        var i = 0

        func peek(_ offset: Int) -> Character? {
            let j = i + offset
            return j < chars.count ? chars[j] : nil
        }

        while i < chars.count {
            let c = chars[i]
            switch mode {
            case .code:
                if c == "/", peek(1) == "/" {
                    mode = .lineComment
                    i += 2
                } else if c == "/", peek(1) == "*" {
                    mode = .blockComment(depth: 1)
                    i += 2
                } else if c == "#", peek(1) == "\"" {
                    mode = .rawString
                    i += 2
                } else if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                    mode = .multilineString
                    i += 3
                } else if c == "\"" {
                    mode = .singleLineString
                    i += 1
                } else {
                    out.append(c)
                    i += 1
                }
            case .lineComment:
                if c == "\n" {
                    out.append(c)
                    mode = .code
                }
                i += 1
            case .blockComment(let depth):
                if c == "\n" {
                    out.append(c)
                    i += 1
                } else if c == "/", peek(1) == "*" {
                    // Swift block comments nest.
                    mode = .blockComment(depth: depth + 1)
                    i += 2
                } else if c == "*", peek(1) == "/" {
                    mode = depth == 1 ? .code : .blockComment(depth: depth - 1)
                    i += 2
                } else {
                    i += 1
                }
            case .singleLineString:
                if c == "\\" {
                    i += 2 // skip the escaped character
                } else if c == "\"" {
                    mode = .code
                    i += 1
                } else if c == "\n" {
                    // Swift single-line strings cannot span lines - resetting
                    // here bounds any scanner desync to a single line.
                    out.append(c)
                    mode = .code
                    i += 1
                } else {
                    i += 1
                }
            case .multilineString:
                if c == "\\" {
                    i += 2 // \"\"\" inside a multiline string is not a close
                } else if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                    mode = .code
                    i += 3
                } else {
                    if c == "\n" { out.append(c) }
                    i += 1
                }
            case .rawString:
                if c == "\"", peek(1) == "#" {
                    mode = .code
                    i += 2
                } else {
                    if c == "\n" { out.append(c) }
                    i += 1
                }
            }
        }
        return out
    }

    /// Number of scenario declarations in `source`: lines whose trimmed
    /// prefix, after sanitizing, is the @Test attribute (followed by end of
    /// line, whitespace, or "(" - never a longer identifier).
    static func countTestMarkers(in source: String) -> Int {
        // Split so this function's own source can never trip the scan of the
        // test directory (the sanitizer also blanks strings; belt and braces).
        let marker = "@" + "Test"
        var count = 0
        for rawLine in sanitize(source).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(marker) else { continue }
            let rest = line.dropFirst(marker.count)
            if rest.isEmpty || rest.first == " " || rest.first == "(" { count += 1 }
        }
        return count
    }
}

// ---- Self-check fixture: a block-commented-out scenario. The naive scan
// this replaces would have counted it; `commentedOutTestsAreNotCounted`
// asserts the sanitized scan of THIS file does not. ----
/*
@Test func fixtureCommentedOutScenario() {}
*/
// ---- End fixture ----

@Suite struct ScenarioCountTests {
    @Test func printScenarioCount() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let dir = thisFile.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var total = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            total += SourceScan.countTestMarkers(in: source)
        }
        // Exclude this counting test itself.
        let scenarios = total - 1
        print("core scenarios: \(scenarios)")
        #expect(scenarios >= 40, "behavioral suite must cover at least 40 scenarios")
    }

    @Test func commentedOutTestsAreNotCounted() throws {
        // Runtime fixture: only the two live scenarios may count - never the
        // line-commented, block-commented, nested-block, or quoted ones.
        // (When THIS file is scanned, this whole literal is blanked as a
        // multiline string, so its contents cannot inflate the total.)
        let fixture = """
            // @Test func lineCommented() {}
            /* @Test func inlineBlockCommented() {} */
            /*
            @Test func blockCommented() {}
            /* nested */
            @Test func stillInsideOuterBlockComment() {}
            */
            let quoted = \"\"\"
            @Test func insideStringLiteral() {}
            \"\"\"
            @Test func liveScenarioA() {}
            @Test(.enabled(if: true)) func liveScenarioB() {}
            @Testing func notTheAttribute() {}
            """
        #expect(SourceScan.countTestMarkers(in: fixture) == 2)

        // Per-file self-check: this file physically contains a
        // block-commented-out @Test (the fixture above the suite) plus the
        // quoted markers in this test - yet exactly its 2 live tests count.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        #expect(SourceScan.countTestMarkers(in: source) == 2)
    }
}
