import Foundation
import Testing

/// Counts behavioral scenarios (test functions) in this suite and prints the
/// summary line required by the phase gate.
@Suite struct ScenarioCountTests {
    @Test func printScenarioCount() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let dir = thisFile.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let marker = "@" + "Test"
        var total = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(marker) { total += 1 }
            }
        }
        // Exclude this counting test itself.
        let scenarios = total - 1
        print("core scenarios: \(scenarios)")
        #expect(scenarios >= 40, "behavioral suite must cover at least 40 scenarios")
    }
}
