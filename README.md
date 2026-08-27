# sing-box 部署套件

把一台 macOS 变成「TUN 内核层透明代理 + 规则分流 + 开机自启 + 一个 `vpn` 命令管全部」。

已有节点时，从零到可用：**一条命令，约 3 分钟**。

```bash
# 先将本仓库克隆到本地，再进入仓库目录
cd singbox-deploy
SB_NODE_HOST=node.example.com SB_NODE_PASSWORD='你的密码' SB_TLS_INSECURE=false ./install.sh
source ~/.zshrc && vpn status
```

如果还没有节点，先按 [`SERVER.md`](SERVER.md) 在 VPS 上搭建 Hysteria2 节点，确认服务端的域名、端口和认证信息后，再执行上面的客户端安装命令。
只有在自签证书或临时测试时才把 `SB_TLS_INSECURE` 显式设为 `true`；它会关闭证书校验。

---

## 文档导航

| 我想…… | 看这份 |
|---|---|
| **装到另一台机器 / 给别人装** | 本文 |
| **从零搭一个节点**（服务端） | `SERVER.md` |
| **搞懂每个配置为什么这么写** | `~/singbox-setup.md` |
| **日常用**（启停、切模式、排障） | `~/singbox-usage.md` |

---

## 先搞清楚你是哪种情况

| 你的情况 | 走哪条路 |
|---|---|
| **A. 自己的第二台 Mac**，想复刻现有环境 | 直接跑 `install.sh`，节点参数填现有那个。**跳到 §2** |
| **B. 同事/朋友要装**，已经有自己的节点 | 同上，但先读 **§1 共用节点还是各自建** |
| **C. 完全从零**，连节点都没有 | 先按 **`SERVER.md`** 开一台 VPS 搭 Hysteria2，再回来跑 `install.sh` |
| **D. 不是 macOS** | 见 **§7 其它平台** |

---

## 1. 共用节点 vs 各自建

第一个要做的决定，因为它决定了你给别人什么。

**共用一个节点**（把同一个密码给多个人）——省事，但：
- Hysteria2 单密码模式**没有按人计量**，谁跑满带宽了查不出来
- 密码泄漏 = 整个节点报废，得改密码 + 通知所有人重装
- 多人同时跑，100/500 Mbps 的声明值是**所有人共享**的

**要给多个人用，就别用单密码。** Hysteria2 服务端支持 userpass，一人一条：

```yaml
auth:
  type: userpass
  userpass:
    alice: <alice的密码>
    bob:   <bob的密码>
```

客户端 `password` 字段写成 `alice:<alice的密码>`。这样能按人吊销；精细流量统计仍需额外的日志或监控配置。
详见 `SERVER.md`。

**各自建** —— 可以从一台低配 VPS 起步；实际速度取决于线路、丢包、CPU 和流量包，`SERVER.md` 里有完整流程。
延迟由地理位置决定，别人在别的城市，你的节点未必比他自己开一台快。

---

## 2. 安装

### 最简

```bash
SB_NODE_HOST=1.2.3.4 SB_NODE_PASSWORD='xxx' ./install.sh
```

不给参数就交互式提问（密码输入不回显）。

### 先看再装（强烈建议第一次这么干）

```bash
SB_NODE_HOST=1.2.3.4 SB_NODE_PASSWORD='xxx' ./install.sh --dry-run
```

只渲染配置并在本机已有 `sing-box` 时执行 `sing-box check`；不会安装 sing-box，也不会修改系统。检查生成的 JSON 没问题再正式跑。脚本会输出临时文件路径；该文件包含节点密码，检查后请按路径手动删除。

### 全部可调参数

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `SB_NODE_HOST` | *（必填）* | 节点 IP 或域名 |
| `SB_NODE_PORT` | `443` | 节点端口（UDP） |
| `SB_NODE_PASSWORD` | *（必填）* | Hysteria2 认证密码 |
| `SB_NODE_TAG` | `节点` | 配置里的节点显示名 |
| `SB_UP_MBPS` / `SB_DOWN_MBPS` | `100` / `500` | 客户端带宽声明，填整数 Mbps 和真实能力；非空值会走 Hysteria 的带宽控制路径，不等于 Linux TCP BBR |
| `SB_TLS_INSECURE` | `true` | 自签证书/测试才用 `true`（关闭证书校验）；域名 + ACME 可信证书必须改 `false` |
| `SB_MIXED_PORT` | `6152` | 本地 HTTP/SOCKS 混合端口 |
| `SB_CLASH_PORT` | `6170` | Clash API 端口 |
| `SB_CLASH_SECRET` | *随机生成* | 不填就随机，**不要跨机器复用** |
| `SB_TUN_CIDR` | `172.19.0.1/30` | TUN 网段，和已有网段冲突时改 |
| `SB_MTU` | `1400` | 热点/弱网 1400；普通 Wi-Fi 可试 1420–1450 |
| `SB_CONFIG` | `~/singbox-config.json` | 配置文件落点 |
| `SB_NO_PROXY_EXTRA` | 空 | 额外绕过的域名，逗号分隔，如 `.corp.example.com` |

