// 插件仓库配置：沿用主工程的 AGP 与 Kotlin 版本来源。
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// 依赖仓库配置：编译期依赖由官方仓库提供。
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven("https://api.xposed.info/")
    }
}

// 模块工程名，与主工程完全隔离。
rootProject.name = "CelechronIslandModule"

// 只包含一个模块应用。
include(":app")
