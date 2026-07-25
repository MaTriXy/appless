import Foundation
import Testing
@testable import GenOSCore

// spec/openui-lang.md §11.1
@Suite struct CleanLangTests {
    @Test func partialFenceLineYieldsEmpty() {
        // "```op" - partial fence, no newline yet; the fence-line regex eats it.
        #expect(Lang.cleanLang("```op") == "")
    }

    @Test func fencedProgramUnwrapped() {
        #expect(Lang.cleanLang("```openui-lang\nPROG\n```") == "PROG")
    }

    @Test func trailingTextAfterCloseCutOnlyWithOpener() {
        #expect(Lang.cleanLang("```openui\nPROG\n``` trailing") == "PROG")
    }

    @Test func trailingFenceRemovedWithoutOpener() {
        #expect(Lang.cleanLang("PROG\n```") == "PROG")
    }

    @Test func midTextFenceSurvivesWithoutOpener() {
        let program = "root = Card(TextContent(\"use ``` to fence\"))\nx = 1"
        #expect(Lang.cleanLang(program) == program)
    }

    @Test func notStringAwareTruncatesAtFenceInsideString() {
        // Opener present and "\n```" occurs inside a string literal -
        // cleanLang truncates there anyway (unlike the parser's stripFences).
        let text = "```\nroot = TextContent(\"a\n``` b\")\n```"
        #expect(Lang.cleanLang(text) == "root = TextContent(\"a")
    }

    @Test func leadingWhitespaceBeforeOpenerAllowed() {
        #expect(Lang.cleanLang("  \n```openui\nPROG\n```") == "PROG")
    }
}

// spec/openui-lang.md §11.2
@Suite struct ExtractActionsTests {
    @Test func collectsTrimsAndDedupesPreservingOrder() {
        let content = """
        a = Button("One", @ToAssistant("  show weather  "))
        b = Button("Two", @ToAssistant("open settings"))
        c = Button("Three", @ToAssistant("show weather"))
        """
        #expect(Lang.extractActions(content) == ["show weather", "open settings"])
    }

    @Test func unescapeCollapsesEveryBackslashPair() {
        // Not JSON semantics: \n becomes n, \" becomes ".
        let content = #"x = Button("t", @ToAssistant("line\nbreak \"quoted\""))"#
        #expect(Lang.extractActions(content) == [#"linenbreak "quoted""#])
    }

    @Test func emptyAfterTrimSkippedAndWhitespaceAfterParenAllowed() {
        let content = """
        a = Button("x", @ToAssistant(   "   "))
        b = Button("y", @ToAssistant(
            "real message"))
        """
        #expect(Lang.extractActions(content) == ["real message"])
    }

    @Test func singleQuotesAndBareTextNotMatched() {
        let content = "a = Button(\"x\", @ToAssistant('nope'))\nb = @ToAssistant(unquoted)"
        #expect(Lang.extractActions(content) == [])
    }
}

// spec/openui-lang.md §11.3
@Suite struct ParseOsCommandTests {
    @Test func simpleCommands() {
        #expect(Lang.parseOsCommand("@OS(back)") == OSCommand(cmd: .back))
        #expect(Lang.parseOsCommand("@OS(home)") == OSCommand(cmd: .home))
        #expect(Lang.parseOsCommand("@OS(switcher)") == OSCommand(cmd: .switcher))
    }

    @Test func caseInsensitiveCommandLowercasedInResult() {
        #expect(Lang.parseOsCommand("@os(HOME)") == OSCommand(cmd: .home))
        #expect(Lang.parseOsCommand("@OS(Back)") == OSCommand(cmd: .back))
    }

    @Test func openWithDoubleQuotedArgOnly() {
        #expect(Lang.parseOsCommand("@OS(open, \"music\")") == OSCommand(cmd: .open, arg: "music"))
        // Single quotes do not match.
        #expect(Lang.parseOsCommand("@OS(open, 'music')") == nil)
    }

    @Test func mustMatchWholeCleanedResponse() {
        #expect(Lang.parseOsCommand("@OS(back)\nroot = Card()") == nil)
        #expect(Lang.parseOsCommand("prefix @OS(back)") == nil)
    }

    @Test func worksThroughFencesAndSurroundingWhitespace() {
        #expect(Lang.parseOsCommand("```\n@OS(switcher)\n```") == OSCommand(cmd: .switcher))
        #expect(Lang.parseOsCommand("  @OS( open , \"maps\" )  ") == OSCommand(cmd: .open, arg: "maps"))
    }

    @Test func unknownCommandRejected() {
        #expect(Lang.parseOsCommand("@OS(reboot)") == nil)
    }
}

// spec/openui-lang.md §11.4
@Suite struct ParseGenosUrlTests {
    @Test func openLinkWithPlusAndPercentDecoding() {
        let parsed = Lang.parseGenosUrl("genos://open?app=music&request=play+some%20jazz")
        #expect(parsed == GenosURL(cmd: "open", params: ["app": "music", "request": "play some jazz"]))
    }

    @Test func keyOnlyPairMapsToEmptyString() {
        let parsed = Lang.parseGenosUrl("genos://toast?text")
        #expect(parsed == GenosURL(cmd: "toast", params: ["text": ""]))
    }

    @Test func upperCaseSchemeAndTrailingSlashAccepted() {
        #expect(Lang.parseGenosUrl("GENOS://HOME") == GenosURL(cmd: "home", params: [:]))
        #expect(Lang.parseGenosUrl("genos://back/") == GenosURL(cmd: "back", params: [:]))
    }

    @Test func badPercentEscapeFallsBackRaw() {
        let parsed = Lang.parseGenosUrl("genos://toast?text=100%zz")
        #expect(parsed == GenosURL(cmd: "toast", params: ["text": "100%zz"]))
    }

    @Test func nonGenosAndNonAlphaCommandRejected() {
        #expect(Lang.parseGenosUrl("https://example.com") == nil)
        #expect(Lang.parseGenosUrl("genos://open2") == nil)
        #expect(Lang.parseGenosUrl("genos:open") == nil)
    }
}

// capabilities.md "Summoned apps": CardHeader rename gate.
@Suite struct SummonRenameTests {
    @Test func adoptsFirstCardHeaderTitleAtDepthOne() {
        let content = "root = Card(CardHeader(\"  Plant Care  \"), TextContent(\"hi\"))"
        #expect(Lang.summonedAppTitle(appId: "summon-plants", stackDepth: 1, content: content) == "Plant Care")
    }

    @Test func gateRejectsDeeperStacksAndNonSummonApps() {
        let content = "root = Card(CardHeader(\"Title\"))"
        #expect(Lang.summonedAppTitle(appId: "summon-x", stackDepth: 2, content: content) == nil)
        #expect(Lang.summonedAppTitle(appId: "weather", stackDepth: 1, content: content) == nil)
    }

    @Test func emptyTitleOrMissingHeaderYieldsNil() {
        #expect(Lang.summonedAppTitle(appId: "summon-x", stackDepth: 1, content: "root = Card(CardHeader(\"   \"))") == nil)
        #expect(Lang.summonedAppTitle(appId: "summon-x", stackDepth: 1, content: "root = TextContent(\"no header\")") == nil)
    }

    @Test func worksThroughFencesWithEscapedQuotes() {
        let content = "```openui\nroot = Card(CardHeader(\"Say \\\"Hi\\\"\"))\n```"
        #expect(Lang.summonedAppTitle(appId: "summon-x", stackDepth: 1, content: content) == "Say \\\"Hi\\\"")
    }
}
