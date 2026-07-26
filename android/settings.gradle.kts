// Android-side Gradle build for the native ports (docs/NATIVE_MIGRATION_PLAN.md).
//
// `openui-lang` is deliberately a PURE Kotlin/JVM library with no Android
// dependency so the fixture-oracle suite runs headlessly on any JDK 21 —
// exactly like the Swift sibling (`ios/Packages/OpenUILang`) runs under
// `swift test`. Android-facing modules (the app, Compose renderers) will be
// added later and will depend on this module.

pluginManagement {
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        mavenCentral()
    }
}

rootProject.name = "appless-android"

include(":openui-lang")
include(":genos-core")
include(":ui-core")
