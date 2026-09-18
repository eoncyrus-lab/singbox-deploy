#!/usr/bin/env bash
# sing-box 一键部署（macOS）
# 用法：
#   SB_NODE_HOST=1.2.3.4 SB_NODE_PASSWORD='xxx' ./install.sh
#   ./install.sh --profile work            # 注入自定义工作/内网直连规则
#   ./install.sh --dry-run                 # 只渲染配置并校验，不动系统
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

PROFILE=generic
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-generic}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

# ---------- 参数 ----------
: "${SB_NODE_HOST:=}"
: "${SB_NODE_PORT:=443}"
: "${SB_NODE_PASSWORD:=}"
: "${SB_NODE_TAG:=节点}"
: "${SB_UP_MBPS:=100}"
: "${SB_DOWN_MBPS:=500}"
: "${SB_TLS_INSECURE:=true}"
: "${SB_MIXED_PORT:=6152}"
: "${SB_CLASH_PORT:=6170}"
: "${SB_TUN_CIDR:=172.19.0.1/30}"
: "${SB_MTU:=1400}"
: "${SB_CONFIG:=$HOME/singbox-config.json}"
: "${SB_WORK_INTERNAL_DOMAINS:=}"
: "${SB_WORK_DIRECT_DOMAINS:=}"
: "${SB_WORK_BYPASS_DOMAINS:=}"
: "${SB_WORK_PROBE_URL:=}"

prompt() {  # prompt VAR "提示语" [silent]
  local var="$1" msg="$2" silent="${3:-}" val
  [[ -n "${!var}" ]] && return 0
  [[ -t 0 ]] || die "$var 未设置且非交互终端，请用环境变量传入"
  if [[ -n "$silent" ]]; then read -rsp "$msg: " val; echo; else read -rp "$msg: " val; fi
  [[ -z "$val" ]] && die "$var 不能为空"
  printf -v "$var" '%s' "$val"
}
prompt SB_NODE_HOST     "节点地址 (IP 或域名)"
prompt SB_NODE_PASSWORD "节点密码 (Hysteria2 auth)" silent

# Clash API 密钥：不给就随机生成，不要跨机器复用
: "${SB_CLASH_SECRET:=$(openssl rand -hex 12)}"

# ---------- 0. 环境自检 ----------
say "环境自检"
[[ "$(uname -s)" == "Darwin" ]] || die "本脚本只支持 macOS（Linux 见 README「其它平台」）"
command -v brew >/dev/null || die "未装 Homebrew: https://brew.sh"
command -v python3 >/dev/null || die "缺 python3"
BREW_PREFIX="$(brew --prefix)"
ok "brew prefix = $BREW_PREFIX ($(uname -m))"
SB_LOG="$BREW_PREFIX/var/log/sing-box.log"

# 端口占用检查：换机器时最常见的冲突源
PORT_NOTE="可用"
for p in "$SB_MIXED_PORT" "$SB_CLASH_PORT"; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    if pgrep -f "sing-box run --config" >/dev/null; then
      PORT_NOTE="被现有 sing-box 占用（本次将覆盖安装）"
    else
      die "端口 $p 已被占用（不是 sing-box）。换端口：SB_MIXED_PORT=xxxx ./install.sh"
    fi
  fi
done
ok "端口 ${SB_MIXED_PORT} / ${SB_CLASH_PORT} ${PORT_NOTE}"

# ---------- 1. 安装二进制 ----------
say "安装 sing-box"
if brew list --versions sing-box >/dev/null 2>&1; then
  ok "已安装: $(sing-box version 2>/dev/null | head -1)"
else
  (( DRY_RUN )) || brew install sing-box
fi
if command -v sing-box >/dev/null; then
  for tag in with_gvisor with_quic with_clash_api; do
    sing-box version | grep -q "$tag" && ok "tag $tag" || warn "缺 tag $tag —— TUN/Hysteria2/ClashAPI 可能不可用"
  done
fi

# ---------- 2. 渲染配置 ----------
say "渲染配置 → $SB_CONFIG"
RENDERED="$(mktemp)"
SB_NODE_HOST="$SB_NODE_HOST" SB_NODE_PORT="$SB_NODE_PORT" \
SB_NODE_PASSWORD="$SB_NODE_PASSWORD" SB_NODE_TAG="$SB_NODE_TAG" \
SB_UP_MBPS="$SB_UP_MBPS" SB_DOWN_MBPS="$SB_DOWN_MBPS" SB_TLS_INSECURE="$SB_TLS_INSECURE" \
SB_MIXED_PORT="$SB_MIXED_PORT" SB_CLASH_PORT="$SB_CLASH_PORT" SB_CLASH_SECRET="$SB_CLASH_SECRET" \
SB_TUN_CIDR="$SB_TUN_CIDR" SB_MTU="$SB_MTU" SB_LOG="$SB_LOG" PROFILE="$PROFILE" \
SB_WORK_INTERNAL_DOMAINS="$SB_WORK_INTERNAL_DOMAINS" SB_WORK_DIRECT_DOMAINS="$SB_WORK_DIRECT_DOMAINS" \
SB_WORK_BYPASS_DOMAINS="$SB_WORK_BYPASS_DOMAINS" SB_WORK_PROBE_URL="$SB_WORK_PROBE_URL" \
python3 "$HERE/render.py" "$HERE/config.template.json" > "$RENDERED"
ok "已渲染 ($(wc -c < "$RENDERED" | tr -d ' ') 字节, profile=$PROFILE)"

