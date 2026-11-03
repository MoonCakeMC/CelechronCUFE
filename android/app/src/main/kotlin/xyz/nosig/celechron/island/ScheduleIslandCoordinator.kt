package xyz.nosig.celechron.island

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.util.Log
import com.it_nomads.fluttersecurestorage.FlutterSecureStorage
import org.json.JSONArray
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * 课程超级岛调度器。
 *
 * 数据来自 Flutter 侧 refreshWidget() 写入的 next_schedule_list。
 * 触发时机：课程开始前 30 分钟、课程开始、课程结束。
 */
object ScheduleIslandCoordinator {

    // 日志标签，便于 adb logcat 过滤。
    private const val TAG = "CelechronIsland"

    // 课前提前显示的时间窗口：30 分钟。
    private const val UPCOMING_WINDOW_MILLIS = 30 * 60 * 1_000L

    // 上课期间刷新进度条与剩余时间的间隔：1 分钟。
    private const val PROGRESS_UPDATE_INTERVAL_MILLIS = 60 * 1_000L

    // 闹钟的固定请求码，保证只存在一个待触发的边界闹钟。
    private const val ALARM_REQUEST_CODE = 52002

    // 记录上次发布签名的偏好文件名。
    private const val PREFS_NAME = "celechron_island_state"

    // 上次发布内容签名的 key。
    private const val KEY_SIGNATURE = "last_signature"

    // 支持的日程类型：课程、考试、手动日程、DDL 规划。
    private const val TYPE_CLASSES = 0
    private const val TYPE_TEST = 1
    private const val TYPE_USER = 2
    private const val TYPE_FLOW = 4

    // 需要上岛的日程类型；排除 virtual 占位。
    private val SUPPORTED_TYPES = setOf(TYPE_CLASSES, TYPE_TEST, TYPE_USER, TYPE_FLOW)