> **节点填域名时注意**：`route_exclude_address`（防环路的关键字段）只接受 IP 前缀，
> 所以渲染期会把域名解析成 IP 写进去。这意味着**节点 IP 变了要重跑 `install.sh`**。
> 解析不了的话该字段留空，防环路退化为只靠 `auto_detect_interface` 兜底，脚本会警告。

### profile

```bash
./install.sh --profile bilibili
```

额外注入 B 站域名 + 公司内网（`.bilibili.co`）的直连规则和绕过列表。
**外部使用者用默认的 `generic` 即可**，别带这个 —— 那是特定公司网络环境的特化。

需要自己公司的内网规则，装完后编辑两个文件（不用改脚本）：

```bash
~/.config/singbox-deploy/bypass.local   # 每行一条，GUI 系统代理绕过用
~/.config/singbox-deploy/env            # 改 SB_NO_PROXY_EXTRA，CLI 用
```

### 装完之后

```bash
source ~/.zshrc
vpn status
```

首次启动 macOS 会弹「允许 sing-box 添加 VPN 配置」，**点允许**（只弹一次）。

---

## 3. install.sh 到底动了什么

装之前你应该知道它改了系统哪些地方 —— 这也是出问题时的排查清单。

| # | 动作 | 落地物 | 可逆 |
|---|---|---|---|
| 0 | 环境自检（macOS / brew / python3 / 端口占用） | — | — |
| 1 | `brew install sing-box`，校验 gvisor·quic·clash_api 三个 tag | `$(brew --prefix)/bin/sing-box` | `brew uninstall` |
| 2 | 渲染配置 → `sing-box check` 校验 | `~/singbox-config.json` **(600，含密码)** | 旧文件自动备份 |
| 3 | 软链到 brew 路径 + 建缓存/日志目录 | `$(brew --prefix)/etc/sing-box/config.json` | `uninstall.sh` |
| 4 | sudo 免密（`visudo -c` 校验后才写） | `/etc/sudoers.d/singbox` | `uninstall.sh` |
| 5 | shell 集成，向 `~/.zshrc` 追加**一行** source | `~/.config/singbox-deploy/{env,vpn.zsh}` | `uninstall.sh` |
| 6 | `sudo brew services start sing-box` | `/Library/LaunchDaemons/homebrew.mxcl.sing-box.plist` | `uninstall.sh` |

安全约定：
- 主要配置文件覆盖前会备份（`.bak-YYYYMMDD-HHMMSS`），不要假定所有辅助文件都有备份
- sudoers 先写临时文件、`visudo -cf` 校验通过才 install —— 写坏 sudoers 会锁死提权
- 免密**只放开 3 条命令**（`brew services {start,stop,restart} sing-box`），不是无限 sudo
- 配置文件 600，因为里面有节点密码
- `~/.zshrc` 只加一行 source，逻辑都在独立文件里，升级不用重新改 zshrc

---

## 4. 验收

```bash
vpn status
```

| 检查项 | 期望 |
|---|---|
| 进程 | `🟢 sing-box: running (pid ...)` |
| 端口 | `127.0.0.1.6152` LISTEN |
| TUN | `utunN  172.19.0.1  mtu=1400 ✓` |
| 路由模式 | `rule` |
| 代理变量 | `https_proxy = http://127.0.0.1:6152` |
| 系统代理 | Enabled: Yes / 127.0.0.1 / 6152，绕过列表条数符合预期 |
| google 204 | `204/<1s` |
| 国内站点 | `200/` 毫秒级 |

补充：

```bash
# 出口 IP 应等于节点 IP
curl -s -x http://127.0.0.1:6152 https://api.ipify.org

# 广告拦截生效（应 000 / connection refused）
curl --max-time 3 -so /dev/null -w "%{http_code}\n" https://doubleclick.net

# 规则集下载成功（13 个）
vpn ui    # 或看日志
```

---

## 5. 日常使用

```bash
vpn on | off | restart | status
vpn log        # 实时日志
vpn check      # 校验配置
vpn ui         # Clash Dashboard
vpn edit       # 编辑配置
vpn mode rule|global|direct     # 热切路由模式，不重启
vpn mtu 1420                    # 改 MTU（自动校验 + 重启）
```

