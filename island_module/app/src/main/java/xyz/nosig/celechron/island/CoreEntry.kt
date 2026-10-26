package xyz.nosig.celechron.island

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage
import java.lang.reflect.Field
import java.lang.reflect.Method
import java.lang.reflect.Modifier

/**
 * 模块入口：只处理 SystemUI 主进程、SystemUI 插件进程与小米服务框架 XMSF。
 *
 * 入口类使用中性名称，避免类名中出现可识别的模块关键字。
 *
 * 参考 HyperCeiler 与 HyperIsland 的实现：
 * 1. 放行焦点通知与自定义焦点通知；
 * 2. 只对 Celechron 放开焦点状态白名单；
 * 3. HyperOS 3 将 AuthManager 的认证结果改成成功；
 * 4. 放行焦点通知签名检查；
 * 5. XMSF AuthSession 认证失败时强制返回成功。
 */
class CoreEntry : IXposedHookLoadPackage {

    companion object {
        // 日志标签，便于 adb logcat 过滤。
        private const val TAG = "CelechronNotify"

        // 只放行 Celechron 主包。
        private const val TARGET_PACKAGE = "xyz.nosig.celechron"

        // 模块需要加载的目标进程。
        private val HOST_PACKAGES = setOf(
            "com.android.systemui",
            "miui.systemui.plugin",
            "com.xiaomi.xmsf"
        )

        // 宿主 APK 中的通知设置管理器。
        private const val HOST_SETTINGS_CLASS =
            "com.miui.systemui.notification.NotificationSettingsManager"

        // 插件 APK 中的通知设置管理器。
        private const val PLUGIN_SETTINGS_CLASS =
            "miui.systemui.notification.NotificationSettingsManager"

        // 插件 APK 中的焦点通知签名检查器。
        private const val SIGNATURE_CHECKER_CLASS =
            "miui.systemui.notification.focus.SignatureChecker"

        // SystemUI 插件工厂内部类，用于拿到插件 ClassLoader。
        private const val PLUGIN_FACTORY_CLASS =
            "com.android.systemui.shared.plugins.PluginInstance\$PluginFactory"

        // HyperOS 3 的认证回调内部类。
        private val AUTH_CLASS_NAMES = arrayOf(
            "miui.systemui.notification.auth.AuthManager\$AuthServiceCallback\$onAuthResult\$1",
            "com.miui.systemui.notification.auth.AuthManager\$AuthServiceCallback\$onAuthResult\$1",
            "miui.systemui.notification.auth.AuthManager\$LowVersionAuthServiceCallback\$onAuthResult\$1",
            "com.miui.systemui.notification.auth.AuthManager\$LowVersionAuthServiceCallback\$onAuthResult\$1"
        )

        // XMSF 的认证会话类。
        private const val XMSF_AUTH_SESSION_CLASS = "com.xiaomi.xms.auth.AuthSession"

        // 已 hook 的方法，避免延迟重试时重复注册。
        private val hookedMethods = mutableSetOf<String>()
    }

    override fun handleLoadPackage(lpparam: XC_LoadPackage.LoadPackageParam) {
        // 不在目标进程时不执行任何逻辑。
        if (lpparam.packageName !in HOST_PACKAGES) return

        log("loaded in ${lpparam.packageName}, process=${lpparam.processName}")

        // 立即尝试一次，类已经加载时马上生效。
        if (lpparam.packageName == "com.xiaomi.xmsf") {
            tryHookXmsf(lpparam.classLoader)
        } else {
            tryHook(lpparam.classLoader)
        }

        // HyperOS 的 SystemUI 插件类可能延迟加载，做多次重试。
        val handler = Handler(Looper.getMainLooper())
        for (delay in longArrayOf(2_000L, 6_000L, 15_000L, 30_000L)) {
            handler.postDelayed({
                if (lpparam.packageName == "com.xiaomi.xmsf") {
                    tryHookXmsf(lpparam.classLoader)
                } else {
                    tryHook(lpparam.classLoader)
                }
            }, delay)
        }
    }

    /**
     * 尝试 hook SystemUI 的宿主类、插件类和认证类。
     */
    private fun tryHook(classLoader: ClassLoader) {
        hookNotificationSettings(classLoader)
        hookAuthManager(classLoader)
        hookSignatureChecker(classLoader)
        hookPluginFactory(classLoader)
        hookPluginClasses(classLoader)
    }

