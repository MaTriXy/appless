// Root build file. Plugins are declared (but not applied) here so subprojects
// resolve a single, pinned Kotlin version.
plugins {
    kotlin("jvm") version "2.0.21" apply false
}
