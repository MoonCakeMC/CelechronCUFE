import 'exam.dart';
import 'package:celechron/utils/json_utils.dart';

class ExamDto {
  String id;
  String? kch; // 教务课程号（如 "0830024"），跨接口统一的课程合并键
  String? semester; // 由 xnm/xqm 解析出的学期，如 "2020-1"；无法解析时为 null
  String name;
  double credit;
  late List<Exam> exams;

  // only used for ugrs
  String get semesterId {
    // 优先使用 xnm/xqm 解析出的学期；无该信息时回退旧逻辑
    final parsed = semester;
    if (parsed != null && parsed.isNotEmpty) return parsed;
    return id.length > 12 ? id.substring(1, 12) : "研究生请勿使用此函数";
  }

  ExamDto.empty()
      : id = "",
        name = "",
        credit = 0,
        exams = [];

  // 第一个元素是开始时间，第二个元素是结束时间
  /*ExamDto(Map<String, dynamic> json)
      : id = json['xkkh'] as String,
        name =
            (json['kcmc'] as String).replaceAll('(', '（').replaceAll(')', '）'),
        credit = double.parse(json['xkxf'] as String) {
    exams = Exam.parseExams(json, id, name);
  }*/

  factory ExamDto.fromZdbk(Map<String, dynamic> json) {
    final kch = asString(json['kch']);
    final id = asString(json['kch_id']) ?? kch;
    if (id == null || id.isEmpty) {
      throw const FormatException('考试条目缺少课程号(kch_id/kch)');
    }
    final dto = ExamDto.empty()
      ..id = id
      ..kch = kch
      ..semester = _parseSemester(asString(json['xnm']), asString(json['xqm']))
      ..name = (asString(json['kcmc']) ?? '未知课程')
          .replaceAll('(', '（')
          .replaceAll(')', '）')
      ..credit = asDouble(json['xf']) ?? 0.0;
    dto.exams = Exam.parseExamsFromZdbk(json, dto.id, dto.name);
    return dto;
  }

  /// 将教务返回的 xnm（学年）与 xqm（学期：3=第一学期，12=第二学期）
  /// 解析为学期标识，如 "2020-1"；无法解析时返回 null。
  static String? _parseSemester(String? xnm, String? xqm) {
    if (xnm == null || xnm.isEmpty) return null;
    final term = switch (xqm) {
      '3' => '1',
      '12' => '2',
      _ => null,
    };
    if (term == null) return null;
    return '$xnm-$term';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kch': kch,
        'semester': semester,
        'name': name,
        'credit': credit,
        'exams': exams,
      };

  ExamDto.fromJson(Map<String, dynamic> json)
      : id = asString(json['id']) ?? '',
        kch = asString(json['kch']),
        semester = asString(json['semester']),
        name = asString(json['name']) ?? '未知课程',
        credit = asDouble(json['credit']) ?? 0.0,
        exams = (asDynamicList(json['exams']) ?? const [])
            .map(asStringMap)
            .whereType<Map<String, dynamic>>()
            .map(Exam.fromJson)
            .toList();
}
