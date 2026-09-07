import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:encrypt/encrypt.dart' as encrypt_pkg;

import 'exceptions.dart';
import 'response_utils.dart';

class YktAppCrypto {
  static const _keyChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  static String _genKey() {
    final rand = Random.secure();
    return List.generate(16, (_) => _keyChars[rand.nextInt(_keyChars.length)]).join();
  }

  static String _handleKey(String s, bool isEncrypt) {
    if (isEncrypt) {
      final shifted = s.substring(10) + s.substring(0, 10);
      return shifted.split('').reversed.join();
    } else {
      final reversed = s.split('').reversed.join();
      return reversed.substring(6) + reversed.substring(0, 6);
    }
  }

  static String buildDataJson(Map<String, dynamic> params) {
    final payload = jsonEncode(params);
    final key = _genKey();

    final encrypter = encrypt_pkg.Encrypter(
        encrypt_pkg.AES(encrypt_pkg.Key.fromUtf8(key), mode: encrypt_pkg.AESMode.ecb, padding: 'PKCS7'));

    final encrypted = encrypter.encrypt(payload, iv: encrypt_pkg.IV.fromLength(16));
    final b64 = encrypted.base64;

    return _handleKey(key, true) + b64;
  }

  static dynamic parseDataJson(String dataJson) {
    if (dataJson.length < 16) return dataJson;

    final keyStr = _handleKey(dataJson.substring(0, 16), false);
    final cipherB64 = dataJson.substring(16);

    final encrypter = encrypt_pkg.Encrypter(
        encrypt_pkg.AES(encrypt_pkg.Key.fromUtf8(keyStr), mode: encrypt_pkg.AESMode.ecb, padding: 'PKCS7'));

    try {
      final decrypted = encrypter.decrypt64(cipherB64, iv: encrypt_pkg.IV.fromLength(16));

      if (decrypted.startsWith('{') || decrypted.startsWith('[')) {
        return jsonDecode(decrypted);
      }
      return decrypted;
    } catch (e, stack) {
      print("=== DECRYPT ERROR ===");
      print(e);
      print(stack);
      rethrow;
    }
  }
}

class ECard {
  static const String _baseUrl = "https://yktapp.cufe.edu.cn";
  static const String _userAgent =
      "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.5304.110 Safari/537.36 Language/zh ColorScheme/Light wxwork/5.0.10 (MicroMessenger/6.2) WindowsWechat  MailPlugin_Electron WeMail embeddisk wwmver/3.26.510.632 noMediaCs/true";

  static Future<Map<String, dynamic>> getBarcodeWithBalance(
      HttpClient httpClient, String openId) async {
    
    httpClient.userAgent = _userAgent;

    // 先模拟前端请求 openHomePageApp 建立会话并获取 JSESSIONID
    final initParams = {
      "usertype": "1",
      "orgid": "2",
      "openid": openId,
    };
    final initDataJson = YktAppCrypto.buildDataJson(initParams);
    // GET 请求需进行 URL 编码
    final encodedDataJson = Uri.encodeComponent(initDataJson);
    final initUri = Uri.parse("$_baseUrl/home/openHomePageApp?openid=$openId&datajson=$encodedDataJson");
    
    final initReq = await httpClient.getUrl(initUri).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw ExceptionWithMessage("请求超时"));
    initReq.headers.set("Accept", "application/json, text/plain, */*");
    initReq.headers.set("x-requested-with", "XMLHttpRequest", preserveHeaderCase: true);
    initReq.headers.set("session-type", "uniapp", preserveHeaderCase: true);
    initReq.headers.set("isWechatApp", "true", preserveHeaderCase: true);
    final initRes = await initReq.close().timeout(const Duration(seconds: 15),
        onTimeout: () => throw ExceptionWithMessage("请求超时"));
    
    // Dart 自带的 initRes.cookies 会由于服务器下发的 "null; SameSite" 等格式不规范报错 FormatException，因此手动提取
    final setCookies = initRes.headers[HttpHeaders.setCookieHeader] ?? [];
    final cookieStrParts = <String>[];
    for (var sc in setCookies) {
      final pair = sc.split(';')[0].trim();
      if (pair.isNotEmpty) cookieStrParts.add(pair);
    }
    await initRes.drain(); // 丢弃响应体，仅获取 Cookie

    final uri = Uri.parse("$_baseUrl/offlineCode/openVirtualcard?openid=$openId");
    final request = await httpClient.postUrl(uri).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw ExceptionWithMessage("请求超时"));
    
    if (cookieStrParts.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookieStrParts.join('; '));
    }

    request.headers.set("Accept", "application/json, text/plain, */*");
    request.headers.set("x-requested-with", "XMLHttpRequest", preserveHeaderCase: true);
    request.headers.set("session-type", "uniapp", preserveHeaderCase: true);
    request.headers.set("isWechatApp", "true", preserveHeaderCase: true);
    request.headers.set("Content-Type", "application/json", preserveHeaderCase: true);

    final params = {
      "appcode": "4",
      "orgid": "2",
      "openid": openId,
      // 首次可以带 paytype="1"，但如果不确定，可以不带或带 1。
      "paytype": "1"
    };

    final dataJson = YktAppCrypto.buildDataJson(params);
    request.write(jsonEncode({"datajson": dataJson}));

    final response = await request.close().timeout(const Duration(seconds: 15),
        onTimeout: () => throw ExceptionWithMessage("请求超时"));
        
    final bodyJson = await readResponseText(response, context: '获取付款码', expectJson: true);
    print("=== HTTP RESPONSE BODY ===");
    print(bodyJson);
    
    final payload = decodeJsonMap(bodyJson, context: '获取付款码解析');
    
    if (payload.containsKey('datajson')) {
      final String rawDataJson = payload['datajson'];
      print("=== RAW DATAJSON ===");
      print(rawDataJson);
      
      final decrypted = YktAppCrypto.parseDataJson(rawDataJson.replaceAll(RegExp(r'\s+'), ''));
      print("=== DECRYPTED DATA ===");
      print(decrypted);
      
      if (decrypted is! Map) {
        throw ExceptionWithMessage("解密后的数据不是 JSON 对象: $decrypted");
      }
      
      final Map<String, dynamic> data = decrypted['data'] ?? {};
      
      final code = data['code'] as String?;
      final balance = data['cardbal']?.toString();
      final realname = data['realname'] as String?;
      
      if (code == null || code.isEmpty) {
         throw ExceptionWithMessage("返回的条码为空. Decrypted data: $decrypted");
      }
      return {
        "code": code,
        "balance": balance,
        "realname": realname,
      };
    } else {
      throw ExceptionWithMessage("返回结构不含 datajson. Body: $bodyJson");
    }
  }
}