if command -v sing-box >/dev/null; then
  sing-box check -c "$RENDERED" && ok "sing-box check 通过" || die "配置校验失败"
fi

if (( DRY_RUN )); then
  say "--dry-run：配置已生成在 ${RENDERED}，未改动系统"
  echo "  预览: cat ${RENDERED}"
  exit 0
fi

if [[ -e "$SB_CONFIG" ]]; then
  cp "$SB_CONFIG" "$SB_CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
  ok "旧配置已备份"
fi
install -m 600 "$RENDERED" "$SB_CONFIG"   # 含密码，600
rm -f "$RENDERED"
ok "$SB_CONFIG (mode 600)"

# ---------- 3. 目录与软链 ----------
say "落位到 brew 路径"
sudo mkdir -p "$BREW_PREFIX/etc/sing-box" "$BREW_PREFIX/var/lib/sing-box" "$BREW_PREFIX/var/log"
LINK="$BREW_PREFIX/etc/sing-box/config.json"
if [[ -e "$LINK" && ! -L "$LINK" ]]; then
  sudo mv "$LINK" "$LINK.bak-$(date +%Y%m%d-%H%M%S)"
  ok "brew 自带配置已备份"
fi
sudo ln -sfn "$SB_CONFIG" "$LINK"
sudo touch "$SB_LOG" && sudo chmod 644 "$SB_LOG"
ok "$LINK → $SB_CONFIG"

# ---------- 4. sudo 免密 ----------
say "配置 sudo 免密（仅 3 条 brew services 命令）"
SUDOERS_TMP="$(mktemp)"
{ for a in start stop restart; do
    echo "$(whoami) ALL=(root) NOPASSWD: $BREW_PREFIX/bin/brew services $a sing-box"
  done
} > "$SUDOERS_TMP"
if sudo visudo -cf "$SUDOERS_TMP" >/dev/null; then
  sudo install -m 440 -o root -g wheel "$SUDOERS_TMP" /etc/sudoers.d/singbox
  ok "/etc/sudoers.d/singbox"
else
  warn "sudoers 语法校验失败，跳过（vpn on 时会要密码）"
fi
rm -f "$SUDOERS_TMP"

# ---------- 5. shell 集成 ----------
say "安装 shell 集成"
CFG_DIR="$HOME/.config/singbox-deploy"
mkdir -p "$CFG_DIR"
cat > "$CFG_DIR/env" <<EOF
# 由 install.sh 生成 $(date +%F)。改完跑 vpn restart。
SB_PREFIX="$BREW_PREFIX"
SB_CONFIG="$SB_CONFIG"
SB_MIXED_PORT=$SB_MIXED_PORT
SB_CLASH_PORT=$SB_CLASH_PORT
SB_TUN_IP="${SB_TUN_CIDR%%/*}"
SB_LOG="$SB_LOG"
# 额外绕过代理的域名(逗号分隔)，如公司内网： SB_NO_PROXY_EXTRA=".corp.example.com"
SB_NO_PROXY_EXTRA="${SB_NO_PROXY_EXTRA:-}"
EOF
chmod 600 "$CFG_DIR/env"
ok "$CFG_DIR/env"

install -m 644 "$HERE/vpn.zsh" "$CFG_DIR/vpn.zsh"
SOURCE_LINE="[ -r \"\$HOME/.config/singbox-deploy/vpn.zsh\" ] && source \"\$HOME/.config/singbox-deploy/vpn.zsh\""
if grep -qF 'singbox-deploy/vpn.zsh' "$HOME/.zshrc" 2>/dev/null; then
  ok "~/.zshrc 已含 source 行"
else
  cp "$HOME/.zshrc" "$HOME/.zshrc.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  printf '\n# === sing-box ===\n%s\n' "$SOURCE_LINE" >> "$HOME/.zshrc"
  ok "已追加 source 行到 ~/.zshrc（原文件已备份）"
fi

if [[ "$PROFILE" == "work" ]]; then
  if [[ -n "$SB_WORK_BYPASS_DOMAINS" ]]; then
    IFS=',' read -r -a _work_bypass <<< "$SB_WORK_BYPASS_DOMAINS"
    printf '%s\n' "${_work_bypass[@]}" > "$CFG_DIR/bypass.local"
    ok "已写入 work profile 系统代理绕过列表"
  else
    warn "work profile 未设置 SB_WORK_BYPASS_DOMAINS；不会生成 bypass.local"
  fi

  if [[ -n "$SB_WORK_PROBE_URL" ]]; then
    printf '%s\n' "$SB_WORK_PROBE_URL" > "$CFG_DIR/probe.local"
    ok "已写入 work profile 连通性探针"
  fi
fi

# ---------- 6. 启动 ----------
say "启动服务"
sudo brew services start sing-box || warn "启动失败，看 $SB_LOG"
echo
echo "首次启动 macOS 会弹「允许 sing-box 添加 VPN 配置」——点【允许】。"
echo
say "完成。现在执行："
echo "    source ~/.zshrc && vpn status"
echo
echo "  Clash API secret: $SB_CLASH_SECRET   (已写进配置，vpn 命令自动读取)"
