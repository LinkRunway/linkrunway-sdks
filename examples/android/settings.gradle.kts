pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "linkrunway-android-example"
// The SDK is built from its sources; com.linkrunway:linkrunway-android resolves to this build.
includeBuild("../../android")
include(":app")
