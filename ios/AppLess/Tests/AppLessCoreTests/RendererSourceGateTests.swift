import Foundation
import Testing

@testable import AppLessCore

/// The Linux gate over `Sources/AppLessUI/`.
///
/// **These are TEXT-level checks, not type checks.** Nothing here compiles a
/// line of SwiftUI: on Linux `canImport(SwiftUI)` is false, the whole target
/// builds to an empty module, and no renderer can register. What the suite
/// does is read the source as a string and assert structural facts about it -
/// which registrations exist, which prop names a body reads, which icon names
/// it hard-codes. A file can satisfy every test here and still fail to
/// type-check on macOS.
///
/// What it therefore catches (and macOS CI would only catch later, or not at
/// all): a component left unwired, a component wired TWICE, a renderer wired
/// under the wrong contract name, a renderer struct that exists but is never
/// registered, a `body` that reads a prop the contract does not define, and an
/// icon name with no SF Symbol behind it.
///
/// What it cannot catch: type errors, wrong modifier order, a view that
/// compiles but draws the wrong thing.
@Suite struct RendererSourceGateTests {

    // MARK: - Source access

    private static let uiDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AppLessCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // AppLess
        .appendingPathComponent("Sources/AppLessUI")

    private static let scriptsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Scripts")

    private static func uiFileNames() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: uiDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
    }

    private static func uiSource(_ name: String) throws -> String {
        try String(contentsOf: uiDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    /// The renderer implementation files - everything that declares a view the
    /// registry can point at.
    private static let rendererFiles = [
        "Renderers+Charts.swift", "Renderers+Forms.swift", "Renderers+Lists.swift",
        "Renderers+Map.swift", "Renderers+Media.swift", "Renderers+Stats.swift",
        "Renderers+Text.swift",
    ]

    // MARK: - Guard shape

    /// `Scripts/parse-swiftui.py` strips the FIRST line equal to the guard and
    /// the LAST line equal to `#endif`, then hands the rest to `swiftc -parse`.
    /// That is only sound if the guard really is the outermost directive, so
    /// the gate pins the shape rather than merely `contains`.
    @Test func everyUIFileIsWrappedInASingleOutermostGuard() throws {
        let files = try Self.uiFileNames()
        #expect(files.count >= 20)
        for file in files {
            let lines = try Self.uiSource(file).components(separatedBy: "\n")
            let significant = lines.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("//") }
            #expect(
                significant.first == "#if canImport(SwiftUI)",
                Comment(rawValue: "\(file): the guard must be the FIRST non-comment line, "
                    + "found \(significant.first ?? "nothing")"))
            #expect(
                significant.last == "#endif",
                "\(file): the guard must be closed by the LAST non-comment line")

            // Balanced, and never dipping below the outer guard's level -
            // which is what makes "first #if / last #endif" the outer pair.
            var depth = 0
            var minimumInterior = Int.max
            for (index, line) in significant.enumerated() {
                if line.hasPrefix("#if") { depth += 1 }
                if line == "#endif" { depth -= 1 }
                if index < significant.count - 1 { minimumInterior = min(minimumInterior, depth) }
                #expect(depth >= 0, "\(file): unbalanced #endif")
            }
            #expect(depth == 0, "\(file): \(depth) unclosed #if")
            #expect(minimumInterior >= 1, "\(file): code escapes the outer guard")
        }
    }

    /// The gate above encodes what the script does; if the script's own
    /// constants change, the two must be changed together.
    @Test func theParseScriptStillStripsTheGuardThisGateAssumes() throws {
        let script = try String(
            contentsOf: Self.scriptsDirectory.appendingPathComponent("parse-swiftui.py"),
            encoding: .utf8)
        // `##"…"##` because the needle itself contains `"#`.
        #expect(script.contains(##"GUARD = "#if canImport(SwiftUI)""##))
        #expect(script.contains(#""Sources" / "AppLessUI""#))
        #expect(script.contains("swiftc"))
        #expect(script.contains("-parse"))
    }

    // MARK: - Registration table

    /// One `registry.register(.Component) { … AnyView(SomeView(…)) }` line.
    private struct Registration: Equatable {
        let component: String
        let viewType: String
        /// The literal arguments the closure passes, e.g. `horizontal: true`.
        let arguments: String
    }

    /// Parse `Renderers.swift`'s registration block.
    private static func registrations() throws -> [Registration] {
        let source = try uiSource("Renderers.swift")
        var out: [Registration] = []
        // `registry.register(.X)` … `AnyView(YView(a: b, c: d))`
        let pattern = #"registry\.register\(\.(\w+)\)[^{]*\{[^}]*?AnyView\((\w+)\(([^)]*)\)\)"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(source.startIndex..., in: source)
        for match in regex.matches(in: source, range: range) {
            func group(_ index: Int) -> String {
                Range(match.range(at: index), in: source).map { String(source[$0]) } ?? ""
            }
            out.append(
                Registration(
                    component: group(1), viewType: group(2), arguments: group(3)))
        }
        return out
    }

    /// The component a view type is expected to render, from its NAME.
    ///
    /// `FooView` renders `Foo`. The exceptions are the two chart pairs, where
    /// one view serves two contract components and a literal argument tells
    /// them apart, plus `MapViewRenderer` (which cannot be `MapViewView`).
    private static func expectedComponents(forViewType name: String) -> Set<String> {
        switch name {
        case "MapViewRenderer": return ["MapView"]
        case "CartesianBarChartView": return ["BarChart", "HorizontalBarChart"]
        case "CartesianLineChartView": return ["LineChart", "AreaChart"]
        default:
            guard name.hasSuffix("View") else { return [] }
            return [String(name.dropLast("View".count))]
        }
    }

    /// Every contract component wired exactly once. A DUPLICATE registration
    /// would silently shadow the earlier renderer, and the old "count the
    /// occurrences of `registry.register(.`" check could not see the
    /// difference between 30 distinct and 29 distinct + 1 duplicated.
    @Test func everyComponentIsRegisteredExactlyOnce() throws {
        let registrations = try Self.registrations()
        #expect(registrations.count == RenderableComponent.requiredCount)

        var counts: [String: Int] = [:]
        for registration in registrations { counts[registration.component, default: 0] += 1 }

        for component in RenderableComponent.allCases.sorted() {
            #expect(
                counts[component.rawValue] == 1,
                Comment(
                    rawValue:
                        "\(component.rawValue) is registered "
                        + "\(counts[component.rawValue] ?? 0) times"))
        }
        // Nothing OUTSIDE the renderable set is registered - a structural
        // placeholder wired by mistake would render where RN renders nothing.
        for name in counts.keys {
            #expect(
                RenderableComponent(rawValue: name) != nil,
                "\(name) is not a renderable contract component")
            #expect(!ContractSchema.structuralPlaceholders.contains(name), "\(name)")
        }
    }

    /// Each registration points at the view whose NAME matches the contract
    /// component. This is what catches a copy-paste that leaves
    /// `registry.register(.Select) { … DatePickerView(…) }` behind - a bug
    /// that compiles perfectly on macOS.
    @Test func everyRendererIsWiredUnderItsOwnContractName() throws {
        for registration in try Self.registrations() {
            let expected = Self.expectedComponents(forViewType: registration.viewType)
            #expect(
                expected.contains(registration.component),
                Comment(
                    rawValue:
                        "\(registration.component) is wired to \(registration.viewType), "
                        + "which renders \(expected.sorted().joined(separator: " / "))"))
        }
    }

    /// A view type serving two components must be told which one it is by a
    /// literal argument, and the two registrations must disagree on it.
    @Test func sharedChartViewsAreDistinguishedByTheirLiteralArgument() throws {
        let registrations = try Self.registrations()
        func arguments(_ component: String) -> String {
            registrations.first { $0.component == component }?.arguments ?? ""
        }
        #expect(arguments("BarChart").contains("horizontal: false"))
        #expect(arguments("HorizontalBarChart").contains("horizontal: true"))
        #expect(arguments("LineChart").contains("area: false"))
        #expect(arguments("AreaChart").contains("area: true"))

        // …and no OTHER view type is shared, which would need the same
        // treatment and does not have it.
        var byType: [String: [String]] = [:]
        for registration in registrations {
            byType[registration.viewType, default: []].append(registration.component)
        }
        for (type, components) in byType where components.count > 1 {
            #expect(
                ["CartesianBarChartView", "CartesianLineChartView"].contains(type),
                Comment(
                    rawValue:
                        "\(type) now serves \(components.sorted()) - give it a "
                        + "distinguishing argument"))
        }
    }

    /// A renderer struct that exists but was never wired renders nothing at
    /// runtime and is invisible to a count-based check, because the count is
    /// still 30.
    @Test func noRendererStructIsLeftUnregistered() throws {
        let registered = Set(try Self.registrations().map(\.viewType))
        let declaration = try NSRegularExpression(
            pattern: #"(?m)^(?:private |public )?struct (\w+): View \{"#)

        var declared: Set<String> = []
        for file in Self.rendererFiles {
            let source = try Self.uiSource(file)
            for structName in Self.structNames(in: source, matching: declaration) {
                // A renderer is exactly a view taking the (node, ctx) pair.
                let body = Self.body(ofStruct: structName, in: source)
                guard body.contains("let node: ElementNode"), body.contains("let ctx: RenderContext")
                else { continue }
                declared.insert(structName)
            }
        }

        #expect(!declared.isEmpty)
        #expect(
            declared.subtracting(registered).isEmpty,
            Comment(
                rawValue: "renderer views declared but never registered: "
                    + declared.subtracting(registered).sorted().joined(separator: ", ")))
        #expect(
            registered.subtracting(declared).isEmpty,
            Comment(
                rawValue: "registered views with no (node, ctx) declaration: "
                    + registered.subtracting(declared).sorted().joined(separator: ", ")))
    }

    // MARK: - Prop names

    /// Every prop name a renderer body reads must be one the contract declares
    /// for that component.
    ///
    /// A typo (`p.text("titel")`) type-checks on macOS and silently renders an
    /// empty row; so does reading a prop that belongs to a sibling component.
    /// The vocabulary comes from `ContractSchema.paramOrder`, which is
    /// generated from `spec/contract/genos.schema.json`.
    @Test func rendererBodiesOnlyReadPropsTheContractDeclares() throws {
        let componentsByView = try Self.componentsByViewType()
        let reader = try NSRegularExpression(
            pattern:
                #"\bp\.(?:string|number|int|bool|array|object|action|isTruthy|enumString|strings|numbers|elements|elementList|text|coerced|value)\(\s*"([^"]+)""#
        )
        let declaration = try NSRegularExpression(
            pattern: #"(?m)^(?:private |public )?struct (\w+): View \{"#)

        var checked = 0
        for file in Self.rendererFiles {
            let source = try Self.uiSource(file)
            for structName in Self.structNames(in: source, matching: declaration) {
                guard let components = componentsByView[structName] else { continue }
                let body = Self.body(ofStruct: structName, in: source)
                // A view shared by two components may read the union of both
                // vocabularies; here the two chart pairs have identical ones.
                let allowed = components.reduce(into: Set<String>()) { set, component in
                    set.formUnion((ContractSchema.paramOrder[component] ?? []).map(\.name))
                }
                #expect(!allowed.isEmpty, "\(structName): no schema entry for \(components)")
                for key in Self.captures(of: reader, in: body) {
                    checked += 1
                    #expect(
                        allowed.contains(key),
                        Comment(
                            rawValue:
                                "\(file): \(structName) reads prop \"\(key)\", which "
                                + "\(components.sorted().joined(separator: "/")) does not "
                                + "declare (allowed: "
                                + "\(allowed.sorted().joined(separator: ", ")))"))
                }
            }
        }
        // The gate is worthless if the regex stopped matching anything.
        #expect(checked >= 30, "only \(checked) prop reads found - has the reader API changed?")
    }

    /// The same gate, negatively: a prop name that is NOT in the contract must
    /// be rejected, so this pins that the vocabulary really is restrictive.
    @Test func theContractVocabularyIsNarrowerThanTheUnionOfAllProps() {
        let listItem = Set((ContractSchema.paramOrder["ListItem"] ?? []).map(\.name))
        #expect(listItem.contains("title"))
        #expect(!listItem.contains("titel"))
        // `header` is `ListBlock`'s, not `ListItem`'s - reading it in a
        // `ListItemView` body must fail the gate above.
        #expect(!listItem.contains("header"))
        #expect(Set((ContractSchema.paramOrder["ListBlock"] ?? []).map(\.name)).contains("header"))
    }

    // MARK: - Icons

    /// Every icon name hard-coded in a SwiftUI file must resolve to an SF
    /// Symbol. An unmapped name does not crash - `spec/icon-map.md` §1
    /// requires the neutral dot - but a chevron silently becoming a grey dot
    /// is exactly the kind of thing no compile step can see.
    @Test func everyHardCodedIconNameResolves() throws {
        let call = try NSRegularExpression(
            pattern: #"(?:LucideIcon|IconBadge)\(\s*"([^"]+)""#,
            options: [.dotMatchesLineSeparators])
        let phosphor = try NSRegularExpression(
            pattern: #"PhosphorIcon\(\s*"([^"]+)""#, options: [.dotMatchesLineSeparators])

        var found: [String] = []
        for file in try Self.uiFileNames() {
            let source = try Self.uiSource(file)
            for name in Self.captures(of: call, in: source) {
                found.append(name)
                #expect(
                    IconMap.resolve(name).symbolName != nil,
                    Comment(
                        rawValue:
                            "\(file): Lucide icon \"\(name)\" has no SF Symbol - it would "
                            + "draw the placeholder dot"))
            }
            for name in Self.captures(of: phosphor, in: source) {
                found.append(name)
                #expect(
                    IconMap.resolvePhosphor(name).symbolName != nil,
                    "\(file): Phosphor icon \"\(name)\" has no SF Symbol")
            }
        }
        // These three are the ones the renderers hard-code today; the assert
        // is on the COUNT so that a new literal cannot slip in unscanned.
        #expect(Set(found) == ["chevrons-up-down", "check", "chevron-right"])
    }

    /// The names the CORE tables can hand a view. A literal scan cannot see
    /// these, because the view only ever writes `variant.iconName`.
    @Test func everyIconNameTheCoreTablesProduceResolves() {
        for variant in CalloutVariant.allCases {
            #expect(
                IconMap.resolve(variant.iconName).symbolName != nil,
                "callout \(variant): \(variant.iconName)")
        }
        for depth in 0...3 {
            let name = ShellChrome.leadingButton(stackDepth: depth).iconName
            #expect(IconMap.resolve(name).symbolName != nil, "leading chrome at depth \(depth)")
        }
        #expect(IconMap.resolvePhosphor(HomeTiles.fallbackIcon).symbolName != nil)
        #expect(
            IconMap.resolvePhosphor(ShellChrome.Home.sendIconPhosphor).symbolName != nil)
        for (label, icon) in HomeTiles.iconsBySuggestionLabel {
            #expect(
                IconMap.resolvePhosphor(icon).symbolName != nil,
                "suggestion \"\(label)\" icon \(icon)")
        }
    }

    // MARK: - Formatting stays in Core

    /// Numbers reach the user through `AppLessCore`, never through a
    /// `String(format:)` in a view. That is not stylistic: the slider read-out
    /// used `String(format: "%g", …)`, which cuts to six significant digits
    /// and printed `123457` for `123456.7`.
    @Test func noSwiftUIFileFormatsANumberItself() throws {
        for file in try Self.uiFileNames() {
            let source = try Self.uiSource(file)
            #expect(
                !source.contains("String(format:"),
                Comment(
                    rawValue:
                        "\(file) formats a value itself - move it to AppLessCore, where a "
                        + "Linux test can pin it against the JS"))
        }
    }

    // MARK: - Text helpers

    private static func captures(of regex: NSRegularExpression, in text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    private static func structNames(
        in source: String, matching regex: NSRegularExpression
    ) -> [String] {
        captures(of: regex, in: source)
    }

    /// Everything between `struct Name…{` and the next line that is a lone
    /// `}` in column 0 - which is where every top-level declaration in this
    /// package closes.
    private static func body(ofStruct name: String, in source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        guard
            let start = lines.firstIndex(where: {
                $0.contains("struct \(name):") && $0.hasSuffix("{")
            })
        else { return "" }
        var end = lines.count
        for index in (start + 1)..<lines.count where lines[index] == "}" {
            end = index
            break
        }
        return lines[start..<end].joined(separator: "\n")
    }

    /// View type → the contract components it is registered for.
    private static func componentsByViewType() throws -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for registration in try registrations() {
            out[registration.viewType, default: []].insert(registration.component)
        }
        return out
    }
}
