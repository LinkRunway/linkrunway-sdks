plugins {
    id("com.android.application") version "8.9.3"
    kotlin("android") version "2.1.20"
}
// Placeholders, not a live workspace. Override them on the command line, for example
//   -Plinkrunway.endpoint=https://go.yourdomain.com -Plinkrunway.key=lr_pk_... -Plinkrunway.appId=...
// Passing -Plinkrunway.cloudProjectNumber=<number> also packages Play Integrity and turns attestation on.
fun setting(name: String, fallback: String) = (findProperty("linkrunway.$name") as String?) ?: fallback
val cloudProjectNumber = (findProperty("linkrunway.cloudProjectNumber") as String?)?.toLong()
android {
    namespace = "com.linkrunway.example"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.linkrunway.example"
        minSdk = 23
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        buildConfigField("String", "LINKRUNWAY_ENDPOINT", "\"${setting("endpoint", "https://go.example.com")}\"")
        buildConfigField("String", "LINKRUNWAY_KEY", "\"${setting("key", "lr_pk_your_key")}\"")
        buildConfigField("String", "LINKRUNWAY_APP_ID", "\"${setting("appId", "your_app_id")}\"")
        buildConfigField("long", "CLOUD_PROJECT_NUMBER", "${cloudProjectNumber ?: 0}L")
    }
    buildFeatures { buildConfig = true }
    buildTypes {
        release {
            // Shrinking is on to show that the SDK needs no keep rules, with or without Play Integrity.
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            // The debug key keeps the sample installable. Sign a real app with your own key.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    implementation("com.linkrunway:linkrunway-android")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    if (cloudProjectNumber != null) implementation("com.google.android.play:integrity:1.6.0")
}
