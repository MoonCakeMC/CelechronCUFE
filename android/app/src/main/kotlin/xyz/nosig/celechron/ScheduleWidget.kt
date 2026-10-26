package xyz.nosig.celechron

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.*
import androidx.glance.action.ActionParameters
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.lazy.LazyColumn
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.layout.*
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.it_nomads.fluttersecurestorage.FlutterSecureStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

class ScheduleWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = ScheduleWidget()

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_SCHEDULE_BOUNDARY) {
            CoroutineScope(Dispatchers.Main).launch {
                glanceAppWidget.updateAll(context)
            }
        }
    }

    companion object {
        const val ACTION_SCHEDULE_BOUNDARY = "xyz.nosig.celechron.SCHEDULE_BOUNDARY"
        private const val ALARM_REQUEST_CODE = 9988

        fun scheduleNextBoundary(context: Context, items: List<ScheduleItem>) {
            val now = System.currentTimeMillis()
            val nextBoundary = items
                .flatMap { listOf(it.startMillis, it.endMillis) }
                .filter { it > now }
                .minOrNull() ?: return

            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
            val intent = Intent(context, ScheduleWidgetReceiver::class.java).apply {
                action = ACTION_SCHEDULE_BOUNDARY
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                ALARM_REQUEST_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val triggerTime = nextBoundary + 1000L // 1秒缓冲，保证边界到达后翻转
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerTime, pendingIntent)
                } else {
                    alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerTime, pendingIntent)
                }
            } catch (e: Exception) {
                try {
                    alarmManager.set(AlarmManager.RTC_WAKEUP, triggerTime, pendingIntent)
                } catch (ignored: Exception) {
                }
            }
        }
    }
}

class RefreshActionCallback : ActionCallback {
    override suspend fun onAction(
        context: Context,
        glanceId: GlanceId,
        parameters: ActionParameters
    ) {
        ScheduleWidget().updateAll(context)
    }
}

data class ScheduleItem(
    val title: String,
    val time: String,
    val location: String,
    val type: Int,
    val startMillis: Long = 0L,
    val endMillis: Long = 0L
)

class ScheduleWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val scheduleList = mutableListOf<ScheduleItem>()
        try {
            val storage = FlutterSecureStorage(context, HashMap())
            val values = storage.readAll()
            val listJson = values["next_schedule_list"]
            if (listJson != null) {
                val array = JSONArray(listJson)
                for (i in 0 until array.length()) {
                    val obj = array.getJSONObject(i)
                    scheduleList.add(
                        ScheduleItem(
                            title = obj.optString("title", "未知"),
                            time = obj.optString("time", ""),
                            location = obj.optString("location", ""),
                            type = obj.optInt("type", 0),
                            startMillis = obj.optLong("startMillis", 0L),
                            endMillis = obj.optLong("endMillis", 0L)
                        )
                    )
                }
            }
        } catch (e: Exception) {
            // ignore
        }

        val now = System.currentTimeMillis()
        // 严格过滤已结束的日程：优先使用毫秒时间戳，回退使用时间字符串对比今天时刻
        val activeList = scheduleList.filter { item ->
            if (item.endMillis > 0L) {
                item.endMillis > now
            } else {
                val parts = item.time.split("-").map { it.trim() }
                if (parts.size == 2) {
                    val endTokens = parts[1].split(":")
                    if (endTokens.size == 2) {
                        val endH = endTokens[0].toIntOrNull()
                        val endM = endTokens[1].toIntOrNull()
                        if (endH != null && endM != null) {
                            val cal = java.util.Calendar.getInstance().apply {
                                timeInMillis = now
                                set(java.util.Calendar.HOUR_OF_DAY, endH)
                                set(java.util.Calendar.MINUTE, endM)
                                set(java.util.Calendar.SECOND, 0)
                                set(java.util.Calendar.MILLISECOND, 0)
                            }
                            now < cal.timeInMillis
                        } else false
                    } else false
                } else false
            }
        }

        // 调度下一次边界闹钟
        ScheduleWidgetReceiver.scheduleNextBoundary(context, activeList)

        provideContent {
            GlanceTheme {
                content(context, id, activeList)
            }
        }
    }

    @Composable
    private fun content(context: Context?, id: GlanceId?, scheduleList: List<ScheduleItem>) {
        Column(
            modifier = GlanceModifier
                .background(GlanceTheme.colors.background)
                .fillMaxSize()
                .padding(horizontal = 12.dp, vertical = 12.dp)
                .cornerRadius(16.dp)
                .clickable {
                    val intent = context?.packageManager?.getLaunchIntentForPackage(context.packageName ?: "")
                    if (intent != null) {
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        context?.startActivity(intent)
                    }
                }
        ) {
            // Header
            Row(
                modifier = GlanceModifier.fillMaxWidth().padding(bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "接下来",
                    maxLines = 1,
                    style = TextStyle(
                        color = GlanceTheme.colors.onBackground,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold
                    )
                )
                Spacer(modifier = GlanceModifier.defaultWeight())
                Image(
                    provider = ImageProvider(resId = R.drawable.sync_24px),
                    contentDescription = "Refresh",
                    modifier = GlanceModifier
                        .size(18.dp)
                        .clickable(actionRunCallback<RefreshActionCallback>()),
                    colorFilter = ColorFilter.tint(GlanceTheme.colors.onBackground)
                )
            }

            if (scheduleList.isEmpty()) {
                Box(modifier = GlanceModifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        text = "今日无安排",
                        style = TextStyle(color = GlanceTheme.colors.onBackground, fontSize = 14.sp)
                    )
                }
            } else {
                LazyColumn(
                    modifier = GlanceModifier.fillMaxSize()
                ) {
                    items(scheduleList.size) { index ->
                        val item = scheduleList[index]

                        // The card style mimicking FlowPage (完全保留原版卡片样式)
                        Column(
                            modifier = GlanceModifier
                                .fillMaxWidth()
                                .padding(bottom = 8.dp)
                                .background(GlanceTheme.colors.surface)
                                .cornerRadius(12.dp)
                                .padding(12.dp)
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically, modifier = GlanceModifier.fillMaxWidth()) {
                                // Dot
                                Box(
                                    modifier = GlanceModifier
                                        .size(10.dp)
                                        .background(if (item.type == 3) GlanceTheme.colors.primary else GlanceTheme.colors.secondary)
                                        .cornerRadius(5.dp)
                                ) {}
                                Spacer(modifier = GlanceModifier.width(8.dp))
                                Text(
                                    text = item.title,
                                    maxLines = 1,
                                    style = TextStyle(
                                        color = GlanceTheme.colors.onSurface,
                                        fontSize = 16.sp,
                                        fontWeight = FontWeight.Bold
                                    ),
                                    modifier = GlanceModifier.defaultWeight()
                                )
                            }

                            // Divider approximation
                            Box(
                                modifier = GlanceModifier
                                    .fillMaxWidth()
                                    .height(1.dp)
                                    .background(GlanceTheme.colors.onSurface)
                                    .padding(vertical = 6.dp)
                            ) {}
                            Spacer(modifier = GlanceModifier.height(6.dp))

                            Row(verticalAlignment = Alignment.CenterVertically, modifier = GlanceModifier.fillMaxWidth()) {
                                Column(modifier = GlanceModifier.defaultWeight()) {
                                    if (item.location.isNotEmpty()) {
                                        Text(
                                            text = item.location,
                                            maxLines = 1,
                                            style = TextStyle(
                                                color = GlanceTheme.colors.onSurface,
                                                fontSize = 14.sp,
                                                fontWeight = FontWeight.Bold
                                            )
                                        )
                                    } else {
                                        Text(text = " ")
                                    }
                                }

                                Column(horizontalAlignment = Alignment.End) {
                                    Text(
                                        text = item.time,
                                        maxLines = 1,
                                        style = TextStyle(
                                            color = GlanceTheme.colors.onSurface,
                                            fontSize = 14.sp
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
