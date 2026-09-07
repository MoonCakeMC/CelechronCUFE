# yktapp 付款码页面机制与接口规范

> 依据前端脚本逆向整理，来源：
> - `https://yktapp.cufe.edu.cn/static/js/pages_other-qrcode-qrcode-qrcode.a7a70734.js`（付款码页面，模块 `a266`）
> - `https://yktapp.cufe.edu.cn/static/js/pages-homepage-guidePage-guidePage~pages_other-qrcode-qrcode-qrcode.c7b54e68.js`（共享 chunk，模块 `194a` 为 QR 生成库、`f7b9` 为摇一摇工具）
> - `https://yktapp.cufe.edu.cn/static/js/index.ba4a36f5.js`（模块 `46c2` 请求封装、`2a7d` 语言包）
> - 抓包样本：`yktfkm.har`、`yktapp.har`

---

## 1. 页面刷新机制

### 1.1 自动刷新（盲定时刷新，无失效检测）

页面 `onShow` 中启动两个定时器：

| 定时器 | 周期 | 动作 | 源码 |
|---|---|---|---|
| `timerTask1` | 60 秒 | `refreshPaycode()` → `initPage()` → 重新调 `openVirtualcard` 换取新付款码 | `setInterval(..., 6e4)` |
| `timerTask2` | 3 秒 | `queryOrder()` → 轮询 `queryOrderStatus` | `setInterval(..., 3e3)` |

- **不存在"检测二维码失效"的逻辑**：60 秒定时无条件换码；支付结果通过 3 秒轮询反馈。
- 页面文案（语言包 `qrcode.refreshpcode`）：**"每分钟自动刷新，连续使用请刷新付款码"**。
  （语言包中 `skin.tip2` 的"自动刷新间隔30S"是皮肤页文案，与付款码无关。）
- 定时器回调先检查当前页面路由是否为 `pages_other/qrcode/qrcode/qrcode`，不是则 `clearInterval` 自毁。
- `onHide` / `onUnload` 中清理两个定时器并 `setShakeType(1)`。

### 1.2 手动刷新

- 点击二维码 canvas（离线码）或图片（在线码）→ `refreshPaycode`；
- 底部按钮"付款码刷新"（语言包 `qrcode.fkmsx`）→ `refreshPaycode`。

### 1.3 摇一摇

- 工具模块 `f7b9`：`setShakeType(1)` 启用、`setShakeType(2)` 禁用。
- 付款码页面 `onLoad` 时 `setShakeType(2)`（禁用），离开时恢复为 1。
- 摇一摇触发时 GET 首页配置的 `shakeurl` 并按其返回 `url` 跳转（首页功能，与付款码无关）。

### 1.4 支付结果跳转

`queryOrderStatus` 响应：

- `success == true` 且 `url` 非空 → `navigateTo(url + "?data=" + JSON.stringify(响应))`（结果页）；
- `success == false` → `redirectTo("/pages/common/fail/fail?data=" + JSON.stringify(响应))`（失败页）。

---

## 2. 接口规范

所有请求遵循统一封装（`index.ba4a36f5.js` 模块 `46c2`）：

- GET：`?datajson=<URL编码的datajson>`；POST：body `{"datajson":"..."}`，部分 POST 的 URL 附带 `?openid=XXX`；
- `datajson = handleKey(随机16位key, true) + Base64(AES-128-ECB-PKCS7(JSON参数, key))`，见 `yktapp.py`；
- 公共参数自动补全：`openid`（会话）、`orgid="2"`；
- 请求头：企业微信 UA（否则 403）、`x-requested-with: XMLHttpRequest`、`session-type: uniapp`、`isWechatApp: true`、`orgid: 2`。

### 2.1 POST /offlineCode/openVirtualcard — 开通/刷新付款码

**请求参数**（加密 body，URL 附带 `?openid=XXX`）：

