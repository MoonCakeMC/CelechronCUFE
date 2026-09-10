import 'package:celechron/utils/json_utils.dart';

class Grade {
  String id; // 课程号（kch_id，缺失时用 kch 兜底）
  String? kch; // 教务课程号（如 "0830024"），跨接口统一的课程合并键
  String? semester; // 由 xnm/xqm 解析出的学期，如 "2020-1"；无法解析时为 null
  String name; // 课程名
  double credit; // 学分
  String original; // 原始成绩
  double fivePoint; // 五分制成绩
  late double fourPoint; // 四分制成绩（4.3 满分）
  late double fourPointLegacy; // 原始的四分制成绩
  late int hundredPoint; // 百分制成绩
  bool major = false; // 计入主修
  bool? isOnline = false; // grs成绩使用这个字段标志是不是线上上课(hack)
  // 计入GPA（弃修、待录、缓考、二级制的不计）
  late bool gpaIncluded;
  // 计入学分（弃修、待录、缓考的不计）
  late bool creditIncluded;

  // 获得的学分（挂科、不计学分的不计）
  double get earnedCredit =>
      (creditIncluded && (fivePoint != 0 || id.contains('xtwkc')))
          ? credit
          : 0.0;

  // only used for ugrs
  String get semesterId {
    // 优先使用 xnm/xqm 解析出的学期；无该信息时回退旧逻辑（研究生等）
    final parsed = semester;
    if (parsed != null && parsed.isNotEmpty) return parsed;
    return id.length > 12 ? id.substring(1, 12) : "研究生请勿使用此函数";
  }

  String get realId {
    var matchClass = RegExp(r'(\(.*\)-.*?)-.*').firstMatch(id);
    var key = matchClass?.group(1);
    key ??= id.length < 22 ? id : id.substring(0, 22);
    return key;
  }

  static final Map<double, double> _toFourPoint = {
    5.0: 4.3,
    4.8: 4.2,
    4.5: 4.1,
    4.2: 4.0,
  };

  static final Map<String, int> _toHundredPoint = {
    "A+": 95,
    "A": 90,
    "A-": 87,
    "B+": 83,
    "B": 80,
    "B-": 77,
    "C+": 73,
    "C": 70,
    "C-": 67,
    "D": 60,
    "F": 0,
    "优秀": 90,
    "良好": 80,
    "中等": 70,
    "及格": 60,
    "不及格": 0,
    "合格": 75,
    "不合格": 0,
    "弃修": 0,
    "缺考": 0,
    "缓考": 0,
    "待录": 0,
    "无效": 0,
  };

  Grade.empty()
      : id = "",
        name = "",
        credit = 0.0,
        original = "",
        fivePoint = 0.0;

  // 从所有成绩查询处爬取，因此不含主修标记
  factory Grade(Map<String, dynamic> json) {
    final kch = asString(json['kch']);
    final id = asString(json['kch_id']) ?? kch;
    if (id == null || id.isEmpty) {
      throw const FormatException('成绩缺少课程号(kch_id/kch)');
    }
    final grade = Grade.empty()
      ..id = id
      ..kch = kch
      ..name = (asString(json['kcmc']) ?? '未知课程')
          .replaceAll('(', '（')
          .replaceAll(')', '）')
      ..credit = asDouble(json['xf']) ?? 0.0
      ..original = asString(json['cj']) ?? ''
      ..fivePoint = asDouble(json['jd']) ?? 0.0
      ..semester = _parseSemester(asString(json['xnm']), asString(json['xqm']));
    grade._completeDerivedFields();
    return grade;
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

  void _completeDerivedFields() {
    final numericScore = RegExp(r'\d+').firstMatch(original)?.group(0);
    hundredPoint =
        _toHundredPoint[original] ?? int.tryParse(numericScore ?? '') ?? 0;
    fourPoint = fivePoint > 4.0 ? (_toFourPoint[fivePoint] ?? 4.0) : fivePoint;
    fourPointLegacy = fivePoint > 4.0 ? 4.0 : fivePoint;
    creditIncluded = original != "弃修" &&
        original != "待录" &&
        original != "缓考" &&
        original != "无效";
    gpaIncluded = creditIncluded &&
        original != "合格" &&
        original != "不合格" &&
        !id.contains('xtwkc');
  }

  // 从主修成绩查询处爬取，因此打上主修标记
  factory Grade.fromMajor(Map<String, dynamic> json) {
    final grade = Grade(json)..major = true;
    return grade;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kch': kch,
        'semester': semester,
        'name': name,
        'credit': credit,
        'original': original,
        'fivePoint': fivePoint,
        'fourPoint': fourPoint,
        'fourPointLegacy': fourPointLegacy,
        'hundredPoint': hundredPoint,
        'gpaIncluded': gpaIncluded,
        'creditIncluded': creditIncluded,
      };

  Grade.fromJson(Map<String, dynamic> json)
      : id = asString(json['id']) ?? '',
        kch = asString(json['kch']),
        semester = asString(json['semester']),
        name = asString(json['name']) ?? '未知课程',
        credit = asDouble(json['credit']) ?? 0.0,
        original = asString(json['original']) ?? '',
        fivePoint = asDouble(json['fivePoint']) ?? 0.0,
        fourPoint = asDouble(json['fourPoint']) ?? 0.0,
        fourPointLegacy = asDouble(json['fourPointLegacy']) ?? 0.0,
        hundredPoint = asInt(json['hundredPoint']) ?? 0,
        gpaIncluded = asBool(json['gpaIncluded']) ?? false,
        creditIncluded = asBool(json['creditIncluded']) ?? false;
}
