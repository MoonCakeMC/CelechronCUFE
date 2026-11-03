import 'package:celechron/model/exam.dart';
import 'package:flutter_test/flutter_test.dart';

// 核验正方考试座位号字段：zwh 才是座位号，row_id 只是表格行标识。
void main() {
  test('期末考试使用 zwh 作为座位号', () {
    final exams = Exam.parseExamsFromZdbk(
      {
        'kssj': '2024-01-20 08:00-10:00',
        'cdmc': '教学楼 101',
        'zwh': '69',
        'row_id': '1',
      },
      'course-1',
      '测试课程',
    );

    expect(exams, hasLength(1));
    expect(exams.single.type, ExamType.finalExam);
    expect(exams.single.seat, '69');
  });

  test('期中考试使用 zwh 作为座位号', () {
    final exams = Exam.parseExamsFromZdbk(
      {
        'qzkssj': '2023-11-16 14:00-16:00',
        'cdmc': '教学楼 202',
        'zwh': '48',
        'row_id': '2',
      },
      'course-2',
      '测试课程',
    );

    expect(exams, hasLength(1));
    expect(exams.single.type, ExamType.midterm);
    expect(exams.single.seat, '48');
  });

  test('缺少 zwh 时不能把 row_id 当作座位号', () {
    final exams = Exam.parseExamsFromZdbk(
      {
        'kssj': '2024-01-21 08:00-10:00',
        'cdmc': '教学楼 303',
        'row_id': '3',
      },
      'course-3',
      '测试课程',
    );

    expect(exams, hasLength(1));
    expect(exams.single.seat, isNull);
  });
}
