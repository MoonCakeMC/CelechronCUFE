import 'package:celechron/utils/time_helper.dart';
import 'package:celechron/utils/json_utils.dart';

class Exam {
  String id;
  String name;
  ExamType type;

  // 第一个元素是开始时间，第二个元素是结束时间
  late List<DateTime> time;
  String? dateLabel;
  String? location;
  String? seat;

  Exam.empty()
      : id = "",
        name = "",
        type = ExamType.finalExam,
        time = [];

  /*Exam._fromAppService(
      this.id, this.name, Map<String, dynamic> json, this.type) {
    switch (type) {
      case ExamType.midterm:
        time = TimeHelper.parseExamDateTime(json['qzkssj']);
        location = json['qzksdd'];
        seat = json['qzzwxh'];
        break;
      case ExamType.finalExam:
        time = TimeHelper.parseExamDateTime(json['qmkssj']);
        location = json['qmksdd'];
        seat = json['zwxh'];
        break;
    }
  }*/

  /*static List<Exam> parseExams(
      Map<String, dynamic> json, String id, String name) {
    var exams = <Exam>[];
    if (json.containsKey("qzkssj")) {
      exams.add(Exam._fromAppService(id, name, json, ExamType.midterm));
    }
    if (json.containsKey("qmkssj")) {
      exams.add(Exam._fromAppService(id, name, json, ExamType.finalExam));
    }
    return exams;
  }*/

  Exam._fromZdbk(this.id, this.name, Map<String, dynamic> json, this.type) {
    switch (type) {
      case ExamType.midterm:
        final dateTimeText = asString(json['qzkssj']) ?? '';
        time = TimeHelper.parseExamDateTime(dateTimeText);
        dateLabel = TimeHelper.parseExamDateLabel(dateTimeText);
        location = asString(json['qzjsmc']) ?? asString(json['cdmc']);
        // 原实现使用 row_id 兜底，但 row_id 是正方表格行标识/行号，不是座位号。
        // seat = asString(json['zwh']) ?? asString(json['row_id']);
        // 正方考试查询接口中只有 zwh 表示座位号；缺失时保持 null，由界面显示“未知”。
        seat = asString(json['zwh']);
        break;
      case ExamType.finalExam:
        final dateTimeText = asString(json['kssj']) ?? '';
        time = TimeHelper.parseExamDateTime(dateTimeText);
        dateLabel = TimeHelper.parseExamDateLabel(dateTimeText);
        location = asString(json['jsmc']) ?? asString(json['cdmc']);
        // 原实现使用 row_id 兜底，但 row_id 是正方表格行标识/行号，不是座位号。
        // seat = asString(json['zwh']) ?? asString(json['row_id']);
        // 正方考试查询接口中只有 zwh 表示座位号；缺失时保持 null，由界面显示“未知”。
        seat = asString(json['zwh']);
        break;
    }
  }

  static List<Exam> parseExamsFromZdbk(
      Map<String, dynamic> json, String id, String name) {
    var exams = <Exam>[];
    if (asString(json["qzkssj"])?.isNotEmpty == true) {
      try {
        exams.add(Exam._fromZdbk(id, name, json, ExamType.midterm));
      } catch (_) {}
    }
    if (asString(json["kssj"])?.isNotEmpty == true) {
      try {
        exams.add(Exam._fromZdbk(id, name, json, ExamType.finalExam));
      } catch (_) {}
    }
    return exams;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.index,
        'time': time.map((e) => e.toIso8601String()).toList(),
        'dateLabel': dateLabel,
        'location': location,
        'seat': seat,
      };

  Exam.fromJson(Map<String, dynamic> json)
      : id = asString(json['id']) ?? '',
        name = asString(json['name']) ?? '未知课程',
        type = _examTypeFromJson(json['type']),
        time = (asDynamicList(json['time']) ?? const [])
            .map(asString)
            .whereType<String>()
            .map(DateTime.tryParse)
            .whereType<DateTime>()
            .toList(),
        dateLabel = asString(json['dateLabel']),
        location = asString(json['location']),
        seat = asString(json['seat']);

  /// 刷新合并时用新解析的考试覆盖旧考试。
  ///
  /// 座位号始终以 [other.seat] 为准：即使为 null 也要覆盖，
  /// 用于清除旧版本从 row_id 误解析并持久化的错误座位号。
  void overwriteFrom(Exam other) {
    // 座位号必须覆盖，不能因为 other.seat 为 null 而保留旧错误值。
    seat = other.seat;
    // 地点缺失时保留旧值，避免接口少字段时把已有地点清空。
    location = other.location ?? location;
    // 名称、日期标签和时间按本次刷新结果更新。
    if (other.name.isNotEmpty) name = other.name;
    dateLabel = other.dateLabel ?? dateLabel;
    if (other.time.length >= 2) {
      time = List<DateTime>.from(other.time);
    }
  }

  get chineseTime {
    if (dateLabel == null) return TimeHelper.chineseTime(time[0], time[1]);
    return '$dateLabel ${_hourMinute(time[0])} - ${_hourMinute(time[1])}';
  }

  get chineseDate =>
      dateLabel ?? TimeHelper.chineseDay(time[0]).replaceAll(" ", "");

  String _hourMinute(DateTime dateTime) =>
      '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
}

ExamType _examTypeFromJson(Object? value) {
  final index = asInt(value);
  if (index == null || index < 0 || index >= ExamType.values.length) {
    return ExamType.finalExam;
  }
  return ExamType.values[index];
}

enum ExamType { midterm, finalExam }
