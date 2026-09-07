# -*- coding: utf-8 -*-
"""
CUFE 一卡通（yktapp.cufe.edu.cn）前端接口对接工具模块。

背景说明：
    yktapp 前端（Vue/uni-app 网页版）与后端之间的业务参数通过 datajson 字段
    传输，其编码方式为 AES-128-ECB + PKCS7 + Base64，且每次请求随机生成密钥，
    密钥经过字符重排后拼在密文前面一并传输。

    datajson 结构：
        datajson = handle_key(key, encrypt=True) + Base64(AES-ECB-PKCS7(json参数, key))
    其中 key 为 16 位随机可见字符（A-Za-z0-9），handle_key 为字符重排函数。

    响应端：
        真实密钥 = handle_key(datajson[:16], encrypt=False)
        明文     = AES-ECB 解密 Base64(datajson[16:])，去掉 PKCS7 填充。

参考：
    前端逻辑位于 https://yktapp.cufe.edu.cn/static/js/index.ba4a36f5.js
    的模块 46c2（w / handleKey / aesEncrypt / aesDecrypt / genKey）。
    本模块已用 yktapp.har 抓包样本双向验证。
"""

import base64
import json
import random
import re
import string
import urllib.parse
from datetime import datetime
from typing import Any, Dict, Optional

import requests
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad, unpad

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

# 服务端基础地址
BASE_URL = "https://yktapp.cufe.edu.cn"

# 企业微信内置浏览器的 User-Agent：不带（或不带正确的）UA 服务端会返回 403
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/107.0.5304.110 Safari/537.36 "
    "Language/zh ColorScheme/Light wxwork/5.0.10 (MicroMessenger/6.2) "
    "WindowsWechat  MailPlugin_Electron WeMail embeddisk "
    "wwmver/3.26.510.632 noMediaCs/true"
)

# 前端请求头里固定的业务字段（index.ba4a36f5.js 模块 46c2 的 globalData.header）
DEFAULT_HEADERS = {
    "User-Agent": USER_AGENT,
    "Accept": "application/json, text/plain, */*",
    "x-requested-with": "XMLHttpRequest",
    "session-type": "uniapp",
    "isWechatApp": "true",
}

# 前端固定参数：机构号（全局数据 orgid），openid 由 OAuth 流程获取
DEFAULT_ORGID = "2"
# 用户类型：1 = 学生（抓包首次登录时前端默认值）
DEFAULT_USERTYPE = "1"

# 随机密钥的字符集与长度（前端 genKey 函数）
_KEY_CHARS = string.ascii_letters + string.digits
_KEY_LENGTH = 16


# ---------------------------------------------------------------------------
# 加解密核心
# ---------------------------------------------------------------------------

def _gen_key(length: int = _KEY_LENGTH) -> str:
    """生成指定长度的随机密钥字符（与前端 genKey 一致）。"""
    return "".join(random.choice(_KEY_CHARS) for _ in range(length))


def handle_key(s: str, encrypt: bool) -> str:
    """
    密钥混淆函数，与前端 handleKey 完全一致。

    加密方向：s[10:] + s[:10] 之后整体反转；
    解密方向：先整体反转，再 s[6:] + s[:6]。
    两个方向互逆，长度为 16 时无信息损失。
    """
    if encrypt:
        return (s[10:] + s[:10])[::-1]
    return s[::-1][6:] + s[::-1][:6]


def aes_encrypt(plaintext: str, key: str) -> str:
    """
    用密钥 key 对 plaintext 做 AES-128-ECB + PKCS7 加密，返回 Base64 字符串。

    等价于前端 aesEncrypt：
        CryptoJS.AES.encrypt(Utf8(plaintext), Utf8(key),
                             {mode: ECB, padding: Pkcs7}).toString()
    """
    cipher = AES.new(key.encode("utf-8"), AES.MODE_ECB)
    ciphertext = cipher.encrypt(pad(plaintext.encode("utf-8"), AES.block_size))
    return base64.b64encode(ciphertext).decode("ascii")


