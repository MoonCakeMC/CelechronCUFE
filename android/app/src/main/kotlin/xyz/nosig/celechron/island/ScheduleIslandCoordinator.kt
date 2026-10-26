package xyz.nosig.celechron.island

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.util.Log
import com.it_nomads.fluttersecurestorage.FlutterSecureStorage
import org.json.JSONArray
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

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

    // 闹钟的固定请求码，保证只存在一个待触发的边界闹钟。
    private const val ALARM_REQUEST_CODE = 52002

    // 记录上次发布签名的偏好文件名。
    private const val PREFS_NAME = "celechron_island_state"

    // 上次发布内容签名的 key。
    private const val KEY_SIGNATURE = "last_signature"

    // 课程类型：PeriodType.classes 的索引为 0。
    private const val TYPE_CLASSES = 0

    // 单线程执行器，避免多次刷新并发读写存储。
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "CelechronIsland").apply { isDaemon = true }
    }

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
                publisher.cancel()
                saveSignature(appContext, "none")
                scheduleNext(appContext, 0L)
                return
            }

            // 正在上课：优先显示到下课，即使下节课的 30 分钟窗口已开始。
            if (ongoing != null) {
                Log.i(TAG, "ongoing: ${ongoing.title}")
                val state = IslandState(
                    title = trimText(ongoing.title, 40),
                    subtitle = "正在上课 · 至 ${formatTime(ongoing.endMillis)}",
                    timeText = "${formatTime(ongoing.startMillis)} - ${formatTime(ongoing.endMillis)}",
                    location = ongoing.location,
                    shortText = "至 ${formatTime(ongoing.endMillis)}",
                    startMillis = ongoing.startMillis,
                    endMillis = ongoing.endMillis
                )
                publishIfChanged(appContext, publisher, state)
                // 下课后立即刷新，切换到下一节或取消岛。
                scheduleNext(appContext, ongoing.endMillis + 1_000L)
                return
            }

            // 没有正在上的课，但有下一节课。
            if (next != null) {
                val untilStart = next.startMillis - now
                Log.i(TAG, "next: ${next.title}, untilStartMin=${untilStart / 60_000L}")
                if (untilStart <= UPCOMING_WINDOW_MILLIS) {
                    // 进入课前 30 分钟窗口：显示即将开始。
                    val state = IslandState(
                        title = trimText(next.title, 40),
                        subtitle = "即将开始 · ${formatTime(next.startMillis)}",
                        timeText = "${formatTime(next.startMillis)} - ${formatTime(next.endMillis)}",
                        location = next.location,
                        shortText = formatTime(next.startMillis),
                        startMillis = next.startMillis,
                        endMillis = next.endMillis
                    )
                    publishIfChanged(appContext, publisher, state)
                    // 开课后立即刷新，切换成“正在上课”。
                    scheduleNext(appContext, next.startMillis + 1_000L)
                } else {
                    // 还没进入窗口：不占用岛，等到开课前 30 分钟再显示。
                    publisher.cancel()
                    saveSignature(appContext, "none")
                    scheduleNext(appContext, next.startMillis - UPCOMING_WINDOW_MILLIS)
                }
                return
            }

            // 没有课程：取消岛和闹钟。
            Log.i(TAG, "no course, cancel island")
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

                // 只保留课程，过滤考试、DDL、用户日程。
                if (item.optInt("type", -1) != TYPE_CLASSES) continue

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
     * 内容未变化时不重复发送通知。
     */
    private fun publishIfChanged(
        context: Context,
        publisher: SuperIslandPublisher,
        state: IslandState
    ) {
        val signature = buildSignature(state)
        if (lastSignature(context) == signature) return
        Log.i(TAG, "publish: ${state.title} / ${state.subtitle}")
        if (publisher.publish(state)) {
            saveSignature(context, signature)
        } else {
            Log.w(TAG, "publish failed")
        }
    }

    /**
     * 使用时间文本生成稳定的内容签名。
     */
    private fun buildSignature(state: IslandState): String {
        return listOf(
            state.title,
            state.subtitle,
            state.timeText,
            state.location,
            state.shortText,
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
