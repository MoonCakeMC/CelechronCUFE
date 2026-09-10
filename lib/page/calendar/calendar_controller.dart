import 'package:celechron/model/task.dart';
import 'package:celechron/utils/utils.dart';
import 'package:get/get.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:celechron/model/period.dart';
import 'package:celechron/model/scholar.dart';
import 'package:celechron/model/semester.dart';

enum CalendarViewMode {
  calendar,
  schedule,
}

class CalendarController extends GetxController {
  final selectedDay = DateTime.now().obs;
  final focusedDay = DateTime.now().obs;
  final calendarFormat = CalendarFormat.month.obs;
  final events = <DateTime, List<Period>>{}.obs;
  final scholar = Get.find<Rx<Scholar>>(tag: 'scholar');
  final taskList = Get.find<RxList<Task>>(tag: 'taskList');
  final viewMode = CalendarViewMode.calendar.obs;

  static List<String> numToChinese = ['一', '二', '三', '四', '五', '六', '七', '八'];

  String dayDescription(DateTime day) {
    var semester = scholar.value.semesters.firstWhereOrNull(
        (e) => !day.isBefore(e.firstDay) && !day.isAfter(e.lastDay));
    if (semester == null) return '考试周/假期';

    var toFirstWeek = day.difference(semester.firstDay).inDays ~/ 7;
    // 如果是类似中财的长学期（无第二半学期），直接显示“第x周”
    if (semester.secondHalfName == '') {
      return '${semester.firstHalfName}学期 第${toFirstWeek + 1}周';
    }

    // 浙大短学期逻辑
    if (toFirstWeek >= 0 && toFirstWeek < 8) {
      return '${semester.firstHalfName}${numToChinese[toFirstWeek]}周';
    }
    
    var toLastWeek = 7 - semester.lastDay.difference(day).inDays ~/ 7;
    if (toLastWeek >= 0 && toLastWeek < 8) {
      return '${semester.secondHalfName}${numToChinese[toLastWeek]}周';
    }
    return '考试周/假期';
  }

  @override
  void onInit() {
    refreshEvents();
    ever(scholar, (callback) => refreshEvents());
    super.onInit();
  }

  void refreshEvents() {
    events.clear();
    Set<DateTime> keySet = {};
    for (var element in Get.find<Rx<Scholar>>(tag: 'scholar').value.periods) {
      DateTime chop = chopDate(element.startTime);
      if (events[chop] == null) events[chop] = <Period>[];
      events[chop]!.add(element);
      keySet.add(chop);
    }
    for (var i in keySet) {
      events[i]!.sort((a, b) => a.startTime.compareTo(b.startTime));
    }
  }

  DateTime chopDate(DateTime day) {
    return DateTime(day.year, day.month, day.day);
  }

  List<Period> getEventsForDay(DateTime day) {
    DateTime chop = chopDate(day);
    var eventsOfDay = <Period>[];
    if (events[chop] != null) {
      for (var event in events[chop]!) {
        eventsOfDay.add(event.copyWith());
      }
    }
    for (var deadline in taskList) {
      if (deadline.type == TaskType.fixed ||
          deadline.type == TaskType.fixedlegacy) {
        List<Period> periods = deadline.getPeriodOfDay(dateOnly(day));
        for (var p in periods) {
          eventsOfDay.add(p);
        }
      }
    }
    eventsOfDay.sort((a, b) => a.startTime.compareTo(b.startTime));
    return eventsOfDay;
  }

  void toggleViewMode() {
    viewMode.value = viewMode.value == CalendarViewMode.calendar
        ? CalendarViewMode.schedule
        : CalendarViewMode.calendar;
  }

  Semester? getCurrentSemester() {
    final now = DateTime.now();
    return scholar.value.semesters.firstWhereOrNull(
      (e) => !now.isBefore(e.firstDay) && !now.isAfter(e.lastDay),
    );
  }

  bool isFirstHalfSemester(Semester semester) {
    // 中财长学期（无第二半学期）：秋学期显示第一视图，春学期显示第二视图
    if (semester.secondHalfName == '') {
      return semester.firstHalfName == '秋';
    }
    final now = DateTime.now();
    final toFirstWeek = now.difference(semester.firstDay).inDays ~/ 7;
    return toFirstWeek < 8;
  }

  String getCurrentSemesterDisplayName() {
    final semester = getCurrentSemester();
    if (semester == null) return '无学期信息';

    final isFirstHalf = isFirstHalfSemester(semester);
    final semesterName = semester.shortName;
    final halfName =
        isFirstHalf ? semester.firstHalfName : semester.secondHalfName;
    return '$semesterName $halfName学期';
  }
}
