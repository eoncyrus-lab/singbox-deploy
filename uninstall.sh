#!/usr/bin/env bash
# 卸载 sing-box 部署。默认保留二进制和配置，--purge 才彻底删除。
set -euo pipefail
PURGE=0; [[ "${1:-}" == "--purge" ]] && PURGE=1
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }

say "停止服务"
sudo brew services stop sing-box 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/homebrew.mxcl.sing-box.plist

say "清理系统代理残留"
# set_system_proxy 异常退出时会把系统代理留在开启状态，导致「服务停了却全网断」
DEV=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
SVC=$(networksetup -listnetworkserviceorder 2>/dev/null | awk -v d="Device: $DEV)" \
      '/^\([0-9]+\)/{n=$0; sub(/^\([0-9]+\) /,"",n)} index($0,d){print n; exit}')
SVC="${SVC:-Wi-Fi}"
for s in setwebproxystate setsecurewebproxystate setsocksfirewallproxystate; do
  networksetup "$s" "$SVC" off 2>/dev/null || true
done
echo "  已关闭 $SVC 的系统代理"

say "撤销 sudo 免密"
sudo rm -f /etc/sudoers.d/singbox

say "移除 shell 集成"
# 只删 source 行，不动 .zshrc 其它内容
if [[ -f "$HOME/.zshrc" ]] && grep -qF 'singbox-deploy/vpn.zsh' "$HOME/.zshrc"; then
  cp "$HOME/.zshrc" "$HOME/.zshrc.bak-$(date +%Y%m%d-%H%M%S)"
  sed -i '' '/singbox-deploy\/vpn.zsh/d; /^# === sing-box ===$/d' "$HOME/.zshrc"
  echo "  已删除 source 行（.zshrc 已备份）"
fi

if (( PURGE )); then
  say "彻底移除（--purge）"
  rm -rf "$HOME/.config/singbox-deploy"
  sudo rm -rf "$BREW_PREFIX/var/lib/sing-box" "$BREW_PREFIX/etc/sing-box"
  brew uninstall sing-box 2>/dev/null || true
  echo "  配置 $HOME/singbox-config.json 保留（含节点密码，请自行确认后删除）"
else
  echo
  echo "保留：sing-box 二进制、~/singbox-config.json、~/.config/singbox-deploy/"
  echo "彻底删除请跑：./uninstall.sh --purge"
fi
say "完成。新开终端生效。"