    /**
     * hook 宿主 APK 中的 NotificationSettingsManager。
     */
    private fun hookNotificationSettings(classLoader: ClassLoader) {
        // 宿主类只处理 com.miui 前缀；插件类由 hookPluginClasses 处理。
        val clazz = findClassByName(HOST_SETTINGS_CLASS, classLoader) ?: return

        // canShowFocus / canCustomFocus：允许焦点通知与自定义焦点通知。
        // 如果方法参数中带有其他应用包名，则不干预，避免影响别的应用。
        hookMethodOnce(clazz, "canShowFocus") { param ->
            val packageArg = findPackageArgument(param.args)
            if (packageArg != null && packageArg != TARGET_PACKAGE) return@hookMethodOnce
            setAllowResult(param)
        }
        hookMethodOnce(clazz, "canCustomFocus") { param ->
            val packageArg = findPackageArgument(param.args)
            if (packageArg != null && packageArg != TARGET_PACKAGE) return@hookMethodOnce
            setAllowResult(param)
        }

        // 旧版本兼容：HyperOS 2 等版本可能存在这两个方法。
        hookStateMethod(clazz, "canShowFocusState")
        hookStateMethod(clazz, "canShowFocusStateApp")
    }

    /**
     * 兼容旧版本的焦点状态白名单：只对 Celechron 返回允许。
     */
    private fun hookStateMethod(clazz: Class<*>, methodName: String) {
        hookMethodOnce(clazz, methodName) { param ->
            if (findPackageArgument(param.args) != TARGET_PACKAGE) return@hookMethodOnce
            setAllowResult(param)
        }
    }

    /**
     * hook 插件 APK 中的焦点通知相关类。
     *
     * 插件类可能由主进程动态加载，也可能运行在 miui.systemui.plugin 进程。
     * 这里直接使用传入的 ClassLoader 尝试加载，失败时只记录 debug 日志。
     */
    private fun hookPluginClasses(classLoader: ClassLoader) {
        // 焦点通知白名单与自定义焦点通知。
        runCatching {
            val clazz = classLoader.loadClass(PLUGIN_SETTINGS_CLASS)
            hookBooleanMethod(clazz, "canShowFocus")
            hookBooleanMethod(clazz, "canCustomFocus")
            log("hooked plugin ${PLUGIN_SETTINGS_CLASS}")
        }.onFailure {
            logDebug("plugin settings class not available: ${it.message}")
        }

        // 焦点通知签名检查。
        hookSignatureChecker(classLoader)

        // 认证回调。
        hookAuthManager(classLoader)
    }

    /**
     * hook 焦点通知签名检查器。
     *
     * HyperIsland 的 UnlockAllFocusHook 会放行
     * miui.systemui.notification.focus.SignatureChecker#checkSignatures。
     */
    private fun hookSignatureChecker(classLoader: ClassLoader) {
        runCatching {
            val clazz = classLoader.loadClass(SIGNATURE_CHECKER_CLASS)
            hookBooleanMethod(clazz, "checkSignatures")
            log("hooked plugin ${SIGNATURE_CHECKER_CLASS}#checkSignatures")
        }.onFailure {
            logDebug("signature checker not available: ${it.message}")
        }
    }

    /**
     * hook SystemUI 插件工厂，拿到插件 ClassLoader 后再次 hook 焦点通知类。
     */
    private fun hookPluginFactory(classLoader: ClassLoader) {
        val factoryClass = findClassByName(PLUGIN_FACTORY_CLASS, classLoader) ?: run {
            logDebug("plugin factory not found")
            return
        }

        hookMethodOnce(factoryClass, "createPluginContext") { param ->
            val context = param.result as? Context ?: return@hookMethodOnce
            log("plugin context ready: ${context.packageName}")
            hookPluginClasses(context.classLoader)
        }
        log("waiting for plugin context via ${PLUGIN_FACTORY_CLASS}")
    }

    /**
     * HyperOS 3 的焦点通知认证回调。
     *
     * 在 invokeSuspend 执行前把 $authBundle 中的 result_code 改为 0，
     * 等同于告诉系统认证成功，从而不需要 App 端临时屏蔽 XMSF 网络。
     */
    private fun hookAuthManager(classLoader: ClassLoader) {
        for (className in AUTH_CLASS_NAMES) {
            val clazz = findClassByName(className, classLoader) ?: continue
            // 必须在 invokeSuspend 执行前修改结果，执行后再改已经来不及。
            hookMethodOnce(clazz, "invokeSuspend", runBefore = true) { param ->
                try {
                    // 读取协程回调对象中的认证结果 Bundle。
                    val bundle = XposedHelpers.getObjectField(
                        param.thisObject,
                        "\$authBundle"
                    ) as? Bundle ?: return@hookMethodOnce

                    // 输出原始结果，方便真机排查不同 HyperOS 版本的字段差异。
                    log("auth bundle keys=${bundle.keySet()} result_code=${bundle.getInt("result_code", Int.MIN_VALUE)}")

                    // 把认证结果改成 0（成功）。
                    bundle.putInt("result_code", 0)
                } catch (throwable: Throwable) {
                    // 认证结构和预期不符时只记录日志，不阻断系统流程。
                    log("auth hook failed: ${throwable.message}")
                }
            }
        }
    }

