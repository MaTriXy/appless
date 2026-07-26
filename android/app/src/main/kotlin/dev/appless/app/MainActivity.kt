package dev.appless.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.remember
import dev.appless.app.shell.GenOSShell
import dev.appless.app.shell.shellHost
import dev.appless.app.theme.AppLessTheme
import dev.appless.openuilang.LibrarySchema
import java.io.IOException

/**
 * The single activity. AppLess has no navigation graph — the OS shell owns all
 * of it, per app, in [dev.appless.app.shell.ShellState].
 */
public class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // The home wallpaper and the generated screens both draw under the
        // system bars; every inset is applied in Compose instead.
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        val app = application as AppLessApplication

        setContent {
            // Loaded once and held for the composition: the parser needs the
            // contract for EVERY parse pass, including the ~20/second during a
            // stream, so re-reading the asset per screen would be absurd.
            val schema = remember { loadContractSchema() }
            // One host instance for the composition: a fresh one per frame would
            // make `GenOSShell`'s parameter unstable and defeat skipping.
            val host = remember(app) { app.shellHost }
            AppLessTheme {
                GenOSShell(app = host, schema = schema)
            }
        }
    }

    /**
     * `spec/contract/genos.schema.json`, staged into assets by the
     * `stageSpecAssets` Gradle task.
     *
     * A missing or corrupt contract is unrecoverable — the parser cannot map a
     * single positional argument without it — so this throws rather than
     * limping along rendering blank screens.
     */
    private fun loadContractSchema(): LibrarySchema {
        val text = try {
            assets.open(CONTRACT_ASSET).use { it.readBytes().toString(Charsets.UTF_8) }
        } catch (e: IOException) {
            throw IllegalStateException("contract asset '$CONTRACT_ASSET' is missing", e)
        }
        return LibrarySchema.parse(text)
    }

    private companion object {
        const val CONTRACT_ASSET = "genos.schema.json"
    }
}
