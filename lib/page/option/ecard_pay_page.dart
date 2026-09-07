import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:qr/qr.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:celechron/design/persistent_headers.dart';
import '../../http/zjuServices/ecard.dart';
import '../../utils/utils.dart';

class ECardPayPage extends StatefulWidget {
  const ECardPayPage({super.key});

  @override
  State<ECardPayPage> createState() => _ECardPayPageState();
}

class _ECardPayPageState extends State<ECardPayPage> {
  final _httpClient = HttpClient();
  Timer? _refreshTimer;
  
  bool _loading = true;
  String _barcode = '';
  String _balance = '';
  String _realname = '';

  @override
  void initState() {
    super.initState();
    _fetchCode();
    // 每 30 秒自动刷新一次，避免二维码在收银机处被提示“已过期”
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _fetchCode();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _httpClient.close();
    super.dispose();
  }

  Future<void> _fetchCode() async {
    setState(() {
      _loading = true;
    });
    
    const secureStorage = FlutterSecureStorage();
    var cufeOpenId = await secureStorage.read(
        key: 'cufeOpenId', iOptions: secureStorageIOSOptions);

    if (cufeOpenId == null || cufeOpenId.isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _barcode = 'PLEASE_CONFIGURE_OPENID';
          _balance = '';
          _realname = '';
        });
      }
      return;
    }

    try {
      final res = await ECard.getBarcodeWithBalance(_httpClient, cufeOpenId);
      if (mounted) {
        setState(() {
          _loading = false;
          _barcode = res['code'] ?? '';
          _balance = res['balance'] ?? '';
          _realname = res['realname'] ?? '';
        });
      }
    } catch (e, stackTrace) {
      print('=== ECARD ERROR ===');
      print(e);
      print(stackTrace);
      if (mounted) {
        setState(() {
          _loading = false;
          _barcode = 'ERROR';
          _balance = '';
          _realname = '';
        });
      }
    }
  }

  static Uint8List hexToBytes(String hexStr) {
    if (hexStr.length % 2 != 0) return Uint8List(0);
    final bytes = Uint8List(hexStr.length ~/ 2);
    for (var i = 0; i < hexStr.length; i += 2) {
      bytes[i ~/ 2] = int.parse(hexStr.substring(i, i + 2), radix: 16);
    }
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: SafeArea(
        child: CustomScrollView(
          slivers: [
            const CelechronSliverTextHeader(subtitle: '校园卡付款码'),
            SliverFillRemaining(
                child: Column(
              children: [
                const Spacer(flex: 4),
                if (_loading && _barcode.isEmpty)
                  const CupertinoActivityIndicator()
                else
                  GestureDetector(
                    onTap: _fetchCode,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 200,
                          height: 200,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        if (_barcode == 'PLEASE_CONFIGURE_OPENID')
                          const Text('请先在选项页\n配置 OpenID',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: CupertinoColors.black))
                        else if (_barcode != 'ERROR' && _barcode.isNotEmpty)
                          QrImageView.withQr(
                              qr: QrCode.fromUint8List(
                                  data: hexToBytes(_barcode),
                                  errorCorrectLevel: QrErrorCorrectLevel.L),
                              size: 200)
                        else
                          const Text('加载失败',
                              style: TextStyle(color: CupertinoColors.black)),
                      ],
                    ),
                  ),
                const SizedBox(height: 20),
                if (_loading && _barcode.isEmpty)
                  const Text('加载中...')
                else if (_barcode == 'PLEASE_CONFIGURE_OPENID')
                  const Text('未配置 OpenID')
                else if (_barcode == 'ERROR')
                  const Text('获取失败，请重试')
                else
                  Text(
                      (_realname.isNotEmpty ? '姓名：$_realname\n' : '') +
                          '余额：$_balance 元\n(已开启 30 秒自动刷新)',
                      textAlign: TextAlign.center),
                const SizedBox(height: 30),
                if (_loading)
                  const CupertinoActivityIndicator()
                else
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    color: CupertinoColors.activeBlue,
                    borderRadius: BorderRadius.circular(20),
                    onPressed: _fetchCode,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.refresh, size: 18, color: CupertinoColors.white),
                        SizedBox(width: 8),
                        Text('刷新二维码',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: CupertinoColors.white),
                        ),
                      ],
                    ),
                  ),
                const Spacer(flex: 6),
              ],
            ))
          ],
        ),
      ),
    );
  }
}
