#!/bin/bash
# aihub-checkin.sh — New API 站点全自动签到（真实 Chrome + CDP 接管，绕过 Turnstile）
#
# 关键原理：Playwright 自己 launch 的 Chrome 会被 Turnstile 判为机器人；
#   改为「原生启动 Chrome（干净标志）→ connectOverCDP 接管」即可通过。
#
# 环境变量（均可选，脚本会取默认值）：
#   AIHUB_SITE       站点，默认 https://aihub.071129.xyz
#   AIHUB_TOKEN      用户系统访问令牌（profile 页生成）
#   AIHUB_TOKEN_FILE 令牌文件路径，默认 ${XDG_CONFIG_HOME:-$HOME/.config}/aihub-checkin/token
#   CHROME_BIN       Chrome 可执行文件，默认 /opt/google/chrome/chrome
#   DISPLAY_NUM      Xvfb display 号，默认 :89
#   CDP_PORT         Chrome remote-debugging 端口，默认 9223
#   STATE_DIR        运行态目录（profile/日志/token 临时文件），默认 /tmp/aihub-checkin
#
# 依赖：真实 Chrome、xvfb、playwright(npm)、curl、python3
set -u

SITE="${AIHUB_SITE:-https://aihub.071129.xyz}"
CHROME_BIN="${CHROME_BIN:-/opt/google/chrome/chrome}"
DISP="${DISPLAY_NUM:-:89}"
CDP_PORT="${CDP_PORT:-9223}"

# 目录推导：脚本所在目录的上一级即项目根
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NODE_SCRIPT="$SCRIPT_DIR/turnstile-get.mjs"

# 状态目录：默认放 /tmp，令牌文件放 XDG config（避免写入项目目录）
STATE_DIR="${STATE_DIR:-/tmp/aihub-checkin}"
TOKEN_FILE="${AIHUB_TOKEN_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/aihub-checkin/token}"
TS_FILE="$STATE_DIR/turnstile.token"
PROFILE="$STATE_DIR/chrome-profile"
LOG_DIR="$STATE_DIR/logs"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$(dirname "$TOKEN_FILE")"
LOG="$LOG_DIR/checkin-$(date +%Y%m%d).log"

# ---------- 工具自检 ----------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ 缺少依赖: $1"; exit 1; }
}
require_cmd curl
require_cmd python3
require_cmd Xvfb
[ -x "$CHROME_BIN" ] || { echo "❌ 找不到 Chrome: $CHROME_BIN"; exit 1; }

# ---------- 清理（用 PID 精确 kill，pkill -f 会匹配到本脚本自身）----------
cleanup() {
  if [ -n "${CHROME_PID:-}" ]; then kill -9 "$CHROME_PID" 2>/dev/null; fi
  if [ -n "${XVFB_PID:-}" ]; then kill -9 "$XVFB_PID" 2>/dev/null; fi
  # 兜底：按 profile 路径特征找 PID（不含会命中自身的字面量）
  local p
  for p in $(pgrep -f "$PROFILE" 2>/dev/null); do
    [ "$p" != "$$" ] && kill -9 "$p" 2>/dev/null
  done
  rm -f "$TS_FILE"
}
trap cleanup EXIT

exec > >(tee -a "$LOG") 2>&1
echo "=== $(date '+%F %T') 开始签到 ==="

# ---------- 0. 令牌 ----------
if [ ! -s "$TOKEN_FILE" ]; then
  echo "❌ 缺少令牌文件 $TOKEN_FILE"
  echo "   请在 $SITE/profile 生成系统访问令牌后写入该文件（echo '令牌' > $TOKEN_FILE）"
  exit 1
fi
TOKEN="$(tr -d ' \r\n' < "$TOKEN_FILE")"

