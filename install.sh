#!/bin/bash
# install.sh — aihub-checkin 一键部署脚本
#
# 功能：
#   1. 检查/安装依赖（Chrome、Xvfb、playwright、curl、python3）
#   2. 拷贝脚本到 /usr/local/lib/aihub-checkin
#   3. 配置令牌
#   4. 安装 systemd 单元 + 每日 09:30 定时器
#
# 用法：
#   sudo AIHUB_TOKEN='<系统访问令牌>' bash install.sh
#   # 或不带令牌，装完后手动写入 /etc/aihub-checkin/token
set -u

SITE="${AIHUB_SITE:-https://aihub.071129.xyz}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/local/lib/aihub-checkin"
CONF_DIR="/etc/aihub-checkin"
SVC_DIR="/etc/systemd/system"

if [ "$(id -u)" != "0" ]; then
  echo "请以 root 运行（需要写入 /usr/local 和 systemd）"
  exit 1
fi

echo "=== 1. 检查依赖 ==="
require() { command -v "$1" >/dev/null 2>&1 && echo "  ✓ $1" || echo "  ✗ $1（缺失）"; }
require curl
require python3
require Xvfb
require node
require npm

if ! command -v google-chrome >/dev/null 2>&1 && [ ! -x /opt/google/chrome/chrome ]; then
  echo ""
  echo "  Chrome 未安装，开始安装（Debian/Ubuntu）..."
  curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb
  apt-get install -y /tmp/chrome.deb || { echo "Chrome 安装失败"; exit 1; }
  rm -f /tmp/chrome.deb
else
  echo "  ✓ Chrome"
fi

if ! node -e "require('playwright')" >/dev/null 2>&1; then
  echo ""
  echo "  playwright 未安装，开始安装..."
  npm install -g playwright || { echo "playwright 安装失败"; exit 1; }
else
  echo "  ✓ playwright"
fi

echo ""
echo "=== 2. 拷贝项目到 $INSTALL_DIR ==="
mkdir -p "$INSTALL_DIR"
cp -r "$SCRIPT_DIR/scripts" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/scripts/aihub-checkin.sh"
echo "  已拷贝"

echo ""
echo "=== 3. 配置令牌 ==="
mkdir -p "$CONF_DIR"
if [ -n "${AIHUB_TOKEN:-}" ]; then
  printf '%s' "$AIHUB_TOKEN" > "$CONF_DIR/token"
  chmod 600 "$CONF_DIR/token"
  echo "  ✓ 令牌已写入 $CONF_DIR/token"
else
  echo "  ℹ 未提供 AIHUB_TOKEN，请稍后手动写入："
  echo "    echo '你的系统访问令牌' > $CONF_DIR/token && chmod 600 $CONF_DIR/token"
  echo "    （令牌在 $SITE/profile 页面生成）"
fi

echo ""
echo "=== 4. 安装 systemd 服务 + 定时器 ==="
# 用仓库里的模板，替换占位符
sed "s#__SITE__#$SITE#; s#__CONF_DIR__#$CONF_DIR#; s#__INSTALL_DIR__#$INSTALL_DIR#" \
  "$SCRIPT_DIR/systemd/aihub-checkin.service" > "$SVC_DIR/aihub-checkin.service"
cp "$SCRIPT_DIR/systemd/aihub-checkin.timer" "$SVC_DIR/aihub-checkin.timer"

systemctl daemon-reload
systemctl enable --now aihub-checkin.timer
echo "  ✓ 定时器已启用"

echo ""
echo "=== 5. 验证 ==="
systemctl list-timers aihub-checkin.timer --no-pager | head -3 | sed 's/^/  /'
echo ""
echo "下次触发时间："
systemctl show aihub-checkin.timer -p NextElapseUSecRealtime --value | \
  python3 -c "import sys,datetime; t=int(sys.stdin.read().strip())//1000000; print('  ', datetime.datetime.fromtimestamp(t).strftime('%F %T'))" 2>/dev/null || echo "  (查询失败)"

echo ""
echo "=== 安装完成 ==="
echo "  立即测试一次：sudo systemctl start aihub-checkin.service"
echo "  查看日志    ：journalctl -u aihub-checkin -n 50 --no-pager"
