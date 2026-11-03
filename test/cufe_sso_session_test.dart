import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:celechron/http/zjuServices/zjuam.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// 中财统一身份认证登录页与提交地址。
final _loginUri = Uri.parse('https://authserver.cufe.edu.cn/authserver/login');

// 构造一次完整的账号密码登录：GET 登录页拿 execution/salt，POST 后返回 CASTGC。
void _expectPasswordLogin(
  _ScriptedHttpClient client, {
  required String cookieValue,
}) {
  client
    ..expectGet(
      _loginUri,
      _ScriptedResponse(
        statusCode: HttpStatus.ok,
        headers: {HttpHeaders.contentTypeHeader: 'text/html'},
        cookies: [Cookie('JSESSIONID', 'form-session')],
        body: '<input id="execution" value="execution-1">'
            '<input id="pwdEncryptSalt" value="0123456789abcdef">',
      ),
    )
    ..expectPost(
      _loginUri,
      _ScriptedResponse(
        statusCode: HttpStatus.found,
        cookies: [Cookie('CASTGC', cookieValue)],
      ),
    );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('同一账号不同 HttpClient 复用账号级 SSO，只执行一次密码登录', () async {
    const username = 'cufe-sso-test-shared-account';
    const scope = 'ugrs:cufe-sso-test-shared-account';
    final firstClient = _ScriptedHttpClient();
    final secondClient = _ScriptedHttpClient();
    _expectPasswordLogin(firstClient, cookieValue: 'shared-cookie');

    // 第一个客户端触发完整密码登录。
    final first = await ZjuAm.getSsoCookie(
      firstClient,
      username,
      'test-password',
      sessionScope: scope,
      reason: '测试首次登录',
    );
    // 第二个客户端应直接命中账号级缓存，不再产生任何网络请求。
    final second = await ZjuAm.getSsoCookie(
      secondClient,
      username,
      'test-password',
      sessionScope: scope,
      reason: '测试复用登录',
    );

    expect(first?.value, 'shared-cookie');
    expect(second?.value, 'shared-cookie');
    expect(identical(first, second), isTrue);
    expect(
      firstClient.requests.where(
          (request) => request.method == 'POST' && request.uri == _loginUri),
      hasLength(1),
    );
    expect(secondClient.requests, isEmpty);
    expect(firstClient.pendingDescriptions, isEmpty);
    expect(secondClient.pendingDescriptions, isEmpty);
  });

  test('不同账号级 scope 仍保持隔离，各自执行密码登录', () async {
    const username = 'cufe-sso-test-scope-isolation';
    final ugrsClient = _ScriptedHttpClient();
    final grsClient = _ScriptedHttpClient();
    _expectPasswordLogin(ugrsClient, cookieValue: 'ugrs-cookie');
    _expectPasswordLogin(grsClient, cookieValue: 'grs-cookie');

    final ugrs = await ZjuAm.getSsoCookie(
      ugrsClient,
      username,
      'test-password',
      sessionScope: 'ugrs:$username',
      reason: '测试本科登录',
    );
    final grs = await ZjuAm.getSsoCookie(
      grsClient,
      username,
      'test-password',
      sessionScope: 'grs:$username',
      reason: '测试研究生登录',
    );

    expect(ugrs?.value, 'ugrs-cookie');
    expect(grs?.value, 'grs-cookie');
    expect(identical(ugrs, grs), isFalse);
    expect(ugrsClient.pendingDescriptions, isEmpty);
    expect(grsClient.pendingDescriptions, isEmpty);
  });

  test('启动时从加密存储恢复 SSO，不执行密码登录', () async {
    const username = 'cufe-sso-test-restore';
    const scope = 'ugrs:cufe-sso-test-restore';
    // 与 ZjuAm 内部 key 格式保持一致，模拟上一次运行写入的加密会话。
    const storageKey = 'cufe_sso_session_${scope}_$username';
    FlutterSecureStorage.setMockInitialValues({
      storageKey: jsonEncode({
        'name': 'CASTGC',
        'value': 'persisted-cookie',
        'domain': 'cufe.edu.cn',
        'path': '/',
        'expires': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
        'savedAt': DateTime.now().toUtc().toIso8601String(),
      }),
    });

    final client = _ScriptedHttpClient();
    final cookie = await ZjuAm.getSsoCookie(
      client,
      username,
      'test-password',
      sessionScope: scope,
      reason: '测试恢复会话',
    );

    expect(cookie?.value, 'persisted-cookie');
    // 恢复成功时不应产生任何 GET/POST 密码登录请求。
    expect(client.requests, isEmpty);
    expect(client.pendingDescriptions, isEmpty);
  });

  test('拿不到真实 SSO Cookie 时不再返回 dummy 凭据', () async {
    const username = 'cufe-sso-test-no-cookie';
    final client = _ScriptedHttpClient()
      ..expectGet(
        _loginUri,
        _ScriptedResponse(
          statusCode: HttpStatus.ok,
          headers: {HttpHeaders.contentTypeHeader: 'text/html'},
          body: '<input id="execution" value="execution-1">'
              '<input id="pwdEncryptSalt" value="0123456789abcdef">',
        ),
      )
      ..expectPost(
        _loginUri,
        _ScriptedResponse(
          statusCode: HttpStatus.found,
          headers: {
            HttpHeaders.locationHeader:
                'https://xuanke.cufe.edu.cn/sso/jziotlogin?ticket=ST-test',
          },
        ),
      );

    await expectLater(
      ZjuAm.getSsoCookie(
        client,
        username,
        'test-password',
        sessionScope: 'ugrs:$username',
        reason: '测试无 Cookie',
      ),
      throwsA(anything),
    );
    expect(
      ZjuAm.peekSsoCookie(
        client,
        username,
        sessionScope: 'ugrs:$username',
      ),
      isNull,
    );
    expect(client.pendingDescriptions, isEmpty);
  });
}

