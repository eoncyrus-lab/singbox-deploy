# === sing-box shell 集成 ============================================
# 由 singbox-deploy/install.sh 安装；在 ~/.zshrc 里 source 本文件。
# 所有可变项都从 ~/.config/singbox-deploy/env 读，本文件本身不含任何机器特化内容。
# ====================================================================

: ${SB_ENV_FILE:=$HOME/.config/singbox-deploy/env}
[[ -r "$SB_ENV_FILE" ]] && source "$SB_ENV_FILE"

: ${SB_PREFIX:=$(brew --prefix 2>/dev/null || echo /opt/homebrew)}
: ${SB_CONFIG:=$HOME/singbox-config.json}
: ${SB_MIXED_PORT:=6152}
: ${SB_CLASH_PORT:=6170}
: ${SB_TUN_IP:=172.19.0.1}
: ${SB_LOG:=$SB_PREFIX/var/log/sing-box.log}
_VPN_BREW="$SB_PREFIX/bin/brew"     # 绝对路径：与 sudoers NOPASSWD 规则严格对齐，
                                    # 裸 brew 依赖 PATH，解析不到就静默要密码。

# Clash API 密钥从配置文件里读，不在 shell 里再存一份。
_sb_secret() {
  [[ -n "${SB_CLASH_SECRET:-}" ]] && { echo "$SB_CLASH_SECRET"; return; }
  python3 -c "import json;print(json.load(open('$SB_CONFIG'))['experimental']['clash_api'].get('secret',''))" 2>/dev/null
}

# --- 绕过列表 -------------------------------------------------------
# 通用部分（任何人都该绕过的）。公司内网域之类的机器特化项写进
# ~/.config/singbox-deploy/bypass.local（每行一条），会自动并进来。
_SB_BYPASS_BASE=(
  "*.local" "localhost" "127.0.0.1"
  "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "169.254.0.0/16"
)
_SB_BYPASS_LOCAL_FILE="$HOME/.config/singbox-deploy/bypass.local"

_sb_bypass_list() {
  local -a out; out=("${_SB_BYPASS_BASE[@]}")
  if [[ -r "$_SB_BYPASS_LOCAL_FILE" ]]; then
    local line
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      out+=("$line")
    done < "$_SB_BYPASS_LOCAL_FILE"
  fi
  printf '%s\n' "${out[@]}"
}

# --- no_proxy（CLI 用）----------------------------------------------
# 为什么需要显式代理变量：TUN 接管了路由，但**没有**接管 DNS —— strict_route
# 在存在其他 VPN(utun) 路由时劫不住本机 DNS，curl/dig 仍会问网关拿到投毒结果。
# 走 HTTP 代理时域名由 sing-box 在远端解析，本地污染 DNS 完全不参与。
# 比把系统 DNS 指向 127.0.0.1 更好：不需要 sudo，也不会造成「sing-box 一停
# 就彻底无法解析域名」的耦合。
_sb_build_no_proxy() {
  local np="localhost,127.0.0.1,::1,*.local"
  np="$np,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16"
  [[ -n "${SB_NO_PROXY_EXTRA:-}" ]] && np="$np,$SB_NO_PROXY_EXTRA"
  echo "$np"
}
export no_proxy="$(_sb_build_no_proxy)"
export NO_PROXY="$no_proxy"

_SB_PROXY_URL="http://127.0.0.1:${SB_MIXED_PORT}"

# 只在真的在监听时才导出代理变量 —— 否则所有 CLI 会指向一个死端口，
# 比不设代理更糟（连内网都连不上）。
_sb_listening() {
  LC_ALL=C netstat -anv -p tcp 2>/dev/null \
    | LC_ALL=C grep -q "127.0.0.1.${SB_MIXED_PORT}.*LISTEN"
}

proxy_env_on() {
  export https_proxy="$_SB_PROXY_URL" http_proxy="$_SB_PROXY_URL"
  export HTTPS_PROXY="$_SB_PROXY_URL" HTTP_PROXY="$_SB_PROXY_URL"
  export all_proxy="socks5h://127.0.0.1:${SB_MIXED_PORT}"
  export ALL_PROXY="$all_proxy"
}
proxy_env_off() {
  unset https_proxy http_proxy HTTPS_PROXY HTTP_PROXY all_proxy ALL_PROXY
}

# 新 shell 启动时按实际状态决定，避免 vpn off 后开的窗口拿到失效的代理变量。
if _sb_listening; then proxy_env_on; fi

