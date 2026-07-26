// `ui-core` — the Android analog of `ios/AppLess/Sources/AppLessCore`.
//
// Deliberately a PURE Kotlin/JVM library: everything in here is the part of
// the Material 3 design layer that can be verified WITHOUT a device — design
// tokens, the icon table, the renderer conformance registry, and the
// platform-independent renderer logic (chart shaping, form state, action
// dispatch, map spans, semantic image policy).
//
// The Compose UI layer lands in a later stage as a separate Android module
// that depends on this one; keeping the testable core Android-free means
// `./gradlew :ui-core:test` runs headlessly on any JDK 21, exactly like
// `:openui-lang`.
plugins {
    kotlin("jvm")
}

kotlin {
    jvmToolchain(21)
    explicitApi()
}

dependencies {
    // Contract prop values (`PropValue`, `ActionPlan`) and the hand-rolled
    // `JsonValue` reader used to load `spec/contract/genos.schema.json`.
    api(project(":openui-lang"))

    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()

    // Tests walk up from here to find `spec/` and `src/genos/` — the RN
    // sources they pin the ported values against.
    workingDir = projectDir

    systemProperty("file.encoding", "UTF-8")

    // `renderers registered: N/30` must reach stdout — a CI gate greps it.
    testLogging {
        showStandardStreams = true
        events("passed", "skipped", "failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        showExceptions = true
        showCauses = true
        showStackTraces = false
    }

    outputs.upToDateWhen { false }
}