def aes_decrypt(cipher_b64: str, key: str) -> str:
    """
    用密钥 key 对 Base64 密文做 AES-128-ECB + PKCS7 解密，返回明文字符串。

    等价于前端 aesDecrypt 中的
        CryptoJS.enc.Utf8.stringify(AES.decrypt(cipher_b64, Utf8(key),
                                                {mode: ECB, padding: Pkcs7}))
    """
    ciphertext = base64.b64decode(cipher_b64)
    cipher = AES.new(key.encode("utf-8"), AES.MODE_ECB)
    plaintext = unpad(cipher.decrypt(ciphertext), AES.block_size)
    return plaintext.decode("utf-8")


def build_datajson(params: Dict[str, Any]) -> str:
    """
    构造请求用的 datajson 参数（与前端 w 函数一致）。

    流程：
        1. 随机生成 16 位密钥 key；
        2. 对 JSON 序列化后的参数做 AES-ECB-PKCS7 加密并 Base64；
        3. 返回 handle_key(key, True) + Base64 密文 拼接串。
    """
    # json.dumps 默认紧凑输出且键序与插入顺序一致，与前端 JSON.stringify 行为一致
    payload = json.dumps(params, ensure_ascii=False, separators=(",", ":"))
    key = _gen_key()
    return handle_key(key, True) + aes_encrypt(payload, key)


def paycode_to_bytes(code: str) -> bytes:
    """
    将付款码（data.code，244 位 hex）转为二维码应编码的原始字节。

    与前端一致（qrcode 页面 Str2Bytes + qrcodejs getFrame）：
        - 每 2 个 hex 字符解析为 1 字节（parseInt(,16) + charCode & 0xFF）；
        - 二维码数据为该 122 字节的原始二进制，不做任何 UTF-8 转换。
    """
    # 奇数长度无法按 2 位一组解析，与前端 Str2Bytes 返回 null 的行为一致
    if len(code) % 2 != 0:
        raise ValueError("付款码长度必须为偶数")
    return bytes.fromhex(code)


def paycode_to_qr(code: str, box_size: int = 10, border: int = 4):
    """
    按前端行为把付款码渲染为二维码 PIL Image。

    前端 qrcodejs 库对二进制字符串逐字符取低 8 位（charCodeAt & 0xFF）打包，
    即 QR 数据 = 付款码原始字节，本函数用字节模式（optimize=0）复刻该行为；
    纠错级别取 qrcodejs 默认值 L（扫码只识别内容，级别不影响正确性）。
    """
    import qrcode  # 延迟导入，避免未安装时影响纯接口调用

    qr = qrcode.QRCode(
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=box_size,
        border=border,
    )
    # optimize=0：禁止模式优化，强制 8bit 字节模式，与前端字节打包一致
    qr.add_data(paycode_to_bytes(code), optimize=0)
    qr.make(fit=True)
    return qr.make_image()


def parse_datajson(datajson: str) -> Any:
    """
    解析响应里的 datajson 字段，返回明文（若以 { 或 [ 开头则返回解析后的对象）。

    流程：
        1. 前 16 个字符是混淆密钥，用 handle_key 还原出真实密钥；
        2. 剩余部分是 Base64 密文，AES-ECB-PKCS7 解密得到 JSON 文本；
        3. 与前端 aesDecrypt 一致：首字符为 { 或 [ 时 JSON.parse。
    """
    # 数据长度不足 16 时视为明文（或异常数据）直接原样返回
    if len(datajson) < _KEY_LENGTH:
        return datajson
    key = handle_key(datajson[:_KEY_LENGTH], False)
    plaintext = aes_decrypt(datajson[_KEY_LENGTH:], key)
    if plaintext[:1] in ("{", "["):
        return json.loads(plaintext)
    return plaintext


def _ensure_openid(params: Dict[str, Any], openid: Optional[str]) -> Dict[str, Any]:
    """按前端 get/post 封装的逻辑补全 openid 与 orgid 参数。"""
    merged = dict(params)
    if openid:
        merged.setdefault("openid", openid)
    merged.setdefault("orgid", DEFAULT_ORGID)
    return merged


