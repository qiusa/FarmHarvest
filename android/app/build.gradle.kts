plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val releaseStoreFile = providers.gradleProperty("FARMHARVEST_STORE_FILE").orNull
val releaseStorePassword = providers.gradleProperty("FARMHARVEST_STORE_PASSWORD").orNull
val releaseKeyAlias = providers.gradleProperty("FARMHARVEST_KEY_ALIAS").orNull
val releaseKeyPassword = providers.gradleProperty("FARMHARVEST_KEY_PASSWORD").orNull
val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "com.yixin.farmharvest.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.yixin.farmharvest.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.create("release").apply {
                    storeFile = rootProject.file(releaseStoreFile!!)
                    storePassword = releaseStorePassword
                    keyAlias = releaseKeyAlias
                    keyPassword = releaseKeyPassword
                }
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    buildFeatures {
        compose = true
    }

    lint {
        // compose-runtime 1.7.3 自带的 lint 检查引用了 AGP 8.7.3 lint 运行时里不存在的
        // IntelliJ PSI/K2 分析类，fresh 分析必崩（NoClassDefFoundError）。升级 AGP 前整组禁用。
        disable += setOf(
            "AutoboxingStateCreation",
            "AutoboxingStateValueProperty",
            "ComposableLambdaParameterNaming",
            "ComposableLambdaParameterPosition",
            "ComposableNaming",
            "CompositionLocalNaming",
            "CoroutineCreationDuringComposition",
            "FlowOperatorInvokedInComposition",
            "MutableCollectionMutableState",
            "OpaqueUnitKey",
            "ProduceStateDoesNotAssignValue",
            "RememberReturnType",
            "StateFlowValueCalledInComposition",
            "UnrememberedMutableState",
        )
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.09.03")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3:1.3.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    // 记录列表长按拖动排序；2.4.x 对应 compose 1.7（BOM 2024.09.03）
    implementation("sh.calvin.reorderable:reorderable:2.4.3")

    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