    /**
     * hook XMSF 的 AuthSession 认证失败回调。
     *
     * 参考 HyperCeiler 的 UnlockFoucsAuth 与 HyperIsland 的 UnlockFocusAuthHook：
     * - 查找 AuthSession 中接收 AuthError、返回 Bundle 的方法；
     * - 将 AuthError 的 int 错误码置 0；
     * - 返回 getAuthSuccess()/h() 的成功 Bundle，跳过原失败流程。
     */
    private fun tryHookXmsf(classLoader: ClassLoader) {
        val clazz = findClassByName(XMSF_AUTH_SESSION_CLASS, classLoader) ?: return

        // 兼容未混淆与混淆后的方法名，最后按方法签名兜底。
        val errorMethod = clazz.declaredMethods.firstOrNull {
            it.name == "getAuthError" && it.parameterCount == 1 && it.returnType == Bundle::class.java
        } ?: clazz.declaredMethods.firstOrNull {
            it.name == "b" && it.parameterCount == 1 && it.returnType == Bundle::class.java
        } ?: clazz.declaredMethods.firstOrNull {
            it.parameterCount == 1 && it.returnType == Bundle::class.java
        }

        val successMethod = clazz.declaredMethods.firstOrNull {
            it.name == "getAuthSuccess" && it.parameterCount == 0 && it.returnType == Bundle::class.java
        } ?: clazz.declaredMethods.firstOrNull {
            it.name == "h" && it.parameterCount == 0 && it.returnType == Bundle::class.java
        } ?: clazz.declaredMethods.firstOrNull {
            it.parameterCount == 0 && it.returnType == Bundle::class.java
        }

        if (errorMethod == null) {
            log("xmsf AuthSession error method not found")
            return
        }

        val key = hookKey(clazz, "${errorMethod.name}#xmsf")
        synchronized(hookedMethods) {
            if (key in hookedMethods) return
            XposedBridge.hookMethod(errorMethod, object : XC_MethodHook() {
                override fun beforeHookedMethod(param: MethodHookParam) {
                    try {
                        // error 为 null 表示认证可能已经成功，保持原流程。
                        val error = param.args.getOrNull(0) ?: return

                        // 找到 AuthError 中的 int 错误码字段并置 0。
                        val field = findErrorIntField(error) ?: run {
                            log("xmsf AuthError int field not found")
                            return
                        }
                        val original = field.getInt(error)
                        field.setInt(error, 0)
                        log("xmsf auth error ${field.name}=$original -> 0")

                        // 返回成功 Bundle，跳过原失败流程。
                        if (successMethod != null) {
                            successMethod.isAccessible = true
                            val result = successMethod.invoke(param.thisObject)
                            if (result is Bundle) {
                                param.result = result
                                log("xmsf auth bypassed via ${successMethod.name}")
                            }
                        }
                    } catch (throwable: Throwable) {
                        log("xmsf auth hook failed: ${throwable.message}")
                    }
                }
            })
            hookedMethods.add(key)
            log("hooked ${clazz.name}#${errorMethod.name} (xmsf)")
        }
    }

    /**
     * 从 AuthError 对象中找到 int 错误码字段。
     *
     * 优先使用混淆后的 a、errorCode、code，找不到时退化为第一个非静态 int 字段。
     */
    private fun findErrorIntField(instance: Any): Field? {
        var clazz: Class<*>? = instance.javaClass
        while (clazz != null) {
            val preferred = clazz.declaredFields.firstOrNull {
                it.type == Int::class.javaPrimitiveType &&
                    !Modifier.isStatic(it.modifiers) &&
                    (it.name == "a" || it.name == "errorCode" || it.name == "code")
            }
            if (preferred != null) {
                preferred.isAccessible = true
                return preferred
            }
            clazz = clazz.superclass
        }

        clazz = instance.javaClass
        while (clazz != null) {
            val fallback = clazz.declaredFields.firstOrNull {
                it.type == Int::class.javaPrimitiveType && !Modifier.isStatic(it.modifiers)
            }
            if (fallback != null) {
                fallback.isAccessible = true
                return fallback
            }
            clazz = clazz.superclass
        }
        return null
    }