# ---------------------------------------------------------------------------
# HTTP 请求封装
# ---------------------------------------------------------------------------

class YktappSession:
    """
    yktapp 接口会话：自动携带企业微信 UA 与业务请求头、维护 Cookie，
    请求参数自动加密为 datajson、响应自动解密为明文对象。
    """

    def __init__(self, base_url: str = BASE_URL, cookie: Optional[str] = None):
        # requests.Session 负责 Cookie 持久化与连接复用
        self.session = requests.Session()
        self.base_url = base_url.rstrip("/")
        self.session.headers.update(DEFAULT_HEADERS)
        if cookie:
            # 外部传入的原始 Cookie 串（例如 "JSESSIONID=xxx; platformMultilingual=zh_CN"）
            self.session.headers["Cookie"] = cookie

    def _request(self, method: str, path: str, params: Optional[Dict[str, Any]] = None,
                 query: Optional[Dict[str, Any]] = None, decrypt: bool = True) -> Any:
        """
        执行一次请求：参数加密为 datajson，响应按需解密。

        query 为直接放在 URL 上的查询参数（部分 POST 接口会附带 openid 查询参数，
        如 /offlineCode/openVirtualcard?openid=XXX，与前端行为一致）。
        """
        url = self.base_url + path
        datajson = build_datajson(_ensure_openid(params or {}, self._openid))
        merged_query = dict(query or {})
        if method.upper() == "GET":
            # GET 请求 datajson 走查询参数，需 URL 编码（Base64 中的 + / =）
            merged_query["datajson"] = datajson
            response = self.session.get(url, params=merged_query, timeout=30)
        else:
            # POST 请求 datajson 放在 JSON body 中，查询参数原样拼接在 URL 上
            response = self.session.post(
                url,
                params=merged_query,
                json={"datajson": datajson},
                timeout=30,
                headers={"Content-Type": "application/json"},
            )
        # 会话内的 Cookie 由 requests 自动持久化；403/401 等由上层处理
        body = response.json() if response.headers.get("Content-Type", "").startswith(
            "application/json") else response.text
        if decrypt and isinstance(body, dict) and "datajson" in body:
            return parse_datajson(body["datajson"])
        return body

    @property
    def _openid(self) -> Optional[str]:
        """从当前会话状态中取出 openid（由 open_home_page 流程写入）。"""
        return getattr(self, "openid", None)

    def open_home_page(self, code: str, state: str = "STATE") -> str:
        """
        模拟企业微信 OAuth 回调后的跳转（/home/openHomePage）。

        携带企业微信授权 code 访问后服务端 302 跳转到
            https://yktapp.cufe.edu.cn#/pages/homepage/index/index?openid=...
        本方法拦截 302、从 Location 中解析 openid 并保存到会话，
        同时自动记录服务端下发的 JSESSIONID Cookie。

        返回解析出的 openid。
        """
        url = self.base_url + "/home/openHomePage"
        # allow_redirects=False 拦截 302，Location 里有 openid
        response = self.session.get(
            url, params={"code": code, "state": state}, allow_redirects=False, timeout=30)
        location = response.headers.get("Location", "")
        # openid 可能在 Location 的 query（?openid=）或 fragment（#...?openid=）里
        match = re.search(r"[?&#]openid=([A-Za-z0-9]+)", location)
        if not match:
            raise RuntimeError("openHomePage 响应中未找到 openid，Location: %s" % location)
        self.openid = match.group(1)
        return self.openid

    def open_home_page_app(self, openid: Optional[str] = None,
                           usertype: str = DEFAULT_USERTYPE) -> Dict[str, Any]:
        """拉取一卡通首页信息（/home/openHomePageApp）。"""
        params = _ensure_openid({"usertype": usertype}, openid or self._openid)
        result = self._request("GET", "/home/openHomePageApp", params)
        return result if isinstance(result, dict) else {}

    def query_wechat_user_last_info(self, openid: Optional[str] = None,
                                    idserial: Optional[str] = None) -> Dict[str, Any]:
        """查询微信用户最近信息（POST /myaccount/querywechatUserLastInfo）。"""
        params = _ensure_openid({}, openid or self._openid)
        if idserial:
            params["idserial"] = idserial
        result = self._request("POST", "/myaccount/querywechatUserLastInfo", params)
        return result if isinstance(result, dict) else {}

    # ------------------------------------------------------------------
    # 付款码（离线码）相关接口
    # ------------------------------------------------------------------

    def open_virtualcard(self, openid: Optional[str] = None,
                         paytype: Optional[str] = None,
                         appcode: str = "4") -> Dict[str, Any]:
        """
        开通/刷新付款码（POST /offlineCode/openVirtualcard）。

        前端在首次开通时携带 paytype="1"，后续定时刷新（约 30 秒）时不携带；
        appcode 恒为 "4"。接口的 URL 上附带 openid 查询参数（与前端一致）。

        返回的 data.code 即为付款码（paycode，十六进制长串），
        其余字段包含 idserial（学号）、realname（姓名）、cardbal（余额）。
        """
        params = _ensure_openid({"appcode": appcode}, openid or self._openid)
        if paytype is not None:
            params["paytype"] = paytype
        result = self._request("POST", "/offlineCode/openVirtualcard", params,
                               query={"openid": params["openid"]})
        return result if isinstance(result, dict) else {}

    def query_order_status(self, paycode: str,
                           openid: Optional[str] = None) -> Dict[str, Any]:
        """
        查询付款码的支付状态（POST /virtualcard/queryOrderStatus）。

        前端获取付款码后定时轮询本接口，直到支付完成或码过期；
        data.status 为 "5" 表示支付失败/付款码未使用。
        """
        params = _ensure_openid({"paycode": paycode}, openid or self._openid)
        result = self._request("POST", "/virtualcard/queryOrderStatus", params,
                               query={"openid": params["openid"]})
        return result if isinstance(result, dict) else {}

    def query_default_skin(self, openid: Optional[str] = None) -> Dict[str, Any]:
        """查询默认虚拟卡皮肤（GET /virtualcard/queryDefaultSkin）。"""
        # nowdate 使用非零填充的 "YYYY-M-D H:M:S" 格式，与前端拼接方式一致
        now = datetime.now()
        nowdate = "%d-%d-%d %d:%d:%d" % (now.year, now.month, now.day,
                                         now.hour, now.minute, now.second)
        params = _ensure_openid({"nowdate": nowdate}, openid or self._openid)
        result = self._request("GET", "/virtualcard/queryDefaultSkin", params)
        return result if isinstance(result, dict) else {}

    def query_bind_payskin(self, idserial: str,
                           openid: Optional[str] = None) -> Dict[str, Any]:
        """查询已绑定的付款码皮肤（GET /virtualcard/queryBindPayskin）。"""
        params = _ensure_openid({"idserial": idserial}, openid or self._openid)
        result = self._request("GET", "/virtualcard/queryBindPayskin", params)
        return result if isinstance(result, dict) else {}


# ---------------------------------------------------------------------------
# 便捷函数（无状态单次调用）
# ---------------------------------------------------------------------------

def open_home_page_code(code: str, state: str = "STATE") -> str:
    """无状态快捷入口：用 code 换 openid。"""
    return YktappSession().open_home_page(code, state)


if __name__ == "__main__":
    # 直接运行时的自检：验证加解密双向一致性与密钥还原
    sample = {"openid": "2CDDDBD64425124A5B62469F7BCA92C923AD61F48F2D8BFA8A884D31E2F37AAF",
              "usertype": "1", "orgid": "2"}
    datajson = build_datajson(sample)
    assert handle_key(datajson[:16], False) != ""
    assert parse_datajson(datajson) == sample
    print("自检通过 datajson 长度:", len(datajson))
