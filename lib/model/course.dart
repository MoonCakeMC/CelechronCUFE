import 'package:celechron/model/exams_dto.dart';
import 'package:celechron/utils/json_utils.dart';

import 'exam.dart';
import 'grade.dart';
import 'session.dart';

class Course {
  String? id;
  // 教务课程号（如 "0830024"），跨接口统一的课程合并键；无 kch 的旧数据为 null
  String? kch;
  late String name;
  late bool confirmed;
  double credit = 0.0;

  Grade? grade;
  String? teacher;

  List<Session> sessions = [];
  List<Exam> exams = [];

  bool? online = false; // only used for grs
  String? type; // GRS-specific course type (e.g., "专业学位课")

  String get realId {
    // 优先展示课程号 kch；课表来源有标准 jxbmc 时展示带学年的课号形式
    if (id == null) return kch ?? '未知';
    var matchClass = RegExp(r'(\(.*\)-.*?)-.*').firstMatch(id!);
    var key = matchClass?.group(1);
    if (key == null) return kch ?? (id!.length < 22 ? id! : id!.substring(0, 22));
    return key;
  }

  /// 课程的全部教师（从各安排收集并去重，保证分周授课的多教师都能展示）
  List<String> get teachers {
    final teachers = <String>{};
    for (final session in sessions) {
      if (session.teacher.isNotEmpty && session.teacher != '未知教师') {
        teachers.add(session.teacher);
      }
    }
    final courseTeacher = teacher;
    if (courseTeacher != null &&
        courseTeacher.isNotEmpty &&
        courseTeacher != '未知教师') {
      teachers.add(courseTeacher);
    }
    return teachers.toList();
  }

  Course._empty()
      : name = '未知课程',
        confirmed = true;

  Course.fromExam(ExamDto examDto) {
    id = examDto.id;
    kch = examDto.kch;
    name = examDto.name;
    credit = examDto.credit;
    confirmed = true;
    exams.addAll(examDto.exams);
  }

  // used for grs
  Course.fromGrsSession(Session session) {
    id = session.id;
    name = session.name;
    confirmed = session.confirmed;
    teacher = session.teacher;
    if (session.credit != null) {
      credit = session.credit!;
    }
    if (session.online != null) {
      online = session.online!;
    }
    if (session.type != null) {
      type = session.type!;
    }
    sessions.add(session);
  }
  // used for zdbk
  Course.fromUgrsSessionWithoutID(Session session) {
    id = session.id;
    kch = session.kch;
    name = session.name;
    confirmed = session.confirmed;
    teacher = session.teacher;
    if (session.credit != null) {
      credit = session.credit!;
    }
    sessions.add(session);
  }

  Course.fromUgrsGrade(Grade this.grade)
      : id = grade.id,
        kch = grade.kch,
        name = grade.name,
        confirmed = true,
        credit = grade.credit;

  // used for grs
  // grs的获取课表接口和获取成绩接口拿到的id不同，一切id以课表接口为准
  Course.fromGrsGrade(Grade this.grade)
      : id = grade.id,
        kch = grade.kch,
        name = grade.name,
        confirmed = true,
        online = grade.isOnline,
        credit = grade.credit;

  /*Course.fromDingtalkTranscript(Map<String ,dynamic> transcript)
      : name = transcript['kcmc'] as String,
        credit = double.parse(transcript['xf'] as String),
        confirmed = true
  {
    grade = Grade.fromDingtalkTranscript(transcript);
    if (transcript.containsKey('xq')) {
      var semester = transcript['xq'] as String;
      firstHalf = semester.contains("秋") || semester.contains("春");
      secondHalf = semester.contains("冬") || semester.contains("夏");
    } else {
      firstHalf = false;
      secondHalf = false;
    }
  }*/

  void completeExam(ExamDto examDto) {
    credit = examDto.credit;
    exams.addAll(examDto.exams);
    // 如果调用了这个函数，则表明该Course对象可能是基于Session创建的。因此，id可能为null，必须补全。
    id ??= examDto.id;
    kch ??= examDto.kch;
    for (var e in sessions) {
      e.id = id;
    }
  }

