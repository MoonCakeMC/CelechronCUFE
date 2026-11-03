import 'dart:convert';
import 'dart:io';

import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:celechron/utils/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'exceptions.dart';
import 'response_utils.dart';
import 'package:celechron/utils/cufe_encrypt.dart';

// 原实现：固定过期时间，跨 login 复用时 2 分钟后凭据被丢弃。
// class _ActiveSsoCookie {
//   final Cookie cookie;
//   final DateTime expiresAt;
//
//   _ActiveSsoCookie(this.cookie, this.expiresAt);
// }

class _ActiveSsoCookie {
  final Cookie cookie;
  // null 表示该凭据不按时间自动过期，只在服务端拒绝或显式清理时失效。
  final DateTime? expiresAt;

  _ActiveSsoCookie(this.cookie, this.expiresAt);
}

class _SsoLoginKey {
  final HttpClient httpClient;
  final String username;
  // sessionScope 不为空时按“账号会话”共享 SSO Cookie，忽略 HttpClient 实例差异；
  // 为空时保持原行为，仍按 HttpClient 实例隔离，兼容校园卡等独立链路。
  final String? sessionScope;

  const _SsoLoginKey(this.httpClient, this.username, [this.sessionScope]);

  @override
  bool operator ==(Object other) =>
      other is _SsoLoginKey &&
      username == other.username &&
      sessionScope == other.sessionScope &&
      // 仅在没有账号级 scope 时才比较客户端实例，避免不同 client 复用同一会话。
      (sessionScope != null || identical(httpClient, other.httpClient));

  @override
  int get hashCode => sessionScope != null
      // 账号级会话只由 scope + 用户名决定，保证不同 HttpClient 命中同一缓存。
      ? Object.hash(sessionScope, username)
      : Object.hash(identityHashCode(httpClient), username);
}

/// 统一身份认证入口。同一进程内的并发消费者共享一次密码登录。
/// 原设计不再从持久化存储恢复 iPlanetDirectoryPro，因为该 Cookie 的服务端
/// 寿命和轮换规则不可靠，1.2 的跨启动复用会把已失效值交给所有子站。
/// 现改为仅对账号级 sessionScope 使用系统加密存储保存 SSO Cookie，
/// 并在恢复时校验过期时间与最长保留期限，失效后自动回退密码登录。
class ZjuAm {
  static const _secureStorage = FlutterSecureStorage();
  static const _processCookieLifetime = Duration(minutes: 2);
  // 加密持久化 SSO 会话的 key 前缀；仅账号级 sessionScope 使用。
  static const _sessionKeyPrefix = 'cufe_sso_session_';
  // 原实现单独使用 EncryptedSharedPreferences 保存 SSO Cookie：
  // static const _androidSsoOptions =
  //     AndroidOptions(encryptedSharedPreferences: true);
  // 该选项会与 DatabaseHelper 的默认安全存储共用同一个 SharedPreferences 文件，
  // 触发插件把 username/password 迁移成加密 key 格式，导致重启后读不到凭据。
  // 现统一使用默认 AndroidOptions（仍由 Keystore 加密），与账号密码保持一致。
  // 持久化 Cookie 的最长保留时间，超过后视为不可用并清理，避免长期复用陈旧凭据。
  static const _persistedCookieMaxAge = Duration(days: 7);
  static final Map<_SsoLoginKey, Future<Cookie?>> _pendingLogins = {};
  static final Map<_SsoLoginKey, _ActiveSsoCookie> _activeCookies = {};
  // 记录每个账号级 scope 实际执行过的密码登录次数，供 Spider 判断本轮凭据是否刚新建。
  static final Map<String, int> _passwordLoginCounts = {};

  static final Uri graduateServiceUri = Uri.parse('https://yjsy.zju.edu.cn/');