    /**
     * 只 hook 返回 boolean 的方法，并让其返回 true。
     */
    private fun hookBooleanMethod(clazz: Class<*>, methodName: String) {
        val key = hookKey(clazz, "$methodName#boolean")
        synchronized(hookedMethods) {
            if (key in hookedMethods) return

            val unhooks = XposedBridge.hookAllMethods(
                clazz,
                methodName,
                object : XC_MethodHook() {
                    override fun afterHookedMethod(param: MethodHookParam) {
                        val method = param.method as? Method ?: return
                        if (method.returnType == Boolean::class.javaPrimitiveType ||
                            method.returnType == java.lang.Boolean::class.java
                        ) {
                            param.result = true
                        }
                    }
                }
            )

            if (unhooks.isNotEmpty()) {
                hookedMethods.add(key)
                log("hooked $key, count=${unhooks.size}")
            }
        }
    }

    /**
     * 只注册一次指定方法名的 hook。
     *
     * @param clazz 目标类
     * @param methodName 目标方法名
     * @param runBefore 是否在方法执行前处理
     * @param action 命中方法后的处理逻辑
     */
    private fun hookMethodOnce(
        clazz: Class<*>,
        methodName: String,
        runBefore: Boolean = false,
        action: (XC_MethodHook.MethodHookParam) -> Unit
    ) {
        // 用“类名@ClassLoader#方法名”作为去重键，避免同名类不同 ClassLoader 冲突。
        val key = hookKey(clazz, methodName)
        synchronized(hookedMethods) {
            if (key in hookedMethods) return

            val unhooks = XposedBridge.hookAllMethods(
                clazz,
                methodName,
                object : XC_MethodHook() {
                    override fun beforeHookedMethod(param: MethodHookParam) {
                        // AuthManager 需要在方法执行前修改认证 Bundle。
                        if (runBefore) action(param)
                    }

                    override fun afterHookedMethod(param: MethodHookParam) {
                        // 焦点通知判定需要在方法执行后改写返回值。
                        if (!runBefore) action(param)
                    }
                }
            )

            // 只有真正找到方法才记录，否则等待下次延迟重试。
            if (unhooks.isNotEmpty()) {
                hookedMethods.add(key)
                log("hooked $key, count=${unhooks.size}")
            }
        }
    }

    /**
     * 生成 hook 去重键，包含 ClassLoader 身份。
     */
    private fun hookKey(clazz: Class<*>, methodName: String): String {
        return "${clazz.name}@${System.identityHashCode(clazz.classLoader)}#$methodName"
    }

    /**
     * 根据原方法返回类型设置“允许”的返回值。
     */
    private fun setAllowResult(param: XC_MethodHook.MethodHookParam) {
        val returnType = (param.method as? Method)?.returnType
        param.result = when (returnType) {
            // 返回 boolean 的方法返回 true。
            Boolean::class.javaPrimitiveType, java.lang.Boolean::class.java -> true
            // 返回 int 的方法返回 1（HyperCeiler 的 canShowFocusState 即如此）。
            Int::class.javaPrimitiveType, java.lang.Integer::class.java -> 1
            // 其他未知类型也返回 true，交给系统按布尔值处理。
            else -> true
        }
    }

    /**
     * 从参数中找出包名。
     *
     * 只做宽松判断：包含点、无空格、长度合理，避免把普通文本当成包名。
     */
    private fun findPackageArgument(args: Array<Any?>?): String? {
        if (args == null) return null
        for (arg in args) {
            if (arg is String && arg.contains('.') && arg.length < 200 && !arg.contains(' ')) {
                return arg
            }
        }
        return null
    }

    /**
     * 按类名查找类，找不到时返回 null。
     */
    private fun findClassByName(name: String, classLoader: ClassLoader): Class<*>? {
        return try {
            XposedHelpers.findClass(name, classLoader)
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * 同时写入 logcat 与模块日志。
     */
    private fun log(message: String) {
        Log.i(TAG, message)
        XposedBridge.log("[$TAG] $message")
    }

    /**
     * 写入 logcat 调试日志，不写入 LSPosed 持久日志，避免刷屏。
     */
    private fun logDebug(message: String) {
        Log.d(TAG, message)
    }
}
