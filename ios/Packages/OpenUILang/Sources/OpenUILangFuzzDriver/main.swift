// Differential-fuzz driver for the Swift port.
//
// Replays a campaign produced by
// `spec/fixtures/generator/probes/gen-fuzz-corpus.mjs` and prints the canonical
// stream that `probes/run-differential.mjs` byte-compares against the JS oracle
// and the Kotlin port:
//
//     === <session name> step <N> ===
//     <TreeSerializer.serialize output, newline-terminated>
//
// Campaign contract (the ONE rule, identical in all three drivers): a session's
// step `[srcIndex, len]` has text `sources[srcIndex]` truncated to `len` UTF-16
// code units, and every step of a session goes to ONE StreamingParser in order.
//
//     openui-fuzz-driver <campaign.json> [--out FILE] [--schema FILE]
//
// This target is build-only tooling: it is not a dependency of `OpenUILang` and
// does not participate in `swift test`.

import Foundation
import OpenUILang

struct Session: Decodable {
    let name: String
    let sources: [String]
    let steps: [[Int]]
}

struct Campaign: Decodable {
    let sessions: [Session]
}

/// `spec/contract/genos.schema.json`, resolved from this file's location:
/// Sources/OpenUILangFuzzDriver -> Sources -> OpenUILang -> Packages -> ios -> repo root.
let defaultSchemaURL: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../../../spec/contract/genos.schema.json")
    .standardizedFileURL

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[fuzz-driver:swift] FAILED: \(message)\n".utf8))
    exit(1)
}

/// Buffered writer — the exhaustive campaign emits tens of megabytes.
final class Out {
    private let handle: FileHandle
    private var buffer = Data()
    init(path: String?) {
        if let path {
            _ = FileManager.default.createFile(atPath: path, contents: nil)
            guard let h = FileHandle(forWritingAtPath: path) else { fail("cannot write \(path)") }
            handle = h
        } else {
            handle = FileHandle.standardOutput
        }
        buffer.reserveCapacity(1 << 22)
    }
    func write(_ s: String) {
        buffer.append(contentsOf: s.utf8)
        if buffer.count >= (1 << 22) { flush() }
    }
    func flush() {
        if !buffer.isEmpty {
            handle.write(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }
}

// MARK: - Arguments

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let campaignPath = args.first(where: { !$0.hasPrefix("--") }) else {
    fail("usage: openui-fuzz-driver <campaign.json> [--out FILE] [--schema FILE]")
}
let schemaURL = option("--schema").map { URL(fileURLWithPath: $0) } ?? defaultSchemaURL

// MARK: - Replay

let start = Date()
let schema: LibrarySchema
do {
    schema = try LibrarySchema.load(from: schemaURL)
} catch {
    fail("cannot load schema at \(schemaURL.path): \(error)")
}

let campaign: Campaign
do {
    campaign = try JSONDecoder().decode(
        Campaign.self, from: Data(contentsOf: URL(fileURLWithPath: campaignPath)))
} catch {
    fail("cannot read campaign \(campaignPath): \(error)")
}

let out = Out(path: option("--out"))
var stepCount = 0
for session in campaign.sessions {
    // Precompute each source's UTF-16 code units once; a step is a prefix of one.
    let units = session.sources.map { Array($0.utf16) }
    let parser = StreamingParser(schema: schema)
    for (index, step) in session.steps.enumerated() {
        guard step.count == 2, step[0] >= 0, step[0] < units.count else {
            fail("malformed step \(index) in session \(session.name)")
        }
        let source = units[step[0]]
        let length = max(0, min(step[1], source.count))
        let text = String(decoding: source[0..<length], as: UTF16.self)
        let result = parser.set(text)
        out.write("=== \(session.name) step \(index) ===\n")
        var tree = TreeSerializer.serialize(result)
        if !tree.hasSuffix("\n") { tree += "\n" }
        out.write(tree)
        stepCount += 1
    }
}
out.flush()

let elapsed = Date().timeIntervalSince(start)
FileHandle.standardError.write(
    Data(
        String(
            format: "[fuzz-driver:swift] sessions=%d steps=%d elapsed=%.3fs\n",
            campaign.sessions.count, stepCount, elapsed
        ).utf8))
