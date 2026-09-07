import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../utils/utils.dart';

class ECardWidgetMessenger {
  static void installNativeHandler() {
    // 苹果手表原生交互模块已根据要求删除
  }

  static Future<bool> update({bool notifyNative = true}) async {
    // 后台定期获取一卡通 Token 的逻辑暂时留空，之后根据中财的实际接口补齐
    return true;
  }

  static Future<void> logout() async {
    const secureStorage = FlutterSecureStorage();
    await secureStorage.delete(
        key: 'cufeOpenId', iOptions: secureStorageIOSOptions);
  }
}