# --- 系统代理绕过（GUI 应用用）--------------------------------------
# GUI 应用不读 shell 变量，走 CFNetwork + 系统代理设置。mixed-in 的
# set_system_proxy 会自动开关系统代理，但**不会**设绕过列表，内网就会被送进
# 代理并撞上 TLS 校验失败。networksetup 设 bypass 不需要 sudo，所以这里补齐。
_sb_netsvc() {
  local dev svc
  dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  [[ -z "$dev" ]] && { echo Wi-Fi; return; }
  svc=$(networksetup -listnetworkserviceorder 2>/dev/null \
        | awk -v d="Device: $dev)" '
            /^\([0-9]+\)/ { name = $0; sub(/^\([0-9]+\) /, "", name) }
            index($0, d) { print name; exit }')
  echo "${svc:-Wi-Fi}"
}

sb_bypass_apply() {
  local svc; svc=$(_sb_netsvc)
  local -a list; list=("${(@f)$(_sb_bypass_list)}")
  networksetup -setproxybypassdomains "$svc" "${list[@]}" >/dev/null 2>&1 \
    && echo "  绕过列表已应用到 $svc (${#list[@]} 条)" \
    || echo "  ⚠️  绕过列表设置失败 ($svc)" >&2
}

# --- 服务控制 -------------------------------------------------------
# 包一层，让 sudo -n 被拒 / brew 报错不再静默吞掉。
# 注意：不能用 `sudo -n true` 预检权限 —— sudoers 只对下面三条命令免密，
# `true` 必然要密码，拿它当探针会误判。
_vpn_svc() {
  local action="$1" out rc
  out=$(sudo -n "$_VPN_BREW" services "$action" sing-box 2>&1); rc=$?
  if (( rc != 0 )); then
    echo "🔴 sing-box $action 失败 (exit $rc)" >&2
    printf '%s\n' "$out" | sed 's/^/   /' >&2
    if printf '%s' "$out" | grep -q "password is required"; then
      echo "   → sudo 免密未命中，/etc/sudoers.d/singbox 需包含：" >&2
      echo "     $(whoami) ALL=(root) NOPASSWD: $_VPN_BREW services $action sing-box" >&2
    fi
    return $rc
  fi
  printf '%s\n' "$out" | grep -E "Successfully|already (started|stopped)" || printf '%s\n' "$out"
}

vpn() {
  local cmd="${1:-status}"
  case "$cmd" in
    on|start)
      _vpn_svc start || return $?
      # 启动成功 ≠ 能用：KeepAlive 崩溃重启循环时进程在、TUN 不在。
      local i
      for i in {1..10}; do
        sleep 1
        if ifconfig 2>/dev/null | grep -q "${SB_TUN_IP//./\\.}" && _sb_listening; then
          proxy_env_on
          sb_bypass_apply
          echo "🟢 TUN 就绪，代理变量 + 系统代理绕过列表已设置（详情: vpn status）"
          return 0
        fi
      done
      echo "⚠️  已启动但 10s 内 TUN/端口未就绪，未设置代理变量。查日志: vpn log" >&2
      return 1
      ;;
    off|stop)
      _vpn_svc stop || return $?
      # 必须同时清掉代理变量：否则本 shell 里所有 CLI 会指向死端口，
      # 连内网和国内站点都连不上，比没有代理更糟。
      proxy_env_off
      echo "🔴 已停止，代理变量已清除（仅影响当前 shell；其他窗口需 source ~/.zshrc）"
      ;;
    restart)
      _vpn_svc restart || return $?
      local i
      for i in {1..10}; do
        sleep 1
        _sb_listening && { proxy_env_on; sb_bypass_apply; echo "🟢 已重启，代理变量已刷新"; return 0; }
      done
      echo "⚠️  重启后 10s 内端口未就绪。查日志: vpn log" >&2
      return 1
      ;;
    mtu)
      # 改配置 + 重启，而不是 ifconfig 改活接口：不需要给 ifconfig 开 sudo 免密
      # （那会连带放开改任意接口 IP / down 网卡的权限），且重启后不会被打回原值。
      local new="${2:-}"
      if [[ -z "$new" ]]; then
        echo "当前 TUN mtu = $(python3 -c "
import json;print([i for i in json.load(open('$SB_CONFIG'))['inbounds'] if i['type']=='tun'][0].get('mtu','?'))" 2>/dev/null)"
        echo "用法: vpn mtu <1280-9000>   (热点/弱网建议 1400，普通 WiFi 可试 1420-1450)"
        return 0
      fi
      if [[ ! "$new" =~ ^[0-9]+$ ]] || (( new < 1280 || new > 9000 )); then
        echo "MTU 必须是 1280-9000 的整数（1280 = IPv6 下限）" >&2
        return 1
      fi
      cp "$SB_CONFIG" "$SB_CONFIG.bak.$(date +%s)" || return 1
      python3 - "$SB_CONFIG" "$new" <<'PY' || return 1
import json, sys
path, mtu = sys.argv[1], int(sys.argv[2])
cfg = json.load(open(path))
for inb in cfg['inbounds']:
    if inb['type'] == 'tun':
        old = inb.get('mtu'); inb['mtu'] = mtu
        json.dump(cfg, open(path, 'w'), ensure_ascii=False, indent=2)
        print(f"  mtu: {old} → {mtu}"); break
