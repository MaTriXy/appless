package dev.appless.genoscore

import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

// spec/openui-lang.md §11.1
class CleanLangTest {
    @Test
    fun `partial fence line yields empty`() {
        // "```op" — a partial fence with no newline yet; the fence-line regex
        // eats it, which is what keeps cleanLang safe on partial streams.
        assertEquals("", Lang.cleanLang("```op"))
    }

    @Test
    fun `fenced program is unwrapped`() {
        assertEquals("PROG", Lang.cleanLang("```openui-lang\nPROG\n```"))
    }

    @Test
    fun `trailing text after the close is cut only with an opener`() {
        assertEquals("PROG", Lang.cleanLang("```openui\nPROG\n``` trailing"))
    }

    @Test
    fun `trailing fence removed without an opener`() {
        assertEquals("PROG", Lang.cleanLang("PROG\n```"))
    }

    @Test
    fun `mid-text fence survives without an opener`() {
        val program = "root = Card(TextContent(\"use ``` to fence\"))\nx = 1"
        assertEquals(program, Lang.cleanLang(program))
    }

    @Test
    fun `not string-aware - truncates at a fence inside a string`() {
        // Opener present and "\n```" occurs inside a string literal — cleanLang
        // truncates there anyway (unlike the parser's stripFences).
        val text = "```\nroot = TextContent(\"a\n``` b\")\n```"
        assertEquals("root = TextContent(\"a", Lang.cleanLang(text))
    }

    @Test
    fun `leading whitespace before the opener is allowed`() {
        assertEquals("PROG", Lang.cleanLang("  \n```openui\nPROG\n```"))
    }

    @Test
    fun `fence info word chars are ASCII-only like JS`() {
        // JS \w is ASCII-only: '```héllo' strips only '```h', leaving 'éllo'.
        // A Unicode-aware \w would wrongly eat the whole info string.
        assertEquals("éllo\nBODY", Lang.cleanLang("```héllo\nBODY\n```"))
    }

    @Test
    fun `vertical tab after the fence info is whitespace like JS`() {
        // JS [^\S\n] includes \v (U+000B); java.util.regex's \s does not.
        assertEquals("BODY", Lang.cleanLang("```md\u000B\nBODY\n```"))
    }

    @Test
    fun `BOM before the opener is whitespace like JS`() {
        // JS \s includes U+FEFF; java.util.regex's \s does not, in any mode.
        assertEquals("PROG", Lang.cleanLang("\uFEFF```\nPROG\n```"))
    }

    @Test
    fun `BOM after the trailing fence is still removed like JS`() {
        assertEquals("PROG", Lang.cleanLang("PROG\n```\uFEFF"))
    }

    @Test
    fun `NEL after the trailing fence is NOT whitespace like JS`() {
        // U+0085 is whitespace to Java's UNICODE_CHARACTER_CLASS \s but not to
        // JS, so the trailing fence must survive.
        assertEquals("PROG\n```\u0085", Lang.cleanLang("PROG\n```\u0085"))
    }

    @Test
    fun `combining mark glued to the closing fence still cuts like JS`() {
        // node: with t = "PROG\n```\u0301x", t.slice(0, t.indexOf("\n```"))
        // === "PROG" — indexOf works on UTF-16 units, which is what Kotlin's
        // indexOf does too.
        assertEquals("PROG", Lang.cleanLang("```\nPROG\n```\u0301x"))
    }

    @Test
    fun `dollar anchor semantics - trailing newline after the fence keeps it`() {
        // JS /\n```\s*$/ with no `m` flag anchors at end of INPUT; Java's `$`
        // also matches before a final line terminator, which would strip here.
        // \s* covers the trailing "\n" so both engines strip — but a fence
        // followed by text after a newline must survive.
        assertEquals("PROG", Lang.cleanLang("PROG\n```\n"))
        assertEquals("PROG\n```\ntail", Lang.cleanLang("PROG\n```\ntail"))
    }
}

// spec/openui-lang.md §11.2
class ExtractActionsTest {
    @Test
    fun `collects, trims and dedupes preserving first-seen order`() {
        val content = """
            a = Button("One", @ToAssistant("  show weather  "))
            b = Button("Two", @ToAssistant("open settings"))
            c = Button("Three", @ToAssistant("show weather"))
        """.trimIndent()
        assertEquals(listOf("show weather", "open settings"), Lang.extractActions(content))
    }

    @Test
    fun `unescape collapses every backslash pair`() {
        // Not JSON semantics: \n becomes n, \" becomes ".
        val content = """x = Button("t", @ToAssistant("line\nbreak \"quoted\""))"""
        assertEquals(listOf("linenbreak \"quoted\""), Lang.extractActions(content))
    }

    @Test
    fun `empty after trim is skipped and whitespace after the paren is allowed`() {
        val content = "a = Button(\"x\", @ToAssistant(   \"   \"))\n" +
            "b = Button(\"y\", @ToAssistant(\n    \"real message\"))"
        assertEquals(listOf("real message"), Lang.extractActions(content))
    }

