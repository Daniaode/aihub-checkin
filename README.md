# aihub-checkin

New API（one-api 系）站点的每日自动签到，实测通过 **Cloudflare Turnstile** 人机验证。

## 它能做什么

- 每天自动对 `https://aihub.071129.xyz` 签到，获得每日随机配额
- 使用**真实 Chrome** 原生启动 + CDP 接管，绕过 Turnstile 对自动化浏览器的识别
- 幂等：已签到则直接退出，不会重复
- 结果打印到 stdout / journald，方便接 TG 推送

## 为什么需要真实 Chrome + CDP 接管（重要）

直接 `playwright.launch()` 启动的 Chromium 会被 Cloudflare Turnstile 判为机器人——挑战框**永远不挂载**（`iframe=0`），控制台报 `Error: 600010`。

关键结论（已验证）：

| 方式 | 结果 |
|---|---|
| Playwright `launch` / `launchPersistentContext`（含真实 Chrome 二进制、无头/有头、补丁指纹） | ❌ 失败 |
| **原生启动 Chrome（干净参数）→ `connectOverCDP` 接管** | ✅ 通过 |

原理：Playwright 的启动路径会注入 `--enable-automation` 等标志，而 `connectOverCDP` 连接的是已经干净启动的浏览器。接管时 Turnstile 通常已经在页面上解出 token，直接读取 `input[name="cf-turnstile-response"]` 即可。

## 依赖

- Linux（Debian/Ubuntu 系，`apt`）
- 真实 Google Chrome（`/opt/google/chrome/chrome`）
- Xvfb（无头显示服务器）
- Node.js ≥ 18 + npm
- playwright（npm 包，仅 `connectOverCDP`，**不需要**它的浏览器缓存）
- curl、python3

## 快速部署（systemd，推荐）

```bash
# 1. 克隆
git clone https://github.com/<you>/aihub-checkin.git
cd aihub-checkin

# 2. 一键安装（带令牌）
sudo AIHUB_TOKEN='你的系统访问令牌' bash install.sh
```

`install.sh` 会：

1. 检查并安装 Chrome / Xvfb / playwright / curl / python3
2. 拷贝脚本到 `/usr/local/lib/aihub-checkin`
3. 把令牌写入 `/etc/aihub-checkin/token`（`chmod 600`）
4. 安装 `aihub-checkin.service` + `aihub-checkin.timer`（每日 09:30）

### 手动安装

```bash
# 依赖
sudo apt-get install -y xvfb curl python3
curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb
sudo apt-get install -y /tmp/chrome.deb
npm install -g playwright

# 项目
sudo mkdir -p /usr/local/lib/aihub-checkin
sudo cp -r scripts /usr/local/lib/aihub-checkin/
sudo chmod +x /usr/local/lib/aihub-checkin/scripts/aihub-checkin.sh

# 令牌
sudo mkdir -p /etc/aihub-checkin
echo '你的系统访问令牌' | sudo tee /etc/aihub-checkin/token >/dev/null
sudo chmod 600 /etc/aihub-checkin/token
```

## 令牌从哪来

1. 浏览器打开 `https://aihub.071129.xyz/profile`
2. 用 GitHub 登录
3. 找到「系统访问令牌 / Access Token」，生成并复制

> 这是**用户级访问令牌**，不是推理用的 API key（`sk-...`）。两者不同，用推理 key 会报 `AUTH_UNAUTHORIZED`。

## 定时

### systemd timer（推荐）

`install.sh` 已装好：

```bash
systemctl list-timers aihub-checkin.timer   # 查看下次触发
sudo systemctl start aihub-checkin.service  # 立即跑一次
journalctl -u aihub-checkin -n 50 --no-pager  # 看日志
```

### cron

```cron
30 9 * * * /usr/local/lib/aihub-checkin/scripts/aihub-checkin.sh >> /var/log/aihub-checkin.log 2>&1
```

### TG 推送（可选）

脚本本身只输出到 stdout。接 TG 推送时，把结果重定向给 bot 即可，例如用 `curl` 调 Bot API，或用你现有的推送通道把 `journalctl` 输出转发出去。

## 配置（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `AIHUB_SITE` | `https://aihub.071129.xyz` | 站点 |
| `AIHUB_TOKEN_FILE` | `$XDG_CONFIG_HOME/aihub-checkin/token` 或 `/etc/...` | 令牌文件路径 |
| `CHROME_BIN` | `/opt/google/chrome/chrome` | Chrome 可执行文件 |
| `DISPLAY_NUM` | `:89` | Xvfb display |
| `CDP_PORT` | `9223` | Chrome remote-debugging 端口 |
| `STATE_DIR` | `/tmp/aihub-checkin` | profile / 日志 / 临时 token |

## 工作流程

```
1. GET /api/user/checkin    查今日状态（无 Turnstile，令牌即可）
   └─ 已签到 → 直接退出
2. Xvfb + 原生启动 Chrome（干净参数）→ 等 CDP 就绪
3. connectOverCDP 接管 → 轮询读 turnstile token（通常 ≤15s）
4. POST /api/user/checkin?turnstile=<token> → 签到
5. 清理 Chrome / Xvfb / token 临时文件
```

## 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `Turnstile token 为空` | 走的是无 Turnstile 的 GET？不对，是 POST 缺 token | 确认 POST 带 `?turnstile=` |
| `Turnstile 校验失败` | token 已过期或被复用 | token 一次性，重新跑 |
| `iframe=0` 且 `Error 600010` | 用 Playwright launch 了 | 改成原生启动 + connectOverCDP |
| `CDP 未就绪` | Chrome 没起来 | `cat $STATE_DIR/chrome.log`，root 需 `--no-sandbox` |
| `AUTH_UNAUTHORIZED` | 令牌是推理 key | 用 profile 页的访问令牌 |
| 找不到 playwright | npm 全局安装 | `npm install -g playwright` |

## 目录结构

```
aihub-checkin/
├── install.sh                  # 一键部署
├── README.md
├── systemd/
│   ├── aihub-checkin.service   # oneshot 服务
│   └── aihub-checkin.timer     # 每日 09:30
└── scripts/
    ├── aihub-checkin.sh        # 主脚本
    └── turnstile-get.mjs       # CDP 接管取 token
```