  bool completeSession(Session session) {
    // 如果调用了这个函数，则表明该Course对象不是基于Session创建的。
    // 然而，通过成绩创建的Course可能没有id，因此我们这里判断下id是否为空，为空则使用sessioin中带的id
    // 后续只合并同一安排或相邻节次，避免重复接口记录生成重叠课程。
    id ??= session.id;
    kch ??= session.kch;
    session.id = id;
    teacher ??= session.teacher;
    // Transfer metadata from Session if available
    if (session.credit != null && credit == 0.0) {
      credit = session.credit!;
    }
    if (session.online != null && online == false) {
      online = session.online!;
    }
    if (session.type != null && type == null) {
      type = session.type!;
    }
    // 无排课时间的课程（如实践课）不参与时间合并，直接加入
    if (session.time.isEmpty) {
      sessions.add(session);
      return true;
    }
    // 判断两个安排是否为“同一时间安排”。中财课表常把同一课程拆成
    // 多条不同周次的安排（如国家安全教育第4/6/8/10周由不同教师授课），
    // 这些安排周次不同，必须保留为独立 session，不能当作重复记录合并。
    bool sameSchedule(Session a, Session b) {
      if (a.dayOfWeek != b.dayOfWeek ||
          a.oddWeek != b.oddWeek ||
          a.evenWeek != b.evenWeek ||
          a.location != b.location ||
          a.customRepeat != b.customRepeat) {
        return false;
      }
      if (a.customRepeat) {
        if (a.customRepeatWeeks.length != b.customRepeatWeeks.length) {
          return false;
        }
        for (var i = 0; i < a.customRepeatWeeks.length; i++) {
          if (a.customRepeatWeeks[i] != b.customRepeatWeeks[i]) return false;
        }
      }
      return true;
    }

    if (sessions.any((e) =>
        sameSchedule(e, session) && e.time.contains(session.time.first))) {
      // 观察到修改过某短学期上课周数的长学期课程出现秋+冬两个session
      // 合并学期类型
      var currentSession = sessions.firstWhere((e) =>
          sameSchedule(e, session) && e.time.contains(session.time.first));
      currentSession.firstHalf = currentSession.firstHalf || session.firstHalf;
      currentSession.secondHalf =
          currentSession.secondHalf || session.secondHalf;
      return false;
    }
    if (sessions.any((e) =>
        sameSchedule(e, session) && (e.time.last + 1 == session.time.first))) {
      var incompleteSession = sessions.firstWhere((e) =>
          sameSchedule(e, session) && (e.time.last + 1 == session.time.first));
      incompleteSession.time.addAll(session.time);
      return false;
    } else {
      //used for grs
      if (online == true && session.location == null) {
        session.location = "线上";
      }
      sessions.add(session);
      return true;
    }
  }

  void completeGrade(Grade grade) {
    credit = grade.credit;
    this.grade = grade;
    kch ??= grade.kch;
    // used for grs online course
    if (grade.isOnline == true && sessions.every((e) => e.location == null)) {
      for (var e in sessions) {
        e.location = "线上";
      }
      online = true;
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'kch': kch,
      'name': name,
      'confirmed': confirmed,
      'credit': credit,
      'grade': grade?.toJson(),
      'teacher': teacher,
      'sessions': sessions.map((e) => e.toJson()).toList(),
      'exams': exams.map((e) => e.toJson()).toList(),
      'online': online,
      'type': type,
    };
  }

  factory Course.fromJson(Map<String, dynamic> json) {
    final course = Course._empty()
      ..id = asString(json['id'])
      ..kch = asString(json['kch'])
      ..name = asString(json['name']) ?? '未知课程'
      ..confirmed = asBool(json['confirmed']) ?? true
      ..credit = asDouble(json['credit']) ?? 0.0
      ..teacher = asString(json['teacher'])
      ..online = asBool(json['online'])
      ..type = asString(json['type']);

    final gradeMap = asStringMap(json['grade']);
    if (gradeMap != null) {
      try {
        course.grade = Grade.fromJson(gradeMap);
      } catch (_) {}
    }
    for (final rawSession in asDynamicList(json['sessions']) ?? const []) {
      final sessionMap = asStringMap(rawSession);
      if (sessionMap == null) continue;
      try {
        final session = Session.fromJson(sessionMap);
        if (session.time.isNotEmpty) course.sessions.add(session);
      } catch (_) {}
    }
    for (final rawExam in asDynamicList(json['exams']) ?? const []) {
      final examMap = asStringMap(rawExam);
      if (examMap == null) continue;
      try {
        final exam = Exam.fromJson(examMap);
        if (exam.time.length >= 2) course.exams.add(exam);
      } catch (_) {}
    }
    return course;
  }
}
