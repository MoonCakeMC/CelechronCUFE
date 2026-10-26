# 保留模块入口类，确保 assets/xposed_init 中的类名不会被 R8 重命名或移除。
-keep class xyz.nosig.celechron.island.CoreEntry { *; }

# Xposed API 仅在编译期提供，运行时由模块加载器注入，忽略缺失类警告。
-dontwarn de.robv.android.xposed.**

# 把其余内部类重打包到无意义包名，减少可识别的包名信息。
-repackageclasses 'a'
