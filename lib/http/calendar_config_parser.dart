import 'package:celechron/http/zjuServices/response_utils.dart';
import 'package:celechron/model/semester.dart';
import 'package:flutter/foundation.dart';

const calendarConfigBaseUrl = 'https://oss-2.147483648.xyz/celechroncufe/';

/// 返回日期所属学年的起始年份；九月是学年边界，不代表课表开放时间。
int academicYearStartFor(DateTime now) =>
    now.month >= DateTime.september ? now.year : now.year - 1;

/// 描述历史/当前学年的正常抓取上限，以及额外尝试一年的探测上限。
class TimetableAcademicYearPlan {
  /// 正常范围止于当前学年或毕业学年，以较早者为准。
  final int normalUpperBound;

  /// 在正常范围后多探测一年，但仍不能越过毕业学年。
  final int probeUpperBound;

  const TimetableAcademicYearPlan({
    required this.normalUpperBound,
    required this.probeUpperBound,
  });

  Iterable<int> yearsFrom(int enrollmentYearStart) sync* {
    for (var year = enrollmentYearStart; year <= probeUpperBound; year++) {
      yield year;
    }
  }

  bool isProbeYear(int academicYearStart) =>
      academicYearStart > normalUpperBound;
}

TimetableAcademicYearPlan timetableAcademicYearPlan({
  required DateTime now,
  required int graduationYearStart,
}) {
  final currentAcademicYearStart = academicYearStartFor(now);
  final normalUpperBound = currentAcademicYearStart < graduationYearStart
      ? currentAcademicYearStart
      : graduationYearStart;
  final nextAcademicYearStart = currentAcademicYearStart + 1;
  final probeUpperBound = nextAcademicYearStart < graduationYearStart
      ? nextAcademicYearStart
      : graduationYearStart;
  return TimetableAcademicYearPlan(
    normalUpperBound: normalUpperBound,
    probeUpperBound: probeUpperBound,
  );
}

bool isExpectedTimetableProbeMiss(Object? error) {
  // 不同部署对“尚未开放”会返回空结果、HTTP 文本或解析错误，
  // 因此仅在探测学年用这些兼容文本识别可忽略失败。
  if (error == null) return true;
  final text = error.toString().toLowerCase();
  return text.contains('404') ||
      text.contains('not found') ||
      text.contains('no data') ||
      text.contains('暂无数据') ||
      text.contains('无数据') ||
      text.contains('未开放') ||
      text.contains('尚未开放') ||
      text.contains('空响应') ||
      text.contains('响应为空') ||
      text.contains('正文为空') ||
      text.contains('empty response') ||
      text.contains('缺少 kblist');
}

/// 该学年学期在 [now] 时是否尚未开学；未开学学期的校历配置未发布属预期状态。
/// 秋冬按 9 月 1 日、春夏按次年 2 月 20 日估算名义开学，日期故意取早：
/// 临近开学时宁可判为“已开始”，让配置缺失照常按降级暴露。
/// 格式非法时返回 false，保持降级报警的保守行为。
bool isFutureSemester(String semesterId, DateTime now) {
  if (semesterId.length < 6) return false;
  final yearStart = int.tryParse(semesterId.substring(0, 4));
  if (yearStart == null) return false;
  final DateTime nominalStart;
  if (semesterId.endsWith('-1')) {
    nominalStart = DateTime(yearStart, DateTime.september, 1);
  } else if (semesterId.endsWith('-2')) {
    nominalStart = DateTime(yearStart + 1, DateTime.february, 20);
  } else {
    return false;
  }
  return now.isBefore(nominalStart);
}

String calendarObjectKeyForSemester(String semesterId) {
  if (!RegExp(r'^\d{4}(?:-\d{4})?-[12]$').hasMatch(semesterId)) {
    throw FormatException('无效的学年学期：$semesterId');
  }
  final parts = semesterId.split('-');
  final year = int.parse(parts[0]);
  return '$year-${year + 1}.json';
}

Uri calendarConfigUriForSemester(String semesterId) {
  final key = calendarObjectKeyForSemester(semesterId);
  return Uri.parse(calendarConfigBaseUrl).resolve(key);
}

Map<String, dynamic> decodeAndValidateCalendarConfig(
  String rawConfig, {
  String? semesterId,
  required String context,
}) {
  // startEnd 依次供两个半学期计算日期；sessionTime 的下标与节次直接对应。
  final config = decodeJsonMap(rawConfig, context: context);
  var startEnd = asDynamicList(config['startEnd']);
  
  if (startEnd != null && startEnd.length == 4) {
    // 学年文件（如中财 2026-2027.json）含四个日期：
    // 按学期精确截取，第一学期取前两段、第二学期取后两段，
    // 复制成上下半学期相同的长学期结构。
    final term = semesterId?.split('-').last;
    if (term == '1') {
      startEnd = [startEnd[0], startEnd[1], startEnd[0], startEnd[1]];
      config['startEnd'] = startEnd;
    } else if (term == '2') {
      startEnd = [startEnd[2], startEnd[3], startEnd[2], startEnd[3]];
      config['startEnd'] = startEnd;
    }
  }

  final sessionTime = asDynamicList(config['sessionTime']);
  if (startEnd == null || startEnd.length != 4) {
    throw FormatException('$context：startEnd 应包含四个日期');
  }
  if (sessionTime == null || sessionTime.length < 10) {
    throw FormatException('$context：sessionTime 缺失或节次数不足');
  }
  return config;
}

void applyCalendarConfig(
  String rawConfig,
  Semester semester,
  Map<DateTime, String> specialDates, {
  String? semesterId,
  required String context,
}) {
  // holiday/dummy 的键是日期；exchange 的键拼接放假日和调休日各 8 位日期。
  final config = decodeAndValidateCalendarConfig(
    rawConfig,
    semesterId: semesterId,
    context: context,
  );
  semester.addZjuCalendar(config);

  void addDates(Object? raw, String suffix) {
    final entries = asStringMap(raw);
    if (entries == null) return;
    for (final entry in entries.entries) {
      final date = asDateTime(entry.key);
      final name = asString(entry.value);
      if (date == null || name == null) {
        debugPrint('$context：跳过异常日期 ${entry.key}=${entry.value}');
        continue;
      }
      specialDates[date] = '$name$suffix';
    }
  }

  addDates(config['holiday'], '放假');
  addDates(config['dummy'], '放假');

  final exchanges = asStringMap(config['exchange']);
  if (exchanges == null) return;
  for (final entry in exchanges.entries) {
    final key = entry.key;
    if (key.length < 16) {
      debugPrint('$context：跳过异常调休键 $key');
      continue;
    }
    final holiday = asDateTime(key.substring(0, 8));
    final workday = asDateTime(key.substring(8, 16));
    final name = asString(entry.value);
    if (holiday == null || workday == null || name == null) {
      debugPrint('$context：跳过异常调休 $key=${entry.value}');
      continue;
    }
    specialDates[holiday] = '$name放假·调 ${workday.month} 月 ${workday.day} 日';
    specialDates[workday] = '$name调休·调 ${holiday.month} 月 ${holiday.day} 日';
  }
}