| 参数 | 说明 |
|---|---|
| `openid` | 必填（自动补） |
| `paytype` | 优先支付方式；首次开通传 `"1"`，存在 `defaultpay` 时用其值，为空则不传 |
| `appcode` | UA 含 `superapp` → `"2"`；含 `micromessenger` → `"4"`；否则不传 |
| `orgid` | `"2"`（自动补） |

**响应**（解密后，HAR 实测样本）：

```json
{
  "data": {
    "code": "563801016CA79FCF8BCE9E175A3C9813731...（244 位 hex 付款码）",
    "qrcode": "",
    "barcode": "",
    "idserial": "2026310926",
    "realname": "吕思齐",
    "cardbal": "0.00",
    "defaultpay": "1"
  },
  "success": true,
  "url": "/pages/qrcode/onoffqrcode/onoffqrcode"
}
```

**前端处理逻辑**：

- `code.startsWith("5638")` → 离线码：`showOnline=false`，hex → 122 字节二进制 → canvas 绘制二维码（见第 4 节）；
- 否则 → 在线码：`showOnline=true`，展示 `data.qrcode` 图片 URL；
- 失败分支：`data.enableOpenQrcodeByUser == "1"` 且 `data.virtualcard == "0"` → 弹窗"校园码暂未开通，是否立即开通？"，确认后调 `openVirtualCardSelf`；
- 其余失败：跳失败页，`title` 缺省"操作"，`message` 缺省"系统异常"。

### 2.2 POST /virtualcard/queryOrderStatus — 支付状态轮询

**请求参数**：`paycode`（openVirtualcard 返回的 `data.code`）、`openid`、`orgid`；URL 附带 `?openid=XXX`。

**响应**（HAR 实测样本）：

```json
{
  "data": {
    "paytime": "2026-09-05 18:08:04",
    "message": "支付失败，付款码未使用",
    "txamt": "0.00",
    "status": "5"
  },
  "success": true,
  "message": "支付失败，付款码未使用",
  "title": "扫码支付"
}
```

**字段语义**（前端源码确认）：

| 字段 | 说明 |
|---|---|
| `success` | **查询本身是否成功，不代表支付成功**（样本中 `success=true` 但支付失败） |
| `url` | 支付完成后返回结果页路径，非空时前端跳转；轮询期间无此字段 |
| `title` | 场景标识："扫码支付"（→文案 `pay.scanpay`）、"门禁扫码"（→文案 `prcode.doorscan`）、空时前端显示"操作"（`common.cz`） |
| `message` | 状态描述，直接展示 |
| `data.paytime` | 支付时间（空为未支付） |
| `data.txamt` | 交易金额 |
| `data.status` | **前端完全不使用该字段**（源码 0 处引用）。实测仅样本 `"5"` = 支付失败/付款码未使用；其他取值无法从前端逆推，需实测补充 |

### 2.3 POST /virtualcard/openVirtualCardSelf — 用户自助开通校园码

- **请求参数**：`{}`（自动补 `openid`/`orgid`）。
- **响应**：`success=true` → 提示"付款码开通成功"并重新 `initPage`；否则跳失败页。

### 2.4 POST /myaccount/querywechatUserLastInfo — 最近绑定信息

- **请求参数**：`idserial`（可空）、`openid`、`orgid`。
- **响应**（HAR 样本）：`{"resultData": {}, "success": true, "message": "CORE10008"}`。
- **付款码页用法**：取 `resultData.messagelastbind`（JSON 字符串）解析 `qrcodeflag`；为 `"0"` 时弹提示"打开 '个人中心'→'设置'→选中'是否允许刷码消费'"并跳转个人中心页。

### 2.5 GET /virtualcard/queryDefaultSkin — 默认皮肤

