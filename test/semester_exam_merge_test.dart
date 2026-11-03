import 'package:celechron/model/exam.dart';
import 'package:celechron/model/exams_dto.dart';
import 'package:celechron/model/semester.dart';
import 'package:flutter_test/flutter_test.dart';

// 构造用于合并测试的考试对象。
Exam _buildExam({
  required String? seat,
  required DateTime start,
  String location = '教学楼 101',
}) {
  final exam = Exam.empty()
    ..id = 'course-1'
    ..name = '测试课程'
    ..type = ExamType.finalExam
    ..time = [start, start.add(const Duration(hours: 2))]
    ..location = location;
  // seat 为 null 时模拟接口缺少 zwh 字段。
  exam.seat = seat;
  return exam;
}

// 构造仅包含一场考试的学期。
Semester _buildSemester(Exam exam, {String semesterId = '2025-1'}) {
  final dto = ExamDto.empty()
    ..id = 'course-1'
    ..kch = 'KCH1'
    ..semester = semesterId
    ..name = '测试课程'
    ..credit = 2
    ..exams = [exam];
  final semester = Semester('2025-2026秋');
  semester.addExamWithSemester(dto, semesterId);
  return semester;
}

void main() {
  test('合并刷新时用新座位号覆盖旧错误座位号', () {
    final start = DateTime(2026, 1, 20, 8);
    final oldSemester = _buildSemester(_buildExam(seat: '1', start: start));
    final newSemester = _buildSemester(_buildExam(seat: '69', start: start));

    oldSemester.mergePartialFrom(newSemester);

    expect(oldSemester.exams, hasLength(1));
    expect(oldSemester.exams.single.seat, '69');
    // 课程内的考试对象也必须同步覆盖。
    expect(oldSemester.courses.values.single.exams.single.seat, '69');
  });

  test('新座位号为空时也能清除旧错误座位号', () {
    final start = DateTime(2026, 1, 21, 8);
    final oldSemester = _buildSemester(_buildExam(seat: '2', start: start));
    final newSemester = _buildSemester(_buildExam(seat: null, start: start));

    oldSemester.mergePartialFrom(newSemester);

    expect(oldSemester.exams.single.seat, isNull);
    expect(oldSemester.courses.values.single.exams.single.seat, isNull);
  });

  test('考试时间调整时仍按课程和类型覆盖而不是新增重复记录', () {
    final oldStart = DateTime(2026, 1, 22, 8);
    final newStart = DateTime(2026, 1, 22, 10);
    final oldSemester = _buildSemester(_buildExam(seat: '3', start: oldStart));
    final newSemester = _buildSemester(_buildExam(seat: '48', start: newStart));

    oldSemester.mergePartialFrom(newSemester);

    expect(oldSemester.exams, hasLength(1));
    expect(oldSemester.exams.single.seat, '48');
    expect(oldSemester.exams.single.time.first, newStart);
  });
}
