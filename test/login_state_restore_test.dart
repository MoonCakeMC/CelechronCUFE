import 'dart:io';

import 'package:celechron/database/database_helper.dart';
import 'package:celechron/model/scholar.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

// 覆盖“Hive 仍有登录标记、但安全存储凭据丢失”的启动恢复场景。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late DatabaseHelper db;

  setUpAll(() async {
    // 每个测试文件使用独立临时目录，避免污染真实 Hive 数据。
    tempDir = await Directory.systemTemp.createTemp('celechron_login_state');
    Hive.init(tempDir.path);
    db = DatabaseHelper();
    await db.init();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() async {
    // 每个用例重置安全存储 Mock 与 Hive 中的 Scholar。
    FlutterSecureStorage.setMockInitialValues({});
    await db.scholarBox.clear();
  });

  test('Hive 有登录标记但安全存储无凭据时降级为未登录', () async {
    // 模拟 Scholar JSON 中的 isLogan=true，但 username/password 未落盘。
    final cached = Scholar()..isLogan = true;
    await db.scholarBox.put('user', cached);

    final restored = await db.getScholar();

    expect(restored.isLogan, isFalse);
    expect(restored.username, isNull);
  });

  test('安全存储有凭据时恢复登录状态', () async {
    FlutterSecureStorage.setMockInitialValues({
      'username': '20260001',
      'password': 'secret',
    });
    final cached = Scholar()..isLogan = true;
    await db.scholarBox.put('user', cached);

    final restored = await db.getScholar();

    expect(restored.username, '20260001');
    expect(restored.password, 'secret');
    expect(restored.isLogan, isTrue);
  });

  test('setScholar 不会用 null 凭据删除已有账号密码', () async {
    FlutterSecureStorage.setMockInitialValues({
      'username': '20260001',
      'password': 'secret',
    });

    // 空 Scholar 的 username/password 为 null，原实现会借此删除安全存储 key。
    await db.setScholar(Scholar());

    const storage = FlutterSecureStorage();
    expect(await storage.read(key: 'username'), '20260001');
    expect(await storage.read(key: 'password'), 'secret');
  });
}
