import Foundation

/// Locating the repo's spec files from a test.
///
/// The Linux tests deliberately read `spec/contract/genos.schema.json` and
/// `spec/icon-map.md` straight from the working tree rather than a copied
/// resource: a copy can go stale silently, the real file cannot.
enum Repo {
    /// `/…/appless` - four levels up from
    /// `ios/AppLess/Tests/AppLessCoreTests/<file>.swift`.
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AppLessCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // AppLess
        .deletingLastPathComponent()  // ios
        .deletingLastPathComponent()  // <repo root>

    static func file(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: file(relativePath), encoding: .utf8)
    }

    static func json(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: file(relativePath))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestError("\(relativePath) is not a JSON object")
        }
        return object
    }
}

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Minimal reader for the pipe tables in `spec/icon-map.md`.
enum MarkdownTable {

    struct Row {
        /// Cells with surrounding whitespace trimmed.
        let cells: [String]
        /// First backtick-quoted token in a cell, e.g. `` `map-pin` `` -> `map-pin`.
        func code(_ index: Int) -> String? {
            guard index < cells.count else { return nil }
            return MarkdownTable.firstCode(cells[index])
        }
    }

    /// Rows of the table under the `## <prefix>…` heading, skipping the header
    /// and separator rows (kept out by requiring a backtick in cell 0).
    static func rows(in markdown: String, section prefix: String) throws -> [Row] {
        let lines = markdown.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## " + prefix) }) else {
            throw TestError("no section '## \(prefix)…' in icon-map.md")
        }
        var out: [Row] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## ") { break }
            guard line.hasPrefix("|") else { continue }
            let cells = line
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.first?.contains("`") == true else { continue }  // header / separator
            out.append(Row(cells: cells))
        }
        return out
    }

    static func firstCode(_ cell: String) -> String? {
        guard let open = cell.firstIndex(of: "`") else { return nil }
        let rest = cell[cell.index(after: open)...]
        guard let close = rest.firstIndex(of: "`") else { return nil }
        return String(rest[..<close])
    }
}
