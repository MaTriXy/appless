package dev.appless.app.compose

import androidx.compose.material3.Text
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.assertIsDisplayed
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SmokeProbe {
    @get:Rule val compose = createComposeRule()

    @Test
    fun composes() {
        compose.setContent { Text("hello") }
        compose.onNodeWithText("hello").assertIsDisplayed()
    }
}
