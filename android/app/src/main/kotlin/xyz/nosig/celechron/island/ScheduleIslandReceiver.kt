package xyz.nosig.celechron.island

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 课程超级岛边界闹钟接收器。
 *
 * 由 ScheduleIslandCoordinator 安排，在课前 30 分钟、上课、下课时触发。
 */
class ScheduleIslandReceiver : BroadcastReceiver() {

    companion object {
        // 自定义的边界刷新 action。
        const val ACTION_ISLAND_TICK = "xyz.nosig.celechron.ISLAND_TICK"
    }

    override fun onReceive(context: Context, intent: Intent) {
        // 只处理本模块关心的广播。
        val action = intent.action ?: return
        if (action != ACTION_ISLAND_TICK &&
            action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }

        // 广播接收器默认在主线程，使用 goAsync 把读取存储的操作放到后台。
        val pendingResult = goAsync()
        val appContext = context.applicationContext

        Thread {
            try {
                // 重新读取课程并刷新岛。
                ScheduleIslandCoordinator.refreshNow(appContext)
            } finally {
                // 无论成功失败都要结束广播，避免系统超时。
                pendingResult.finish()
            }
        }.start()
    }
}
