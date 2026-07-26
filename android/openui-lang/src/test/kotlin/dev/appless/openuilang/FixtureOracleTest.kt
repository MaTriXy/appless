package dev.appless.openuilang

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.DynamicTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestFactory
import java.io.File
import java.nio.charset.StandardCharsets

/** One `.oui` / `.expected.json` twin from `spec/fixtures`. */
internal data class Fixture(
    /** `"001-minimal-card"` or `"partial/104-before-root"`. */
    val name: String,
    val oui: File,
    val expected: File,
    /**
     * `partial/` fixtures are streamed via [StreamingParser.set]; complete
     * fixtures are batch-parsed.
     */
    val isPartial: Boolean,
)

internal object FixtureCorpus {
    /** The CI gate: exactly this many fixtures must be discovered. */
    const val EXPECTED_SIZE: Int = 112

    /**
     * `spec/fixtures`, found by walking up from the module directory to the
     * repo root. The Gradle `test` task sets `workingDir` to
     * `android/openui-lang`, but the walk starts from this class's own
     * location too so the suite also works when run from an IDE or from the
     * repo root.
     */
    val fixturesRoot: File by lazy {
        val starts = listOfNotNull(
            File(System.getProperty("user.dir") ?: ".").absoluteFile,
            classDirectory(),
        )
        for (start in starts) {
            var dir: File? = start
            while (dir != null) {
                val candidate = File(dir, "spec/fixtures")
                if (candidate.isDirectory) return@lazy candidate.canonicalFile
                dir = dir.parentFile
            }
        }
        throw IllegalStateException(
            "could not locate spec/fixtures walking up from ${starts.joinToString()}"
        )
    }

    val schemaFile: File by lazy {
        File(fixturesRoot.parentFile, "contract/genos.schema.json").canonicalFile
    }

    private fun classDirectory(): File? = try {
        val uri = FixtureCorpus::class.java.protectionDomain?.codeSource?.location?.toURI()
        uri?.let { File(it).absoluteFile }
    } catch (_: Exception) {
        null
    }

    /**
     * Discovers every `.oui` under `spec/fixtures` (top level and `partial/`),
     * sorted by name. Returns `[]` if discovery fails; [corpusSize] turns that
     * into a hard failure.
     */
    fun discover(): List<Fixture> {
        fun fixtures(directory: File, prefix: String): List<Fixture>? {
            val entries = directory.listFiles() ?: return null
            return entries
                .filter { it.isFile && it.name.endsWith(".oui") }
                .map { oui ->
                    val base = oui.name.removeSuffix(".oui")
                    Fixture(
                        name = prefix + base,
                        oui = oui,
                        expected = File(directory, "$base.expected.json"),
                        isPartial = prefix.isNotEmpty(),
                    )
                }
        }

        val root = try {
            fixturesRoot
        } catch (_: IllegalStateException) {
            return emptyList()
        }
        val complete = fixtures(root, "") ?: return emptyList()
        val partial = fixtures(File(root, "partial"), "partial/") ?: return emptyList()
        return (complete + partial).sortedBy { it.name }
    }
}

/**
 * Fixture oracle: the Kotlin port is correct when, for every fixture in
 * `spec/fixtures`, `TreeSerializer.serialize(parse(<file>))` is byte-identical
 * to the generated `.expected.json` twin.
 *
 * Mirrors `ios/Packages/OpenUILang/Tests/OpenUILangTests/FixtureOracleTests.swift`:
 * full-tree byte comparison, per-fixture failure output with the
 * first-divergence byte offset and +/-40 bytes of context, and a hard
 * corpus-count assertion.
 */
class FixtureOracleTest {

    /**
     * CI gate: exactly 112 fixtures must be discovered, and the exact line
     * `fixtures exercised: 112` must reach stdout.
     */
    @Test
    fun corpusSize() {
        val fixtures = FixtureCorpus.discover()
        println("fixtures exercised: ${fixtures.size}")
        assertEquals(
            FixtureCorpus.EXPECTED_SIZE,
            fixtures.size,
            "expected ${FixtureCorpus.EXPECTED_SIZE} fixtures under " +
                "${FixtureCorpus.fixturesRoot}, found ${fixtures.size}",
        )
    }

    /** The contract must load from the real schema file. */
    @Test
    fun schemaLoads() {
        val schema = LibrarySchema.load(FixtureCorpus.schemaFile)
        assertEquals("Card", schema.root)
        assertEquals(33, schema.components.size)
        assertEquals(schema.components.size, schema.paramOrder.size)
    }

    /**
     * Oracle: parse each fixture and byte-compare the canonical serialization
     * against the generated expected tree (normalizing ONLY a trailing newline
     * on each side).
     */
    @TestFactory
    fun oracle(): List<DynamicTest> {
        val fixtures = FixtureCorpus.discover()
        val schema = LibrarySchema.load(FixtureCorpus.schemaFile)
        return fixtures.map { fixture ->
            DynamicTest.dynamicTest(fixture.name) { runFixture(fixture, schema) }
        }
    }

    private fun runFixture(fixture: Fixture, schema: LibrarySchema) {
        // Bytes are fed verbatim — no trimming (spec/fixtures/README.md).
        val text = fixture.oui.readText(StandardCharsets.UTF_8)
        val expected = fixture.expected.readText(StandardCharsets.UTF_8)

        val result: ParseResult = if (fixture.isPartial) {
            val parser = StreamingParser(schema)
            parser.set(text)
            parser.result
        } else {
            OpenUIParser(schema).parse(text)
        }
        val actual = TreeSerializer.serialize(result)

        compareBytes(
            actual = normalizeTrailingNewline(actual),
            expected = normalizeTrailingNewline(expected),
            fixture = fixture,
        )
    }

    // ---- Comparison helpers -------------------------------------------------

    private fun normalizeTrailingNewline(s: String): String =
        if (s.endsWith("\n")) s.dropLast(1) else s

    private fun compareBytes(actual: String, expected: String, fixture: Fixture) {
        val a = actual.toByteArray(StandardCharsets.UTF_8)
        val e = expected.toByteArray(StandardCharsets.UTF_8)
        if (a.contentEquals(e)) return

        var offset = 0
        while (offset < minOf(a.size, e.size) && a[offset] == e[offset]) offset++

        val context = 40
        fun excerpt(bytes: ByteArray): String {
            val lo = maxOf(0, offset - context)
            val hi = minOf(bytes.size, offset + context)
            return String(bytes, lo, hi - lo, StandardCharsets.UTF_8)
                .replace("\n", "\\n")
                .replace("\t", "\\t")
        }

        throw AssertionError(
            buildString {
                append("fixture ${fixture.name}: first divergence at byte offset $offset ")
                append("(actual ${a.size} bytes, expected ${e.size} bytes)\n")
                append("expected ...${excerpt(e)}...\n")
                append("actual   ...${excerpt(a)}...")
            }
        )
    }
}
