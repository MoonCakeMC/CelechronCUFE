# -*- coding: utf-8 -*-
"""
CUFE 一卡通（yktapp.cufe.edu.cn）完整访问流程模拟脚本。

流程（对应 yktapp.har / yktfkm.har 抓包）：
    1. 在企业微信中打开应用 → 企业微信向 yktapp 发起 OAuth 回调
       GET /home/openHomePage?code=XXX&state=STATE
       （code 由企业微信发放，一次性有效，需自行提供）
    2. 服务端 302 跳转到
       https://yktapp.cufe.edu.cn#/pages/homepage/index/index?openid=XXX
       并下发 JSESSIONID Cookie
    3. 携带 openid 拉取首页信息
       GET /home/openHomePageApp?datajson=加密({openid, usertype, orgid})
    4. 可选：查询微信用户最近信息（返回学号 idserial）
       POST /myaccount/querywechatUserLastInfo
    5. 可选：开通/刷新付款码并轮询支付状态
       POST /offlineCode/openVirtualcard → data.code（付款码）
       POST /virtualcard/queryOrderStatus → 轮询支付结果

用法：
    python yktapp_flow.py <code>
    python yktapp_flow.py <code> --idserial 2026310926
    python yktapp_flow.py <code> --paycode

其中 <code> 为企业微信 OAuth 一次性授权码：
    - 可从抓包工具（如 Fiddler）中再次访问应用时获取；
    - 或从企业微信开发者工具构造授权链接后回调中获取。
"""

import argparse
import json
import sys
import time
from typing import Optional

from yktapp import YktappSession, paycode_to_qr


def run_paycode(client: YktappSession) -> dict:
    """开通付款码、生成二维码并轮询支付状态，返回付款码与最终状态。"""
    print("     [a] 开通付款码 /offlineCode/openVirtualcard ...")
    # 首次开通携带 paytype="1"，与前端首次开通行为一致
    pay = client.open_virtualcard(paytype="1")
    print("         付款码响应:", json.dumps(pay, ensure_ascii=False)[:400])
    code = (pay.get("data") or {}).get("code", "")
    if not code:
        print("         未取得付款码，结束")
        return {"paycode": "", "status": None}

    print("     [b] 生成二维码（122 字节原始二进制，与前端一致）...")
    qr_image = paycode_to_qr(code)
    qr_path = "paycode.png"
    qr_image.save(qr_path)
    print("         二维码已保存:", qr_path, qr_image.size)

    print("     [c] 轮询支付状态 /virtualcard/queryOrderStatus ...")
    for round_no in range(1, 4):
        time.sleep(3)
        status = client.query_order_status(code)
        print("         第 %d 次轮询:" % round_no,
              json.dumps(status, ensure_ascii=False)[:300])
    return {"paycode": code, "status": status}


def run_flow(code: str, idserial: Optional[str] = None,
             with_paycode: bool = False) -> dict:
    """执行完整流程并返回结果摘要。"""
    # 会话自动管理 JSESSIONID Cookie 与 openid
    client = YktappSession()

    print("[1/4] OAuth 回调 /home/openHomePage ...")
    openid = client.open_home_page(code)
    print("      openid =", openid)

    print("[2/4] 拉取首页信息 /home/openHomePageApp ...")
    home = client.open_home_page_app()
    # 首页信息里一般包含 cardinfo（卡信息）、funcList（功能列表）等
    print("      首页返回:", json.dumps(home, ensure_ascii=False)[:500])

    print("[3/4] 查询最近登录信息 /myaccount/querywechatUserLastInfo ...")
    user_info = client.query_wechat_user_last_info(idserial=idserial)
    print("      用户信息:", json.dumps(user_info, ensure_ascii=False)[:500])

    paycode = {}
    if with_paycode:
        print("[4/4] 付款码流程 ...")
        paycode = run_paycode(client)
    else:
        print("[4/4] 完成")

    return {"openid": openid, "home": home, "user_info": user_info,
            "paycode": paycode}


def main() -> int:
    # 命令行参数：code 必填，idserial 可选（已有学号时可省一次查询）
    parser = argparse.ArgumentParser(description="yktapp 一卡通流程模拟")
    parser.add_argument("code", help="企业微信 OAuth 一次性授权码")
    parser.add_argument("--idserial", default=None, help="学号（可选，已知时跳过查询）")
    parser.add_argument("--paycode", action="store_true",
                        help="同时演示付款码开通与支付状态轮询")
    args = parser.parse_args()

    try:
        result = run_flow(args.code, args.idserial, with_paycode=args.paycode)
    except RuntimeError as exc:
        print("流程失败:", exc, file=sys.stderr)
        return 1
    print(json.dumps(result["user_info"], ensure_ascii=False, indent=2))
    if args.paycode:
        print(json.dumps(result["paycode"], ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
