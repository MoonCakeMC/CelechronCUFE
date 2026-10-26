import 'package:get/get.dart';

import 'package:celechron/model/option.dart';
import 'package:celechron/database/database_helper.dart';

/// 课表“屏蔽课程”状态的读写助手。
///
/// 屏蔽状态保存在全局 [Option.hiddenCourses]（RxMap，供界面响应式刷新），
/// 并同步落盘到 [DatabaseHelper]。这里不依赖只在设置页才创建的
/// OptionController，因此课程详情等任意位置都能安全调用。
class HiddenCourseStore {
  // 纯静态工具类，禁止实例化
  HiddenCourseStore._();

  static Option get _option => Get.find<Option>(tag: 'option');
  static DatabaseHelper get _db => Get.find<DatabaseHelper>(tag: 'db');

  /// 当前全部屏蔽项（键为课程标识，值为课程名）。
  /// 通过读取 RxMap 的 keys/[] 建立 Obx 依赖，实现响应式刷新。
  static Map<String, String> get all {
    final map = _option.hiddenCourses;
    return {for (final key in map.keys) key: map[key]!};
  }

  /// 当前屏蔽标识集合，供课表过滤使用
  static Set<String> get keys => _option.hiddenCourses.keys.toSet();

  /// 指定课程标识是否已被屏蔽
  static bool isHidden(String key) => _option.hiddenCourses.keys.contains(key);

  /// 设置某门课程的屏蔽状态，并持久化到数据库
  static void setHidden(String key, String name, bool hidden) {
    // 拷贝一份再做增删，最后整体写回以触发 RxMap 监听，让界面（Obx）刷新
    final map = Map<String, String>.from(_option.hiddenCourses);
    if (hidden) {
      map[key] = name;
    } else {
      map.remove(key);
    }
    _option.hiddenCourses.assignAll(map);
    _db.setHiddenCourses(map);
  }
}
