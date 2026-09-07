# -*- coding: utf-8 -*-
"""
CUFE 一卡通（yktapp.cufe.edu.cn）完整访问流程模拟脚本。

流程（对应 yktapp.har 抓包）：
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

用法：
    python yktapp_flow.py <code>
    python yktapp_flow.py <code> --idserial 2026310926

其中 <code> 为企业微信 OAuth 一次性授权码：
    - 可从抓包工具（如 Fiddler）中再次访问应用时获取；
    - 或从企业微信开发者工具构造授权链接后回调中获取。
"""

import argparse
import json
import sys
from typing import Optional

from yktapp import YktappSession


def run_flow(code: str, idserial: Optional[str] = None) -> dict:
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

    print("[4/4] 完成")
    return {"openid": openid, "home": home, "user_info": user_info}


def main() -> int:
    # 命令行参数：code 必填，idserial 可选（已有学号时可省一次查询）
    parser = argparse.ArgumentParser(description="yktapp 一卡通流程模拟")
    parser.add_argument("code", help="企业微信 OAuth 一次性授权码")
    parser.add_argument("--idserial", default=None, help="学号（可选，已知时跳过查询）")
    args = parser.parse_args()

    try:
        result = run_flow(args.code, args.idserial)
    except RuntimeError as exc:
        print("流程失败:", exc, file=sys.stderr)
        return 1
    print(json.dumps(result["user_info"], ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
