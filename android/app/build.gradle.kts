plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.absenmusam"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    configurations.all {
        resolutionStrategy {
            force("androidx.browser:browser:1.8.0")
            force("androidx.activity:activity:1.8.0")
            force("androidx.activity:activity-ktx:1.8.0")
            force("androidx.core:core:1.13.1")
            force("androidx.core:core-ktx:1.13.1")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        }
    }

    defaultConfig {
        applicationId = "com.example.absenmusam"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // Catatan: Blok rename manual di-comment agar Flutter CLI secara otomatis
    // memberi nama file sesuai arsitektur (app-arm64-v8a-release.apk, dll) tanpa error/menimpa.
    /*
    applicationVariants.all {
        if (buildType.name == "release") {
            outputs.all {
                (this as? com.android.build.gradle.api.ApkVariantOutput)?.let { output ->
                    val abi = output.filters.find { it.filterType.name == "ABI" }?.identifier
                    output.outputFileName = if (abi != null) {
                        "AbsensiMassal-$abi.apk"
                    } else {
                        "AbsensiMassal.apk"
                    }
                }
            }
        }
    }
    */

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("libs")
        }
    }
}

tasks.whenTaskAdded {
    if (name == "checkDebugAarMetadata") {
        enabled = false
    }
}

dependencies {
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.jar"))))
    
    constraints {
        implementation("androidx.browser:browser:1.8.0") {
            because("Force older version for compatibility")
        }
        implementation("androidx.activity:activity:1.8.0") {
            because("Force older version for compatibility")
        }
        implementation("androidx.activity:activity-ktx:1.8.0") {
            because("Force older version for compatibility")
        }
        implementation("androidx.core:core:1.13.1") {
            because("Force older version for compatibility")
        }
        implementation("androidx.core:core-ktx:1.13.1") {
            because("Force older version for compatibility")
        }
    }
}

flutter {
    source = "../.."
}
