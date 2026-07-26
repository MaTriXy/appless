// `:app` — the Compose Material 3 layer and the Android half of every seam the
// pure modules deliberately left abstract.
//
// The three modules below are Android-free by design (`:openui-lang` parses,
// `:genos-core` streams/stores, `:ui-core` holds the tokens + platform-
// independent renderer logic). Everything that needs a device — Compose UI,
// Keystore-backed key storage, OkHttp networking, WebView maps, Coil images —
// lives here and NOWHERE else.
plugins {
    // Versions are pinned in the ROOT build file (see the comment there) so AGP
    // and the Kotlin plugin share one classloader.
    id("com.android.application")
    kotlin("android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "dev.appless.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.appless.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"

        // AppLess is BYOK: there is no key in the build. These exist so a
        // developer can inject one locally (`-PapplessCerebrasKey=…`) exactly
        // like the RN app's `EXPO_PUBLIC_*` env override.
        buildConfigField(
            "String",
            "CEREBRAS_KEY",
            "\"" + (providers.gradleProperty("applessCerebrasKey").orNull ?: "") + "\"",
        )
        buildConfigField(
            "String",
            "EXA_KEY",
            "\"" + (providers.gradleProperty("applessExaKey").orNull ?: "") + "\"",
        )
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    // The system prompt is a build artifact of `spec/prompt` (the spec-gates
    // workflow proves it is byte-identical to the shipped RN SYSTEM_PROMPT);
    // it is copied into assets rather than duplicated as a Kotlin string.
    sourceSets.getByName("main") {
        assets.srcDir(layout.buildDirectory.dir("generated/appless-assets"))
    }

    packaging {
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}")
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

kotlin {
    jvmToolchain(21)
}

/**
 * Stage `spec/prompt/system-prompt.generated.txt` into the APK's assets.
 *
 * Failing loudly when the file is missing is deliberate: a silently absent
 * prompt would produce an app that streams garbage instead of screens.
 */
val stageSpecAssets by tasks.registering(Copy::class) {
    val prompt = rootProject.layout.projectDirectory.file("../spec/prompt/system-prompt.generated.txt")
    // The contract the parser validates against — the SAME file `:ui-core`'s
    // ContractSchema is generated from, so the app can never drift from it.
    val contract = rootProject.layout.projectDirectory.file("../spec/contract/genos.schema.json")
    from(prompt) { rename { "system-prompt.txt" } }
    from(contract)
    into(layout.buildDirectory.dir("generated/appless-assets"))
    doFirst {
        require(prompt.asFile.isFile) { "missing ${prompt.asFile} — run spec/prompt/build-prompt.mjs" }
        require(contract.asFile.isFile) { "missing ${contract.asFile} — run spec/contract/export-schema.mjs" }
    }
}

tasks.withType<com.android.build.gradle.tasks.MergeSourceSetFolders>().configureEach {
    dependsOn(stageSpecAssets)
}

dependencies {
    implementation(project(":openui-lang"))
    implementation(project(":genos-core"))
    implementation(project(":ui-core"))

    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    // The Material Symbols table in `ui-core`'s IconMap resolves against this
    // vector set (see MaterialSymbols.kt for the name bridge).
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")

    // Keystore-backed SecureStore.
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // HttpStreaming / HttpFetching.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // SemanticImage loading.
    implementation("io.coil-kt:coil-compose:2.7.0")

    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.withType<Test>().configureEach {
    useJUnitPlatform()
    systemProperty("file.encoding", "UTF-8")
    testLogging {
        showStandardStreams = true
        events("passed", "skipped", "failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
    outputs.upToDateWhen { false }
}
