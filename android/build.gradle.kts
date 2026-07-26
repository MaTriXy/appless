// Root build file. Plugins are declared (but not applied) here so subprojects
// resolve a single, pinned Kotlin version.
plugins {
    kotlin("jvm") version "2.0.21" apply false

    // `:app` only. These MUST be declared here rather than in
    // `app/build.gradle.kts`: the Kotlin plugin is already on the root build
    // classpath, so an AGP declared further down the tree lands in a child
    // classloader and `kotlin-android` cannot see `com.android.build.*`.
    // `apply false` keeps the three pure Kotlin/JVM modules untouched.
    id("com.android.application") version "8.7.3" apply false
    kotlin("android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
}
