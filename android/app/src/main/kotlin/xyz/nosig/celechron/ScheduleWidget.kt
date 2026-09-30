package xyz.nosig.celechron

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.*
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.layout.*
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.it_nomads.fluttersecurestorage.FlutterSecureStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class ScheduleWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = ScheduleWidget()
}

class ScheduleWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        var title = "暂无日程"
        var timeStr = ""
        var locationStr = ""
        try {
            val storage = FlutterSecureStorage(context, HashMap())
            val values = storage.readAll()
            title = values["next_schedule_title"] ?: "今日无安排"
            timeStr = values["next_schedule_time"] ?: ""
            locationStr = values["next_schedule_location"] ?: ""
        } catch (e: Exception) {
            title = "加载失败"
        }

        provideContent {
            GlanceTheme {
                content(context, id, title, timeStr, locationStr)
            }
        }
    }

    @Composable
    private fun content(context: Context?, id: GlanceId?, title: String, timeStr: String, locationStr: String) {
        Column(
            modifier = GlanceModifier
                .background(GlanceTheme.colors.background)
                .fillMaxSize()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .cornerRadius(16.dp)
                .clickable {
                    val intent = context?.packageManager?.getLaunchIntentForPackage(context.packageName)
                    if (intent != null) {
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        context.startActivity(intent)
                    }
                },
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(modifier = GlanceModifier.fillMaxWidth()) {
                Image(
                    provider = ImageProvider(resId = R.drawable.sync_24px),
                    contentDescription = "Schedule",
                    modifier = GlanceModifier.size(20.dp),
                    colorFilter = ColorFilter.tint(GlanceTheme.colors.onBackground)
                )
                Spacer(modifier = GlanceModifier.width(6.dp))
                Text(
                    text = "下个日程", maxLines = 1, style = TextStyle(
                        color = GlanceTheme.colors.onBackground,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Bold
                    )
                )
                Spacer(modifier = GlanceModifier.defaultWeight())
                Image(
                    provider = ImageProvider(resId = R.drawable.sync_24px),
                    contentDescription = "Refresh",
                    modifier = GlanceModifier.size(20.dp).clickable {
                        CoroutineScope(Dispatchers.Main).launch {
                            update(context!!, id!!)
                        }
                    },
                    colorFilter = ColorFilter.tint(GlanceTheme.colors.onBackground)
                )
            }

            Spacer(modifier = GlanceModifier.height(8.dp))
            Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = GlanceModifier.defaultWeight()) {
                    Text(
                        text = title,
                        maxLines = 1,
                        style = TextStyle(
                            color = GlanceTheme.colors.primary,
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold
                        )
                    )
                    Spacer(modifier = GlanceModifier.height(4.dp))
                    if (timeStr.isNotEmpty()) {
                        Text(
                            text = timeStr,
                            maxLines = 1,
                            style = TextStyle(
                                color = GlanceTheme.colors.onBackground,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Normal,
                            )
                        )
                    }
                    if (locationStr.isNotEmpty()) {
                        Text(
                            text = locationStr,
                            maxLines = 1,
                            style = TextStyle(
                                color = GlanceTheme.colors.onBackground,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Normal,
                            )
                        )
                    }
                }
            }
        }
    }
}
