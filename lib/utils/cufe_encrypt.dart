import 'dart:math';
import 'package:encrypt/encrypt.dart';

class CufeEncrypt {
  static const String _aesChars = "ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678";

  static String _randomString(int length) {
    final rnd = Random();
    return String.fromCharCodes(Iterable.generate(
        length, (_) => _aesChars.codeUnitAt(rnd.nextInt(_aesChars.length))));
  }

  static String encryptPassword(String password, String salt) {
    if (salt.isEmpty) return password;
    
    final keyStr = salt.trim();
    final ivStr = _randomString(16);
    final dataStr = _randomString(64) + password;

    final key = Key.fromUtf8(keyStr);
    final iv = IV.fromUtf8(ivStr);

    final encrypter = Encrypter(AES(key, mode: AESMode.cbc, padding: 'PKCS7'));
    final encrypted = encrypter.encrypt(dataStr, iv: iv);
    
    return encrypted.base64;
  }
}
