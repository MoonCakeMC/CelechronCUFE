import 'package:celechron/model/semester.dart';
import 'package:celechron/model/session.dart';
import 'package:celechron/utils/hidden_course_store.dart';
import 'package:get/get.dart';
import 'package:celechron/model/scholar.dart';

class CourseScheduleController extends GetxController {
  final _scholar = Get.find<Rx<Scholar>>(tag: 'scholar');
  late final RxInt semesterIndex;
  late final RxBool firstOrSecondSemester;
  RxBool hideCourseInfomation = false.obs;

  Semester get semester => _scholar.value.semesters[semesterIndex.value];
  List<Semester> get semesters => _scholar.value.semesters;

  void init(String initialName, bool initialFirstOrSecondSemester) {
    semesterIndex = semesters.indexWhere((e) => e.name == initialName).obs;
    firstOrSecondSemester = initialFirstOrSecondSemester.obs;
  }

  CourseScheduleController({
    required String initialName,
    required bool initialFirstOrSecondSemester,
    required bool initialHideCourseInfomation,
  }) {
    init(initialName, initialFirstOrSecondSemester);
    hideCourseInfomation = initialHideCourseInfomation.obs;
  }

  // 课表按星期分组。这里在返回前统一剔除用户屏蔽的课程，
  // 使被屏蔽课程不再与其它课程生成“冲突课程”卡片。
  List<List<Session>> get sessionsByDayOfWeek => Session.filterHiddenTimetable(
      firstOrSecondSemester.value
          ? _scholar.value.semesters[semesterIndex.value].firstHalfTimetable
          : _scholar.value.semesters[semesterIndex.value].secondHalfTimetable,
      HiddenCourseStore.keys);
}
