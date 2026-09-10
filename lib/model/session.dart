import 'package:celechron/utils/json_utils.dart';

class Session {
  String? id;
  late String name;
  late String teacher;
  String? teacherId; // GRS teacher ID for detail API calls
  String? location;
  bool confirmed;
  int dayOfWeek;
  late List<int> time;

  // firstHalf : 秋/春 需要上课
  // secondHalf: 夏/冬 需要上课
  // 举例：秋冬学期的课程，firstHalf为true，secondHalf也为true
  // CUFE 只有一个学段，默认全覆盖
  bool firstHalf = true;
  bool secondHalf = true;

  // oddWeek:  单周 需要上课
  // evenWeek: 双周 需要上课
  // 举例：单双周的课程，oddWeek为true，evenWeek也为true
  bool oddWeek;
  bool evenWeek;

  // 自定义单双周。目前仅在研究生课程中出现。
  bool customRepeat = false;
  List<int> customRepeatWeeks = [];

  // GRS course metadata (used when creating Course)
  double? credit;
  bool? online;
  String? type;

  // 教务课程号（如 "0830024"），跨接口（课表/成绩/考试）统一的课程合并键
  String? kch;

  // 是否显示在课表网格中。教务网“其他课程”（实践课等）没有具体时间地点，
  // 仅进入课程列表，不占用课表网格。
  bool showOnTimetable = true;

  String get semesterId => id!.substring(1, 12);

  static const String dayMap = '零一二三四五六日';

  /// 按请求的学期参数设置上半/下半学期归属：
  /// 中财长学期分秋（xqm=1）与春（xqm=2）两个独立学期，
  /// 秋学期课程记为 firstHalf，春学期课程记为 secondHalf。
  /// 其余参数值不做修改（研究生链路由 grs_new 自行设置）。
  static void applySemesterHalf(Session session, String? semester) {
    switch (semester) {
      case '1':
        session.firstHalf = true;
        session.secondHalf = false;
        break;
      case '2':
        session.firstHalf = false;
        session.secondHalf = true;
        break;
      default:
        break;
    }
  }

  Session.empty()
      : confirmed = true,
        oddWeek = false,
        evenWeek = false,
        dayOfWeek = 1;

  /*Session.fromAppService(Map<String, dynamic> json)
      : id = RegExp(r'(.*?-){5}\d+(?=.*\d{10})')
            .firstMatch(json['kcid'] as String)!
            .group(0)!,
        name = json['mc'],
        teacher = json['jsxm'],
        confirmed = (json['sfqd'] as int) == 1,
        dayOfWeek = json['xqj'],
        oddWeek = !json['zcxx'].contains("双"),
        evenWeek = !json['zcxx'].contains("单"),
        time = (json['jc'] as List<dynamic>).map((e) => int.parse(e)).toList(),
        location = json['skdd'] {
    if (json.containsKey('xq')) {
      var semester = json['xq'] as String;
      firstHalf = semester.contains("秋") || semester.contains("春");
      secondHalf = semester.contains("冬") || semester.contains("夏");
    }
  }*/

