package xyz.nosig.celechron.island

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.TextUtils
import org.json.JSONObject
import xyz.nosig.celechron.MainActivity
import xyz.nosig.celechron.R

/**
 * 超级岛通知发布器。
 *
 * 参考 Xiaomi-SuperIsland-Playground 的 FocusTemplateV3 结构，
 * 只保留课程提醒需要的字段，避免 payload 过大。
 */
class SuperIslandPublisher(context: Context) {

    companion object {
        // 通知渠道 ID，独立于成绩/DDL 通知渠道。
        private const val CHANNEL_ID = "celechron_super_island"

        // 固定通知 ID，保证更新同一座岛。
        private const val NOTIFICATION_ID = 52001

        // 焦点通知参数 key。
        private const val FOCUS_PARAM = "miui.focus.param"
        private const val FOCUS_PICS = "miui.focus.pics"

        // 岛上使用的图片 key。
        private const val LOGO_KEY = "miui.focus.pic_island_logo"
        private const val PRIMARY_IMAGE_KEY = "miui.focus.pic_island_primary"
        private const val SECONDARY_IMAGE_KEY = "miui.focus.pic_island_secondary"

        // V3 模板的序列化类型名。
        private const val FOCUS_V3_SERIAL_NAME =
            "com.xzakota.hyper.notification.focus.FocusNotification.FocusTemplateFactory.V3"

        // 自定义业务名，避免占用官方业务。
        private const val BUSINESS_NAME = "custom_island"

        // 系统开关：焦点通知协议版本，>=3 表示支持超级岛。
        private const val FOCUS_PROTOCOL_SETTING = "notification_focus_protocol"

        // 岛标题使用的强调色（Celechron 蓝色）。
        private const val ACCENT_COLOR = "#4F6EF7"

        // 更新时不自动弹开岛。
        private const val ISLAND_UPDATE_NO_FLOAT = "miui.island.updateNoFloat"
        private const val ISLAND_FIRST_FLOAT = "miui.island.firstFloat"
        private const val MIUI_ENABLE_FLOAT = "miui.enableFloat"
    }

    // 使用 Application Context，避免持有多 Activity。
    private val appContext = context.applicationContext

    // 通知管理器，懒加载。
    private val notificationManager by lazy {
        appContext.getSystemService(NotificationManager::class.java)
    }

    /**
     * 当前设备是否支持小米焦点通知/超级岛。
     */
    fun isSupported(): Boolean {
        // 超级岛依赖 Android 12 以上的通知接口。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        // 只对小米/Redmi/POCO 设备启用。
        if (!Build.MANUFACTURER.contains("xiaomi", ignoreCase = true)) return false
        // 读取系统的焦点通知协议版本。
        val protocol = runCatching {
            Settings.System.getInt(
                appContext.contentResolver,
                FOCUS_PROTOCOL_SETTING,
                0
            )
        }.getOrDefault(0)
        return protocol >= 3
    }

    /**
     * 发布或更新超级岛。
     *
     * @return 是否成功提交给系统
     */
    fun publish(state: IslandState): Boolean {
        // 不支持时直接跳过，不影响普通通知。
        if (!isSupported()) return false

        // 通知权限未授予时不提交，避免系统丢弃后仍记录为已发布。
        if (!notificationManager.areNotificationsEnabled()) return false

        return runCatching {
            // 首次发布前创建低打扰通知渠道。
            ensureChannel()
            // 提交通知，系统会解析 miui.focus.param。
            notificationManager.notify(NOTIFICATION_ID, buildNotification(state))
            true
        }.getOrDefault(false)
    }

    /**
     * 取消当前超级岛。
     */
    fun cancel() {
        runCatching {
            notificationManager.cancel(NOTIFICATION_ID)
        }
    }