    // 单线程执行器，避免多次刷新并发读写存储。
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "CelechronIsland").apply { isDaemon = true }
    }

    // 秒级刷新线程：仅在当前有课程/即将开始课程时运行。
    private val ticker: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "CelechronIslandTick").apply { isDaemon = true }
    }

    // 当前需要每秒刷新的课程。
    @Volatile
    private var activeCourse: Course? = null

    // 当前秒级刷新任务。
    @Volatile
    private var tickFuture: ScheduledFuture<*>? = null

    // 当前进程内最近一次发布的内容签名，避免每秒读写 SharedPreferences。
    @Volatile
    private var lastPublishedSignature: String? = null

    // 刷新锁，保证同一时刻只有一个刷新流程。
    private val lock = Any()

    /**
     * 异步刷新超级岛。
     */
    fun refresh(context: Context) {
        val appContext = context.applicationContext
        executor.execute { refreshNow(appContext) }
    }

    /**
     * 清除本地发布签名，强制下一次刷新重新发布。
     *
     * 用于开机、应用更新等通知一定已经消失的场景。
     */
    fun invalidate(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_SIGNATURE)
            .apply()
    }

    /**
     * 同步刷新超级岛，供广播接收器在后台线程调用。
     */
    fun refreshNow(context: Context) {
        val appContext = context.applicationContext

        synchronized(lock) {
            // 用同一个时间点做所有判断，避免临界时刻状态不一致。
            val now = System.currentTimeMillis()

            // 读取课程列表。
            val courses = loadCourses(appContext)
            Log.d(TAG, "refreshNow: courses=${courses.size}")

            // 正在上的课：开始时间已到且尚未结束。
            val ongoing = courses.firstOrNull { it.startMillis <= now && it.endMillis > now }

            // 下一节课：开始时间在当前时间之后。
            val next = courses.firstOrNull { it.startMillis > now }

            val publisher = SuperIslandPublisher(appContext)

            // 非小米/HyperOS 2 以下：取消岛与闹钟。
            if (!publisher.isSupported()) {
                Log.i(TAG, "device not supported, cancel island")
                stopTicker()
                publisher.cancel()
                saveSignature(appContext, "none")
                scheduleNext(appContext, 0L)
                return
            }

            // 正在上课：优先显示到下课，即使下节课的 30 分钟窗口已开始。
            if (ongoing != null) {
                Log.i(TAG, "ongoing: ${ongoing.title}")
                val state = buildOngoingState(ongoing, now)
                activeCourse = ongoing
                publishIfChanged(appContext, publisher, state)
                startTicker(appContext)
                // 下课后立即刷新；每分钟仍保留一次兜底刷新。
                scheduleNext(
                    appContext,
                    minOf(
                        ongoing.endMillis + 1_000L,
                        now + PROGRESS_UPDATE_INTERVAL_MILLIS
                    )
                )
                return
            }

            // 没有正在上的课，但有下一节课。
            if (next != null) {
                val untilStart = next.startMillis - now
                Log.i(TAG, "next: ${next.title}, untilStartMin=${untilStart / 60_000L}")
                if (untilStart <= UPCOMING_WINDOW_MILLIS) {
                    // 进入课前 30 分钟窗口：显示即将开始。
                    val state = buildUpcomingState(next, now)
                    activeCourse = next
                    publishIfChanged(appContext, publisher, state)
                    startTicker(appContext)
                    // 开课后立即刷新；每秒刷新由 ticker 负责。
                    scheduleNext(
                        appContext,
                        minOf(
                            next.startMillis + 1_000L,
                            now + PROGRESS_UPDATE_INTERVAL_MILLIS
                        )
                    )
                } else {
                    // 还没进入窗口：不占用岛，等到开课前 30 分钟再显示。
                    stopTicker()
                    publisher.cancel()
                    saveSignature(appContext, "none")
                    scheduleNext(appContext, next.startMillis - UPCOMING_WINDOW_MILLIS)
                }
                return
            }

            // 没有课程：取消岛和闹钟。
            Log.i(TAG, "no course, cancel island")
            stopTicker()
            publisher.cancel()
            saveSignature(appContext, "none")
            scheduleNext(appContext, 0L)
        }
    }

    /**
     * 读取并解析 next_schedule_list。
     */
    private fun loadCourses(context: Context): List<Course> {
        return runCatching {
            // 与 ScheduleWidget 使用相同的读取方式。
            val storage = FlutterSecureStorage(context, HashMap())
            val raw = storage.readAll()["next_schedule_list"]
            if (raw.isNullOrBlank()) return emptyList()

            val array = JSONArray(raw)
            val result = mutableListOf<Course>()

            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue

                // 同时支持课程、考试、手动添加的固定日程和 DDL 规划。
                // 原逻辑只保留 type == 0（课程），导致手动日程/任务没有通知。
                if (item.optInt("type", -1) !in SUPPORTED_TYPES) continue

                val startMillis = item.optLong("startMillis", 0L)
                val endMillis = item.optLong("endMillis", 0L)

                // 丢弃时间无效或已经结束的课程。
                if (startMillis <= 0L || endMillis <= startMillis) continue
                if (endMillis <= System.currentTimeMillis()) continue

                result.add(
                    Course(
                        title = item.optString("title", "未知课程"),
                        location = item.optString("location", ""),
                        startMillis = startMillis,
                        endMillis = endMillis
                    )
                )
            }

            result.sortedBy { it.startMillis }
        }.getOrDefault(emptyList())
    }

    /**
     * 构造“正在上课”的岛状态。
     */
    private fun buildOngoingState(course: Course, now: Long): IslandState {
        val progress = computeProgress(now, course.startMillis, course.endMillis)
        val timeText = friendlyTimeTodayBased(now, course.startMillis, course.endMillis)
        val remain = course.endMillis - now
        return IslandState(
            title = trimText(course.title, 40),
            // 顶部小字只显示时间范围，倒计时放到进度条附近。
            subtitle = timeText,
            timeText = timeText,
            location = course.location,
            shortText = "$progress%",
            startMillis = course.startMillis,
            endMillis = course.endMillis,
            progress = progress,
            countdownLabel = "离结束还有",
            // 展开态精确到秒。
            countdownValue = formatDurationHMS(remain),
            // 折叠态使用“分钟:秒”，小时折算进分钟。
            collapsedValue = formatDurationMS(remain)
        )
    }

    /**
     * 构造“即将开始”的岛状态。
     */
    private fun buildUpcomingState(course: Course, now: Long): IslandState {
        val timeText = friendlyTimeTodayBased(now, course.startMillis, course.endMillis)
        val remain = course.startMillis - now
        return IslandState(
            title = trimText(course.title, 40),
            subtitle = timeText,
            timeText = timeText,
            location = course.location,
            shortText = "0%",
            startMillis = course.startMillis,
            endMillis = course.endMillis,
            progress = 0,
            countdownLabel = "开始还有",
            countdownValue = formatDurationHMS(remain),
            collapsedValue = formatDurationMS(remain)
        )
    }

    /**
     * 根据当前时间判断课程是即将开始、正在进行还是已结束。
     */
    private fun buildStateForCourse(course: Course, now: Long): IslandState? {
        return when {
            now < course.startMillis -> buildUpcomingState(course, now)
            now < course.endMillis -> buildOngoingState(course, now)
            else -> null
        }
    }

    /**
     * 启动秒级刷新，用于精确显示秒数。
     */
    private fun startTicker(context: Context) {
        synchronized(lock) {
            val current = tickFuture
            if (current != null && !current.isCancelled) return
            tickFuture = ticker.scheduleAtFixedRate(
                { tick(context.applicationContext) },
                0L,
                1L,
                TimeUnit.SECONDS
            )
        }
    }

    /**
     * 停止秒级刷新。
     */
    private fun stopTicker() {
        synchronized(lock) {
            tickFuture?.cancel(false)
            tickFuture = null
            activeCourse = null
            lastPublishedSignature = null
        }
    }

    /**
     * 每秒刷新一次当前课程状态。
     */
    private fun tick(context: Context) {
        synchronized(lock) {
            val course = activeCourse ?: return
            val now = System.currentTimeMillis()
            val state = buildStateForCourse(course, now)
            if (state == null) {
                // 课程已结束，交给完整刷新流程处理下一节或取消岛。
                activeCourse = null
                tickFuture?.cancel(false)
                tickFuture = null
                executor.execute { refreshNow(context) }
                return
            }

            val publisher = SuperIslandPublisher(context)
            if (!publisher.isSupported()) {
                stopTicker()
                return
            }
            publishIfChanged(context, publisher, state)
        }
    }

    /**
     * 内容未变化时不重复发送通知。
     */
    private fun publishIfChanged(
        context: Context,
        publisher: SuperIslandPublisher,
        state: IslandState
    ) {
        val signature = buildSignature(state)
        // 使用内存签名判断秒级变化；通知实际消失时仍然重新发布。
        if (lastPublishedSignature == signature && publisher.isPublished()) return
        Log.d(TAG, "publish: ${state.title} / ${state.countdownValue}")
        if (publisher.publish(state)) {
            lastPublishedSignature = signature
            // 持久化签名去掉秒级字段，避免每秒写 SharedPreferences。
            val persistent = buildPersistentSignature(state)
            if (lastSignature(context) != persistent) {
                saveSignature(context, persistent)
            }
        } else {
            Log.w(TAG, "publish failed")
        }
    }

    /**
     * 完整签名，用于进程内秒级去重。
     */
    private fun buildSignature(state: IslandState): String {
        return listOf(
            state.title,
            state.subtitle,
            state.timeText,
            state.location,
            state.shortText,
            state.startMillis,
            state.endMillis,
            state.progress,
            state.countdownLabel,
            state.countdownValue,
            state.collapsedValue
        ).joinToString("|")
    }

    /**
     * 持久化签名，不包含秒级字段，避免高频写盘。
     */
    private fun buildPersistentSignature(state: IslandState): String {
        return listOf(
            state.title,
            state.subtitle,
            state.timeText,
            state.location,
            state.startMillis,
            state.endMillis
        ).joinToString("|")
    }

    /**
     * 安排下一次状态切换闹钟。
     *
     * @param triggerAtMillis 0 表示取消闹钟
     */
    private fun scheduleNext(context: Context, triggerAtMillis: Long) {
        val alarmManager = context.getSystemService(AlarmManager::class.java) ?: return

        val intent = Intent(context, ScheduleIslandReceiver::class.java).apply {
            action = ScheduleIslandReceiver.ACTION_ISLAND_TICK
        }

        val pendingIntent = PendingIntent.getBroadcast(
            context,
            ALARM_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 先取消旧闹钟，避免边界堆积。
        alarmManager.cancel(pendingIntent)

        // 0 表示不再安排。
        if (triggerAtMillis <= 0L) {
            Log.d(TAG, "cancel next alarm")
            return
        }

        // 保证触发时间在当前时间之后，避免立即循环触发。
        val safeTrigger = maxOf(triggerAtMillis, System.currentTimeMillis() + 1_000L)
        Log.d(TAG, "schedule next alarm at ${formatTime(safeTrigger)}")

        try {
            // 优先使用精确闹钟，保证上下课切换及时。
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                safeTrigger,
                pendingIntent
            )
        } catch (_: SecurityException) {
            // 没有精确闹钟权限时退化为普通闹钟。
            runCatching {
                alarmManager.set(AlarmManager.RTC_WAKEUP, safeTrigger, pendingIntent)
            }
        } catch (_: Throwable) {
            // 个别 ROM 可能限制闹钟，失败时只记录，不影响当前岛。
            runCatching {
                alarmManager.set(AlarmManager.RTC_WAKEUP, safeTrigger, pendingIntent)
            }
        }
    }

    /**
     * 格式化时间为 HH:mm。
     */
    private fun formatTime(millis: Long): String {
        return SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(millis))
    }

    /**
     * 计算课程进度百分比。
     */
    private fun computeProgress(now: Long, startMillis: Long, endMillis: Long): Int {
        if (endMillis <= startMillis) return 0
        return (((now - startMillis) * 100L) / (endMillis - startMillis))
            .toInt()
            .coerceIn(0, 100)
    }

    /**
     * 与首页卡片一致的时间范围文本。
     *
     * 例如：今天显示 "16:00 - 18:35"，明天显示 "明天 08:00 - 09:35"。
     */
    private fun friendlyTimeTodayBased(now: Long, startMillis: Long, endMillis: Long): String {
        return "${dayRelation(now, startMillis)}${formatTime(startMillis)} - " +
            "${dayAfterRelation(startMillis, endMillis)}${formatTime(endMillis)}"
    }

    /**
     * 日期相对今天的描述。
     */
    private fun dayRelation(now: Long, targetMillis: Long): String {
        val zone = ZoneId.systemDefault()
        val targetDate = Instant.ofEpochMilli(targetMillis).atZone(zone).toLocalDate()
        val nowDate = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        return when (ChronoUnit.DAYS.between(nowDate, targetDate)) {
            0L -> ""
            1L -> "明天 "
            2L -> "后天 "
            -1L -> "昨天 "
            -2L -> "前天 "
            else -> "${targetDate.monthValue} 月 ${targetDate.dayOfMonth} 日 "
        }
    }

    /**
     * 跨天课程在结束时间前加“次日”或“N 天后”。
     */
    private fun dayAfterRelation(startMillis: Long, endMillis: Long): String {
        val zone = ZoneId.systemDefault()
        val startDate = Instant.ofEpochMilli(startMillis).atZone(zone).toLocalDate()
        val endDate = Instant.ofEpochMilli(endMillis).atZone(zone).toLocalDate()
        val days = ChronoUnit.DAYS.between(startDate, endDate)
        return when {
            days == 1L -> "次日 "
            days > 1L -> "$days 天后 "
            else -> ""
        }
    }

    /**
     * 展开态剩余时间：HH:mm:ss，精确到秒。
     */
    private fun formatDurationHMS(durationMillis: Long): String {
        val totalSeconds = durationMillis.coerceAtLeast(0L) / 1_000L
        val hours = totalSeconds / 3_600L
        val minutes = (totalSeconds % 3_600L) / 60L
        val seconds = totalSeconds % 60L
        return String.format(Locale.US, "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /**
     * 折叠态剩余时间：分钟:秒，小时折算进分钟。
     */
    private fun formatDurationMS(durationMillis: Long): String {
        val totalSeconds = durationMillis.coerceAtLeast(0L) / 1_000L
        val totalMinutes = totalSeconds / 60L
        val seconds = totalSeconds % 60L
        return String.format(Locale.US, "%02d:%02d", totalMinutes, seconds)
    }

    /**
     * 截断过长文本，避免岛布局溢出。
     */
    private fun trimText(value: String, maxLength: Int): String {
        return if (value.length <= maxLength) value else value.take(maxLength)
    }

    /**
     * 读取上次发布签名。
     */
    private fun lastSignature(context: Context): String? {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_SIGNATURE, null)
    }

    /**
     * 保存本次发布签名。
     */
    private fun saveSignature(context: Context, signature: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_SIGNATURE, signature)
            .apply()
    }

    /**
     * 解析后的课程数据。
     */
    private data class Course(
        val title: String,
        val location: String,
        val startMillis: Long,
        val endMillis: Long
    )
}