    @Test
    fun `single quotes and bare text are not matched`() {
        val content = "a = Button(\"x\", @ToAssistant('nope'))\nb = @ToAssistant(unquoted)"
        assertEquals(emptyList(), Lang.extractActions(content))
    }

    @Test
    fun `ECMAScript whitespace and dot semantics inside the matcher`() {
        // \s* before the quote must accept U+FEFF (JS \s), and the escape
        // matcher \\. must accept \v (JS . excludes only \n \r U+2028 U+2029).
        val content = "a = @ToAssistant(\uFEFF\"bom ws\")\nb = @ToAssistant(\"esc\\\u000Baped\")"
        assertEquals(listOf("bom ws", "esc\u000Baped"), Lang.extractActions(content))
    }

    @Test
    fun `an escaped newline terminates the capture like JS dot`() {
        // JS `.` does not match \n, so "\<newline>" is not a valid escape pair
        // and the capture cannot cross it.
        assertEquals(emptyList(), Lang.extractActions("@ToAssistant(\"a\\\nb\")"))
    }
}

// spec/openui-lang.md §11.3
class ParseOsCommandTest {
    @Test
    fun `simple commands`() {
        assertEquals(OSCommand(OSCommandKind.BACK), Lang.parseOsCommand("@OS(back)"))
        assertEquals(OSCommand(OSCommandKind.HOME), Lang.parseOsCommand("@OS(home)"))
        assertEquals(OSCommand(OSCommandKind.SWITCHER), Lang.parseOsCommand("@OS(switcher)"))
    }

    @Test
    fun `case-insensitive, command lower-cased in the result`() {
        assertEquals(OSCommand(OSCommandKind.HOME), Lang.parseOsCommand("@os(HOME)"))
        assertEquals(OSCommand(OSCommandKind.BACK), Lang.parseOsCommand("@OS(Back)"))
    }

    @Test
    fun `open takes a double-quoted arg only`() {
        assertEquals(
            OSCommand(OSCommandKind.OPEN, "music"),
            Lang.parseOsCommand("@OS(open, \"music\")"),
        )
        assertNull(Lang.parseOsCommand("@OS(open, 'music')"))
    }

    @Test
    fun `must match the whole cleaned response`() {
        assertNull(Lang.parseOsCommand("@OS(back)\nroot = Card()"))
        assertNull(Lang.parseOsCommand("prefix @OS(back)"))
    }

    @Test
    fun `works through fences and surrounding whitespace`() {
        assertEquals(OSCommand(OSCommandKind.SWITCHER), Lang.parseOsCommand("```\n@OS(switcher)\n```"))
        assertEquals(
            OSCommand(OSCommandKind.OPEN, "maps"),
            Lang.parseOsCommand("  @OS( open , \"maps\" )  "),
        )
    }

    @Test
    fun `unknown commands are rejected`() {
        assertNull(Lang.parseOsCommand("@OS(reboot)"))
        assertNull(Lang.parseOsCommand("@OS()"))
    }

    @Test
    fun `case-folding lookalikes are rejected like JS`() {
        // JS /…/i (no `u` flag) does NOT fold U+212A (KELVIN) to "k" or U+017F
        // (LONG S) to "s". Spelling the case variants out keeps that true here
        // regardless of any UNICODE_CASE flag default.
        assertNull(Lang.parseOsCommand("@OS(bac\u212A)"))
        assertNull(Lang.parseOsCommand("@O\u017F(back)"))
        assertNull(Lang.parseOsCommand("@OS(\u017Fwitcher)"))
    }

    @Test
    fun `ECMAScript whitespace inside the parens is accepted`() {
        // JS \s includes U+FEFF and \v, which Java's \s misses.
        assertEquals(OSCommand(OSCommandKind.BACK), Lang.parseOsCommand("@OS(\uFEFFback\u000B)"))
    }

    @Test
    fun `a trailing newline does not defeat the end anchor`() {
        // Java's `$` matches before a final line terminator; JS's does not. The
        // ported pattern uses \z, and the jsTrim before it removes the newline,
        // so this still parses — but a line terminator FOLLOWED by text must not.
        assertEquals(OSCommand(OSCommandKind.BACK), Lang.parseOsCommand("@OS(back)\n"))
        assertNull(Lang.parseOsCommand("@OS(back)\nx"))
    }
}

// spec/openui-lang.md §11.4
class ParseGenosUrlTest {
    @Test
    fun `open link with plus and percent decoding`() {
        assertEquals(
            GenosUrl("open", mapOf("app" to "music", "request" to "play some jazz")),
            Lang.parseGenosUrl("genos://open?app=music&request=play+some%20jazz"),
        )
    }

    @Test
    fun `key-only pair maps to the empty string`() {
        assertEquals(
            GenosUrl("toast", mapOf("text" to "")),
            Lang.parseGenosUrl("genos://toast?text"),
        )
    }