# ---------- 1. 今日是否已签到（GET 接口无 Turnstile）----------
echo "--- 检查今日状态"
STATUS=$(python3 - "$TOKEN" "$SITE" <<'PY'
import subprocess, json, sys
tok, site = sys.argv[1], sys.argv[2]
r = subprocess.run(['curl','-s','--max-time','20',
    '-H','Authorization: Bearer '+tok,
    '-H','User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36',
    site+'/api/user/checkin'], capture_output=True, text=True)
try:
    s = json.loads(r.stdout).get('data', {}).get('stats', {})
    print('CHECKED' if s.get('checked_in_today') else 'NOT_CHECKED')
except Exception:
    print('ERROR')
PY
)
echo "  状态: $STATUS"
case "$STATUS" in
  CHECKED) echo "ℹ️ 今日已签到，无需重复"; exit 0 ;;
  ERROR)   echo "❌ 状态查询失败"; exit 1 ;;
esac

# ---------- 2. 原生启动干净 Chrome ----------
echo "--- 启动真实 Chrome（干净标志，勿加 automation 参数）"
Xvfb "$DISP" -screen 0 1440x900x24 -ac >"$STATE_DIR/xvfb.log" 2>&1 &
XVFB_PID=$!
sleep 2
export DISPLAY="$DISP"

rm -rf "$PROFILE"
nohup "$CHROME_BIN" \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port="$CDP_PORT" \
  --no-sandbox \
  --no-first-run \
  --no-default-browser-check \
  --window-size=1440,900 \
  --window-position=0,0 \
  --lang=zh-CN \
  --disable-dev-shm-usage \
  "$SITE/sign-in" \
  >"$STATE_DIR/chrome.log" 2>&1 &
CHROME_PID=$!

CDP_READY=0
for i in $(seq 1 30); do
  if curl -s --max-time 2 "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; then
    CDP_READY=1; echo "  CDP 就绪 (${i}s)"; break
  fi
  sleep 1
done
[ "$CDP_READY" = "1" ] || { echo "❌ Chrome CDP 未就绪"; tail -5 "$STATE_DIR/chrome.log"; exit 1; }

# ---------- 3. CDP 接管取 Turnstile token ----------
echo "--- 获取 Turnstile token"
if ! CDP_PORT="$CDP_PORT" TS_FILE="$TS_FILE" AIHUB_SITE="$SITE" timeout 120 node "$NODE_SCRIPT"; then
  echo "❌ 未能获取 Turnstile token"
  exit 1
fi
[ -s "$TS_FILE" ] || { echo "❌ token 文件为空"; exit 1; }
echo "  token 长度: $(wc -c < "$TS_FILE")"

# ---------- 4. 提交签到 ----------
echo "--- 提交签到"
python3 - "$TOKEN" "$TS_FILE" "$SITE" <<'PY'
import subprocess, json, sys
tok, ts_file, site = sys.argv[1], sys.argv[2], sys.argv[3]
ts = open(ts_file).read().strip()
r = subprocess.run(['curl','-s','--max-time','25','-X','POST',
    '-H','Authorization: Bearer '+tok,
    '-H','User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36',
    '-H','Content-Type: application/json','-d','{}',
    site+'/api/user/checkin?turnstile='+ts], capture_output=True, text=True)
try:
    d = json.loads(r.stdout)
except Exception:
    print('❌ 响应解析失败: ' + r.stdout[:200]); sys.exit(1)

if d.get('success'):
    data = d.get('data') or {}
    print('✅ 签到成功')
    print('  日期: %s' % data.get('checkin_date', '-'))
    print('  获得: %s' % data.get('quota_awarded', '-'))
    sys.exit(0)
msg = d.get('message') or ''
if any(k in msg for k in ('已签到', 'already', '重复')):
    print('ℹ️ 今日已签到'); sys.exit(0)
print('❌ 签到失败: ' + msg[:150]); sys.exit(1)
PY
RC=$?

echo "=== $(date '+%F %T') 结束 (rc=$RC) ==="
exit $RC
