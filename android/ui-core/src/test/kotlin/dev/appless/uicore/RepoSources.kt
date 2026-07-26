package dev.appless.uicore

import java.io.File

/**
 * Locates the repository sources the ported values are pinned against.
 *
 * Gradle sets the test working directory to `android/ui-core`, but the walk
 * starts from this class's own location too so the suite also works when run
 * from an IDE or from the repo root — same approach as
 * `openui-lang`'s `FixtureCorpus`.
 */
internal object RepoSources {

    val repoRoot: File by lazy {
        val starts = listOfNotNull(
            File(System.getProperty("user.dir") ?: ".").absoluteFile,
            classDirectory(),
        )
        for (start in starts) {
            var dir: File? = start
            while (dir != null) {
                if (File(dir, "spec/contract/genos.schema.json").isFile &&
                    File(dir, "src/genos/ui/material/theme.ts").isFile
                ) {
                    return@lazy dir.canonicalFile
                }
                dir = dir.parentFile
            }
        }
        throw IllegalStateException(
            "could not locate the repo root walking up from ${starts.joinToString()}"
        )
    }

    /** `android/ui-core` — where the ported Kotlin sources live. */
    val moduleRoot: File by lazy { File(repoRoot, "android/ui-core").canonicalFile }

    fun file(relative: String): File = File(repoRoot, relative).canonicalFile

    fun text(relative: String): String = file(relative).readText(Charsets.UTF_8)

    /** 1-based line access, so a citation like `theme.ts L43` reads naturally. */
    fun lines(relative: String): List<String> = text(relative).split("\n")

    fun line(relative: String, oneBased: Int): String = lines(relative)[oneBased - 1]

    val schemaJson: String by lazy { text("spec/contract/genos.schema.json") }
    val iconMapMarkdown: String by lazy { text("spec/icon-map.md") }
    val materialThemeTs: List<String> by lazy { lines("src/genos/ui/material/theme.ts") }
    val androidThemeTs: List<String> by lazy { lines("src/genos/theme.android.ts") }

    private fun classDirectory(): File? = try {
        val uri = RepoSources::class.java.protectionDomain?.codeSource?.location?.toURI()
        uri?.let { File(it).absoluteFile }
    } catch (_: Exception) {
        null
    }
}