  factory Session.fromZdbk(Map<String, dynamic> json) {
    // 中财教务网课表条目解析，兼容两类接口：
    // 1. 个人课表接口 xskbcx_cxXsKb（app 课表主数据源，字段以 get_info.py
    //    中 get_schedule 为准：kcmc/xm/kch_id/jc/zcd/cdmc/jxbmc/xf/xqj 等）；
    // 2. 班级课表接口 bjkbdy_cxBjKb（兜底，含 zcds/jcs 等展开字段）。
    // 另外保留旧版 zdbk 结构兼容：kcb 将课程名、教学班、教师和地点编码在
    // HTML 换行块中；xxq 表示半学期，djj/skcd 分别提供起始节次和连续节数。
    final session = Session.empty()
      ..id = asString(json['jxbmc']) ?? asString(json['jxb_id']) ?? asString(json['kch_id']) ?? asString(json['kch']) ?? asString(json['id'])
      ..kch = asString(json['kch'])
      ..credit = asDouble(json['xf'])
      ..confirmed = asString(json['sfqd']) != '0'
      ..dayOfWeek = asInt(json['xqj']) ?? 1
      ..oddWeek = asString(json['dsz']) != '1'
      ..evenWeek = asString(json['dsz']) != '0'
      ..name = '未知课程'
      ..teacher = '未知教师'
      ..time = <int>[];
    //名称、教师、地点
    final courseBlock = asString(json['kcb']);
    if (courseBlock != null) {
      var nameTeacherPosition = RegExp(r'(.*?)<br>(.*?)<br>(.*?)<br>(.*?)zwf')
          .firstMatch(courseBlock);
      if (nameTeacherPosition != null) {
        session.name = nameTeacherPosition.group(1)!.replaceAll('(', '（').replaceAll(')', '）');
        session.teacher = nameTeacherPosition.group(3) ?? '未知教师';
        session.location = nameTeacherPosition.group(4) == '' ? null : nameTeacherPosition.group(4);
      }
    }
    
    // 如果 kcb 解析失败（中财可能不返回 kcb HTML块），回退到原始字段。
    // 教务数据中 kcmc 可能带前导/尾随空格（如 " 国家安全教育"），统一 trim。
    if (session.name == '未知课程') {
      session.name = (asString(json['kcmc']) ?? '未知课程')
          .replaceAll('(', '（')
          .replaceAll(')', '）')
          .trim();
      session.teacher =
          (asString(json['xm']) ?? asString(json['jsxm']) ?? '未知教师')
              .trim();
      session.location = asString(json['cdmc'])?.trim();
    }
    // 短学期 or 长学期
    final semester = asString(json['xxq']);
    if (semester != null) {
      session.firstHalf = semester.contains("秋") || semester.contains("春");
      session.secondHalf = semester.contains("冬") || semester.contains("夏");
    }
    // 第几节
    final initial = asInt(json['djj']);
    final duration = asInt(json['skcd']);
    if (initial != null && duration != null && duration > 0) {
      session.time = List<int>.generate(duration, (index) => initial + index);
    } else {
      final jcs = asString(json['jcs']) ?? asString(json['jc']);
      if (jcs != null) {
        final matchRange = RegExp(r'(\d+)-(\d+)').firstMatch(jcs);
        final matchSingle = RegExp(r'^(\d+)').firstMatch(jcs);
        if (matchRange != null) {
          final start = int.parse(matchRange.group(1)!);
          final end = int.parse(matchRange.group(2)!);
          session.time = List<int>.generate(end - start + 1, (index) => start + index);
        } else if (matchSingle != null) {
          final val = int.parse(matchSingle.group(1)!);
          session.time = [val];
        }
      }
    }
    if (session.time.isEmpty) {
      throw const FormatException('课表条目缺少有效节次');
    }

    // 周次：中财接口返回 zcds（已展开的周列表，如 "4,13,14,15,16,17,18"，
    // 单双周已体现在列表中），优先使用；否则回退解析 zcd 字符串。
    final zcds = asString(json['zcds']);
    final zcd = asString(json['zcd']);
    if (zcds != null && zcds.isNotEmpty) {
      session.customRepeat = true;
      session.customRepeatWeeks = _parseZcds(zcds);
    } else if (zcd != null && zcd.isNotEmpty) {
      session.customRepeat = true;
      session.customRepeatWeeks = _parseZcd(zcd);
    }
    // 若接口同时提供 dsz（0=双周，1=单周），按单双周过滤展开的周列表，
    // 防止 zcd 未标注单双周时把全部周次都当作上课周。
    final dsz = asString(json['dsz']);
    if (session.customRepeatWeeks.isNotEmpty && (dsz == '0' || dsz == '1')) {
      session.customRepeatWeeks = session.customRepeatWeeks
          .where((week) => dsz == '0' ? week.isEven : week.isOdd)
          .toList();
    }

    return session;
  }

  /// 解析中财接口返回的 zcds 字段（逗号分隔的已展开周次列表，如 "4,13,14,15"）
  static List<int> _parseZcds(String zcds) {
    final weeks = <int>{};
    for (var part in zcds.split(',')) {
      part = part.replaceAll('\u5468', '').trim();
      final w = int.tryParse(part);
      if (w != null) weeks.add(w);
    }
    final sorted = weeks.toList()..sort();
    return sorted;
  }

  static List<int> _parseZcd(String zcd) {
    final weeks = <int>{};
    for (var part in zcd.split(',')) {
      // 清理“周”“第”“单”“双”等中文标记，保留纯数字或数字范围
      part = part
          .replaceAll('\u5468', '') // 周
          .replaceAll('\u7b2c', '') // 第
          .trim();
      bool onlyOdd = part.contains('(\u5355)');
      bool onlyEven = part.contains('(\u53cc)');
      part = part.replaceAll('(\u5355)', '').replaceAll('(\u53cc)', '').trim();
      if (part.contains('-')) {
        final bounds = part.split('-');
        if (bounds.length == 2) {
          final start = int.tryParse(bounds[0]) ?? 0;
          final end = int.tryParse(bounds[1]) ?? 0;
          if (start > 0 && end >= start) {
            for (var w = start; w <= end; w++) {
              if (onlyOdd && w % 2 == 0) continue;
              if (onlyEven && w % 2 == 1) continue;
              weeks.add(w);
            }
          }
        }
      } else {
        final w = int.tryParse(part);
        if (w != null) weeks.add(w);
      }
    }
    final sorted = weeks.toList()..sort();
    return sorted;
  }

