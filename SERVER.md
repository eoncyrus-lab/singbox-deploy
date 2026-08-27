# 服务端：在 VPS 上搭建 Hysteria2 节点

这份教程用于“还没有节点”的情况：在一台 Linux VPS 上部署 Hysteria2，
再回到 `README.md` 给 macOS 客户端接入。已有节点直接回 `README.md` §2。

> 说明：服务端流程未在本套件的原始机器上验证过；命令按 Hysteria2 官方安装方式整理。
> 本文以 Debian 12 / Ubuntu 22.04+、systemd、公开 IPv4 和单个 UDP 节点端口为例。

官方参考：

- [Hysteria2 服务端快速教程](https://www.hy2.io/docs/getting-started/Server/)
- [官方安装脚本](https://hy2.io/docs/getting-started/Server-Installation-Script/)
- [完整服务端配置](https://www.hy2.io/docs/advanced/Full-Server-Config/)

---

## 1. 准备 VPS、域名和端口

### VPS 选择

| 项目 | 建议 |
|---|---|
| 系统 | Debian 12 或 Ubuntu 22.04/24.04 LTS |
| 网络 | 有公网 IPv4；确认云厂商安全组支持 UDP |
| 地域 | 以你和常用网站之间的延迟、丢包为准，不是越远越好 |
| 资源 | 先从 1 vCPU / 512 MB 起步；实际速度受 CPU、线路、UDP 质量和流量包限制 |
| 端口 | 默认使用 UDP 443；云厂商和 VPS 本机防火墙都要放行 |

不要把“1 核 512M”或“BBR”理解成固定的千兆保证。代理速度的瓶颈经常是 VPS 线路、运营商限速、丢包或月流量包。

### 域名（推荐）

准备一个自己控制的域名，例如 `node.example.com`，添加 A 记录指向 VPS 公网 IPv4：

```bash
dig +short A node.example.com
```

输出应包含 VPS 的公网 IPv4。若域名还有 AAAA 记录，请同时确认 VPS 的 IPv6、防火墙和 Hysteria2 监听都已配置好；否则先不要发布指向不可用 IPv6 的 AAAA 记录。

域名用于 ACME 自动申请证书。使用可信证书后，客户端可以关闭 TLS 不安全模式；没有域名时也能用自签证书，但客户端无法验证服务端身份。

---

## 2. VPS 初始化与 SSH 安全

先更新系统并安装本教程会用到的工具：

```bash
sudo apt update
sudo apt -y full-upgrade
sudo apt install -y curl ca-certificates openssl ufw
```

如果还在使用 root 密码登录，建议按下面顺序迁移到 SSH key：

1. 在本地生成或准备 SSH key。
2. 创建一个有 `sudo` 权限的普通用户，并为它配置公钥。
3. **不要关闭当前 SSH 会话**，另开一个终端验证普通用户能登录并能执行 `sudo`。
4. 确认备用登录可用后，再编辑 `/etc/ssh/sshd_config`，按需设置：

   ```text
   PermitRootLogin no
   PasswordAuthentication no
   ```

5. 修改后先校验再重载 SSH：

   ```bash
   sudo sshd -t && sudo systemctl reload ssh
   ```

不同 VPS 镜像的 SSH 服务名可能是 `sshd`；如果 `ssh` 不存在，先用 `systemctl status sshd` 确认服务名。不要在没有备用登录会话时直接关闭密码登录。

---

## 3. 安装 Hysteria2

官方脚本负责安装、升级、卸载二进制和 systemd unit，但只会生成示例配置，仍需要手动配置：

```bash
bash <(curl -fsSL https://get.hy2.sh/)
```

这是远程脚本执行命令，存在供应链和版本漂移风险。只从官方域名获取；需要可复现部署时，按[官方安装说明](https://hy2.io/docs/getting-started/Server-Installation-Script/)使用其中的固定版本参数，不要换成第三方“一键脚本”。

安装后通常会有：

- 配置文件：`/etc/hysteria/config.yaml`
- systemd 服务：`hysteria-server.service`
- 程序运行用户：由安装脚本创建和管理

---

## 4. 配置域名和 TLS

### 路线 A：域名 + ACME（推荐）

编辑 `/etc/hysteria/config.yaml`：

```yaml
listen: :443

acme:
  domains:
    - node.example.com
  email: you@example.com
```

把域名和邮箱替换成自己的值。`acme` 和 `tls` 二选一，不能同时配置。

ACME 验证期间要确保云安全组和本机防火墙能访问对应的 TCP 验证端口；常见的 TLS-ALPN 验证需要 TCP 443，HTTP 验证需要 TCP 80。Hysteria2 节点本身仍然需要 UDP 443。

客户端使用可信证书：

```bash
SB_NODE_HOST=node.example.com \
SB_NODE_PORT=443 \
SB_NODE_PASSWORD='你的密码' \
SB_TLS_INSECURE=false \
./install.sh
```

### 路线 B：自签证书（仅无域名或临时测试）

自签证书不会自动建立可验证的服务端身份。生成一对证书和私钥：

```bash
sudo mkdir -p /etc/hysteria
sudo openssl ecparam -name prime256v1 -genkey -noout \
  -out /etc/hysteria/server.key
sudo openssl req -new -x509 -key /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt -days 365 \
  -subj "/CN=node.example.com"
```

官方安装脚本默认让 `hysteria:hysteria` 这个 systemd 用户运行服务。让它能读取证书，但不要把私钥开放给所有用户：

```bash
sudo chown root:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt
sudo chmod 640 /etc/hysteria/server.key /etc/hysteria/server.crt
```

如果你安装时通过 `HYSTERIA_USER` 改过运行用户，把上面的组名替换成 systemd unit 中的实际 `Group=`。可这样查看：

```bash
systemctl cat hysteria-server.service | grep -E '^(User|Group)='
```

配置：

```yaml
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
```

客户端只能在明确接受风险时使用：

```bash
SB_NODE_HOST=1.2.3.4 \
SB_NODE_PASSWORD='你的密码' \
SB_TLS_INSECURE=true \
./install.sh
```

`SB_TLS_INSECURE=true` 的含义是关闭证书校验，不是“兼容但仍然安全”。在公共网络上长期使用应改用自己域名的 ACME 证书，并设置为 `false`。

---

## 5. 认证和完整配置

### 单人使用：一个强密码

生成密码：

```bash
openssl rand -base64 32
```

把结果写入配置：

```yaml
auth:
  type: password
  password: CHANGE_ME_TO_A_LONG_RANDOM_VALUE
```

### 多人使用：每人一个 userpass

```yaml
auth:
  type: userpass
  userpass:
    alice: CHANGE_ME_ALICE
    bob: CHANGE_ME_BOB
```

客户端的 `SB_NODE_PASSWORD` 填 `alice:CHANGE_ME_ALICE`。这样可以单独吊销某个用户；精细的流量统计仍需要额外的日志或监控配置，不能把 userpass 当成自动计费系统。

### 推荐的域名完整配置

下面是“域名 + ACME + 单用户密码”的最小可用示例：

```yaml
# /etc/hysteria/config.yaml
listen: :443

acme:
  domains:
    - node.example.com
  email: you@example.com

auth:
  type: password
  password: CHANGE_ME_TO_A_LONG_RANDOM_VALUE

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
```

`masquerade` 是可选项，用于让普通 HTTP 请求得到一个正常站点的响应；它不是“不可探测”保证。若不需要伪装，可以删除整个 `masquerade` 段。不要使用自己无权控制或明显不相关的站点来承诺安全效果。

配置和私钥不能对所有用户可读。默认安装的 unit 以 `hysteria:hysteria` 运行；如果你手工创建了配置，可以设置为 root 属主、服务组可读：

```bash
sudo chown root:hysteria /etc/hysteria/config.yaml
sudo chmod 640 /etc/hysteria/config.yaml
```

若 unit 中的 `User=`/`Group=` 不是默认值，请替换 `hysteria`。不要简单地改成全局可读；若服务无法读取文件，优先检查 `systemctl status` 和日志中的运行用户。

> **关于 BBR 的重要说明**：本服务端配置不需要添加一个名为“BBR”的 YAML 开关。
> Hysteria2 的 QUIC 拥塞控制由客户端的带宽声明和 Hysteria 配置决定，见下一节。

---

## 6. BBR 与 Hysteria2 拥塞控制

这里有两个容易混淆的“BBR”：

1. **Linux TCP BBR**：只影响 VPS 上的 TCP 连接，例如软件更新、SSH 或其他 TCP 服务；Hysteria2 的数据面是 QUIC/UDP，它不会因为 Linux TCP BBR 打开就直接变快。
2. **Hysteria2 的 QUIC BBR**：Hysteria2 自己的拥塞控制。按官方文档，客户端没有设置某个方向的带宽时，该方向的非 Brutal 路径默认使用 BBR；客户端为某个方向设置带宽，则该方向会进入 Brutal 带宽控制。

### 可选：启用 Linux TCP BBR

先检查当前内核是否提供 BBR：

```bash
sysctl net.ipv4.tcp_available_congestion_control
```

输出包含 `bbr` 时再持久化：

```bash
sudo tee /etc/sysctl.d/99-hysteria-bbr.conf >/dev/null <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sudo sysctl --system
sysctl net.ipv4.tcp_congestion_control
```

最后一条应输出 `bbr`。如果当前内核没有 BBR，不要执行第三方“一键换内核/一键 BBR”脚本；保持现状也不影响 Hysteria2 使用，或按照 VPS 厂商/发行版的官方方式升级内核后再评估。`fq` 是常见的 pacing 配置，但不是所有场景都必须设置。

### 本套件当前的客户端行为

本仓库的 `config.template.json` 默认会写入 `up_mbps` 和 `down_mbps`，`README.md` 中对应 `SB_UP_MBPS` / `SB_DOWN_MBPS`，默认值是 `100` / `500`。因此本套件默认不是“删除带宽字段后的 Hysteria BBR”模式，而是使用客户端声明带宽的路径。

这两个值应填写客户端实际可用的上下行能力，且只能填整数 Mbps，例如：

```bash
SB_UP_MBPS=20 SB_DOWN_MBPS=100 ./install.sh
```

虚报带宽可能造成拥塞和不稳定；更大的数字不等于更快。若要让 Hysteria2 使用非 Brutal 的默认 BBR，需要客户端支持省略对应带宽字段；当前本套件没有提供这个 opt-in 开关，本文不擅自修改脚本和模板。

---

## 7. 防火墙和云安全组

先放行你当前实际使用的 SSH 端口，再启用 UFW。默认 SSH 端口为 22：

```bash
sudo ufw allow OpenSSH
sudo ufw allow 443/udp
sudo ufw allow 443/tcp   # 域名 ACME 常用；不使用 ACME 时可按需关闭
sudo ufw enable
sudo ufw status verbose
```

如果 SSH 不是 22，使用实际端口替换 `OpenSSH`：

```bash
sudo ufw allow <SSH端口>/tcp
```

云厂商安全组还要单独放行：

- 节点端口：UDP 443（或你在 `listen` 中自定义的 UDP 端口）；
- ACME 验证：按验证方式放行 TCP 443 或 TCP 80；
- SSH：只对你的管理来源放行实际 SSH 端口。

`SB_NODE_PORT`、服务端 `listen`、UFW 规则和云安全组必须使用同一个节点端口。已有 nftables/firewalld 时不要再让 UFW 并行接管，选择一种防火墙管理方式即可。

---

## 8. 启动和验证

写完配置后启动：

```bash
sudo systemctl enable --now hysteria-server.service
sudo systemctl status hysteria-server.service
sudo journalctl --no-pager -e -u hysteria-server.service
```

服务应为 `active (running)`，日志不能有证书、端口占用或配置解析错误。检查 UDP 监听：

```bash
sudo ss -lunp | grep ':443'
```

回到客户端目录，用域名证书场景接入：

```bash
SB_NODE_HOST=node.example.com \
SB_NODE_PORT=443 \
SB_NODE_PASSWORD='你的密码' \
SB_TLS_INSECURE=false \
./install.sh
source ~/.zshrc
vpn status
curl -sS -x http://127.0.0.1:6152 https://api.ipify.org
```

最后一个命令应返回 VPS 的公网出口 IP。`vpn status` 能反映客户端本地状态，但不能替代服务端日志和云安全组检查。

---

## 9. 常见故障

| 现象 | 优先检查 |
|---|---|
| 客户端握手超时 | 云安全组和 UFW 是否都放行 **UDP** 节点端口；`SB_NODE_PORT`、`listen` 是否一致 |
| 域名模式 TLS 报错 | A 记录是否指向当前 VPS；客户端是否错误地使用了 `SB_TLS_INSECURE=true`；ACME 的 TCP 验证端口是否放行 |
| 服务启动失败 | `sudo systemctl status hysteria-server.service` 与 `sudo journalctl --no-pager -e -u hysteria-server.service` |
| 端口被占用 | `sudo ss -lntup | grep ':443'`；确认没有其他服务占用 TCP/UDP 443 |
| 开了 BBR 但速度没变化 | 这是预期可能性：Linux TCP BBR 不直接控制 Hysteria2 的 QUIC/UDP；继续检查线路、丢包、CPU、MTU 和真实带宽 |
| 速度忽高忽低 | 降低 `SB_UP_MBPS` / `SB_DOWN_MBPS` 到真实值，检查 VPS 流量包和丢包，不要盲目把带宽数字调大 |
| 修改密码后仍不能连接 | 修改后执行 `sudo systemctl restart hysteria-server.service`；客户端同步修改 `SB_NODE_PASSWORD` 并重新运行 `install.sh` |

服务端配置变更后使用 `restart`，不要假设所有安装版本都支持无中断 `reload`。

---

## 10. 升级、换密码和卸载

升级前先备份配置，再执行官方升级脚本：

```bash
sudo cp -a /etc/hysteria/config.yaml \
  "/etc/hysteria/config.yaml.bak.$(date +%Y%m%d-%H%M%S)"
bash <(curl -fsSL https://get.hy2.sh/)
sudo systemctl restart hysteria-server.service
sudo systemctl status hysteria-server.service
```

密码泄漏时，单密码模式直接换密码；多用户模式只删除或修改对应用户，然后重启服务并让该客户端重新渲染配置。不要把密码提交到 Git、工单或公开聊天。

如果确认不再使用：

```bash
sudo systemctl disable --now hysteria-server.service
bash <(curl -fsSL https://get.hy2.sh/) --remove
```

卸载前请确认已经从云安全组和 UFW 撤销不再需要的开放端口，并保留配置备份直到不再需要回滚。