else:
    sys.exit("找不到 tun inbound")
PY
      sing-box check -c "$SB_CONFIG" || { echo "配置校验失败，已留备份" >&2; return 1; }
      vpn restart
      ;;
    log)   tail -f "$SB_LOG" ;;
    check) sing-box check -c "$SB_CONFIG" ;;
    ui)    open "http://127.0.0.1:${SB_CLASH_PORT}/ui" ;;
    edit)  ${EDITOR:-vim} "$SB_CONFIG" ;;
    mode)
      local m="${2:-rule}"
      curl -s -X PATCH "http://127.0.0.1:${SB_CLASH_PORT}/configs" \
        -H "Authorization: Bearer $(_sb_secret)" \
        -H "Content-Type: application/json" \
        -d "{\"mode\":\"$m\"}" && echo "→ mode=$m"
      ;;
    status|"")
      local pid
      pid=$(pgrep -f "sing-box run --config" | head -1)
      if [[ -n "$pid" ]]; then
        echo "🟢 sing-box: running (pid $pid)"
      else
        echo "🔴 sing-box: stopped  (启动: vpn on)"; return 1
      fi
      echo ""
      echo "端口："
      LC_ALL=C netstat -anv -p tcp 2>/dev/null \
        | LC_ALL=C awk -v p="sing-box:$pid" '$0 ~ p && /LISTEN/ {print "  "$4}' | sort -u
      echo ""
      echo "TUN："
      ifconfig 2>/dev/null | awk -v ip="$SB_TUN_IP" \
        '/^utun[0-9]+.*flags=/{n=$1; m=$NF} index($0, ip){print "  "n"  "ip"  mtu="m" ✓"}'
      local phy phy_mtu
      phy=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
      # 取 "mtu" 后紧跟的那个字段：热点下行尾可能是 constrained 而非数值，$NF 会取错。
      phy_mtu=$(ifconfig "$phy" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}')
      echo "  物理出口 $phy mtu=${phy_mtu:-?}$(ifconfig "$phy" 2>/dev/null | grep -q constrained && echo '  (constrained/低数据模式)')"
      echo ""
      local mode
      mode=$(curl -s --max-time 2 -H "Authorization: Bearer $(_sb_secret)" \
             "http://127.0.0.1:${SB_CLASH_PORT}/configs" 2>/dev/null \
             | python3 -c "import json,sys; print(json.load(sys.stdin).get('mode','?'))" 2>/dev/null)
      echo "路由模式：${mode:-N/A}  (切换: vpn mode rule|global|direct)"
      echo ""
      echo "代理变量（CLI 用）："
      if [[ -n "${https_proxy:-}" ]]; then
        echo "  https_proxy = $https_proxy"
        _sb_listening || echo "  ⚠️  ${SB_MIXED_PORT} 未监听，变量已失效 → 跑 vpn off 清除"
      else
        echo "  (未设置，走 TUN)"
      fi
      echo ""
      echo "系统代理（GUI 应用用）："
      local svc bypass_n
      svc=$(_sb_netsvc)
      echo "  网络服务 = $svc"
      networksetup -getsecurewebproxy "$svc" 2>/dev/null | awk '/Enabled|Server|Port/{print "  "$0}'
      bypass_n=$(networksetup -getproxybypassdomains "$svc" 2>/dev/null | grep -c .)
      echo "  绕过列表 = $bypass_n 条（期望 $(_sb_bypass_list | grep -c .) 条；不符跑 sb_bypass_apply）"
      echo ""
      echo "连通性："
      local g204 cn
      g204=$(curl -so /dev/null -w "%{http_code}/%{time_total}s" --max-time 6 https://www.google.com/generate_204 2>/dev/null)
      cn=$(curl -so /dev/null -w "%{http_code}/%{time_total}s" --max-time 6 https://www.baidu.com 2>/dev/null)
      echo "  google 204  = $g204   (期望 204)"
      echo "  国内站点    = $cn   (期望 200，毫秒级)"
      # 机器特化的连通性检查（如公司内网）写进 ~/.config/singbox-deploy/probe.local
      local probe="$HOME/.config/singbox-deploy/probe.local"
      if [[ -r "$probe" ]]; then
        local url
        while IFS= read -r url; do
          [[ -z "$url" || "$url" == \#* ]] && continue
          echo "  $url = $(curl -so /dev/null -w '%{http_code}/%{time_total}s' --max-time 6 "$url" 2>/dev/null)"
        done < "$probe"
      fi
      ;;
    *)
      echo "usage: vpn {on|off|restart|status|log|check|ui|edit|mtu [值]|mode <rule|global|direct>}"
      return 1
      ;;
  esac
}

alias proxy-on='vpn on'
alias proxy-off='vpn off'
alias proxy-status='vpn status'
