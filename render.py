#!/usr/bin/env python3
"""把 config.template.json 渲染成可用配置。

- 替换 __XXX__ 占位符，并把数值/布尔占位符还原成 JSON 原生类型
- 生成 13 条远程 rule_set（download_detour 指向本次的节点 tag）
- --profile work 时按环境变量注入自定义工作/内网直连规则
所有参数从环境变量读，见 install.sh。
"""
import json, os, sys

TPL = sys.argv[1]
tag = os.environ["SB_NODE_TAG"]
host = os.environ["SB_NODE_HOST"]

def csv_env(name):
    return [v.strip().lstrip(".") for v in os.environ.get(name, "").split(",") if v.strip()]

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

# --- profile: work ---
# 内网域名由调用者通过环境变量提供，真实组织信息不需要写进仓库。
# INTERNAL 域使用系统 DNS；DIRECT 域使用国内 DoH。两类都强制直连。
if os.environ.get("PROFILE") == "work":
    internal_domains = csv_env("SB_WORK_INTERNAL_DOMAINS")
    direct_domains = csv_env("SB_WORK_DIRECT_DOMAINS")

    dns_rules = cfg["dns"]["rules"]
    dns_insert = next(i for i, r in enumerate(dns_rules) if r.get("query_type") == "AAAA")
    extra_dns = []
    if internal_domains:
        extra_dns.append({"domain_suffix": internal_domains, "server": "bootstrap"})
    if direct_domains:
        extra_dns.append({"domain_suffix": direct_domains, "server": "doh-cn"})
    dns_rules[dns_insert:dns_insert] = extra_dns

    all_direct = list(dict.fromkeys(internal_domains + direct_domains))
    if all_direct:
        route_rules = cfg["route"]["rules"]
        route_insert = next(i for i, r in enumerate(route_rules)
                            if "geosite-openai" in (r.get("rule_set") or []))
        route_rules.insert(route_insert, {"domain_suffix": all_direct, "outbound": "direct"})
    else:
        print("warn: work profile 未配置任何域名；不会注入额外 DNS/路由规则。", file=sys.stderr)

json.dump(cfg, sys.stdout, ensure_ascii=False, indent=2)
print()
