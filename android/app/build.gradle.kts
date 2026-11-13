import java.io.FileInputStream
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Aithra ships for arm64 phones only. CI also builds an x86_64 APK
// (ORG_GRADLE_PROJECT_aithraAbi=x86_64) to launch-test on an emulator,
// since GitHub's runners cannot run an arm64 one.
val appAbi = providers.gradleProperty("aithraAbi").orElse("arm64-v8a").get()

android {
    namespace = "dev.abdullah.aithra"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.abdullah.aithra"
        // SpeechRecognizer.createOnDeviceSpeechRecognizer needs API 31; the
        // on-device models Aithra runs need a 2021+ phone anyway.
        minSdk = 31
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters += listOf(appAbi)
        }
        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=c++_shared", "-DCMAKE_BUILD_TYPE=Release")
                // Flutter's Gradle plugin adds every Flutter ABI to the
                // filters; llama.cpp is built for the one shipped ABI.
                abiFilters += listOf(appAbi)
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packaging {
        jniLibs {
            // LiteRT-LM's NPU backend dlopens the dispatch library from
            // nativeLibraryDir, so native libraries must be extracted on install.
            useLegacyPackaging = true
            // Dependencies carry native libraries for every ABI.
            excludes += listOf("arm64-v8a", "x86_64", "armeabi-v7a", "x86")
                .filter { it != appAbi }
                .map { "lib/$it/**" }
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Signs with the shared Offlyne keystore when android/key.properties
            // exists; uses debug keys otherwise so local builds still work.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.19.1")
    implementation("com.google.ai.edge.litert:litert-npu-runtime-google-tensor:2.3.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("androidx.activity:activity-ktx:1.11.0")
    implementation("androidx.core:core-ktx:1.17.0")
    testImplementation("junit:junit:4.13.2")

    // integration_test pins these through the debug runtime classpath, and
    // AGP resolves the test classpath consistently with it.
    androidTestImplementation("androidx.test:runner:1.2.0")
    androidTestImplementation("androidx.test:rules:1.2.0")
    androidTestImplementation("junit:junit:4.12")
}