---

## 6. 换机器/换人时最容易踩的坑

按「换环境」这个场景排序，和单机文档里的通用故障不同：

| 现象 | 根因 | 处理 |
|---|---|---|
| Intel Mac 上装完 `vpn on` 要密码 | sudoers 里写的是 `/opt/homebrew/bin/brew`，Intel 机是 `/usr/local/bin/brew` | 脚本已用 `brew --prefix` 自适应；手抄的话注意这点 |
| 一启动就全网断 | 漏了 `route_exclude_address` 节点 IP，去节点的流量被 TUN 劫回形成环路 | 脚本自动填；手改配置换节点时**务必同步这一行** |
| 换了节点但忘了改 exclude | 同上 | 换节点建议直接重跑 `install.sh`，别手改 |
| 节点用域名，某天突然全网断 | 域名背后的 IP 变了，`route_exclude_address` 里还是旧 IP | 重跑 `install.sh`（渲染期会重新解析）|
| `172.19.0.1` 网段冲突 | 对方机器已有 VPN/Docker 占了该段 | `SB_TUN_CIDR=172.31.9.1/30 ./install.sh` |
| 6152/6170 端口被占 | 装了 Surge/ClashX/其它代理 | 脚本会检测并报错；`SB_MIXED_PORT=7152 ./install.sh` |
| 装完能上外网，公司内网全挂 | 用了 `--profile bilibili` 以外的环境，没配内网绕过 | 填 `bypass.local` + `SB_NO_PROXY_EXTRA` |
| 对方用 bash 不是 zsh | `vpn.zsh` 里用了 zsh 数组语法 | 见 §7 |
| Hysteria2 连不上，TCP 能通 | 云厂商安全组只放了 TCP 443 | 放行 **UDP** 443 |
| 多人共用节点后集体变慢 | 单密码无法计量，带宽被某人跑满 | 改 userpass 一人一条，见 §1 |
| `vpn log` 没输出 | 旧配置的 `log` 块缺 `output` | 本套件模板已默认写入 `output` |

---

## 7. 其它平台

**Intel Mac**：直接支持，脚本用 `brew --prefix` 自适应 `/usr/local`。

**bash 用户**：`vpn.zsh` 用了 zsh 的数组语法（`${(@f)...}`），bash 下不能直接 source。
两个选择 —— 装个 zsh 只用来跑这个（`brew install zsh`，不用改默认 shell），
或者只用最小集：手动 `export https_proxy=http://127.0.0.1:6152`，服务用
`sudo brew services {start,stop} sing-box` 管，放弃 `vpn` 函数的便利。

**Linux**：配置字段（`config.template.json` + `render.py`）可作为参考，
安装/服务部分不通用。差异：
- 装法：官方仓库或 `.deb`/`.rpm`，不是 brew
- 服务：systemd unit（`sing-box.service`），不是 launchd
- TUN：Linux 原生支持更好，`stack` 可用 `system` 性能更佳
- 系统代理：没有 `networksetup`，`set_system_proxy` 在 Linux 上不生效，
  桌面环境得自己设 GNOME/KDE 代理

用法：`--dry-run` 生成配置，拷到 Linux 机器，套 systemd 跑。

**Windows**：只有配置文件可复用，建议直接用 sing-box 官方 GUI 客户端导入。

---

## 8. 卸载

```bash
./uninstall.sh            # 停服务、关自启、撤免密、清系统代理、删 source 行
./uninstall.sh --purge    # 上面全部 + 卸载二进制 + 删缓存和配置目录
```

`--purge` **不会**自动删 `~/singbox-config.json`（里面有节点密码，留给你自己确认后删）。

特别注意：`uninstall.sh` 会显式关闭系统代理。这一步不能省 —— `set_system_proxy`
在服务异常退出时会把系统代理留在开启状态，指向一个已经没人监听的端口，
表现为「明明卸载了却全网断」。

---

## 9. 文件清单

| 文件 | 作用 |
|---|---|
| `install.sh` | 一键部署，幂等，支持 `--dry-run` / `--profile` |
| `uninstall.sh` | 卸载，支持 `--purge` |
| `render.py` | 模板渲染：占位符替换、类型还原、生成 13 条规则集、profile 注入 |
| `config.template.json` | 参数化配置模板（自身是合法 JSON，可单独校验） |
| `vpn.zsh` | shell 集成，零机器特化，装到 `~/.config/singbox-deploy/` |
| `SERVER.md` | 服务端 Hysteria2 从零搭建（情况 C 看这个） |
| `README.md` | 本文 |

单机的配置原理逐条解释、路由规则表、日常故障排查，见 `~/singbox-setup.md`。