    /**
     * 创建无声、低打扰的通知渠道。
     */
    private fun ensureChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "超级岛课程提醒",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "显示正在上的课程和即将开始的课程"
            // 岛更新时不响铃、不振动。
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        notificationManager.createNotificationChannel(channel)
    }

    /**
     * 构建带焦点通知 extras 的通知。
     */
    private fun buildNotification(state: IslandState): Notification {
        // 岛图片：统一使用 Celechron 应用图标。
        val appIcon = Icon.createWithResource(appContext, R.mipmap.ic_launcher)

        // 图片 Bundle，key 与 payload 中的 picInfo 对应。
        val pics = Bundle().apply {
            putParcelable(LOGO_KEY, appIcon)
            putParcelable(PRIMARY_IMAGE_KEY, appIcon)
            putParcelable(SECONDARY_IMAGE_KEY, appIcon)
        }

        // 焦点通知 extras。
        val extras = Bundle().apply {
            putString(FOCUS_PARAM, buildFocusPayload(state))
            putBundle(FOCUS_PICS, pics)
            // 更新时不要主动浮起岛。
            putBoolean(ISLAND_UPDATE_NO_FLOAT, true)
            putBoolean(ISLAND_FIRST_FLOAT, false)
            putBoolean(MIUI_ENABLE_FLOAT, false)
        }

        // 点击岛打开 Celechron。
        val contentIntent = PendingIntent.getActivity(
            appContext,
            NOTIFICATION_ID,
            Intent(appContext, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return Notification.Builder(appContext, CHANNEL_ID)
            // 小图标用于通知栏与岛。
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(state.title)
            .setContentText(state.subtitle)
            .setSubText(state.location)
            .setContentIntent(contentIntent)
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            // 课程期间保持常驻。
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setAutoCancel(false)
            .addExtras(extras)
            .build()
    }

    /**
     * 构建 FocusTemplateV3 JSON。
     */
    private fun buildFocusPayload(state: IslandState): String {
        // 距离课程结束的毫秒数，用于设置超时。
        val remainMillis = (state.endMillis - System.currentTimeMillis()).coerceAtLeast(60_000L)

        val paramV2 = JSONObject()
            // 协议版本固定为 1。
            .put("protocol", 1)
            .put("business", BUSINESS_NAME)
            // 通知栏与 AOD 文本。
            .put("ticker", escapeHtml(state.title))
            .put("tickerPic", LOGO_KEY)
            .put("aodTitle", escapeHtml(state.title))
            .put("aodPic", LOGO_KEY)
            // 允许系统更新同一座岛。
            .put("updatable", true)
            .put("reopen", "close")
            // 不在首帧自动浮起。
            .put("enableFloat", false)
            .put("islandFirstFloat", false)
            // 通知展开后的基础信息。
            .put("baseInfo", buildBaseInfo(state))
            // 岛的大/小区域布局。
            .put("param_island", buildIslandParam(state, remainMillis))
            // 超时时间（分钟），最多 12 小时。
            .put(
                "timeout",
                (remainMillis / 60_000L).coerceIn(1L, 720L)
            )

        // 外层必须带 V3 类型名，系统据此选择解析器。
        return JSONObject()
            .put("type", FOCUS_V3_SERIAL_NAME)
            .put("param_v2", paramV2)
            .toString()
    }

    /**
     * 通知展开态的基础信息。
     */
    private fun buildBaseInfo(state: IslandState): JSONObject = JSONObject()
        // type=1 表示单行标题 + 内容。
        .put("type", 1)
        .put("title", escapeHtml(state.title))
        .put("content", escapeHtml(state.subtitle))
        // 地点作为副标题。
        .apply {
            if (state.location.isNotBlank()) {
                put("subTitle", escapeHtml(state.location))
                put("showDivider", true)
            } else {
                put("showDivider", false)
            }
        }
        .put("colorTitle", ACCENT_COLOR)
        .put("colorTitleDark", ACCENT_COLOR)

    /**
     * 岛的布局参数。
     */
    private fun buildIslandParam(state: IslandState, remainMillis: Long): JSONObject {
        val bigIslandArea = JSONObject()
            // 左侧：应用图标 + 课程名/地点。
            .put(
                "imageTextInfoLeft",
                JSONObject()
                    .put("type", 1)
                    .put("picInfo", pictureInfo(PRIMARY_IMAGE_KEY))
                    .put("textInfo", summaryText(state.title, state.location))
            )
            // 右侧：状态时间文本。
            .put(
                "textInfo",
                summaryText(state.timeText, state.shortText)
            )

        // 小岛：图标 + 简短时间。
        val smallIslandArea = JSONObject()
            .put(
                "imageTextInfoRight",
                JSONObject()
                    .put("type", 6)
                    .put("picInfo", pictureInfo(PRIMARY_IMAGE_KEY, 4))
                    .put("textInfo", summaryText(state.shortText, ""))
            )

        return JSONObject()
            // islandProperty=1 表示信息展示型岛。
            .put("islandProperty", 1)
            .put("islandOrder", false)
            .put("highlightColor", ACCENT_COLOR)
            .put("bigIslandArea", bigIslandArea)
            .put("smallIslandArea", smallIslandArea)
            // 岛自身超时（秒），与通知生命周期对齐。
            .put(
                "islandTimeout",
                (remainMillis / 1_000L).coerceIn(60L, 43_200L)
            )
    }

    /**
     * 岛上的文本块。
     */
    private fun summaryText(title: String, content: String): JSONObject = JSONObject()
        .put("title", escapeHtml(title))
        .apply {
            if (content.isNotBlank()) {
                put("content", escapeHtml(content))
            }
        }
        // 使用强调色显示标题。
        .put("showHighlightColor", true)

    /**
     * 图片引用。
     */
    private fun pictureInfo(key: String, type: Int = 1): JSONObject = JSONObject()
        .put("type", type)
        .put("pic", key)

    /**
     * 焦点通知字段需要 HTML 转义，避免特殊字符破坏解析。
     */
    private fun escapeHtml(value: String): String = TextUtils.htmlEncode(value)
}

/**
 * 岛当前要展示的状态。
 *
 * @param title 课程名
 * @param subtitle 状态描述（正在上课 / 即将开始）
 * @param timeText 右侧时间文本
 * @param location 上课地点
 * @param shortText 小岛文本
 * @param startMillis 课程开始时间
 * @param endMillis 课程结束时间
 */
data class IslandState(
    val title: String,
    val subtitle: String,
    val timeText: String,
    val location: String,
    val shortText: String,
    val startMillis: Long,
    val endMillis: Long
)
