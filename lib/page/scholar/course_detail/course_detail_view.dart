import 'package:celechron/page/scholar/course_list/course_brief_card.dart';
import 'package:celechron/design/sub_title.dart';
import 'package:celechron/design/custom_colors.dart';
import 'package:celechron/design/persistent_headers.dart';
import 'package:celechron/design/round_rectangle_card.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:celechron/model/course.dart';

import 'package:celechron/model/exam.dart';
import 'package:celechron/model/session.dart';
import 'package:celechron/model/scholar.dart';

class CourseDetailPage extends StatelessWidget {
  final _scholar = Get.find<Rx<Scholar>>(tag: 'scholar');
  late final Course course;

  CourseDetailPage({String? courseId, Course? initialCourse, super.key}) {
    if (initialCourse != null) {
      course = initialCourse;
      return;
    }

    Course? found;
    if (courseId != null) {
      for (var sem in _scholar.value.semesters) {
        if (sem.courses.containsKey(courseId)) {
          found = sem.courses[courseId];
          break;
        }
        for (var c in sem.courses.values) {
          // 课程 map 的 key 为课程号(kch)，同时兼容旧 id/课号形式的 courseId
          if (c.id == courseId || c.realId == courseId || c.kch == courseId) {
            found = c;
            break;
          }
        }
        if (found != null) break;
      }
    }
    // Fallback if not found
    course = found ?? Course.fromUgrsSessionWithoutID(Session.empty());
  }

  Widget createSessionCard(context, List<Session> sessions) {
    // 无排课时间的课程（实践课等）排在最后
    sessions.sort((a, b) {
      if (a.time.isEmpty || b.time.isEmpty) {
        return a.time.isEmpty && b.time.isEmpty
            ? 0
            : a.time.isEmpty
                ? 1
                : -1;
      }
      return a.time.first.compareTo(b.time.first);
    });

    Widget infoRow(IconData icon, String text) {
      return Row(children: [
        Icon(
          icon,
          size: 14,
          color: CupertinoTheme.of(context)
              .textTheme
              .textStyle
              .color!
              .withOpacity(0.5),
        ),
        Expanded(
            child: Text(' $text',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: CupertinoTheme.of(context)
                      .textTheme
                      .textStyle
                      .color!
                      .withOpacity(0.75),
                  overflow: TextOverflow.ellipsis,
                )))
      ]);
    }

    // 根据时间分组，合并相同时间的安排
    Map<String, List<Session>> groupedSessions = {};
    for (var s in sessions) {
      String key = s.time.isEmpty
          ? 'empty_${s.hashCode}'
          : '${s.dayOfWeek}-${s.time.join(',')}';
      groupedSessions.putIfAbsent(key, () => []).add(s);
    }
    List<List<Session>> sessionGroups = groupedSessions.values.toList();

    String combineAttributes(
        List<Session> group, String Function(Session) extractor) {
      final attributes = group
          .map(extractor)
          .where((e) => e.isNotEmpty && e != '未知' && e != '未知地点' && e != '未知教师')
          .toSet()
          .toList();
      if (attributes.isEmpty) return '未知';
      return attributes.join('、');
    }

    String getBaseTimeString(Session s) {
      if (s.time.isEmpty) return '未知时间';
      return '周${Session.dayMap[s.dayOfWeek]} 第${s.time.join(', ')}节';
    }

    Widget sessionGroupBlock(List<Session> group) {
      Session baseSession = group.first;
      String timeTitle = getBaseTimeString(baseSession);
      String combinedTeachers = combineAttributes(group, (s) => s.teacher);
      String combinedWeeks = combineAttributes(group, (s) => s.chineseWeeks);
      String combinedLocations =
          combineAttributes(group, (s) => s.location ?? '');

      return Column(
        children: [
          Row(
            children: [
              Container(
                width: 12.0,
                height: 12.0,
                decoration: BoxDecoration(
                  color: TimeColors.colorFromClass(
                      baseSession.time.isEmpty ? 0 : baseSession.time.first),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8.0),
              Expanded(
                  child: Text(timeTitle,
                      style: CupertinoTheme.of(context)
                          .textTheme
                          .textStyle
                          .copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            overflow: TextOverflow.ellipsis,
                          ))),
            ],
          ),
          const SizedBox(height: 4.0),
          infoRow(CupertinoIcons.person_2_alt, '教师：$combinedTeachers'),
          infoRow(CupertinoIcons.calendar, '周次：$combinedWeeks'),
          infoRow(CupertinoIcons.location_solid, '地点：$combinedLocations'),
        ],
      );
    }

