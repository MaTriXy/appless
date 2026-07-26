package dev.appless.openuilang.fuzz

import dev.appless.openuilang.JsonValue
import dev.appless.openuilang.LibrarySchema
import dev.appless.openuilang.StreamingParser
import dev.appless.openuilang.TreeSerializer
import java.io.BufferedWriter
import java.io.File
import java.io.OutputStreamWriter
import java.nio.charset.StandardCharsets
import kotlin.system.exitProcess

/**
 * Differential-fuzz driver for the Kotlin port.
 *
 * Replays a campaign produced by
 * `spec/fixtures/generator/probes/gen-fuzz-corpus.mjs` and prints the canonical
 * stream that `probes/run-differential.mjs` byte-compares against the JS oracle
 * and the Swift port:
 * ```
 * === <session name> step <N> ===
 * <TreeSerializer.serialize output, newline-terminated>
 * ```
 *
 * Campaign contract (the ONE rule, identical in all three drivers): a session's
 * step `[srcIndex, len]` has text `sources[srcIndex]` truncated to `len` UTF-16
 * code units — which is exactly [String.substring] on the JVM — and every step
 * of a session goes to ONE [StreamingParser] in order.
 *
 * ```
 * ./gradlew :openui-lang:fuzzDriver -PfuzzCampaign=<file> [-PfuzzOut=<file>] [-PfuzzSchema=<file>]
 * ```
 *
 * Build-only tooling; it is not referenced by the library or by any test.
 */
private fun fail(message: String): Nothing {
    System.err.println("[fuzz-driver:kotlin] FAILED: $message")
    exitProcess(1)
}

/** `spec/contract/genos.schema.json`, found by walking up to the repo root. */
private fun defaultSchemaFile(): File {
    var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
    while (dir != null) {
        val candidate = File(dir, "spec/contract/genos.schema.json")
        if (candidate.isFile) return candidate.canonicalFile
        dir = dir.parentFile
    }
    fail("could not locate spec/contract/genos.schema.json above ${System.getProperty("user.dir")}")
}

public fun main(argv: Array<String>) {
    fun option(name: String): String? {
        val i = argv.indexOf(name)
        return if (i >= 0 && i + 1 < argv.size) argv[i + 1] else null
    }
    val campaignPath = argv.firstOrNull { !it.startsWith("--") }
        ?: fail("usage: fuzz-driver <campaign.json> [--out FILE] [--schema FILE]")
    val schemaFile = option("--schema")?.let(::File) ?: defaultSchemaFile()

    val started = System.nanoTime()
    val schema = try {
        LibrarySchema.load(schemaFile)
    } catch (e: Exception) {
        fail("cannot load schema at $schemaFile: $e")
    }

    val campaign = try {
        JsonValue.parse(File(campaignPath).readText(StandardCharsets.UTF_8))
    } catch (e: Exception) {
        fail("cannot read campaign $campaignPath: $e")
    }
    val sessions = campaign["sessions"]?.arrayValue ?: fail("campaign has no \"sessions\" array")

    val outPath = option("--out")
    val writer: BufferedWriter = if (outPath != null) {
        File(outPath).bufferedWriter(StandardCharsets.UTF_8, 1 shl 22)
    } else {
        BufferedWriter(OutputStreamWriter(System.out, StandardCharsets.UTF_8), 1 shl 22)
    }

    var stepCount = 0
    writer.use { out ->
        for (session in sessions) {
            val name = session["name"]?.stringValue ?: fail("session without \"name\"")
            val sources = (session["sources"]?.arrayValue ?: fail("session $name without sources"))
                .map { it.stringValue ?: fail("non-string source in session $name") }
            val steps = session["steps"]?.arrayValue ?: fail("session $name without steps")
            val parser = StreamingParser(schema)
            for ((index, stepValue) in steps.withIndex()) {
                val step = stepValue.arrayValue
                    ?: fail("malformed step $index in session $name")
                val src = step.getOrNull(0)?.numberValue?.toInt()
                    ?: fail("malformed step $index in session $name")
                val requested = step.getOrNull(1)?.numberValue?.toInt()
                    ?: fail("malformed step $index in session $name")
                if (src < 0 || src >= sources.size) {
                    fail("step $index in session $name references source $src")
                }
                val source = sources[src]
                // UTF-16 code-unit prefix; the generator never cuts a surrogate pair.
                val text = source.substring(0, requested.coerceIn(0, source.length))
                val result = parser.set(text)
                out.write("=== $name step $index ===\n")
                val tree = TreeSerializer.serialize(result)
                out.write(tree)
                if (!tree.endsWith("\n")) out.write("\n")
                stepCount++
            }
        }
    }

    val elapsed = (System.nanoTime() - started) / 1e9
    System.err.println(
        "[fuzz-driver:kotlin] sessions=${sessions.size} steps=$stepCount " +
            "elapsed=${"%.3f".format(elapsed)}s"
    )
}
