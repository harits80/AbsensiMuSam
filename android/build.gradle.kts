buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.3.21")
        classpath("com.google.gms:google-services:4.4.2")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: java.io.File = rootProject.layout.buildDirectory.asFile.orNull?.resolve("../../build") ?: error("Cannot resolve build directory")
rootProject.layout.buildDirectory.set(file(newBuildDir))

subprojects {
    val newSubprojectBuildDir = file(newBuildDir.resolve(project.name))
    project.layout.buildDirectory.set(newSubprojectBuildDir)
    
    // FORCE NDK DAN SDK VERSION UNTUK SEMUA SUBPROJECTS
    afterEvaluate {
        if (project.hasProperty("android")) {
            project.extensions.findByName("android")?.let { android ->
                try {
                    // Force NDK
                    android.javaClass.getMethod("setNdkVersion", String::class.java).invoke(android, "28.2.13676358")
                    // Force Compile SDK
                    android.javaClass.getMethod("setCompileSdkVersion", Int::class.javaPrimitiveType ?: Int::class.java).invoke(android, 36)
                    
                    // Force Target SDK via defaultConfig if it exists
                    val defaultConfig = android.javaClass.getMethod("getDefaultConfig").invoke(android)
                    defaultConfig.javaClass.getMethod("setTargetSdkVersion", Int::class.javaPrimitiveType ?: Int::class.java).invoke(defaultConfig, 36)

                    // FORCE JAVA 17 di CompileOptions (Mendukung fitur Java modern)
                    val compileOptions = android.javaClass.getMethod("getCompileOptions").invoke(android)
                    compileOptions.javaClass.getMethod("setSourceCompatibility", JavaVersion::class.java).invoke(compileOptions, JavaVersion.VERSION_17)
                    compileOptions.javaClass.getMethod("setTargetCompatibility", JavaVersion::class.java).invoke(compileOptions, JavaVersion.VERSION_17)
                } catch (e: Exception) {
                    // Ignore if method doesn't exist
                }
            }
        }
        
        // FORCE JVM TARGET 17 UNTUK SEMUA TUGAS KOMPILASI KOTLIN
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
