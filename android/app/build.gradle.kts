import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing config lives in android/key.properties (gitignored).
// See https://flutter.dev/to/reference-keystore for the expected keys.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.teapodstream.teapodstream"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    defaultConfig {
        applicationId = "com.teapodstream.teapodstream"
        minSdk = 29  // Required by teapod-tun2socks AAR (getConnectionOwnerUid)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // teapod-core no longer ships a 32-bit runtime. Restrict native builds
        // as well as Flutter target platforms, including local APK/AAB builds.
        // Android rejects ndk.abiFilters combined with Flutter ABI splits.
        // Split builds already receive the explicit 64-bit --target-platform.
        if (project.findProperty("split-per-abi") != "true") {
            ndk {
                abiFilters.clear()
                abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
            }
        }

    }

    packaging {
        jniLibs {
            // Neither 32-bit architecture is supported by teapod-core
            excludes.add("lib/x86/**")
            excludes.add("lib/armeabi-v7a/**")
        }
    }

    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        if (keystoreProperties.isNotEmpty()) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Sign with the release keystore from key.properties when present;
            // fall back to debug keys so `flutter run --release` still works
            // on machines without the keystore.
            signingConfig = if (keystoreProperties.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

dependencies {
    implementation(files("libs/teapod-core.aar"))
    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