  /// 解析中财课表接口 sjkList 中的“其他课程”（实践课等，无具体时间地点）。
  /// 文本格式示例：“大学生安全教育★董笑含(共15周)/4-18周”
  factory Session.fromZdbkSjkList(String qtkcgs) {
    final session = Session.empty()
      ..confirmed = true
      ..dayOfWeek = 1
      ..time = <int>[]
      ..location = '未排地点'
      ..customRepeat = true
      ..customRepeatWeeks = <int>[];

    // 提取周次部分（“/”之后的内容，如 “4-18周” 或 “11-13周”）
    final slashIndex = qtkcgs.indexOf('/');
    final weekText = slashIndex >= 0 ? qtkcgs.substring(slashIndex + 1) : '';
    if (weekText.isNotEmpty) {
      session.customRepeatWeeks = _parseZcd(weekText);
    }

    // 提取课程名与教师。格式为“课程名★教师名(共N周)”，
    // 课程名与教师以 ★（讲课）或 ●（实践）分隔。
    final namePart = slashIndex >= 0 ? qtkcgs.substring(0, slashIndex) : qtkcgs;
    final bracketIndex = namePart.indexOf('(');
    final nameTeacher = bracketIndex >= 0
        ? namePart.substring(0, bracketIndex)
        : namePart;
    final segments =
        nameTeacher.split(RegExp('[\u2605\u25cf]')).map((e) => e.trim());
    var name = segments.isEmpty ? '' : segments.first;
    var teacher = segments.length > 1 ? segments.elementAt(1) : '';
    if (name.isEmpty) name = namePart.trim().isEmpty ? '未知课程' : namePart.trim();
    session.name = name.replaceAll('(', '\uff08').replaceAll(')', '\uff09');
    session.teacher = teacher.isEmpty
        ? '未知教师'
        : teacher.replaceAll('(', '\uff08').replaceAll(')', '\uff09');
    session.id = '${session.name}${session.teacher}';
    // 其他课程没有排课时间，不显示在课表网格中
    session.showOnTimetable = false;
    return session;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kch': kch,
        'name': name,
        'teacher': teacher,
        'teacherId': teacherId,
        'confirmed': confirmed,
        'firstHalf': firstHalf,
        'secondHalf': secondHalf,
        'oddWeek': oddWeek,
        'evenWeek': evenWeek,
        'day': dayOfWeek,
        'time': time,
        'location': location,
        'customRepeat': customRepeat,
        'customRepeatWeeks': customRepeatWeeks,
        'credit': credit,
        'online': online,
        'type': type,
        'showOnTimetable': showOnTimetable,
      };

  Session.fromJson(Map<String, dynamic> json)
      : id = asString(json['id']),
        name = asString(json['name']) ?? '未知课程',
        teacher = asString(json['teacher']) ?? '未知教师',
        teacherId = asString(json['teacherId']),
        confirmed = asBool(json['confirmed']) ?? true,
        firstHalf = asBool(json['firstHalf']) ?? false,
        secondHalf = asBool(json['secondHalf']) ?? false,
        oddWeek = asBool(json['oddWeek']) ?? true,
        evenWeek = asBool(json['evenWeek']) ?? true,
        dayOfWeek = asInt(json['day']) ?? 1,
        time = (asDynamicList(json['time']) ?? const [])
            .map(asInt)
            .whereType<int>()
            .toList(),
        location = asString(json['location']),
        customRepeat = asBool(json['customRepeat']) ?? false,
        customRepeatWeeks =
            (asDynamicList(json['customRepeatWeeks']) ?? const [])
                .map(asInt)
                .whereType<int>()
                .toList(),
        credit = asDouble(json['credit']),
        online = asBool(json['online']),
        type = asString(json['type']),
        kch = asString(json['kch']),
        showOnTimetable = asBool(json['showOnTimetable']) ?? true;

  String get chineseTime {
    // 其他课程（实践课等）没有排课时间，直接返回提示
    if (time.isEmpty) return '时间未排';
    var timeString =
        '${(oddWeek & evenWeek) ? '' : oddWeek ? '单 - ' : '双 - '}周${dayMap[dayOfWeek]}第';
    for (var i = 0; i < time.length; i++) {
      timeString += time[i].toString();
      if (i != time.length - 1) {
        timeString += ', ';
      }
    }
    timeString.trimRight();
    timeString += '节';
    return timeString;
  }

  /// 紧凑的周次描述，如“4-18周”“第4周”“4周,13-18周”。
  /// 严格按 customRepeatWeeks 展示，不做任何推算。
  String get chineseWeeks {
    if (customRepeatWeeks.isEmpty) {
      return oddWeek && evenWeek
          ? '每周'
          : oddWeek
              ? '单周'
              : evenWeek
                  ? '双周'
                  : '无';
    }
    final parts = <String>[];
    var start = customRepeatWeeks.first;
    var prev = start;
    for (var i = 1; i < customRepeatWeeks.length; i++) {
      final week = customRepeatWeeks[i];
      if (week == prev + 1) {
        prev = week;
        continue;
      }
      parts.add(start == prev ? '第$start周' : '$start-$prev周');
      start = week;
      prev = week;
    }
    parts.add(start == prev ? '第$start周' : '$start-$prev周');
    return parts.join(',');
  }
}
