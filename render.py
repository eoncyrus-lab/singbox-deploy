#!/usr/bin/env python3
"""把 config.template.json 渲染成可用配置。

- 替换 __XXX__ 占位符，并把数值/布尔占位符还原成 JSON 原生类型
- 生成 13 条远程 rule_set（download_detour 指向本次的节点 tag）
- --profile bilibili 时注入 B 站/内网直连规则
所有参数从环境变量读，见 install.sh。
"""
import json, os, sys

TPL = sys.argv[1]
tag = os.environ["SB_NODE_TAG"]
host = os.environ["SB_NODE_HOST"]

STR_SUBS = {
    "__NODE_TAG__": tag,
    "__NODE_HOST__": host,
    "__NODE_PASSWORD__": os.environ["SB_NODE_PASSWORD"],
    "__TUN_CIDR__": os.environ["SB_TUN_CIDR"],
    "__CLASH_SECRET__": os.environ["SB_CLASH_SECRET"],
    "__LOG_FILE__": os.environ["SB_LOG"],
}
NUM_SUBS = {
    "__MTU__": int(os.environ["SB_MTU"]),
    "__MIXED_PORT__": int(os.environ["SB_MIXED_PORT"]),
    "__NODE_PORT__": int(os.environ["SB_NODE_PORT"]),
    "__UP_MBPS__": int(os.environ["SB_UP_MBPS"]),
    "__DOWN_MBPS__": int(os.environ["SB_DOWN_MBPS"]),
    "__CLASH_PORT__": int(os.environ["SB_CLASH_PORT"]),
    "__TLS_INSECURE__": os.environ["SB_TLS_INSECURE"].lower() == "true",
}

def walk(node):
    if isinstance(node, dict):
        return {k: walk(v) for k, v in node.items()}
    if isinstance(node, list):
        return [walk(v) for v in node]
    if isinstance(node, str):
        if node in NUM_SUBS:          # 整个字符串就是数值占位符 → 换成原生类型
            return NUM_SUBS[node]
        for ph, val in STR_SUBS.items():
            node = node.replace(ph, val)
        # __CLASH_PORT__ 嵌在 "127.0.0.1:__CLASH_PORT__" 里，单独处理
        node = node.replace("__CLASH_PORT__", str(NUM_SUBS["__CLASH_PORT__"]))
        return node
    return node

cfg = walk(json.load(open(TPL)))

# --- route_exclude_address 只吃 IP 前缀 ---
# 这一行是防环路的关键：不排除节点地址，去节点的流量会被 TUN 自己劫回来，
# 表现为「一启动就全网断」。但节点填域名时（ACME 证书场景）没法直接写，
# 得在渲染期解析成 IP。
import ipaddress, socket
tun = next(i for i in cfg["inbounds"] if i["type"] == "tun")
try:
    ipaddress.ip_address(host)
    excl = [f"{host}/32"]
except ValueError:
    try:
        addrs = {ai[4][0] for ai in socket.getaddrinfo(host, None, socket.AF_INET)}
        excl = sorted(f"{a}/32" for a in addrs)
        print(f"note: {host} 解析到 {', '.join(sorted(addrs))}，已写入 route_exclude_address。"
              f"节点 IP 变更后需重跑 install.sh。", file=sys.stderr)
    except OSError:
        excl = []
        print(f"warn: {host} 解析失败，route_exclude_address 留空 —— "
              f"防环路改由 auto_detect_interface 兜底。若启动后全网断，"
              f"手动把节点 IP 填进 inbounds[0].route_exclude_address。", file=sys.stderr)
if excl:
    tun["route_exclude_address"] = excl
else:
    tun.pop("route_exclude_address", None)

# --- 远程规则集 ---
GEOSITE = ["category-ads-all", "cn", "apple", "microsoft", "openai", "anthropic",
           "category-ai-chat-!cn", "google", "github", "telegram", "twitter", "youtube"]
BASE = "https://raw.githubusercontent.com/SagerNet"
rs = [{"tag": f"geosite-{n}", "type": "remote", "format": "binary",
       "url": f"{BASE}/sing-geosite/rule-set/geosite-{n}.srs",
       "download_detour": tag, "update_interval": "7d"} for n in GEOSITE]
rs.append({"tag": "geoip-cn", "type": "remote", "format": "binary",
           "url": f"{BASE}/sing-geoip/rule-set/geoip-cn.srs",
           "download_detour": tag, "update_interval": "7d"})
cfg["route"]["rule_set"] = rs

# --- profile: bilibili ---
# 规则集是远程下载的，首次启动/断网时还没到位；把内网和自家域名硬编码进规则，
# 保证任何时候都直连（走代理 100% 失败，还会把内网主机名泄漏给境外节点）。
if os.environ.get("PROFILE") == "bilibili":
    BILI = ["bilibili.com", "bilibili.cn", "bilibili.tv", "bilivideo.com", "bilivideo.cn",
            "hdslb.com", "biliapi.net", "acg.tv", "b23.tv", "maoer.co", "missevan.com"]
    # 内网域必须用系统 DNS（只有内网 DNS 有记录），绝不能走 doh.pub
    dns_rules = cfg["dns"]["rules"]
    idx = next(i for i, r in enumerate(dns_rules) if r.get("query_type") == "AAAA")
    dns_rules[idx:idx] = [
        {"domain_suffix": ["bilibili.co"], "server": "bootstrap"},
        {"domain_suffix": BILI, "server": "doh-cn"},
    ]
    route_rules = cfg["route"]["rules"]
    idx = next(i for i, r in enumerate(route_rules)
               if "geosite-openai" in (r.get("rule_set") or []))
    route_rules.insert(idx, {"domain_suffix": ["bilibili.co"] + BILI, "outbound": "direct"})

json.dump(cfg, sys.stdout, ensure_ascii=False, indent=2)
print()
