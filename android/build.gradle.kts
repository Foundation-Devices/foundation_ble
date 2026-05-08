import java.util.Properties

group = "xyz.foundation.ble.foundation_ble"
version = "1.0-SNAPSHOT"

val localProperties = Properties().apply {
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.exists()) {
        localPropertiesFile.inputStream().use(::load)
    }
}

val flutterSdkPath =
    localProperties.getProperty("flutter.sdk")
        ?: System.getenv("FLUTTER_ROOT")

val flutterJar =
    flutterSdkPath
        ?.let { sdkPath ->
            listOf(
                "android-arm/flutter.jar",
                "android-arm64/flutter.jar",
                "android-x64/flutter.jar",
                "android-x86/flutter.jar",
            )
                .asSequence()
                .map { "$sdkPath/bin/cache/artifacts/engine/$it" }
                .map(::file)
                .firstOrNull { it.exists() }
        }

buildscript {
    val kotlinVersion = "2.0.21"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.7.3")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "xyz.foundation.ble.foundation_ble"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

dependencies {
    flutterJar?.let {
        compileOnly(files(it))
    }

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