  // 原实现：没有 sessionScope，跨 login 永远按 HttpClient 实例隔离。
  // static Future<Cookie?> getSsoCookie(
  //     HttpClient httpClient, String username, String password) async {
  //   final key = _SsoLoginKey(httpClient, username);
  //   ...
  // }
  static Future<Cookie?> getSsoCookie(
    HttpClient httpClient,
    String username,
    String password, {
    // 传账号级 scope 时，同一账号的不同 HttpClient 复用同一个进程内 SSO 会话；
    // 不传则保持原有按客户端隔离的行为。
    String? sessionScope,
    // 记录本次密码登录的触发原因，便于诊断“反复登录”。
    String reason = '未指定',
  }) async {
    // 账号级会话优先复用，避免每次 login() 都重新执行账号密码认证。
    final key = _SsoLoginKey(httpClient, username, sessionScope);
    final active = _activeSsoCookie(key);
    if (active != null) {
      return active;
    }

    // 同一 key（账号级 scope 或同一 HttpClient）、同一账号共享一次登录任务。
    final pending = _pendingLogins[key];
    if (pending != null) return await pending;

    // 把“从加密存储恢复”和“密码登录”放进同一个单飞任务，
    // 避免并发调用同时读取持久化 Cookie 或同时开始密码认证。
    final login = _restoreOrLoginSsoCookie(
      httpClient,
      username,
      password,
      sessionScope: sessionScope,
      reason: reason,
    );
    _pendingLogins[key] = login;
    try {
      final cookie = await login;
      if (cookie != null) {
        // 账号级 scope 不按时间过期，只在服务端拒绝或显式清理时失效；
        // 默认的客户端隔离仍保留 2 分钟短生命周期。
        _activeCookies[key] = _ActiveSsoCookie(
          cookie,
          sessionScope == null
              ? DateTime.now().add(_processCookieLifetime)
              : null,
        );
      }
      return cookie;
    } finally {
      if (identical(_pendingLogins[key], login)) {
        _pendingLogins.remove(key);
      }
    }
  }

