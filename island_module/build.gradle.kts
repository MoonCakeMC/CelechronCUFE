// 根工程只声明插件版本，不在这里应用插件。
plugins {
    // 与主工程保持一致的 Android Gradle Plugin 版本。
    id("com.android.application") version "8.13.2" apply false
    // 与主工程保持一致的 Kotlin 版本。
    id("org.jetbrains.kotlin.android") version "2.2.0" apply false
}
