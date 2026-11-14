plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.github.moriri.hibivo"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.github.moriri.hibivo"
        minSdk = 28
        // 34 rather than 35: targeting 35 forces edge-to-edge on every window, the keyboard's included.
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    lint {
        // Shipped outside Google Play, so its target API requirement doesn't apply.
        disable += "ExpiredTargetSdkVersion"
        disable += "OldTargetApi"
        // Versions are raised deliberately, not whenever a newer one exists.
        disable += "GradleDependency"
        // The logo is full colour by design; a themed (monochrome) icon would need separate artwork.
        disable += "MonochromeLauncherIcon"
        warningsAsErrors = true
        abortOnError = true
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    // The logo has one source, shared with the macOS app; see `copyLogo` below.
    sourceSets["main"].res.srcDir(layout.buildDirectory.dir("generated/logo/res"))
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

// The launcher icon is drawn from the macOS app's icon source rather than a second copy of it.
val copyLogo by tasks.registering(Copy::class) {
    from(rootProject.file("../Resources/AppIconSource.png"))
    into(layout.buildDirectory.dir("generated/logo/res/drawable-nodpi"))
    rename { "hibivo_logo.png" }
}
tasks.named("preBuild") { dependsOn(copyLogo) }

dependencies {
    implementation(project(":core"))
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.preference:preference-ktx:1.2.1")
    implementation("com.google.android.material:material:1.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.test:core:1.6.1")
}
