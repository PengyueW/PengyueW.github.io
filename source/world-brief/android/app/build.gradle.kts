plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.worldbrief.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.worldbrief.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"
        resourceConfigurations += listOf("en")
    }

    buildFeatures {
        viewBinding = true
    }

    signingConfigs {
        // A release build is signed with the keystore named by these environment variables, and
        // falls back to the debug key when they are absent so a local build still produces an APK.
        create("release") {
            val store = System.getenv("WORLDBRIEF_KEYSTORE")
            if (store != null && file(store).exists()) {
                storeFile = file(store)
                storePassword = System.getenv("WORLDBRIEF_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("WORLDBRIEF_KEY_ALIAS") ?: "worldbrief"
                keyPassword = System.getenv("WORLDBRIEF_KEY_PASSWORD")
                    ?: System.getenv("WORLDBRIEF_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = if (System.getenv("WORLDBRIEF_KEYSTORE") != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    packaging {
        resources.excludes += setOf("META-INF/*.version", "kotlin/**", "DebugProbesKt.bin")
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.swiperefreshlayout:swiperefreshlayout:1.1.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
