plugins {
    id("com.android.library") version "8.9.3"
    kotlin("android") version "2.1.20"
    `maven-publish`
}
// With rootProject.name this is the coordinate an app's includeBuild substitutes: com.linkrunway:linkrunway-android.
// JitPack sets GROUP and VERSION when it builds a release tag of the public SDK repository.
group = System.getenv("GROUP") ?: "com.linkrunway"
version = System.getenv("VERSION") ?: "0.2.1"
android {
    namespace = "com.linkrunway.sdk"
    compileSdk = 35
    defaultConfig {
        minSdk = 23
        consumerProguardFiles("consumer-rules.pro")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    // Robolectric reads the merged manifest and resources through this.
    testOptions { unitTests { isIncludeAndroidResources = true } }
    // The loopback HTTP server serves both the JVM tests and the on-device smoke test.
    sourceSets {
        getByName("test").java.srcDir("src/sharedTest/java")
        getByName("androidTest").java.srcDir("src/sharedTest/java")
    }
    publishing { singleVariant("release") { withSourcesJar() } }
}
afterEvaluate {
    publishing {
        publications {
            register<MavenPublication>("release") {
                from(components["release"])
                artifactId = "linkrunway-android"
                pom {
                    name.set("LinkRunway for Android")
                    description.set("Consent-gated LinkRunway client: App Links, install referrer matching and events.")
                    url.set("https://github.com/LinkRunway/linkrunway-sdks")
                    licenses { license { name.set("MIT"); url.set("https://opensource.org/license/mit") } }
                }
            }
        }
    }
}
dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("com.android.installreferrer:installreferrer:2.2")
    // Only PlayIntegrityAttestation uses Play Integrity. Apps that want it add the dependency themselves.
    compileOnly("com.google.android.play:integrity:1.6.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    testImplementation("com.google.android.play:integrity:1.6.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("com.google.android.play:integrity:1.6.0")
}
// A failing test prints its assertion message and stack; Gradle's default prints only the class
// and line, which left an intermittent CI failure undiagnosable.
tasks.withType<Test>().configureEach {
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
