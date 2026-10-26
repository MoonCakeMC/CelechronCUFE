import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';

import 'package:celechron/design/persistent_headers.dart';
import 'package:celechron/utils/hidden_course_store.dart';

/// 已屏蔽课程管理页：集中查看并取消课表中被屏蔽的课程。
class HiddenCoursePage extends StatelessWidget {
  const HiddenCoursePage({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoDynamicColor.resolve(
          CupertinoColors.systemGroupedBackground, context),
      child: CustomScrollView(
        slivers: [
          const CelechronSliverTextHeader(subtitle: '已屏蔽课程'),
          SliverToBoxAdapter(
            // 用 Obx 监听屏蔽列表，取消屏蔽后列表即时刷新
            child: Obx(() {
              final hidden = HiddenCourseStore.all;
              if (hidden.isEmpty) {
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                  child: Text(
                    '暂无屏蔽课程。可在课程详情中开启“从课表中屏蔽”。',
                    style: TextStyle(
                      color: CupertinoDynamicColor.resolve(
                          CupertinoColors.secondaryLabel, context),
                      fontSize: 14,
                    ),
                  ),
                );
              }
              return CupertinoListSection.insetGrouped(
                margin: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 10),
                additionalDividerMargin: 2,
                children: <CupertinoListTile>[
                  for (final entry in hidden.entries)
                    CupertinoListTile(
                      title: Text(entry.value),
                      trailing: CupertinoButton(
                        padding: EdgeInsets.zero,
                        child: const Text('取消屏蔽'),
                        onPressed: () => HiddenCourseStore.setHidden(
                            entry.key, entry.value, false),
                      ),
                    ),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }
}
