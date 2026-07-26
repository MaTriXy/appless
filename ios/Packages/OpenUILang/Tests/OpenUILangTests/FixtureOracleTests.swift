import Foundation
import OpenUILang
import Testing

/// One `.oui` / `.expected.json` twin from `spec/fixtures`.
struct Fixture: Sendable, CustomTestStringConvertible {
    /// `"001-minimal-card"` or `"partial/104-before-root"`.
    let name: String
    let ouiURL: URL
    let expectedURL: URL
    /// `partial/` fixtures are streamed via `StreamingParser.set(_:)`;
    /// complete fixtures are batch-parsed.
    let isPartial: Bool

    var testDescription: String { name }
}

enum FixtureCorpus {
    /// `spec/fixtures`, resolved relative to this test file:
    /// `#filePath` is `ios/Packages/OpenUILang/Tests/OpenUILangTests/FixtureOracleTests.swift`,
    /// so the repo root is five directories above this file's directory
    /// (OpenUILangTests -> Tests -> OpenUILang -> Packages -> ios).
    static let fixturesRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../../../spec/fixtures")
        .standardizedFileURL

    static let schemaURL: URL = fixturesRoot
        .appendingPathComponent("../contract/genos.schema.json")
        .standardizedFileURL

    /// Discovers every `.oui` under `spec/fixtures` (top level and `partial/`),
    /// sorted by name. Returns `[]` if discovery fails; `corpusSize` turns
    /// that into a hard failure.
    static func discover() -> [Fixture] {
        let fm = FileManager.default

        func fixtures(in directory: URL, prefix: String) -> [Fixture]? {
            guard
                let entries = try? fm.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                )
            else { return nil }
            return entries
                .filter { $0.pathExtension == "oui" }
                .map { oui in
                    let base = oui.deletingPathExtension().lastPathComponent
                    return Fixture(
                        name: prefix + base,
                        ouiURL: oui,
                        expectedURL: directory.appendingPathComponent(
                            base + ".expected.json"),
                        isPartial: !prefix.isEmpty
                    )
                }
        }

        guard
            let complete = fixtures(in: fixturesRoot, prefix: ""),
            let partial = fixtures(
                in: fixturesRoot.appendingPathComponent("partial"),
                prefix: "partial/")
        else { return [] }
        return (complete + partial).sorted { $0.name < $1.name }
    }
}

@Suite struct FixtureOracleTests {
    /// CI gate: exactly 90 fixtures must be discovered, and the exact line
    /// "fixtures exercised: 90" must reach stdout.
    @Test func corpusSize() {
        let fixtures = FixtureCorpus.discover()
        print("fixtures exercised: \(fixtures.count)")
        #expect(
            fixtures.count == 90,
            "expected 90 fixtures under \(FixtureCorpus.fixturesRoot.path), found \(fixtures.count)"
        )
    }

    /// The contract must load from the real schema file.
    @Test func schemaLoads() throws {
        let schema = try LibrarySchema.load(from: FixtureCorpus.schemaURL)
        #expect(schema.root == "Card")
        #expect(schema.components.count == 33)
        #expect(schema.paramOrder.count == schema.components.count)
    }

    /// Oracle: parse each fixture and byte-compare the canonical serialization
    /// against the generated expected tree (normalizing ONLY a trailing
    /// newline on each side).
    @Test(arguments: FixtureCorpus.discover())
    func oracle(_ fixture: Fixture) throws {
        let schema = try LibrarySchema.load(from: FixtureCorpus.schemaURL)
        let text = try String(contentsOf: fixture.ouiURL, encoding: .utf8)
        let expected = try String(contentsOf: fixture.expectedURL, encoding: .utf8)

        let result: ParseResult
        if fixture.isPartial {
            let parser = StreamingParser(schema: schema)
            parser.set(text)
            result = parser.result
        } else {
            result = OpenUIParser(schema: schema).parse(text)
        }
        let actual = TreeSerializer.serialize(result)

        compareBytes(
            actual: normalizeTrailingNewline(actual),
            expected: normalizeTrailingNewline(expected),
            fixture: fixture
        )
    }

    // MARK: - Comparison helpers

    private func normalizeTrailingNewline(_ s: String) -> String {
        s.hasSuffix("\n") ? String(s.dropLast()) : s
    }

    private func compareBytes(actual: String, expected: String, fixture: Fixture) {
        let a = Array(actual.utf8)
        let e = Array(expected.utf8)
        if a == e { return }

        var offset = 0
        while offset < min(a.count, e.count) && a[offset] == e[offset] {
            offset += 1
        }
        let context = 40
        func excerpt(_ bytes: [UInt8]) -> String {
            let lo = max(0, offset - context)
            let hi = min(bytes.count, offset + context)
            let slice = String(decoding: bytes[lo..<hi], as: UTF8.self)
            return slice
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
        }
        Issue.record(
            """
            fixture \(fixture.name): first divergence at byte offset \(offset) \
            (actual \(a.count) bytes, expected \(e.count) bytes)
            expected …\(excerpt(e))…
            actual   …\(excerpt(a))…
            """
        )
    }
}
