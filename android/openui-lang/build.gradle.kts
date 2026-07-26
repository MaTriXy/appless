plugins {
    kotlin("jvm")
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()

    // The fixture oracle walks up from this directory to find `spec/fixtures`.
    workingDir = projectDir

    // Everything in this build reads/writes UTF-8; the oracle compares UTF-8
    // bytes against the generated expected trees.
    systemProperty("file.encoding", "UTF-8")

    // `fixtures exercised: NN` must reach stdout — a CI gate greps that literal.
    testLogging {
        showStandardStreams = true
        events("passed", "skipped", "failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        showExceptions = true
        showCauses = true
        showStackTraces = false
    }

    // Never let Gradle's up-to-date check hide the oracle output.
    outputs.upToDateWhen { false }
}

// Differential-fuzz driver (build-only tooling, not part of `test`).
// Replays a campaign from spec/fixtures/generator/probes/gen-fuzz-corpus.mjs:
//   ./gradlew :openui-lang:fuzzDriver -PfuzzCampaign=<file> [-PfuzzOut=<file>]
// See spec/fixtures/generator/probes/README.md.
tasks.register<JavaExec>("fuzzDriver") {
    group = "verification"
    description = "Replays a differential-fuzz campaign through the Kotlin port."
    mainClass.set("dev.appless.openuilang.fuzz.FuzzDriverKt")
    classpath = sourceSets["main"].runtimeClasspath
    // Deeply nested fuzz inputs recurse in the expression parser.
    jvmArgs("-Dfile.encoding=UTF-8", "-Xss16m")
    workingDir = rootProject.projectDir.parentFile ?: projectDir
    argumentProviders.add {
        val campaign = providers.gradleProperty("fuzzCampaign").orNull
            ?: throw GradleException("fuzzDriver requires -PfuzzCampaign=<campaign.json>")
        buildList {
            add(campaign)
            providers.gradleProperty("fuzzOut").orNull?.let { add("--out"); add(it) }
            providers.gradleProperty("fuzzSchema").orNull?.let { add("--schema"); add(it) }
        }
    }
}
