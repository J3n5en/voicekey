import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// CI 推 tag 时经 -PvkVersionCode / -PvkVersionName 传入；本地构建不传则用下面的默认值
val vkCode = providers.gradleProperty("vkVersionCode").orNull?.toInt() ?: 7
val vkName = providers.gradleProperty("vkVersionName").orNull ?: "0.5.1"
val vkRequireSigning = providers.gradleProperty("vkRequireSigning").orNull == "true"

android {
    namespace = "j3.voicekey"
    compileSdk = 36
    ndkVersion = "27.1.12297006"

    defaultConfig {
        applicationId = "do.j3.voicekey"
        minSdk = 26
        targetSdk = 36
        versionCode = vkCode
        versionName = vkName
        ndk { abiFilters += "arm64-v8a" }
    }

    val ks = rootProject.file("keystore.properties").takeIf { it.exists() }?.let { f ->
        Properties().apply { f.inputStream().use { load(it) } }
    }
    if (vkRequireSigning && ks == null) throw GradleException("vkRequireSigning=true 但缺少 keystore.properties，拒绝用 debug 签名出包")
    signingConfigs {
        if (ks != null) create("release") {
            storeFile = rootProject.file(ks.getProperty("storeFile"))
            storePassword = ks.getProperty("storePassword")
            keyAlias = ks.getProperty("keyAlias")
            keyPassword = ks.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName(if (ks != null) "release" else "debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }
    packaging { jniLibs { useLegacyPackaging = false } }
}

kotlin { jvmToolchain(17) }

dependencies {
    val bom = platform("androidx.compose:compose-bom:2025.10.01")
    implementation(bom)
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    testImplementation("junit:junit:4.13.2")
}
