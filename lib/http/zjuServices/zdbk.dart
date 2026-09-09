import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:celechron/utils/tuple.dart';
import 'package:flutter/foundation.dart';

import 'package:celechron/database/database_helper.dart';
import 'package:celechron/utils/gpa_helper.dart';
import 'package:celechron/model/grade.dart';
import 'package:celechron/model/session.dart';
import 'package:celechron/model/exams_dto.dart';
import 'package:celechron/design/captcha_input.dart';
import 'package:celechron/utils/global.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'exceptions.dart';
import 'response_utils.dart';

/// 本科教务网客户端；统一管理 CAS 业务会话、并发限流与按接口缓存降级。
class Zdbk {
  Cookie? _jSessionId;
  Cookie? _route;
  Cookie? _iPlanetDirectoryPro;
  String? _captcha;
  DatabaseHelper? _db;
  Future<bool>? _loginFuture;
  int _sessionGeneration = 0;
  int _activeSiteRequests = 0;
  final List<Completer<void>> _siteWaiters = [];

  set db(DatabaseHelper? db) {
    _db = db;
  }

  DateTime? get practiceScoresCacheUpdatedAt {
    final value = _db?.getCachedWebPage('zdbk_practiceScores_timestamp');
    return value == null ? null : DateTime.tryParse(value)?.toLocal();
  }

  Future<bool> login(HttpClient httpClient, Cookie? iPlanetDirectoryPro) async {
    if (iPlanetDirectoryPro == null) {
      throw AuthenticationExpiredException("教务网：统一身份认证凭据无效");
    }
    _iPlanetDirectoryPro = iPlanetDirectoryPro;
    // 同一客户端只建立一套 JSESSIONID/route，避免并发 CAS 回调互相覆盖。
    final pending = _loginFuture;
    if (pending != null) return await pending;
    final login = _doLogin(httpClient, iPlanetDirectoryPro);
    _loginFuture = login;
    try {
      return await login;
    } finally {
      if (identical(_loginFuture, login)) _loginFuture = null;
    }
  }

  Future<bool> _doLogin(
      HttpClient httpClient, Cookie iPlanetDirectoryPro) async {
    _captcha = null;
    _jSessionId = null;
    _route = null;
    
    Map<String, Cookie> accumulatedCookies = {};
    String currentUrl = "https://authserver.cufe.edu.cn/authserver/login?service=https%3A%2F%2Fxuanke.cufe.edu.cn%2Fsso%2Fjziotlogin";
    int redirectCount = 0;
    
    while (redirectCount < 15) {
      var request = await httpClient
          .getUrl(Uri.parse(currentUrl))
          .timeout(const Duration(seconds: 8),
              onTimeout: () => throw requestTimeout());
      request.followRedirects = false;
      
      // Inject accumulated cookies
      for (var cookie in accumulatedCookies.values) {
        request.cookies.add(cookie);
      }
      // Explicitly inject CASTGC if domain is authserver (WebVPN CAS callback might redirect here)
      if (Uri.parse(currentUrl).host == "authserver.cufe.edu.cn") {
        request.cookies.add(iPlanetDirectoryPro);
      }

      var response = await request.close().timeout(const Duration(seconds: 8),
          onTimeout: () => throw requestTimeout());
          
      // Save new cookies
      for (var cookie in response.cookies) {
        accumulatedCookies[cookie.name] = cookie;
      }

      if (response.statusCode >= 300 && response.statusCode < 400) {
        var nextLocation = response.headers.value(HttpHeaders.locationHeader);
        if (nextLocation == null) break;
        
        // CUFE sends http:// redirects from WebVPN ticketlogin, force upgrade to https to avoid firewall drop
        if (nextLocation.startsWith("http://")) {
          nextLocation = nextLocation.replaceFirst("http://", "https://");
        } else if (nextLocation.startsWith("/")) {
          final uri = Uri.parse(currentUrl);
          nextLocation = '${uri.scheme}://${uri.host}$nextLocation';
        }
        currentUrl = nextLocation;
        redirectCount++;
      } else {
        // HTTP 200 or other terminal state
        break;
      }
    }

    if (accumulatedCookies.containsKey('JSESSIONID')) {
      _jSessionId = accumulatedCookies['JSESSIONID'];
      if (accumulatedCookies.containsKey('route')) {
        _route = accumulatedCookies['route'];
      }
    } else {
      throw ExceptionWithMessage(
          "教务网登录无法获取 JSESSIONID；重定向最终停留在: $currentUrl");
    }

    _sessionGeneration++;
    return true;
  }

  void logout() {
    _jSessionId = null;
    _route = null;
    _iPlanetDirectoryPro = null;
    _captcha = null;
  }

  void _validateResponse(HttpClientResponse response, String responseText,
      {required String context,
      required Uri requestUri,
      bool expectJson = true,
      bool relogged = false,
      bool retried = false}) {
    try {
      validateResponse(
        response: response,
        body: responseText,
        context: context,
        expectJson: expectJson,
        requestUri: requestUri,
        relogged: relogged,
        retried: retried,
      );
    } on AuthenticationExpiredException catch (error) {
      throw SessionExpiredException(
        shortErrorText(error),
        details: detailedErrorText(error),
        originalError: error,
        stackTrace: error.stackTrace,
      );
    }
  }