- **请求参数**：`nowdate`（格式 `"YYYY-M-D H:M:S"`，**时分秒不补零**）、`openid`、`orgid`。
- **响应**：`resultData` 非空 → 取 `[0].imageUrl` 换肤；为空 → 回退调 `queryBindPayskin`。
- HAR 样本：`{"message": "CORE10008", "resultData": [], "success": true}`。

### 2.6 GET /virtualcard/queryBindPayskin — 已绑定付款码皮肤

- **请求参数**：`idserial`、`openid`、`orgid`。
- **响应**：`resultData[0]` 含 `{id, begindate, enddate, displayflag, imageUrl}`；当前日期在 `[begindate, enddate]` 内且 `displayflag == "1"` 时应用该皮肤。

### 2.7 POST /virtualcard/queryBankInfo — 绑定银行卡信息

- **请求参数**：`idserial`、`openid`、`orgid`。
- **响应**：`data.bankcdno`（银行卡号）→ 页面显示末 4 位尾号（`ccb.png` 图标）。

### 2.8 GET /easypayment/easypaymentsign — 微信代扣签约状态

- **请求参数**：`openid`。
- **响应**：`data.isopeneasypay == "SUCCESS"` 时支付方式列表中显示"微信代扣"（type `"3"`）。

### 2.9 GET /myaccount/updatedefaultpay — 更新默认支付方式

- **请求参数**：`idserial`、`paytype`。
- **响应**：前端不处理（仅打日志）。

---

## 3. 支付方式枚举（页面 `payArrys`）

| type | 名称 | 图标 | 显示条件 |
|---|---|---|---|
| `"1"` | 校园卡支付（文案 `cardpay.xykpay`） | `change.png` | 恒显示；标题带一卡通余额 |
| `"2"` | 银行卡（建行） | `ccb.png` | `queryBankInfo` 返回 `bankcdno` 非空时显示，标题带尾号 4 位 |
| `"3"` | 微信代扣（文案 `qrcode.wechatwithholding`） | `change.png` | `easypaymentsign` 返回 `isopeneasypay == "SUCCESS"` 时显示 |

---

## 4. 离线码二维码转换规则（已实测闭环验证）

1. `openVirtualcard` 返回 `data.code`（244 位 hex，`5638` 开头为离线码）；
2. 前端 `Str2Bytes`：每 2 个 hex 字符 `parseInt(,16)` 转 1 字节，`String.fromCharCode` 拼为二进制字符串；
3. QR 库（模块 `194a`，qrcodejs 风格）`getFrame` 逐字符 `charCodeAt & 0xFF` 打包（`utf16to8` 函数存在但**从未调用**），即 **QR 数据 = 122 字节原始二进制，无 UTF-8 转换**；
4. 验证方式：
   - OpenCV 解码真实截图报 `UnicodeDecodeError: byte 0xa7 in position 5`（原始二进制证据）；
   - zbar/pyzbar 对字节模式数据做 ISO-8859-1→UTF-8 转码输出（174 字节），`utf-8 decode → latin-1 encode` 还原即得 122 字节付款码；
   - `yktapp.py` 的 `paycode_to_qr` 生成结果与截图在 cv2/pyzbar 下表现逐字节一致。

---

## 5. 未知项清单（需实测补充）

| 项 | 说明 |
|---|---|
| `queryOrderStatus.data.status` 其他取值 | 前端不使用该字段；仅实测 `"5"`=支付失败/付款码未使用。候选语义（如 0=未支付、1=支付成功、2=支付中…）未证实 |
| 支付成功时 `queryOrderStatus` 的 `url` 与结果页数据结构 | HAR 无成功样本；成功时前端跳 `url + "?data=" + JSON(响应)` |
| `openVirtualcard` 的 `barcode` 字段 | 抓包样本恒为空串 |
| 在线码（非 5638 前缀）的 `data.qrcode` 图片格式 | HAR 无在线码样本 |
| `queryOrderStatus` 的 `title="门禁扫码"` 场景 | 仅从文案逆推，无抓包样本 |
