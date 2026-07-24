import Foundation

/// Names and classification from lang-core `parser/builtins.js`
/// (spec/openui-lang.md §9.2 builtins, §9.3 actions).
enum Builtins {
    static let dataBuiltins: Set<String> = [
        "Count", "First", "Last", "Sum", "Avg", "Min", "Max",
        "Sort", "Filter", "Round", "Abs", "Floor", "Ceil",
    ]
    static let lazyBuiltins: Set<String> = ["Each"]
    /// parser-level action step names → runtime step type strings
    static let actionSteps: [String: String] = [
        "Run": "run",
        "ToAssistant": "continue_conversation",
        "OpenUrl": "open_url",
        "Set": "set",
        "Reset": "reset",
    ]
    static let actionNames: Set<String> = {
        var s = Set(actionSteps.keys)
        s.insert("Action")
        return s
    }()
    static let allNames: Set<String> = dataBuiltins.union(lazyBuiltins).union(actionNames)

    static func isBuiltin(_ name: String) -> Bool { allNames.contains(name) }
    static func isReservedCall(_ name: String) -> Bool { name == "Query" || name == "Mutation" }
}
