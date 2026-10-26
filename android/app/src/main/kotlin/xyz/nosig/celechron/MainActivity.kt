package xyz.nosig.celechron

import android.os.Bundle
import androidx.glance.appwidget.updateAll
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import xyz.nosig.celechron.island.ScheduleIslandCoordinator

class MainActivity: FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = 0
        // 新增：应用启动时先按已缓存的课程数据恢复一次超级岛。
        ScheduleIslandCoordinator.refresh(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "top.celechron.celechron/scheduleWidget").setMethodCallHandler {
                call, result ->
            CoroutineScope(Dispatchers.Main).launch {
                ScheduleWidget().updateAll(this@MainActivity)
                // 新增：Flutter 写入 next_schedule_list 并更新小组件后，同步刷新超级岛。
                ScheduleIslandCoordinator.refresh(this@MainActivity)
            }
        }
    }
}
