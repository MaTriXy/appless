package dev.appless.genoscore

import org.junit.jupiter.api.Test
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Counts behavioral scenarios (test functions) in this suite and prints the
 * summary line the phase gate greps for.
 *
 * TAMPER-PROOFING: a naive textual scan counts any line whose trimmed prefix is
 * the test annotation — including tests disabled inside block comments or quoted
 * in string literals. The hardening here mirrors the Swift sibling's:
 *   1. the scan runs on SANITIZED source — `//` line comments and (nested)
 *      `/* */` block comments are stripped, and the CONTENTS of string literals
 *      ("...", """...""") and character literals are blanked, so neither a
 *      commented-out nor a quoted annotation can ever count;
 *   2. this file embeds a block-commented-out fixture (below) and a per-file
 *      self-check asserts it is NOT counted;
 *   3. [commented out tests are not counted] exercises the sanitizer against
 *      line-comment, inline-block, multi-line-block, nested-block and
 *      string-literal fixtures.
 */
private object SourceScan {
    private enum class Mode { CODE, LINE_COMMENT, BLOCK_COMMENT, STRING, RAW_STRING, CHAR }

    /**
     * Returns [source] with comments removed and string/char-literal contents
     * blanked. Every "\n" survives, so line-prefix scanning still works.
     */
    fun sanitize(source: String): String {
        val out = StringBuilder(source.length)
        var mode = Mode.CODE
        var depth = 0
        var i = 0
        fun peek(offset: Int): Char? = source.getOrNull(i + offset)

        while (i < source.length) {
            val c = source[i]
            when (mode) {
                Mode.CODE -> when {
                    c == '/' && peek(1) == '/' -> {
                        mode = Mode.LINE_COMMENT
                        i += 2
                    }
                    c == '/' && peek(1) == '*' -> {
                        mode = Mode.BLOCK_COMMENT
                        depth = 1
                        i += 2
                    }
                    c == '"' && peek(1) == '"' && peek(2) == '"' -> {
                        mode = Mode.RAW_STRING
                        i += 3
                    }
                    c == '"' -> {
                        mode = Mode.STRING
                        i += 1
                    }
                    c == '\'' -> {
                        mode = Mode.CHAR
                        i += 1
                    }
                    else -> {
                        out.append(c)
                        i += 1
                    }
                }
                Mode.LINE_COMMENT -> {
                    if (c == '\n') {
                        out.append(c)
                        mode = Mode.CODE
                    }
                    i += 1
                }
                Mode.BLOCK_COMMENT -> when {
                    c == '\n' -> {
                        out.append(c)
                        i += 1
                    }
                    c == '/' && peek(1) == '*' -> {
                        depth += 1 // Kotlin block comments nest
                        i += 2
                    }
                    c == '*' && peek(1) == '/' -> {
                        depth -= 1
                        if (depth == 0) mode = Mode.CODE
                        i += 2
                    }
                    else -> i += 1
                }
                Mode.STRING -> when {
                    c == '\\' -> i += 2
                    c == '"' -> {
                        mode = Mode.CODE
                        i += 1
                    }
                    c == '\n' -> {
                        // Kotlin single-line strings cannot span lines —
                        // resetting bounds any scanner desync to one line.
                        out.append(c)
                        mode = Mode.CODE
                        i += 1
                    }
                    else -> i += 1
                }
                Mode.RAW_STRING -> when {
                    c == '"' && peek(1) == '"' && peek(2) == '"' -> {
                        mode = Mode.CODE
                        i += 3
                    }
                    else -> {
                        if (c == '\n') out.append(c)
                        i += 1
                    }
                }
                Mode.CHAR -> when {
                    c == '\\' -> i += 2
                    c == '\'' -> {
                        mode = Mode.CODE
                        i += 1
                    }
                    c == '\n' -> {
                        out.append(c)
                        mode = Mode.CODE
                        i += 1
                    }
                    else -> i += 1
                }
            }
        }
        return out.toString()
    }

    /**
     * Number of scenario declarations in [source]: lines whose trimmed prefix,
     * after sanitizing, is the test annotation followed by end of line,
     * whitespace or "(" — never a longer identifier.
     */
    fun countTestMarkers(source: String): Int {
        // Split so this function's own source can never trip the directory scan
        // (the sanitizer also blanks strings; belt and braces).
        val marker = "@" + "Test"
        var count = 0
        for (rawLine in sanitize(source).split('\n')) {
            val line = rawLine.trim()
            if (!line.startsWith(marker)) continue
            val rest = line.substring(marker.length)
            if (rest.isEmpty() || rest[0] == ' ' || rest[0] == '(') count++
        }
        return count
    }
}

// ---- Self-check fixture: a block-commented-out scenario. The naive scan this
// replaces would have counted it; `commented out tests are not counted` asserts
// the sanitized scan of THIS file does not. ----
/*
@Test
fun fixtureCommentedOutScenario() {}
*/
// ---- End fixture ----

class ScenarioCountTest {
    private val sourceDir = File("src/test/kotlin/dev/appless/genoscore")

    @Test
    fun `print scenario count`() {
        assertTrue(sourceDir.isDirectory, "test sources not found at ${sourceDir.absolutePath}")
        val files = sourceDir.listFiles { f: File -> f.extension == "kt" }!!.sortedBy { it.name }
        var total = 0
        for (file in files) {
            total += SourceScan.countTestMarkers(file.readText())
        }
        // Exclude this counting test itself.
        val scenarios = total - 1
        println("core scenarios: $scenarios")
        assertTrue(scenarios >= 120, "behavioral suite must cover at least 120 scenarios, got $scenarios")
    }

    @Test
    fun `commented out tests are not counted`() {
        // Runtime fixture: only the two live scenarios may count — never the
        // line-commented, block-commented, nested-block or quoted ones. (When
        // THIS file is scanned, the whole literal below is blanked as a raw
        // string, so its contents cannot inflate the total.)
        val fixture = """
            // @Test fun lineCommented() {}
            /* @Test fun inlineBlockCommented() {} */
            /*
            @Test fun blockCommented() {}
            /* nested */
            @Test fun stillInsideOuterBlockComment() {}
            */
            val quoted = "@Test fun insideStringLiteral() {}"
            @Test fun liveScenarioA() {}
            @Test(enabled = true) fun liveScenarioB() {}
            @TestFactory fun notTheAnnotation() {}
        """.trimIndent()
        assertEquals(2, SourceScan.countTestMarkers(fixture))

        // Per-file self-check: this file physically contains a
        // block-commented-out annotation (the fixture above the class) plus the
        // quoted markers in this test — yet exactly its 2 live tests count.
        assertEquals(2, SourceScan.countTestMarkers(File("$sourceDir/ScenarioCountTest.kt").readText()))
    }
}
