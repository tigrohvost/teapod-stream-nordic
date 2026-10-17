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

    }

    packaging {
        jniLibs {
            // x86 is not supported by teapod-core
            excludes.add("lib/x86/**")
            // teapod-core ships libgojni.so already stripped; AGP's re-strip still
            // rewrites the ELF header, so the APK would no longer carry the bytes
            // pinned in dependencies.lock.json (verify_release_apks.py compares them).
            keepDebugSymbols.add("**/libgojni.so")
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
    // android.jar only stubs org.json; unit tests of the native stores need the real one.
    testImplementation("org.json:json:20240303")
}

flutter {
    source = "../.."
}
