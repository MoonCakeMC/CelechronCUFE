package xyz.nosig.celechron

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.*
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.lazy.LazyColumn
import androidx.glance.appwidget.provideContent
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
}

data class ScheduleItem(
    val title: String,
    val time: String,
    val location: String,
    val type: Int
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
                            type = obj.optInt("type", 0)
                        )
                    )
                }
            }
        } catch (e: Exception) {
            // ignore
        }

        provideContent {
            GlanceTheme {
                content(context, id, scheduleList)
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
                    modifier = GlanceModifier.size(18.dp).clickable {
                        CoroutineScope(Dispatchers.Main).launch {
                            if (context != null && id != null) {
                                update(context, id)
                            }
                        }
                    },
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
                        
                        // The card style mimicking FlowPage
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
