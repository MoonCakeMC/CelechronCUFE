import 'dart:convert';
import 'dart:io';
import 'package:get/get.dart';

import 'package:celechron/database/database_helper.dart';

class Fuse {
  late DateTime lastUpdateTime;

  final bool isBeta = false;
  final version = [1, 3, 0];
  final build = 2;
  List<int>? remoteVersion;
  int? remoteBuild;
  bool hasNewVersion = false;

  final HttpClient _httpClient = HttpClient();
  final DatabaseHelper _db = Get.find<DatabaseHelper>(tag: 'db');

  String get displayVersion =>
      '${version.join('.')}_CUFE${isBeta ? ' beta' : ''}';

  Fuse() {
    lastUpdateTime = DateTime(2001, 1, 1);
  }

  Future<String?> checkUpdate() async {
    try {
      if (lastUpdateTime
          .isAfter(DateTime.now().subtract(const Duration(days: 1)))) {
        return null;
      }

      var request = await _httpClient
          .getUrl(Uri.parse(
              "https://oss-2.147483648.xyz/celechroncufe/latest_version.json"))
          .timeout(const Duration(seconds: 8));
      var response = await request.close().timeout(const Duration(seconds: 8));
      var jsonStr = await response.transform(utf8.decoder).join();
      var jsonMap = jsonDecode(jsonStr);

      String? remoteVerStr;
      if (Platform.isAndroid) {
        remoteVerStr = jsonMap['android'];
      } else if (Platform.isIOS) {
        remoteVerStr = jsonMap['ios'];
      } else if (Platform.isWindows) {
        remoteVerStr = jsonMap['windows'];
      }

      if (remoteVerStr != null) {
        remoteVerStr = remoteVerStr.trim();
        var match = RegExp(r'[0-9.]+').firstMatch(remoteVerStr);
        if (match != null) {
          remoteVersion =
              match.group(0)!.split('.').map((e) => int.parse(e)).toList();
          remoteBuild = 1;
          hasNewVersion =
              _compareVersion(remoteVerStr.toLowerCase().contains('beta'));
        }
      }
      lastUpdateTime = DateTime.now();
      await _db.setFuse(this);

      if (hasNewVersion) {
        return "有新版本可用";
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  bool _compareVersion(bool remoteIsBeta) {
    if (remoteVersion == null || remoteBuild == null) {
      return false;
    }
    if (remoteVersion![0] > version[0]) {
      return true;
    } else if (remoteVersion![0] == version[0]) {
      if (remoteVersion![1] > version[1]) {
        return true;
      } else if (remoteVersion![1] == version[1]) {
        if (remoteVersion![2] > version[2]) {
          return true;
        } else if (remoteVersion![2] == version[2]) {
          if (remoteBuild! > build) {
            return true;
          } else if (remoteBuild == build) {
            if (isBeta && !remoteIsBeta) {
              return true;
            }
          }
        }
      }
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
        'lastUpdateTime': lastUpdateTime.toIso8601String(),
      };

  Fuse.fromJson(Map<String, dynamic> json) {
    lastUpdateTime = DateTime.parse(json['lastUpdateTime']);
  }
}
