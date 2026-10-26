// 使用 Android 应用插件，产出可被模块加载器加载的 APK。
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    // 模块包名，不使用可识别的模块关键字。
    namespace = "xyz.nosig.celechron.island"

    // HyperOS 3 对应 Android 16，直接使用 API 36 编译。
    compileSdk = 36

    defaultConfig {
        applicationId = "xyz.nosig.celechron.island"
        // HyperOS 3 设备均为 Android 12 以上，minSdk 31 足够。
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            // 原配置：isMinifyEnabled = false
            // 修改原因：启用 R8 隐藏内部类名；入口类由 proguard-rules.pro 保留。
            isMinifyEnabled = true
            // 同步压缩未使用的资源。
            isShrinkResources = true
            // 本地安装测试使用 debug 签名；正式分发时请替换为自己的签名配置。
            signingConfig = signingConfigs.getByName("debug")
            // 指定默认优化规则与模块自定义 keep 规则。
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // 经典 Xposed API 仅在编译期使用，运行时由模块加载器提供。
    compileOnly("de.robv.android.xposed:api:82")
}