typedef _ResponseFactory = FutureOr<HttpClientResponse> Function(
  _ScriptedRequest request,
);

class _ExpectedExchange {
  final String method;
  final Uri uri;
  final _ResponseFactory responseFactory;

  _ExpectedExchange(this.method, this.uri, this.responseFactory);

  String get description => '$method $uri';
}

class _ScriptedHttpClient implements HttpClient {
  final Queue<_ExpectedExchange> _pending = Queue<_ExpectedExchange>();
  final List<_ScriptedRequest> requests = <_ScriptedRequest>[];

  List<String> get pendingDescriptions =>
      _pending.map((exchange) => exchange.description).toList(growable: false);

  void expectGet(Uri uri, HttpClientResponse response) {
    expectGetAsync(uri, (_) => response);
  }

  void expectGetAsync(Uri uri, _ResponseFactory responseFactory) {
    _pending.add(_ExpectedExchange('GET', uri, responseFactory));
  }

  void expectPost(Uri uri, HttpClientResponse response) {
    _pending.add(_ExpectedExchange('POST', uri, (_) => response));
  }

  Future<HttpClientRequest> _open(String method, Uri uri) async {
    if (_pending.isEmpty) {
      throw StateError('Unexpected HTTP request: $method $uri');
    }
    final expected = _pending.removeFirst();
    if (expected.method != method || expected.uri != uri) {
      throw StateError(
        'Unexpected HTTP request: $method $uri; expected ${expected.description}',
      );
    }
    final request = _ScriptedRequest(method, uri, expected.responseFactory);
    requests.add(request);
    return request;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _open('GET', url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _open('POST', url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected HttpClient call: $invocation');
}

class _ScriptedRequest implements HttpClientRequest {
  @override
  final String method;
  @override
  final Uri uri;
  final _ResponseFactory _responseFactory;
  @override
  final List<Cookie> cookies = <Cookie>[];
  @override
  final _TestHttpHeaders headers = _TestHttpHeaders();
  final List<int> body = <int>[];

  bool _followRedirects = true;
  bool _closed = false;

  _ScriptedRequest(this.method, this.uri, this._responseFactory);

  @override
  bool get followRedirects => _followRedirects;

  @override
  set followRedirects(bool value) => _followRedirects = value;

  @override
  void add(List<int> data) => body.addAll(data);

  @override
  Future<HttpClientResponse> close() async {
    if (_closed) throw StateError('HTTP request closed twice: $method $uri');
    _closed = true;
    return await _responseFactory(this);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected HttpClientRequest call: $invocation');
}

class _ScriptedResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  @override
  final int statusCode;
  @override
  final HttpHeaders headers;
  @override
  final List<Cookie> cookies;
  final int _bodyLength;

  _ScriptedResponse({
    required this.statusCode,
    Map<String, String> headers = const {},
    List<Cookie> cookies = const [],
    String body = '',
  })  : headers = _TestHttpHeaders(headers),
        cookies = List<Cookie>.from(cookies),
        _bodyLength = utf8.encode(body).length,
        super(Stream<List<int>>.fromIterable([utf8.encode(body)]));

  @override
  int get contentLength => _bodyLength;

  @override
  bool get isRedirect =>
      statusCode == HttpStatus.movedPermanently ||
      statusCode == HttpStatus.found ||
      statusCode == HttpStatus.seeOther ||
      statusCode == HttpStatus.temporaryRedirect ||
      statusCode == HttpStatus.permanentRedirect;

  @override
  String get reasonPhrase => '';

  @override
  bool get persistentConnection => false;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  List<RedirectInfo> get redirects => const <RedirectInfo>[];

  @override
  X509Certificate? get certificate => null;

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected HttpClientResponse call: $invocation');
}

class _TestHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = <String, List<String>>{};
  ContentType? _contentType;

  _TestHttpHeaders([Map<String, String> initial = const {}]) {
    for (final entry in initial.entries) {
      set(entry.key, entry.value);
    }
  }

  @override
  ContentType? get contentType => _contentType;

  @override
  set contentType(ContentType? value) {
    _contentType = value;
    if (value == null) {
      _values.remove(HttpHeaders.contentTypeHeader);
    } else {
      _values[HttpHeaders.contentTypeHeader] = <String>[value.toString()];
    }
  }

  @override
  List<String>? operator [](String name) {
    final values = _values[name.toLowerCase()];
    return values == null ? null : List<String>.from(values);
  }

  @override
  String? value(String name) {
    final values = _values[name.toLowerCase()];
    if (values == null || values.isEmpty) return null;
    if (values.length > 1) {
      throw HttpException('More than one value for header $name');
    }
    return values.single;
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    final key = name.toLowerCase();
    final additions = value is Iterable
        ? value.map((item) => item.toString())
        : <String>[value.toString()];
    _values.putIfAbsent(key, () => <String>[]).addAll(additions);
    if (key == HttpHeaders.contentTypeHeader) {
      _contentType = ContentType.parse(_values[key]!.last);
    }
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    final key = name.toLowerCase();
    final values = value is Iterable
        ? value.map((item) => item.toString()).toList()
        : <String>[value.toString()];
    _values[key] = values;
    if (key == HttpHeaders.contentTypeHeader) {
      _contentType = ContentType.parse(values.single);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected HttpHeaders call: $invocation');
}