  Future<void> _relogin(HttpClient httpClient) async {
    final iPlanetDirectoryPro = _iPlanetDirectoryPro;
    if (iPlanetDirectoryPro == null) {
      throw LoginExpiredException("教务网会话已过期，请重新登录");
    }
    await login(httpClient, iPlanetDirectoryPro);
  }

  Future<T> _withAutoRelogin<T>(HttpClient httpClient,
      Future<T> Function(bool relogged, bool retried) requestFactory) {
    return _withSitePermit(
      () => _withAutoReloginUnlocked(httpClient, requestFactory),
    );
  }

  Future<T> _withAutoReloginUnlocked<T>(HttpClient httpClient,
      Future<T> Function(bool relogged, bool retried) requestFactory) async {
    var relogged = false;
    for (var i = 0; i < 2; i++) {
      var generation = _sessionGeneration;
      var reloginAttempted = false;
      try {
        if (_jSessionId == null || _route == null) {
          reloginAttempted = true;
          await _relogin(httpClient);
          relogged = true;
          generation = _sessionGeneration;
        }
        return await requestFactory(relogged, i > 0);
      } on AuthenticationExpiredException catch (error) {
        if (i == 1 || reloginAttempted) {
          throw LoginExpiredException(
            "教务网会话已过期，请手动重新登录",
            details: detailedErrorText(error),
            originalError: error,
          );
        }
        // 若其它并发请求已更新会话，本请求直接复用，避免重复登录。
        if (_sessionGeneration == generation) {
          await _relogin(httpClient);
          relogged = true;
        }
      }
    }
    throw LoginExpiredException("教务网会话已过期，请手动重新登录");
  }

  Future<T> _withSitePermit<T>(Future<T> Function() action) async {
    // 限制同时访问教务站的请求数，避免刷新时多个模块共同放大瞬时压力。
    if (_activeSiteRequests >= 3) {
      final waiter = Completer<void>();
      _siteWaiters.add(waiter);
      await waiter.future;
    }
    _activeSiteRequests++;
    try {
      return await action();
    } finally {
      _activeSiteRequests--;
      if (_siteWaiters.isNotEmpty) {
        _siteWaiters.removeAt(0).complete();
      }
    }
  }

