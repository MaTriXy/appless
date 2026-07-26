// `genos-core` is the Android analog of the converged Swift `GenOSCore`
// package (ios/Packages/GenOSCore): the app's core layer — SSE streaming +
// tool loop, screen store, navigation/prefetch controller, BYOK key gate,
// the §11 pure helpers, the Exa/Unsplash tools and telemetry.
//
// Like `openui-lang` it is deliberately a PURE Kotlin/JVM library with NO
// Android dependency, so the whole behavioral suite runs headlessly on any
// JDK 21 — exactly like the Swift sibling runs under `swift test`. Every
// platform seam (networking, key persistence, time/scheduling) is an
// interface; the Android app supplies OkHttp/Keystore/Handler implementations
// and consumes the Flow/StateFlow surface from Compose.
plugins {
    kotlin("jvm")
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        // The port must stay warning-clean; the phase gate greps for warnings.
        allWarningsAsErrors.set(true)
    }
}

dependencies {
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")

    testImplementation(kotlin("test"))
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()

    // The scenario counter walks up from this directory to find the sources.
    workingDir = projectDir

    systemProperty("file.encoding", "UTF-8")

    // `core scenarios: NN` must reach stdout — a CI gate greps that literal.
    testLogging {
        showStandardStreams = true
        events("passed", "skipped", "failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        showExceptions = true
        showCauses = true
        showStackTraces = false
    }

    // Never let Gradle's up-to-date check hide the scenario-count output.
    outputs.upToDateWhen { false }
}
