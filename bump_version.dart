import 'dart:io';

void main() {
  final pubspecFile = File('pubspec.yaml');
  final fuseFile = File('lib/worker/fuse.dart');

  if (!pubspecFile.existsSync() || !fuseFile.existsSync()) {
    print('Error: pubspec.yaml or lib/worker/fuse.dart not found.');
    return;
  }

  final pubspecContent = pubspecFile.readAsStringSync();
  final versionMatch = RegExp(r'version:\s+(\d+)\.(\d+)\.(\d+)\+(\d+)').firstMatch(pubspecContent);

  if (versionMatch == null) {
    print('Error: Could not parse version from pubspec.yaml');
    return;
  }

  int major = int.parse(versionMatch.group(1)!);
  int minor = int.parse(versionMatch.group(2)!);
  int patch = int.parse(versionMatch.group(3)!);
  int build = int.parse(versionMatch.group(4)!);

  print('=========================================');
  print('当前版本 / Current Version: $major.$minor.$patch+$build');
  print('=========================================');
  print('请选择要升级的版本号部分 / Choose what to bump:');
  print('[1] 大版本 (Major) -> ${major + 1}.0.0+1');
  print('[2] 小版本 (Minor) -> $major.${minor + 1}.0+1');
  print('[3] 补丁版 (Patch) -> $major.$minor.${patch + 1}+1');
  print('[4] 构建号 (Build) -> $major.$minor.$patch+${build + 1}');
  print('[5] 不修改，直接打包 (Skip & Build)');
  print('');
  print('!! 警告: 如果你重置了 Build 号为 1，直接在手机上覆盖安装可能会因为 Android versionCode 变小而失败，需先卸载旧版 !!');
  stdout.write('请输入选项 (1-5): ');

  final choice = stdin.readLineSync()?.trim();

  if (choice == '5' || choice == null || choice.isEmpty) {
    print('跳过版本号修改。');
    return;
  }

  if (choice == '1') {
    major++;
    minor = 0;
    patch = 0;
    build = 1;
  } else if (choice == '2') {
    minor++;
    patch = 0;
    build = 1;
  } else if (choice == '3') {
    patch++;
    build = 1;
  } else if (choice == '4') {
    build++;
  } else {
    print('无效选项，跳过版本号修改。');
    return;
  }

  final newVersionStr = '$major.$minor.$patch+$build';
  print('正在更新版本号为 / Updating to: $newVersionStr');

  // Update pubspec.yaml
  final newPubspec = pubspecContent.replaceFirst(
    RegExp(r'version:\s+\d+\.\d+\.\d+\+\d+'),
    'version: $newVersionStr'
  );
  pubspecFile.writeAsStringSync(newPubspec);

  // Update fuse.dart
  final fuseContent = fuseFile.readAsStringSync();
  var newFuse = fuseContent.replaceFirst(
    RegExp(r'final\s+version\s*=\s*\[\d+,\s*\d+,\s*\d+\];'),
    'final version = [$major, $minor, $patch];'
  );
  newFuse = newFuse.replaceFirst(
    RegExp(r'final\s+build\s*=\s*\d+;'),
    'final build = $build;'
  );
  fuseFile.writeAsStringSync(newFuse);

  // Update latest_version.json
  final latestVersionFile = File('latest_version.json');
  if (!latestVersionFile.existsSync()) {
    latestVersionFile.writeAsStringSync('{\n  "android": "$newVersionStr",\n  "ios": "$newVersionStr",\n  "windows": "$newVersionStr"\n}');
  } else {
    String jsonStr = latestVersionFile.readAsStringSync();
    jsonStr = jsonStr.replaceFirst(RegExp(r'"android"\s*:\s*"[^"]+"'), '"android": "$newVersionStr"');
    latestVersionFile.writeAsStringSync(jsonStr);
  }

  print('版本号更新成功！');
}