    @Test
    fun `upper-case scheme and trailing slash accepted`() {
        assertEquals(GenosUrl("home", emptyMap()), Lang.parseGenosUrl("GENOS://HOME"))
        assertEquals(GenosUrl("back", emptyMap()), Lang.parseGenosUrl("genos://back/"))
    }

    @Test
    fun `bad percent escape falls back to raw`() {
        assertEquals(
            GenosUrl("toast", mapOf("text" to "100%zz")),
            Lang.parseGenosUrl("genos://toast?text=100%zz"),
        )
    }

    @Test
    fun `non-genos and non-alpha commands are rejected`() {
        assertNull(Lang.parseGenosUrl("https://example.com"))
        assertNull(Lang.parseGenosUrl("genos://open2"))
        assertNull(Lang.parseGenosUrl("genos:open"))
        assertNull(Lang.parseGenosUrl(""))
    }

    @Test
    fun `form feed in the query matches like the JS dot`() {
        // JS `.` excludes only \n \r U+2028 U+2029; Java's `.` also excludes
        // U+0085 and would reject a query containing it.
        assertEquals(
            GenosUrl("open", mapOf("note" to "a\u000Cb")),
            Lang.parseGenosUrl("genos://open?note=a\u000Cb"),
        )
        assertEquals(
            GenosUrl("open", mapOf("note" to "a\u0085b")),
            Lang.parseGenosUrl("genos://open?note=a\u0085b"),
        )
    }

    @Test
    fun `a newline in the query is rejected like the JS dot`() {
        assertNull(Lang.parseGenosUrl("genos://open?note=a\nb"))
    }

    @Test
    fun `folded lookalike scheme is rejected like JS`() {
        assertNull(Lang.parseGenosUrl("geno\u017F://home"))
    }

    @Test
    fun `combining mark after the ampersand still splits pairs like JS`() {
        // node: "a=1&\u0301b=2".split("&") === ["a=1", "\u0301b=2"].
        assertEquals(
            GenosUrl("open", mapOf("a" to "1", "\u0301b" to "2")),
            Lang.parseGenosUrl("genos://open?a=1&\u0301b=2"),
        )
    }

    @Test
    fun `combining mark after equals still splits key and value like JS`() {
        // node: "k=\u0301v".indexOf("=") === 1.
        assertEquals(
            GenosUrl("open", mapOf("k" to "\u0301v")),
            Lang.parseGenosUrl("genos://open?k=\u0301v"),
        )
    }

    @Test
    fun `empty pairs between ampersands are skipped, trailing ones included`() {
        // Kotlin's split keeps trailing empties (java.lang.String.split does
        // not); the JS loop skips them explicitly.
        assertEquals(
            GenosUrl("open", mapOf("a" to "1", "b" to "2")),
            Lang.parseGenosUrl("genos://open?a=1&&b=2&"),
        )
    }
}

// capabilities.md "Summoned apps": the CardHeader rename gate.
class SummonRenameTest {
    @Test
    fun `adopts the first CardHeader title at depth one`() {
        val content = "root = Card(CardHeader(\"  Plant Care  \"), TextContent(\"hi\"))"
        assertEquals("Plant Care", Lang.summonedAppTitle("summon-plants", 1, content))
    }

    @Test
    fun `gate rejects deeper stacks and non-summon apps`() {
        val content = "root = Card(CardHeader(\"Title\"))"
        assertNull(Lang.summonedAppTitle("summon-x", 2, content))
        assertNull(Lang.summonedAppTitle("summon-x", 0, content))
        assertNull(Lang.summonedAppTitle("weather", 1, content))
        assertNull(Lang.summonedAppTitle("summon-x", 1, ""))
    }

    @Test
    fun `empty title or missing header yields null`() {
        assertNull(Lang.summonedAppTitle("summon-x", 1, "root = Card(CardHeader(\"   \"))"))
        assertNull(Lang.summonedAppTitle("summon-x", 1, "root = TextContent(\"no header\")"))
    }

    @Test
    fun `works through fences with escaped quotes`() {
        val content = "```openui\nroot = Card(CardHeader(\"Say \\\"Hi\\\"\"))\n```"
        assertEquals("Say \\\"Hi\\\"", Lang.summonedAppTitle("summon-x", 1, content))
    }

    @Test
    fun `BOM whitespace before the title is accepted and trimmed like JS`() {
        val content = "root = Card(CardHeader(\uFEFF\"\uFEFFPlant Care\uFEFF\"))"
        assertEquals("Plant Care", Lang.summonedAppTitle("summon-x", 1, content))
    }

    @Test
    fun `combining mark right after the summon prefix does not defeat the gate`() {
        // JS startsWith works on UTF-16 units, so "summon-\u0301x" still starts
        // with "summon-". Kotlin's startsWith is the same operation.
        val content = "root = Card(CardHeader(\"T\"))"
        assertEquals("T", Lang.summonedAppTitle("summon-\u0301x", 1, content))
    }
}