  // 读取加密存储中的账号级 SSO Cookie；没有则执行一次密码登录。
  static Future<Cookie?> _restoreOrLoginSsoCookie(
    HttpClient httpClient,
    String username,
    String password, {
    required String? sessionScope,
    required String reason,
  }) async {
    if (sessionScope != null) {
      final restored = await _restoreSsoCookie(username, sessionScope);
      if (restored != null) {
        // 命中持久化会话时不触发任何账号密码认证。
        DiagnosticLogService.instance.record(
          module: '统一身份认证',
          operation: 'restoreSession',
          message: '已从加密存储恢复 SSO 会话；原因=$reason；scope=$sessionScope',
        );
        return restored;
      }
    }

    // 记录密码登录开始，供诊断日志确认是否存在重复认证。
    DiagnosticLogService.instance.record(
      module: '统一身份认证',
      operation: 'passwordLogin',
      message: '开始账号密码登录；原因=$reason；'
          'scope=${sessionScope ?? '<按 HttpClient 隔离>'}',
    );
    if (sessionScope != null) {
      // 让上层能判断本轮凭据是否来自新的密码登录。
      _passwordLoginCounts.update(
        sessionScope,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    final cookie = await _createFreshSsoCookie(httpClient, username, password);
    if (cookie != null && sessionScope != null) {
      // 只有新密码登录得到的凭据才写入加密存储；恢复时不再刷新 savedAt。
      await _persistSsoCookie(username, sessionScope, cookie);
    }
    return cookie;
  }

  // 查询某个账号级 scope 已执行的密码登录次数。
  static int passwordLoginCount(String sessionScope) {
    return _passwordLoginCounts[sessionScope] ?? 0;
  }

  // 仅供 Spider 判断是否已有可复用凭据：只查内存缓存，不触发网络或密码登录。
  static Cookie? peekSsoCookie(
    HttpClient httpClient,
    String username, {
    String? sessionScope,
  }) {
    return _activeSsoCookie(
      _SsoLoginKey(httpClient, username, sessionScope),
    );
  }

  static Cookie? _activeSsoCookie(_SsoLoginKey key) {
    final active = _activeCookies[key];
    if (active == null) return null;
    // expiresAt 为 null 表示账号级会话不按时间过期。
    final expiresAt = active.expiresAt;
    if (expiresAt == null || DateTime.now().isBefore(expiresAt)) {
      return active.cookie;
    }
    _activeCookies.remove(key);
    return null;
  }

  static Future<Cookie?> _createFreshSsoCookie(
      HttpClient httpClient, String username, String password) async {
    // 先删除 1.2 时期留下的值，防止降级后的旧版本再读取。
    await _deleteLegacyCachedSsoCookie(username);
    return _getSsoCookie(httpClient, username, password);
  }

  static String _cookieStorageKey(String username) =>
      'zju_sso_cookie_$username';

  // 账号级 SSO 会话的加密存储 key；scope 已包含用户名，再追加用户名便于按账号清理。
  static String _sessionStorageKey(String username, String sessionScope) =>
      '$_sessionKeyPrefix${sessionScope}_$username';

  // 读取并校验加密存储中的 SSO Cookie；失效或损坏时清理并返回 null。
  static Future<Cookie?> _restoreSsoCookie(
      String username, String sessionScope) async {
    final storageKey = _sessionStorageKey(username, sessionScope);
    try {
      final raw = await _secureStorage.read(
        key: storageKey,
        iOptions: secureStorageIOSOptions,
      );
      if (raw == null || raw.trim().isEmpty) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await _deletePersistedSsoCookie(storageKey);
        return null;
      }
      final name = decoded['name']?.toString();
      final value = decoded['value']?.toString();
      if (name == null ||
          !_ssoCookieNames.contains(name) ||
          value == null ||
          value.isEmpty) {
        await _deletePersistedSsoCookie(storageKey);
        return null;
      }

      final cookie = Cookie(name, value);
      cookie.domain = decoded['domain']?.toString();
      cookie.path = decoded['path']?.toString();
      final expiresText = decoded['expires']?.toString();
      if (expiresText != null && expiresText.isNotEmpty) {
        cookie.expires = DateTime.tryParse(expiresText);
      }
      if (cookie.domain == null || cookie.domain!.trim().isEmpty) {
        cookie.domain = 'cufe.edu.cn';
      }
      if (cookie.path == null || cookie.path!.trim().isEmpty) {
        cookie.path = '/';
      }

      // 超过最长保留时间视为陈旧，主动删除并回退到密码登录。
      final savedAt = DateTime.tryParse(decoded['savedAt']?.toString() ?? '');
      if (savedAt != null &&
          DateTime.now().toUtc().difference(savedAt.toUtc()) >
              _persistedCookieMaxAge) {
        await _deletePersistedSsoCookie(storageKey);
        return null;
      }
      if (!_isUsableSsoCookie(cookie, DateTime.now())) {
        await _deletePersistedSsoCookie(storageKey);
        return null;
      }
      return cookie;
    } on Object catch (error, stackTrace) {
      // 读取/解析失败不能阻断正常登录，按无缓存处理。
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: '统一身份认证',
        operation: 'restoreSession',
        message: '读取加密存储的 SSO 会话失败，将重新登录',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  // 将账号级 SSO Cookie 写入系统加密存储。
  static Future<void> _persistSsoCookie(
      String username, String sessionScope, Cookie cookie) async {
    final storageKey = _sessionStorageKey(username, sessionScope);
    try {
      // 服务端若只给 Max-Age，则落盘时换算成绝对过期时间。
      final expires = cookie.expires ??
          (cookie.maxAge != null
              ? DateTime.now().add(Duration(seconds: cookie.maxAge!))
              : null);
      final payload = jsonEncode({
        'name': cookie.name,
        'value': cookie.value,
        'domain': cookie.domain,
        'path': cookie.path,
        'expires': expires?.toUtc().toIso8601String(),
        'savedAt': DateTime.now().toUtc().toIso8601String(),
      });
      await _secureStorage.write(
        key: storageKey,
        value: payload,
        iOptions: secureStorageIOSOptions,
      );
    } on Object catch (error, stackTrace) {
      // 持久化失败只影响下次启动复用，不影响本次登录。
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: '统一身份认证',
        operation: 'persistSession',
        message: '写入加密存储的 SSO 会话失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static Future<void> _deletePersistedSsoCookie(String storageKey) {
    return _secureStorage.delete(
      key: storageKey,
      iOptions: secureStorageIOSOptions,
    );
  }

  // 按用户名清理所有 scope 的加密 SSO 会话。
  static Future<void> _deletePersistedSsoCookies(String username) async {
    if (username.isEmpty) return;
    try {
      final all = await _secureStorage.readAll(
        iOptions: secureStorageIOSOptions,
      );
      for (final storageKey in all.keys) {
        if (storageKey.startsWith(_sessionKeyPrefix) &&
            storageKey.endsWith('_$username')) {
          await _deletePersistedSsoCookie(storageKey);
        }
      }
    } on Object catch (error, stackTrace) {
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: '统一身份认证',
        operation: 'persistSession',
        message: '清理加密存储的 SSO 会话失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static Future<void> clearCachedSsoCookie(String username) async {
    _activeCookies.removeWhere((key, _) => key.username == username);
    await Future.wait([
      _deleteLegacyCachedSsoCookie(username),
      _deletePersistedSsoCookies(username),
    ]);
  }

  static Future<void> _deleteLegacyCachedSsoCookie(String username) {
    return _secureStorage.delete(
      key: _cookieStorageKey(username),
      iOptions: secureStorageIOSOptions,
    );
  }

  /// Requests a fresh, single-use CAS service ticket and returns only its
  /// callback URI. The URI must be consumed immediately and never persisted.
  static Future<Uri> getServiceCallback(
    HttpClient httpClient,
    Cookie iPlanetDirectoryPro,
    Uri service, {
    String context = 'CAS service 登录',
  }) async {
    final uri = buildServiceLoginUri(service);
    final startedAt = DateTime.now();
    try {
      final request = await httpClient.getUrl(uri).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout('CAS service 请求超时'),
          );
      request.followRedirects = false;
      request.cookies.add(
        Cookie(iPlanetDirectoryPro.name, iPlanetDirectoryPro.value),
      );
      final response = await request.close().timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout('CAS service 响应超时'),
          );
      final location = response.headers.value(HttpHeaders.locationHeader);
      final statusCode = response.statusCode;
      final contentType = response.headers.value(HttpHeaders.contentTypeHeader);
      final body =
          await readResponseBody(response, context: '$context CAS service');
      DiagnosticLogService.instance.record(
        module: context,
        operation: 'casService',
        requestUri: uri,
        statusCode: statusCode,
        contentType: contentType,
        location: location,
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        message: 'CAS service ticket 响应已读取',
      );
      if (!isHttpRedirectStatus(statusCode) ||
          location == null ||
          location.isEmpty) {
        final details = 'HTTP $statusCode\n'
            'Content-Type：${contentType ?? '<缺失>'}\n'
            '响应摘要：${responseSummary(body)}';
        // CAS returns its HTTP 200 login page (or an explicit auth status)
        // when the SSO cookie is no longer usable. Other statuses are
        // transport/protocol failures and must not invalidate a good cache.
        if (statusCode == HttpStatus.ok ||
            statusCode == HttpStatus.unauthorized ||
            statusCode == HttpStatus.forbidden) {
          throw AuthenticationExpiredException(
            '$context：未获得 CAS ticket',
            details: details,
          );
        }
        throw ExceptionWithMessage(
          '$context：CAS service 请求失败',
          details: details,
        );
      }
      final callback = uri.resolve(location);
      if (!_isValidServiceCallback(callback, service)) {
        throw ExceptionWithMessage('$context：CAS service 回调无效');
      }
      return callback;
    } on Object catch (error, stackTrace) {
      throw exceptionFrom(
        error,
        context: context,
        requestUri: uri,
        stackTrace: stackTrace,
      );
    }
  }

  @visibleForTesting
  static Uri buildServiceLoginUri(Uri service) => Uri.https(
        'authserver.cufe.edu.cn',
        '/authserver/login',
        {'service': service.toString()},
      );

  static bool _isValidServiceCallback(Uri callback, Uri service) {
    final ticket = callback.queryParameters['ticket'];
    return callback.scheme == service.scheme &&
        callback.host == service.host &&
        callback.port == service.port &&
        callback.path == service.path &&
        ticket != null &&
        ticket.isNotEmpty;
  }

  // 统一身份认证真实会话 Cookie 名称（中财使用 CASTGC，保留 ZJU 兼容名）。
  static const _ssoCookieNames = <String>{'CASTGC', 'iPlanetDirectoryPro'};

  // 判断 Cookie 是否仍然可用：名称匹配、值非空、未被服务端标记删除。
  static bool _isUsableSsoCookie(Cookie cookie, DateTime now) {
    return _ssoCookieNames.contains(cookie.name) &&
        cookie.value.isNotEmpty &&
        (cookie.maxAge == null || cookie.maxAge! > 0) &&
        (cookie.expires == null || cookie.expires!.isAfter(now));
  }

  // 同时从已解析 Cookie 与原始 Set-Cookie 中提取真实 SSO 凭据。
  static List<Cookie> _extractSsoCookies(
      HttpClientResponse response, DateTime now) {
    final result = <Cookie>[];
    final seen = <String>{};
    // 先使用 dart:io 已解析的结果。
    for (final cookie in response.cookies) {
      if (_isUsableSsoCookie(cookie, now) && seen.add(cookie.name)) {
        result.add(cookie);
      }
    }
    // 兜底解析原始响应头：部分 Set-Cookie 带 SameSite=None 等属性时，
    // dart:io 可能无法完整解析，但真实凭据仍需被提取。
    for (final raw
        in response.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
      final parts = raw.split(';');
      final first = parts.first.trim();
      final separator = first.indexOf('=');
      if (separator <= 0) continue;
      final name = first.substring(0, separator).trim();
      final value = first.substring(separator + 1).trim();
      if (!_ssoCookieNames.contains(name) ||
          value.isEmpty ||
          seen.contains(name)) {
        continue;
      }
      final cookie = Cookie(name, value);
      for (final attribute in parts.skip(1)) {
        final eq = attribute.indexOf('=');
        if (eq <= 0) continue;
        final key = attribute.substring(0, eq).trim().toLowerCase();
        final attrValue = attribute.substring(eq + 1).trim();
        switch (key) {
          case 'path':
            cookie.path = attrValue;
          case 'domain':
            cookie.domain = attrValue;
          case 'max-age':
            cookie.maxAge = int.tryParse(attrValue);
          case 'expires':
            try {
              cookie.expires = HttpDate.parse(attrValue);
            } on Object {
              // 无法解析的 Expires 不影响提取，仍交给服务端拒绝时再失效。
            }
        }
      }
      if (_isUsableSsoCookie(cookie, now)) {
        result.add(cookie);
        seen.add(name);
      }
    }
    return result;
  }

  static Future<Cookie?> _getSsoCookie(
      HttpClient httpClient, String username, String password) async {
    late HttpClientRequest request;
    late HttpClientResponse response;

    try {
      request = await httpClient
          .getUrl(Uri.parse('https://authserver.cufe.edu.cn/authserver/login'))
          .timeout(const Duration(seconds: 8),
              onTimeout: () => throw requestTimeout());
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0');
      response = await request.close().timeout(const Duration(seconds: 8),
          onTimeout: () => throw requestTimeout());

      var cookies = List<Cookie>.from(response.cookies);
      var body = await readResponseBody(response, context: '统一身份认证登录页');
      final loginLocation = response.headers.value(HttpHeaders.locationHeader);

      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.found) {
        throw LoginException('统一身份认证登录页请求失败；HTTP ${response.statusCode}'
            '${loginLocation == null ? '' : '；Location $loginLocation'}'
            '；响应摘要：${responseSummary(body)}');
      }

      var execution =
          RegExp(r'id="execution" value="(.*?)"').firstMatch(body)?.group(1);
      if (execution == null) {
        execution = RegExp(r'name="execution" value="(.*?)"')
            .firstMatch(body)
            ?.group(1);
      }
      if (execution == null) {
        throw LoginException(
            '统一身份认证登录页无法获取 execution；HTTP ${response.statusCode}'
            '；响应摘要：${responseSummary(body)}');
      }

      var salt = RegExp(r'id="pwdEncryptSalt" value="(.*?)"')
              .firstMatch(body)
              ?.group(1) ??
          '';

      String pwdEnc = CufeEncrypt.encryptPassword(password, salt);

      request = await httpClient
          .postUrl(Uri.parse('https://authserver.cufe.edu.cn/authserver/login'))
          .timeout(const Duration(seconds: 8),
              onTimeout: () => throw requestTimeout());
      request.followRedirects = false;
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.headers.set(HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0');
      request.headers.set('Origin', 'https://authserver.cufe.edu.cn');
      request.cookies.addAll(cookies);

      request.add(utf8.encode(Uri(queryParameters: {
        'username': username,
        'password': pwdEnc,
        'captcha': '',
        'rememberMe': 'true',
        '_eventId': 'submit',
        'cllt': 'userNameLogin',
        'dllt': 'generalLogin',
        'lt': '',
        'execution': execution,
      }).query));

      response = await request.close().timeout(const Duration(seconds: 8),
          onTimeout: () => throw requestTimeout());
      body = await readResponseBody(response, context: '统一身份认证登录提交');

      final now = DateTime.now();
      // 原实现只读取 response.cookies，并在拿不到 Cookie 时伪造 dummy_ticket_auth；
      // 假 Cookie 会让子站必然失败，从而触发二次/多次密码登录。
      // 现改为同时解析原始 Set-Cookie，并在确实没有真实凭据时明确失败。
      final ssoCookies = _extractSsoCookies(response, now);

      if (ssoCookies.isNotEmpty) {
        final cookie = ssoCookies.last;
        if (cookie.domain == null || cookie.domain!.trim().isEmpty) {
          cookie.domain = 'cufe.edu.cn';
        }
        if (cookie.path == null || cookie.path!.trim().isEmpty) {
          cookie.path = '/';
        }
        return cookie;
      } else {
        final location = response.headers.value(HttpHeaders.locationHeader);
        // 原实现：Location 含 ticket 时返回 dummy_ticket_auth。
        // if (location != null && (response.statusCode == HttpStatus.found ||
        //     response.statusCode == HttpStatus.movedPermanently)) {
        //   if (location.contains('ticket=')) {
        //     return Cookie('CASTGC', 'dummy_ticket_auth')
        //       ..domain = 'cufe.edu.cn'
        //       ..path = '/';
        //   }
        // }
        throw LoginException("统一身份认证失败，未获得 CASTGC/iPlanetDirectoryPro"
            "；HTTP ${response.statusCode}"
            "${location == null ? '' : '；Location $location'}"
            "；响应摘要：${responseSummary(body)}");
      }
    } on Object catch (error, stackTrace) {
      throw exceptionFrom(
        error,
        context: '统一身份认证',
        requestUri:
            Uri.parse('https://authserver.cufe.edu.cn/authserver/login'),
        stackTrace: stackTrace,
      );
    }
  }
}
