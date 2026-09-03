import 'dart:convert';
import 'dart:io';

import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:celechron/utils/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'exceptions.dart';
import 'response_utils.dart';
import 'package:celechron/utils/cufe_encrypt.dart';

class _ActiveSsoCookie {
  final Cookie cookie;
  final DateTime expiresAt;

  _ActiveSsoCookie(this.cookie, this.expiresAt);
}

class _SsoLoginKey {
  final HttpClient httpClient;
  final String username;

  const _SsoLoginKey(this.httpClient, this.username);

  @override
  bool operator ==(Object other) =>
      other is _SsoLoginKey &&
      identical(httpClient, other.httpClient) &&
      username == other.username;

  @override
  int get hashCode => Object.hash(identityHashCode(httpClient), username);
}

/// 统一身份认证入口。同一进程内的并发消费者共享一次密码登录，
/// 但不再从持久化存储恢复 iPlanetDirectoryPro。该 Cookie 的服务端寿命和
/// 轮换规则不可靠，1.2 引入的跨启动复用会把已失效值交给所有子站。
class ZjuAm {
  static const _secureStorage = FlutterSecureStorage();
  static const _processCookieLifetime = Duration(minutes: 2);
  static final Map<_SsoLoginKey, Future<Cookie?>> _pendingLogins = {};
  static final Map<_SsoLoginKey, _ActiveSsoCookie> _activeCookies = {};

  static final Uri graduateServiceUri = Uri.parse('https://yjsy.zju.edu.cn/');

  static Future<Cookie?> getSsoCookie(
      HttpClient httpClient, String username, String password) async {
    final key = _SsoLoginKey(httpClient, username);
    final active = _activeSsoCookie(key);
    if (active != null) {
      return active;
    }

    // 同一 HttpClient、同一账号共享一次登录任务；不同客户端保持隔离。
    final pending = _pendingLogins[key];
    if (pending != null) return await pending;

    final login = _createFreshSsoCookie(httpClient, username, password);
    _pendingLogins[key] = login;
    try {
      final cookie = await login;
      if (cookie != null) {
        _activeCookies[key] = _ActiveSsoCookie(
          cookie,
          DateTime.now().add(_processCookieLifetime),
        );
      }
      return cookie;
    } finally {
      if (identical(_pendingLogins[key], login)) {
        _pendingLogins.remove(key);
      }
    }
  }

  static Cookie? _activeSsoCookie(_SsoLoginKey key) {
    final active = _activeCookies[key];
    if (active == null) return null;
    if (DateTime.now().isBefore(active.expiresAt)) {
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

  static Future<void> clearCachedSsoCookie(String username) {
    _activeCookies.removeWhere((key, _) => key.username == username);
    return _deleteLegacyCachedSsoCookie(username);
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
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0');
      response = await request.close().timeout(const Duration(seconds: 8),
          onTimeout: () => throw requestTimeout());

      var cookies = List<Cookie>.from(response.cookies);
      var body = await readResponseBody(response, context: '统一身份认证登录页');
      final loginLocation = response.headers.value(HttpHeaders.locationHeader);
      
      if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.found) {
        throw LoginException('统一身份认证登录页请求失败；HTTP ${response.statusCode}'
            '${loginLocation == null ? '' : '；Location $loginLocation'}'
            '；响应摘要：${responseSummary(body)}');
      }
      
      var execution = RegExp(r'id="execution" value="(.*?)"').firstMatch(body)?.group(1);
      if (execution == null) {
        execution = RegExp(r'name="execution" value="(.*?)"').firstMatch(body)?.group(1);
      }
      if (execution == null) {
        throw LoginException(
            '统一身份认证登录页无法获取 execution；HTTP ${response.statusCode}'
            '；响应摘要：${responseSummary(body)}');
      }
      
      var salt = RegExp(r'id="pwdEncryptSalt" value="(.*?)"').firstMatch(body)?.group(1) ?? '';
      
      String pwdEnc = CufeEncrypt.encryptPassword(password, salt);

      request = await httpClient
          .postUrl(Uri.parse('https://authserver.cufe.edu.cn/authserver/login'))
          .timeout(const Duration(seconds: 8),
              onTimeout: () => throw requestTimeout());
      request.followRedirects = false;
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0');
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
      // Look for CASTGC or iPlanetDirectoryPro depending on what CUFE uses
      final ssoCookies = response.cookies
          .where((cookie) =>
              (cookie.name == 'CASTGC' || cookie.name == 'iPlanetDirectoryPro') &&
              cookie.value.isNotEmpty &&
              (cookie.maxAge == null || cookie.maxAge! > 0) &&
              (cookie.expires == null || cookie.expires!.isAfter(now)))
          .toList();
          
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
        if (location != null && (response.statusCode == HttpStatus.found || response.statusCode == HttpStatus.movedPermanently)) {
           // We might just return a dummy cookie if ticket is in location and that's enough
           // But normally CASTGC is returned for CAS logins.
           // To keep compatibility, we create a dummy cookie if auth succeeded but no CASTGC is visible.
           if (location.contains('ticket=')) {
             return Cookie('CASTGC', 'dummy_ticket_auth')
               ..domain = 'cufe.edu.cn'
               ..path = '/';
           }
        }
        
        throw LoginException("统一身份认证失败，学号或密码错误，或认证会话已失效"
            "；HTTP ${response.statusCode}"
            "${location == null ? '' : '；Location $location'}"
            "；响应摘要：${responseSummary(body)}");
      }
    } on Object catch (error, stackTrace) {
      throw exceptionFrom(
        error,
        context: '统一身份认证',
        requestUri: Uri.parse('https://authserver.cufe.edu.cn/authserver/login'),
        stackTrace: stackTrace,
      );
    }
  }
}
