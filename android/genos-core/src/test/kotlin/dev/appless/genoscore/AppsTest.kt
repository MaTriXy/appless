package dev.appless.genoscore

import org.junit.jupiter.api.Test
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * App catalog parity (src/genos/apps.ts).
 *
 * Several scenarios read the RN source directly as an ORACLE: the Gradle test
 * task sets `workingDir = projectDir`, so the repo root is two levels up. That
 * turns "ported verbatim" from a claim into an assertion.
 */
class AppsTest {
    private fun repoFile(path: String): File = File("../../$path")

    @Test
    fun `twelve built-in apps with stable ids`() {
        assertEquals(12, Apps.all.size)
        assertEquals(
            listOf(
                "messages", "food", "fitness", "banking", "flights", "calendar",
                "music", "photos", "weather", "notes", "maps", "settings",
            ),
            Apps.all.map { it.id },
        )
        // ids are unique and lower-case.
        assertEquals(Apps.all.size, Apps.all.map { it.id }.toSet().size)
        assertTrue(Apps.all.all { it.id == it.id.lowercase() })
    }

    @Test
    fun `messages app request is verbatim`() {
        val messages = Apps.find("messages")
        assertNotNull(messages)
        assertEquals("Messages", messages.name)
        assertEquals("💬", messages.emoji)
        assertEquals("#34c759", messages.tileStart)
        assertEquals("#28a745", messages.tileEnd)
        assertEquals(
            "Open the \"Messages\" app home screen: an inbox list of 7 conversations with " +
                "contact names, last message snippets, timestamps, and a compose button.",
            messages.request,
        )
    }

    @Test
    fun `every app request appears verbatim in the RN source`() {
        val source = repoFile("src/genos/apps.ts").readText()
        // apps.ts quotes requests with single quotes and escapes inner
        // apostrophes as \' — undo that one escape before searching.
        val unescaped = source.replace("\\'", "'")
        for (app in Apps.all) {
            assertTrue(
                unescaped.contains(app.request),
                "request for ${app.id} is not verbatim from src/genos/apps.ts",
            )
        }
    }

    @Test
    fun `every tile colour and emoji appears in the RN source`() {
        val source = repoFile("src/genos/apps.ts").readText()
        for (app in Apps.all) {
            assertTrue(source.contains("\"${app.tileStart}\""), "tileStart ${app.tileStart}")
            assertTrue(source.contains("\"${app.tileEnd}\""), "tileEnd ${app.tileEnd}")
            assertTrue(source.contains("\"${app.emoji}\""), "emoji for ${app.id}")
        }
        assertEquals("#5e5ce6", Apps.DEFAULT_TILE_START)
        assertEquals("#bf5af2", Apps.DEFAULT_TILE_END)
    }

    @Test
    fun `ten suggestion chips phrased as commands, verbatim`() {
        assertEquals(10, Apps.suggestions.size)
        val source = repoFile("src/genos/apps.ts").readText().replace("\\'", "'")
        for (s in Apps.suggestions) {
            assertTrue(source.contains("\"${s.command}\""), "command '${s.command}' not verbatim")
            assertTrue(source.contains("\"${s.label}\""), "label '${s.label}' not verbatim")
        }
        assertEquals("order some dinner from a great place nearby", Apps.suggestions[0].command)
        assertEquals("start a note for my grocery list", Apps.suggestions.last().command)
    }

    @Test
    fun `slug lower-cases and collapses non-alphanumeric runs`() {
        assertEquals("summon-plant-care", Apps.summonApp("Plant Care").id)
        assertEquals("summon-my-todo-list", Apps.summonApp("My  TODO   list").id)
        assertEquals("summon-a1b2", Apps.summonApp("a1b2").id)
        // Non-ASCII letters are not [a-z0-9] and collapse into a dash.
        assertEquals("summon-caf-", Apps.summonApp("Café").id)
    }

    @Test
    fun `slug keeps boundary dashes from surrounding punctuation`() {
        // RN's replace does not trim: "  Hi!  " → "-hi-".
        assertEquals("summon--hi-", Apps.summonApp("  Hi!  ").id)
        assertEquals("summon--", Apps.summonApp("!!!").id)
        assertEquals("summon-", Apps.summonApp("").id)
    }

    @Test
    fun `summoned app carries the sparkle emoji, default tile and request template`() {
        val app = Apps.summonApp("Plant Care")
        assertEquals("Plant Care", app.name)
        assertEquals("✨", app.emoji)
        assertEquals(Apps.DEFAULT_TILE_START, app.tileStart)
        assertEquals(Apps.DEFAULT_TILE_END, app.tileEnd)
        assertEquals(
            "Open an app called \"Plant Care\". Invent a plausible, polished home screen for " +
                "it with realistic content and tappable rows or buttons for its main features.",
            app.request,
        )
    }

    @Test
    fun `summon request template is verbatim from the RN source`() {
        val source = repoFile("src/genos/apps.ts").readText()
        val marker = ". Invent a plausible, polished home screen for it with realistic content " +
            "and tappable rows or buttons for its main features."
        assertTrue(source.contains(marker))
        assertTrue(Apps.summonApp("X").request.endsWith(marker))
    }

    @Test
    fun `lowercase is locale-independent - a Turkish default locale cannot break the slug`() {
        val previous = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.forLanguageTag("tr-TR"))
            // "I".toLowerCase(tr) is "ı" (dotless), which is not [a-z0-9] and
            // would collapse to a dash. Kotlin's lowercase() is Locale.ROOT.
            assertEquals("summon-india", Apps.summonApp("INDIA").id)
        } finally {
            java.util.Locale.setDefault(previous)
        }
    }

    @Test
    fun `find returns null for unknown ids`() {
        assertNull(Apps.find("nope"))
        assertNull(Apps.find("Weather")) // case-sensitive, like the RN lookup
        assertEquals("Weather", Apps.find("weather")?.name)
    }
}