    return Column(
      children: [
        SubSubtitleRow(subtitle: '课时'),
        RoundRectangleCard(
            child: Padding(
          padding: const EdgeInsets.only(left: 8, right: 8),
          child: Column(children: [
            for (var i = 0; i < sessionGroups.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 24,
                  thickness: 1,
                  indent: 0,
                  endIndent: 0,
                  color: CupertinoDynamicColor.resolve(
                      CupertinoColors.systemFill, context),
                ),
              sessionGroupBlock(sessionGroups[i]),
            ],
          ]),
        ))
      ],
    );
  }

  Widget createExamCard(context, List<Exam> exams) {
    return Column(
      children: [
        SubSubtitleRow(subtitle: '考试'),
        RoundRectangleCard(
            child: Padding(
          padding: const EdgeInsets.only(left: 8, right: 8),
          child: Column(children: [
            Row(
              children: [
                Expanded(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 12.0,
                              height: 12.0,
                              decoration: BoxDecoration(
                                color: CupertinoColors.systemPink,
                                shape: exams[0].type == ExamType.midterm
                                    ? BoxShape.circle
                                    : BoxShape.rectangle,
                              ),
                            ),
                            const SizedBox(width: 8.0),
                            Expanded(
                                child: Text(exams[0].chineseTime,
                                    style: CupertinoTheme.of(context)
                                        .textTheme
                                        .textStyle
                                        .copyWith(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          overflow: TextOverflow.ellipsis,
                                        ))),
                          ],
                        ),
                        const SizedBox(height: 4.0),
                        Row(children: [
                          Icon(
                            CupertinoIcons.location_solid,
                            size: 14,
                            color: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .color!
                                .withOpacity(0.5),
                          ),
                          Expanded(
                              child: Text(' 地点：${exams[0].location ?? '未知'}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: CupertinoTheme.of(context)
                                        .textTheme
                                        .textStyle
                                        .color!
                                        .withOpacity(0.75),
                                    overflow: TextOverflow.ellipsis,
                                  )))
                        ]),
                        Row(children: [
                          Icon(
                            CupertinoIcons.map_pin_ellipse,
                            size: 14,
                            color: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .color!
                                .withOpacity(0.5),
                          ),
                          Expanded(
                              child: Text(' 座位：${exams[0].seat ?? '未知'}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: CupertinoTheme.of(context)
                                        .textTheme
                                        .textStyle
                                        .color!
                                        .withOpacity(0.75),
                                    overflow: TextOverflow.ellipsis,
                                  )))
                        ]),
                        if (exams[0].type == ExamType.midterm)
                          Row(children: [
                            Icon(
                              CupertinoIcons.doc_text,
                              size: 14,
                              color: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .color!
                                  .withOpacity(0.5),
                            ),
                            Expanded(
                                child: Text(' 类型：期中',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.normal,
                                      color: CupertinoTheme.of(context)
                                          .textTheme
                                          .textStyle
                                          .color!
                                          .withOpacity(0.75),
                                      overflow: TextOverflow.ellipsis,
                                    )))
                          ]),
                      ],
                    ),
                    for (var i = 1; i < exams.length; i++)
                      Column(
                        children: [
                          Divider(
                            height: 16,
                            thickness: 1,
                            indent: 0,
                            endIndent: 0,
                            color: CupertinoDynamicColor.resolve(
                                CupertinoColors.systemFill, context),
                          ),
                          Row(
                            children: [
                              Container(
                                width: 12.0,
                                height: 12.0,
                                decoration: BoxDecoration(
                                  color: CupertinoColors.systemPink,
                                  shape: exams[i].type == ExamType.midterm
                                      ? BoxShape.circle
                                      : BoxShape.rectangle,
                                ),
                              ),
                              const SizedBox(width: 8.0),
                              Expanded(
                                  child: Text(exams[i].chineseTime,
                                      style: CupertinoTheme.of(context)
                                          .textTheme
                                          .textStyle
                                          .copyWith(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            overflow: TextOverflow.ellipsis,
                                          ))),
                            ],
                          ),
                          const SizedBox(height: 4.0),
                          Row(children: [
                            Icon(
                              CupertinoIcons.location_solid,
                              size: 14,
                              color: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .color!
                                  .withOpacity(0.5),
                            ),
                            Expanded(
                                child: Text(' 地点：${exams[i].location ?? '未知'}',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.normal,
                                      color: CupertinoTheme.of(context)
                                          .textTheme
                                          .textStyle
                                          .color!
                                          .withOpacity(0.75),
                                      overflow: TextOverflow.ellipsis,
                                    )))
                          ]),
                          Row(children: [
                            Icon(
                              CupertinoIcons.map_pin_ellipse,
                              size: 14,
                              color: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .color!
                                  .withOpacity(0.5),
                            ),
                            Expanded(
                                child: Text(' 座位：${exams[i].seat ?? '未知'}',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.normal,
                                      color: CupertinoTheme.of(context)
                                          .textTheme
                                          .textStyle
                                          .color!
                                          .withOpacity(0.75),
                                      overflow: TextOverflow.ellipsis,
                                    )))
                          ]),
                          if (exams[i].type == ExamType.midterm)
                            Row(children: [
                              Icon(
                                CupertinoIcons.doc_text,
                                size: 14,
                                color: CupertinoTheme.of(context)
                                    .textTheme
                                    .textStyle
                                    .color!
                                    .withOpacity(0.5),
                              ),
                              Expanded(
                                  child: Text(' 类型：期中',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.normal,
                                        color: CupertinoTheme.of(context)
                                            .textTheme
                                            .textStyle
                                            .color!
                                            .withOpacity(0.75),
                                        overflow: TextOverflow.ellipsis,
                                      )))
                            ]),
                        ],
                      ),
                  ],
                )),
              ],
            ),
          ]),
        ))
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoDynamicColor.resolve(
          CupertinoColors.systemGroupedBackground, context),
      child: CustomScrollView(
        slivers: [
          const CelechronSliverTextHeader(subtitle: '课程详情'),
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.only(bottom: 5, left: 16, right: 16),
              child: Column(
                children: [
                  SubSubtitleRow(subtitle: '基本信息'),
                  CourseBriefCard(course: course),
                ],
              ),
            ),
          ),
          if (course.sessions.isNotEmpty)
            SliverToBoxAdapter(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                child: createSessionCard(context, course.sessions),
              ),
            ),
          if (course.exams.isNotEmpty)
            SliverToBoxAdapter(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                child: createExamCard(context, course.exams),
              ),
            ),
        ],
      ),
    );
  }
}