  _CachedList _cachedList(String cacheKey, String context) {
    // 缓存内容必须重新走与实时响应相同的解析器；损坏缓存视为不可用。
    final cached = _db?.getCachedWebPage(cacheKey);
    if (cached == null || cached.trim().isEmpty) {
      return const _CachedList([], false);
    }
    try {
      final cachedAt = _db?.getCachedWebPage('${cacheKey}_timestamp') ?? '<未知>';
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: context,
        operation: 'readCache',
        cacheUsed: true,
        message: '使用缓存；缓存时间=$cachedAt',
      );
      return _CachedList(
        decodeJsonList(cached, context: context),
        true,
        cachedAt: cachedAt,
      );
    } on Object catch (error, stackTrace) {
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: context,
        operation: 'readCache',
        cacheUsed: false,
        error: error,
        stackTrace: stackTrace,
      );
      return const _CachedList([], false);
    }
  }

  void _writeCache(String cacheKey, String value) {
    unawaited(Future.wait([
      _db?.setCachedWebPage(cacheKey, value) ?? Future<void>.value(),
      _db?.setCachedWebPage(
            '${cacheKey}_timestamp',
            DateTime.now().toUtc().toIso8601String(),
          ) ??
          Future<void>.value(),
    ]));
  }

  Exception _cacheAwareException(
    Exception exception,
    _CachedList cache,
    String context,
  ) {
    // 返回缓存时仍保留实时异常，并用降级标记告知上层不要清空旧数据。
    if (!cache.used) return exception;
    return CachedDataException(
      '$context：实时请求失败，已使用缓存',
      details: [
        '缓存时间：${cache.cachedAt ?? '<未知>'}',
        detailedErrorText(exception),
      ].join('\n'),
      originalError: exception,
      stackTrace:
          exception is ExceptionWithMessage ? exception.stackTrace : null,
    );
  }

  List<Grade> _parseGrades(Object? raw, String context, {bool major = false}) {
    final items = asDynamicList(raw) ?? const [];
    final grades = <Grade>[];
    for (var index = 0; index < items.length; index++) {
      final item = asStringMap(items[index]);
      if (item == null) {
        if (kDebugMode) {
          debugPrint('$context：跳过第 ${index + 1} 条成绩，条目不是对象');
        }
        continue;
      }
      try {
        final grade = major ? Grade.fromMajor(item) : Grade(item);
        grades.add(grade);
      } on Object catch (error, stackTrace) {
        if (kDebugMode) {
          debugPrint(
              '$context：跳过第 ${index + 1} 条成绩：${error.runtimeType}: $error\n$stackTrace');
        }
      }
    }
    return grades;
  }

  List<Session> _parseSessions(Object? raw, String context) {
    final items = asDynamicList(raw) ?? const [];
    final sessions = <Session>[];
    for (var index = 0; index < items.length; index++) {
      final item = asStringMap(items[index]);
      if (item == null ||
          asString(item['sfyjskc']) == '1') {
        continue;
      }
      try {
        // 缓存合并时给其他课程（实践课）打的标记；这些课程无时间地点，仅进课程列表
        if (asBool(item['_sjkCourse']) == true) {
          final qtkcgs =
              asString(item['qtkcgs']) ?? asString(item['sjkcgs']);
          if (qtkcgs == null || qtkcgs.trim().isEmpty) continue;
          sessions.add(Session.fromZdbkSjkList(qtkcgs));
        } else {
          sessions.add(Session.fromZdbk(item));
        }
      } on Object catch (error, stackTrace) {
        if (kDebugMode) {
          debugPrint(
              '$context：跳过第 ${index + 1} 条课程：${error.runtimeType}: $error\n$stackTrace');
        }
      }
    }
    return sessions;
  }

  /// 将 kbList 与其他课程 sjkList 合并为统一列表（sjkList 条目打上标记），
  /// 使实时解析与缓存降级路径使用同一解析器。
  List<dynamic> _combineTimetableItems(
      List<dynamic> kbItems, List<dynamic> sjkItems) {
    return <dynamic>[
      ...kbItems,
      for (final item in sjkItems)
        if (item is Map) {...item, '_sjkCourse': true}
    ];
  }

  List<ExamDto> _parseExams(Object? raw, String context) {
    final items = asDynamicList(raw) ?? const [];
    final exams = <ExamDto>[];
    for (var index = 0; index < items.length; index++) {
      final item = asStringMap(items[index]);
      if (item == null) continue;
      try {
        exams.add(ExamDto.fromZdbk(item));
      } on Object catch (error, stackTrace) {
        if (kDebugMode) {
          debugPrint(
              '$context：跳过第 ${index + 1} 条考试：${error.runtimeType}: $error\n$stackTrace');
        }
      }
    }
    return exams;
  }

  Future<Tuple<Exception?, Tuple<List<double>, String>>> getMajorGrade(
      HttpClient httpClient) async {
    return await _withAutoRelogin(httpClient, (relogged, retried) async {
      late HttpClientRequest request;
      late HttpClientResponse response;
      final uri = Uri.parse(
          "https://xuanke.cufe.edu.cn/jwglxt/zycjtj/xszgkc_cxXsZgkcIndex.html?doType=query&queryModel.showCount=5000");

      try {
        request = await httpClient.postUrl(uri).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout());
        request.headers
          ..add("Referer",
              "https://xuanke.cufe.edu.cn/jwglxt/xtgl/index_initMenu.html")
          ..set('Connection', 'close')
          ..add('User-Agent',
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36')
          ..add('Accept', 'application/json, text/javascript, */*; q=0.01')
          ..add('X-Requested-With', 'XMLHttpRequest');
        request.cookies.add(_jSessionId!);
        request.cookies.add(_route!);
        request.followRedirects = false;
        response = await request.close().timeout(const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout());

        var responseText =
            await readResponseBody(response, context: '教务网主修成绩接口');
        const context = '教务网主修成绩接口';
        _validateResponse(response, responseText,
            context: context,
            requestUri: uri,
            relogged: relogged,
            retried: retried);
        final payload = decodeJsonMap(responseText,
            context: '$context；HTTP ${response.statusCode}');
        final items = asDynamicList(payload['items']);
        if (items == null) {
          throw ExceptionWithMessage(
              '$context：缺少 items 数组；HTTP ${response.statusCode}'
              '；响应摘要：${responseSummary(responseText)}');
        }
        final grades = _parseGrades(items, context, major: true);
        var majorGpa = GpaHelper.calculateGpa(grades);
        _writeCache('zdbk_MajorGrade', jsonEncode(items));
        return Tuple(
            null, Tuple([majorGpa.item1[0], majorGpa.item2], responseText));
      } on Object catch (error, stackTrace) {
        if (error is AuthenticationExpiredException) rethrow;
        final exception = exceptionFrom(error,
            context: '教务网主修成绩接口',
            requestUri: uri,
            relogged: relogged,
            retried: retried,
            stackTrace: stackTrace);
        final cachedItems = _cachedList('zdbk_MajorGrade', '教务网主修成绩缓存');
        final grades = _parseGrades(cachedItems.data, '教务网主修成绩缓存', major: true);
        var majorGpa = GpaHelper.calculateGpa(grades);
        return Tuple(
            _cacheAwareException(exception, cachedItems, '教务网主修成绩'),
            Tuple([majorGpa.item1[0], majorGpa.item2],
                '{"items":${jsonEncode(cachedItems.data)},"limit":0}'));
      }
    });
  }

  Future<Tuple<Exception?, Iterable<Grade>>> getTranscript(
      HttpClient httpClient) async {
    return await _withAutoRelogin(httpClient, (relogged, retried) async {
      late HttpClientRequest request;
      late HttpClientResponse response;
      final uri = Uri.parse(
          "https://xuanke.cufe.edu.cn/jwglxt/cjcx/cjcx_cxDgXscj.html?doType=query&gnmkdm=N305005&queryModel.showCount=5000");

      try {
        request = await httpClient.postUrl(uri).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout());
        request.headers
          ..add("Referer",
              "https://xuanke.cufe.edu.cn/jwglxt/xtgl/index_initMenu.html")
          ..set('Connection', 'close')
          ..add('User-Agent',
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36')
          ..add('Accept', 'application/json, text/javascript, */*; q=0.01')
          ..add('X-Requested-With', 'XMLHttpRequest');
        request.cookies.add(_jSessionId!);
        request.cookies.add(_route!);
        request.followRedirects = false;
        response = await request.close().timeout(const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout());

        var responseText = await readResponseBody(response, context: '教务网成绩接口');
        const context = '教务网成绩接口';
        _validateResponse(response, responseText,
            context: context,
            requestUri: uri,
            relogged: relogged,
            retried: retried);
        final payload = decodeJsonMap(responseText,
            context: '$context；HTTP ${response.statusCode}');
        final items = asDynamicList(payload['items']);
        if (items == null) {
          throw ExceptionWithMessage(
              '$context：缺少 items 数组；HTTP ${response.statusCode}'
              '；响应摘要：${responseSummary(responseText)}');
        }
        final grades = _parseGrades(items, context);
        _writeCache('zdbk_Transcript', jsonEncode(items));
        return Tuple(null, grades);
      } on Object catch (error, stackTrace) {
        if (error is AuthenticationExpiredException) rethrow;
        final exception = exceptionFrom(error,
            context: '教务网成绩接口',
            requestUri: uri,
            relogged: relogged,
            retried: retried,
            stackTrace: stackTrace);
        final cached = _cachedList('zdbk_Transcript', '教务网成绩缓存');
        return Tuple(
          _cacheAwareException(exception, cached, '教务网成绩'),
          _parseGrades(cached.data, '教务网成绩缓存'),
        );
      }
    });
  }

  /// 获取学生个人课表（app 课表页的主数据源）。
  /// 接口地址以 get_info.py 中 get_schedule 为准：kbcx/xskbcx_cxXsKb.html，
  /// 响应 JSON 含 xsxx、kbList（kcmc/xm/kch_id/jc/zcd/cdmc/jxbmc/xf/xqj 等字段）
  /// 与 sjkList（qtkcgs 文本形式的其他课程/实践课）。
  Future<Tuple<Exception?, Iterable<Session>>> getTimetable(
      HttpClient httpClient, String year, String semester) async {
    return await _withAutoRelogin(httpClient, (relogged, retried) async {
      late HttpClientRequest request;
      late HttpClientResponse response;
      final uri =
          Uri.parse("https://xuanke.cufe.edu.cn/jwglxt/kbcx/xskbcx_cxXsKb.html?gnmkdm=N2151");

      try {
        for (var i = 0; i < 3; i++) {
          request = await httpClient.postUrl(uri).timeout(
              const Duration(seconds: 8),
              onTimeout: () => throw requestTimeout());
          request.headers
            ..add("Referer",
                "https://xuanke.cufe.edu.cn/jwglxt/xtgl/index_initMenu.html")
            ..set('Connection', 'close')
            ..add('User-Agent',
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36')
            ..add('Accept', 'application/json, text/javascript, */*; q=0.01');
          request.cookies.add(_jSessionId!);
          request.cookies.add(_route!);
          request.followRedirects = false;
          request.headers.contentType = ContentType(
              'application', 'x-www-form-urlencoded',
              charset: 'utf-8');
          final captchaStr = _captcha != null ? '&captcha_value=$_captcha' : '';
          final bodyBytes = utf8.encode('xnm=$year&xqm=$semester$captchaStr');
          request.headers.contentLength = bodyBytes.length;
          request.add(bodyBytes);
          response = await request.close().timeout(const Duration(seconds: 8),
              onTimeout: () => throw requestTimeout());

          var responseText =
              await readResponseBody(response, context: '教务网课表接口');
          print("\n=== RAW TIMETABLE JSON ===");
          print(responseText);
          print("==========================\n");
          final context = '教务网课表接口（学年 $year，学期 $semester，请求类型 课表）';
          _validateResponse(response, responseText,
              context: context,
              requestUri: uri,
              relogged: relogged,
              retried: retried);

          if (responseText.contains("captcha_error")) {
            _captcha = null;
            if (GlobalStatus.isFirstScreenReq) {
              throw ExceptionWithMessage("需要验证码");
            }
            var imageBytes = await getCaptcha(httpClient);
            var captcha = await ImageCodePortal.show(
                imageBytes: imageBytes,
                onRefresh: () async {
                  return await getCaptcha(httpClient);
                });
            if (captcha == null) {
              throw ExceptionWithMessage("验证码未填写");
            }
            _captcha = captcha.trim();
            continue;
          }

          if (responseText.trim() == "null") return Tuple(null, <Session>[]);
          final payload = decodeJsonMap(responseText,
              context: '$context；HTTP ${response.statusCode}');
          final items = asDynamicList(payload['kbList']);
          if (items == null) {
            throw ExceptionWithMessage(
                '$context：缺少 kbList 数组；HTTP ${response.statusCode}'
                '；响应摘要：${responseSummary(responseText)}');
          }
          // 其他课程（实践课等）与 kbList 合并后统一解析并缓存，
          // 保证缓存降级路径也能还原完整课表。
          final combined = _combineTimetableItems(
              items, asDynamicList(payload['sjkList']) ?? const []);
          final sessions = _parseSessions(combined, context);
          _writeCache('zdbk_Timetable$year$semester', jsonEncode(combined));
          return Tuple(null, sessions);
        }
        throw ExceptionWithMessage("验证码识别失败");
      } on Object catch (error, stackTrace) {
        if (error is AuthenticationExpiredException) rethrow;
        final context = '教务网课表接口（学年 $year，学期 $semester，请求类型 课表）';
        final exception = exceptionFrom(error,
            context: context,
            requestUri: uri,
            relogged: relogged,
            retried: retried,
            stackTrace: stackTrace);
        final cached =
            _cachedList('zdbk_Timetable$year$semester', '$context 缓存');
        return Tuple(
          _cacheAwareException(exception, cached, context),
          _parseSessions(cached.data, '$context 缓存'),
        );
      }
    });
  }

  Future<Tuple<Exception?, Iterable<ExamDto>>> getExamsDto(
      HttpClient httpClient) async {
    return await _withAutoRelogin(httpClient, (relogged, retried) async {
      late HttpClientRequest request;
      late HttpClientResponse response;
      final uri = Uri.parse(
          "https://xuanke.cufe.edu.cn/jwglxt/kwgl/kscx_cxXsksxxIndex.html?doType=query&gnmkdm=N358105&queryModel.showCount=5000");

      try {
        request = await httpClient.postUrl(uri).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout());
        request.headers
          ..add("Referer",
              "https://xuanke.cufe.edu.cn/jwglxt/xtgl/index_initMenu.html")
          ..set('Connection', 'close')
          ..add('User-Agent',
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36')
          ..add('Accept', 'application/json, text/javascript, */*; q=0.01')
          ..add('X-Requested-With', 'XMLHttpRequest');
        request.cookies.add(_jSessionId!);
        request.cookies.add(_route!);
        request.followRedirects = false;
        response = await request.close().timeout(const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout());

        var responseText = await readResponseBody(response, context: '教务网考试接口');
        const context = '教务网考试接口（请求类型 考试）';
        _validateResponse(response, responseText,
            context: context,
            requestUri: uri,
            relogged: relogged,
            retried: retried);
        final payload = decodeJsonMap(responseText,
            context: '$context；HTTP ${response.statusCode}');
        final items = asDynamicList(payload['items']);
        if (items == null) {
          throw ExceptionWithMessage(
              '$context：缺少 items 数组；HTTP ${response.statusCode}'
              '；响应摘要：${responseSummary(responseText)}');
        }
        final exams = _parseExams(items, context);
        _writeCache('zdbk_exams', jsonEncode(items));
        return Tuple(null, exams);
      } on Object catch (error, stackTrace) {
        if (error is AuthenticationExpiredException) rethrow;
        final exception = exceptionFrom(error,
            context: '教务网考试接口（请求类型 考试）',
            requestUri: uri,
            relogged: relogged,
            retried: retried,
            stackTrace: stackTrace);
        final cached = _cachedList('zdbk_exams', '教务网考试缓存');
        return Tuple(
          _cacheAwareException(exception, cached, '教务网考试'),
          _parseExams(cached.data, '教务网考试缓存'),
        );
      }
    });
  }

  Future<Tuple<Exception?, Map<String, double>>> getPracticeScores(
      HttpClient httpClient, String studentId) async {
    return await _withAutoRelogin(httpClient, (relogged, retried) async {
      late HttpClientRequest request;
      late HttpClientResponse response;
      final uri = Uri.parse(
          "https://xuanke.cufe.edu.cn/jwglxt/dessktgl/dessktcx_cxDessktcxIndex.html?gnmkdm=N108001&layout=default&su=$studentId");

      try {
        request = await httpClient.getUrl(uri).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout());
        request.headers
          ..add("Referer",
              "https://xuanke.cufe.edu.cn/jwglxt/xtgl/index_initMenu.html")
          ..set('Connection', 'close')
          ..add('User-Agent',
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36')
          ..add('Accept',
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
        request.cookies.add(_jSessionId!);
        request.cookies.add(_route!);
        request.followRedirects = false;
        response = await request.close().timeout(const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout());

        var html = await readResponseBody(response, context: '教务网实践分接口');
        _validateResponse(response, html,
            context: '教务网实践分接口（学号 $studentId，请求类型 实践分）',
            requestUri: uri,
            expectJson: false,
            relogged: relogged,
            retried: retried);

        _writeCache("zdbk_practiceScores", html);

        var scores = <String, double>{
          'pt2': 0.0,
          'pt3': 0.0,
          'pt4': 0.0,
        };

        var rowPattern = RegExp(
            r'<tr>.*?<td[^>]*>.*?</td>.*?<td[^>]*>(.*?)</td>.*?<td[^>]*>(.*?)</td>.*?</tr>',
            dotAll: true);
        var matches = rowPattern.allMatches(html);

        for (var match in matches) {
          var type = match.group(1)?.trim();
          var scoreStr = match.group(2)?.trim();
          if (type == null || scoreStr == null) continue;

          final score = double.tryParse(scoreStr);
          if (score == null) continue;

          if (type.contains('第二课堂')) {
            scores['pt2'] = score;
          } else if (type.contains('第三课堂')) {
            scores['pt3'] = score;
          } else if (type.contains('第四课堂')) {
            scores['pt4'] = score;
          }
        }

        if (scores['pt2'] == 0.0 &&
            scores['pt3'] == 0.0 &&
            scores['pt4'] == 0.0) {
          var altPattern = RegExp(
              r'<td[^>]*>第二课堂</td>.*?<td[^>]*>([0-9.]+)</td>',
              dotAll: true);
          var pt2Match = altPattern.firstMatch(html);
          if (pt2Match != null) {
            scores['pt2'] = double.tryParse(pt2Match.group(1) ?? '0') ?? 0.0;
          }

          altPattern = RegExp(r'<td[^>]*>第三课堂</td>.*?<td[^>]*>([0-9.]+)</td>',
              dotAll: true);
          var pt3Match = altPattern.firstMatch(html);
          if (pt3Match != null) {
            scores['pt3'] = double.tryParse(pt3Match.group(1) ?? '0') ?? 0.0;
          }

          altPattern = RegExp(r'<td[^>]*>第四课堂</td>.*?<td[^>]*>([0-9.]+)</td>',
              dotAll: true);
          var pt4Match = altPattern.firstMatch(html);
          if (pt4Match != null) {
            scores['pt4'] = double.tryParse(pt4Match.group(1) ?? '0') ?? 0.0;
          }
        }

        return Tuple(null, scores);
      } on Object catch (error, stackTrace) {
        if (error is AuthenticationExpiredException) rethrow;

        final exception = exceptionFrom(error,
            context: '教务网实践分接口（学号 $studentId，请求类型 实践分）',
            requestUri: uri,
            relogged: relogged,
            retried: retried,
            stackTrace: stackTrace);

        var cachedHtml = _db?.getCachedWebPage("zdbk_practiceScores");
        if (cachedHtml != null) {
          try {
            var scores = <String, double>{
              'pt2': 0.0,
              'pt3': 0.0,
              'pt4': 0.0,
            };
            var altPattern = RegExp(
                r'<td[^>]*>第二课堂</td>.*?<td[^>]*>([0-9.]+)</td>',
                dotAll: true);
            var pt2Match = altPattern.firstMatch(cachedHtml);
            if (pt2Match != null) {
              scores['pt2'] = double.tryParse(pt2Match.group(1) ?? '0') ?? 0.0;
            }

            altPattern = RegExp(r'<td[^>]*>第三课堂</td>.*?<td[^>]*>([0-9.]+)</td>',
                dotAll: true);
            var pt3Match = altPattern.firstMatch(cachedHtml);
            if (pt3Match != null) {
              scores['pt3'] = double.tryParse(pt3Match.group(1) ?? '0') ?? 0.0;
            }

            altPattern = RegExp(r'<td[^>]*>第四课堂</td>.*?<td[^>]*>([0-9.]+)</td>',
                dotAll: true);
            var pt4Match = altPattern.firstMatch(cachedHtml);
            if (pt4Match != null) {
              scores['pt4'] = double.tryParse(pt4Match.group(1) ?? '0') ?? 0.0;
            }
            final cachedException = CachedDataException(
              '教务网实践分：实时请求失败，已使用缓存',
              details: detailedErrorText(exception),
              originalError: exception,
            );
            return Tuple(cachedException, scores);
          } on Object catch (cacheError, cacheStackTrace) {
            DiagnosticLogService.instance.record(
              level: CelechronLogLevel.warning,
              module: '教务网实践分',
              operation: 'readCache',
              cacheUsed: false,
              error: cacheError,
              stackTrace: cacheStackTrace,
            );
          }
        }
        return Tuple(exception, {'pt2': 0.0, 'pt3': 0.0, 'pt4': 0.0});
      }
    });
  }

  Future<Uint8List> getCaptcha(HttpClient httpClient) async {
    late HttpClientRequest request;
    late HttpClientResponse response;

    if (_jSessionId == null || _route == null) {
      throw ExceptionWithMessage("未登录");
    }
    request = await httpClient
        .getUrl(Uri.parse(
            "https://xuanke.cufe.edu.cn/jwglxt/kaptcha?time=${DateTime.now().millisecondsSinceEpoch}"))
        .timeout(const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout());
    request.cookies.add(_jSessionId!);
    request.cookies.add(_route!);
    request.followRedirects = false;
    response = await request.close().timeout(const Duration(seconds: 8),
        onTimeout: () => throw requestTimeout());
    var bytes = await consolidateHttpClientResponseBytes(response);
    final contentType =
        response.headers.value(HttpHeaders.contentTypeHeader) ?? '<缺失>';
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (response.isRedirect ||
        response.statusCode == HttpStatus.unauthorized ||
        response.statusCode == HttpStatus.forbidden) {
      throw AuthenticationExpiredException(
          '教务网验证码接口：登录态已失效；HTTP ${response.statusCode}'
          '${location == null ? '' : '；Location $location'}');
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        !contentType.toLowerCase().startsWith('image/')) {
      final body = utf8.decode(bytes, allowMalformed: true);
      throw ExceptionWithMessage('教务网验证码接口返回异常；HTTP ${response.statusCode}'
          '；Content-Type $contentType'
          '${location == null ? '' : '；Location $location'}'
          '；响应摘要：${responseSummary(body)}');
    }
    return bytes;
  }

  Future<String> solveCaptcha(HttpClient httpClient) async {
    throw UnimplementedError("验证码识别功能未开发");
  }

  /// 获取班级课表（兜底数据源，非 app 课表页主数据）。
  /// 接口为 kbdy/bjkbdy_cxBjKb.html，响应 kbList 条目字段与个人课表接口
  /// 略有不同（含 zcds 展开周列表、jcs 节次），与个人课表共用同一解析器。
  Future<Tuple<Exception?, List<Session>>> getClassTimetable(
      HttpClient httpClient,
      String year,
      String semester,
      String njdmId,
      String zyhId,
      String bhId,
      String bh) async {
    return await _withSitePermit(() async {
      await _initClassTimetableModule(httpClient);
      return await _withAutoReloginUnlocked(httpClient, (relogged, retried) async {
        late HttpClientRequest request;
        late HttpClientResponse response;
        final uri = Uri.parse(
            "https://xuanke.cufe.edu.cn/jwglxt/kbdy/bjkbdy_cxBjKb.html?gnmkdm=N214505");

        try {
          request = await httpClient.postUrl(uri).timeout(
              const Duration(seconds: 8),
              onTimeout: () => throw requestTimeout());
          request.headers
            ..add("Referer",
                "https://xuanke.cufe.edu.cn/jwglxt/kbdy/bjkbdy_cxBjkbdyIndex.html")
            ..set('Connection', 'close')
            ..add('User-Agent',
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36')
            ..add('Accept', 'application/json, text/javascript, */*; q=0.01');
          request.cookies.add(_jSessionId!);
          request.cookies.add(_route!);
          request.followRedirects = false;
          request.headers.contentType = ContentType(
              'application', 'x-www-form-urlencoded',
              charset: 'utf-8');
          
          final bodyBytes = utf8.encode(
              'xnm=$year&xqm=$semester&xnmc=$year&xqmmc=1&xqh_id=2&njdm_id=$njdmId&zyh_id=$zyhId&bh_id=$bhId&tjkbzdm=1&tjkbzxsdm=0&zymc=&jgmc=&njmc=2026&bj=&xkrs=29&bh=$bh&zxszjjs=false&akcxqjchb=false&kzlx=ck&sfcxxqh=1');
          request.headers.contentLength = bodyBytes.length;
          request.add(bodyBytes);
          response = await request.close().timeout(const Duration(seconds: 8),
              onTimeout: () => throw requestTimeout());

          var responseText = await readResponseBody(response, context: '班级课表接口');
          print("\n=== RAW CLASS TIMETABLE JSON ===");
          print(responseText);
          print("==========================\n");
          final context = '班级课表接口（学年 $year，学期 $semester）';
          _validateResponse(response, responseText,
              context: context,
              requestUri: uri,
              relogged: relogged,
              retried: retried);

          final payload = decodeJsonMap(responseText,
              context: '$context：HTTP ${response.statusCode}');
          final items = asDynamicList(payload['kbList']);
          if (items == null) {
            throw ExceptionWithMessage(
                '$context：缺少 kbList 数组；HTTP ${response.statusCode}');
          }
          // 其他课程（实践课等）与 kbList 合并后统一解析
          final combined = _combineTimetableItems(
              items, asDynamicList(payload['sjkList']) ?? const []);
          final sessions = _parseSessions(combined, context);
          return Tuple(null, sessions);
        } on Object catch (error, stackTrace) {
          if (error is AuthenticationExpiredException) rethrow;
          final exception = exceptionFrom(error,
              context: '班级课表接口（学年 $year，学期 $semester）',
              requestUri: uri,
              relogged: relogged,
              retried: retried,
              stackTrace: stackTrace);
          return Tuple(exception, <Session>[]);
        }
      });
    });
  }

  /// 获取班号信息（用于查询班级课表兜底）
  /// 返回 Tuple<Exception?, Map<String, String>?>，Map 中包含 'bh_id' 和 'bh'
  Future<Tuple<Exception?, Map<String, String>?>> getBhIdByClassInfo(
      HttpClient httpClient,
      String year,
      String semester,
      String njdmId,
      String zyhId,
      String bjmc) async {
    return await _withSitePermit(() async {
      await _initClassTimetableModule(httpClient);
      return await _withAutoReloginUnlocked(httpClient, (relogged, retried) async {
        late HttpClientRequest request;
        late HttpClientResponse response;
        final uri = Uri.parse(
            "https://xuanke.cufe.edu.cn/jwglxt/kbdy/bjkbdy_cxBjkbdyTjkbList.html?gnmkdm=N214505");

        try {
          request = await httpClient.postUrl(uri).timeout(
              const Duration(seconds: 8),
              onTimeout: () => throw requestTimeout());
          request.headers
            ..add("Referer",
                "https://xuanke.cufe.edu.cn/jwglxt/kbdy/bjkbdy_cxBjkbdyIndex.html")
            ..set('Connection', 'close')
            ..add('User-Agent',
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36')
            ..add('Accept', 'application/json, text/javascript, */*; q=0.01');
          request.cookies.add(_jSessionId!);
          request.cookies.add(_route!);
          request.followRedirects = false;
          request.headers.contentType = ContentType(
              'application', 'x-www-form-urlencoded',
              charset: 'utf-8');
          
          // 发送专业、年级等信息，请求班级列表
          // 注：xqh_id 可能不是必须的，如果不传遇到问题可加入 xqh_id=1 或 2
          final bodyBytes = utf8.encode(
              'xnm=$year&xqm=$semester&njdm_id=$njdmId&zyh_id=$zyhId&queryModel.showCount=100&queryModel.currentPage=1&queryModel.sortName=&queryModel.sortOrder=asc&time=0');
          request.headers.contentLength = bodyBytes.length;
          request.add(bodyBytes);
          response = await request.close().timeout(const Duration(seconds: 8),
              onTimeout: () => throw requestTimeout());

          var responseText = await readResponseBody(response, context: '班级列表接口');
          final context = '班级列表接口（专业 $zyhId）';
          _validateResponse(response, responseText,
              context: context,
              requestUri: uri,
              relogged: relogged,
              retried: retried);

          final payload = decodeJsonMap(responseText,
              context: '$context：HTTP ${response.statusCode}');
          
          final items = asDynamicList(payload['items']);
          if (items == null) {
             return Tuple(null, null); // 没查到班级
          }

          for (var item in items) {
            if (item is Map) {
              final String? classTitle = item['bjmc']?.toString() ?? item['bj']?.toString();
              if (classTitle != null && classTitle == bjmc) {
                final bhId = item['bh_id']?.toString();
                final bh = item['bh']?.toString();
                if (bhId != null && bh != null) {
                  return Tuple(null, {'bh_id': bhId, 'bh': bh});
                }
              }
            }
          }

          return Tuple(null, null); // 未找到匹配的班级
        } on Object catch (error, stackTrace) {
          if (error is AuthenticationExpiredException) rethrow;
          final exception = exceptionFrom(error,
              context: '班级列表接口（专业 $zyhId）',
              requestUri: uri,
              relogged: relogged,
              retried: retried,
              stackTrace: stackTrace);
          return Tuple(exception, null);
        }
      });
    });
  }

  /// 唤醒班级课表模块的状态
  Future<void> _initClassTimetableModule(HttpClient httpClient) async {
    await _withAutoReloginUnlocked(httpClient, (relogged, retried) async {
      final uri = Uri.parse(
          "https://xuanke.cufe.edu.cn/jwglxt/kbdy/bjkbdy_ylBjkbdyIndex.html?gnmkdm=N214505");
      late HttpClientRequest request;
      try {
        request = await httpClient.getUrl(uri).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout());
        request.headers
          ..add("Referer",
              "https://xuanke.cufe.edu.cn/jwglxt/xtgl/index_initMenu.html")
          ..set('Connection', 'close')
          ..add('User-Agent',
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
        request.cookies.add(_jSessionId!);
        request.cookies.add(_route!);
        request.followRedirects = false;
        
        final response = await request.close().timeout(const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout());
        await readResponseBody(response, context: '唤醒班级课表模块');
      } catch (_) {
        // 唤醒接口即使失败也不抛出异常，尽力而为
      }
    });
  }
}

class _CachedList {
  final List<dynamic> data;
  final bool used;
  final String? cachedAt;

  const _CachedList(this.data, this.used, {this.cachedAt});
}
