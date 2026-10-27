#!/usr/bin/env node
// turnstile-get.mjs — 接管已运行的干净 Chrome，取得 Cloudflare Turnstile token
//
// 关键原理（务必保留）：
//   Playwright 自己 launch 的 Chrome 会带 --enable-automation 等标志，
//   Turnstile 据此判为机器人，挑战框永不挂载（iframe=0，报 600010）。
//   改用「原生启动 Chrome + connectOverCDP 接管」即可通过 —— 接管时 token
//   往往已经存在，直接读 input[name="cf-turnstile-response"] 即可。
//
// 环境变量：
//   CDP_PORT   Chrome remote-debugging 端口（默认 9223）
//   TS_FILE    token 输出文件（默认 /tmp/aihub_ts_token.txt）
//   AIHUB_SITE 站点（默认 https://aihub.071129.xyz）
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import fs from 'node:fs';

const require = createRequire(import.meta.url);

// 动态解析全局 npm 模块路径，避免硬编码 /usr/lib/node_modules
function globalRequire(name) {
  const candidates = [name];
  try {
    const root = execSync('npm root -g', { encoding: 'utf8' }).trim();
    if (root) candidates.push(`${root}/${name}`);
  } catch { /* npm 不在 PATH，忽略 */ }
  for (const c of candidates) {
    try { return require(c); } catch { /* 继续 */ }
  }
  throw new Error(`未找到 ${name}，请执行 npm install -g ${name}`);
}

let pw;
try {
  pw = globalRequire('playwright');
} catch (e) {
  console.log('❌ ' + e.message);
  process.exit(1);
}
const { chromium } = pw;

const PORT = process.env.CDP_PORT || '9223';
const OUT = process.env.TS_FILE || '/tmp/aihub_ts_token.txt';
const SITE = process.env.AIHUB_SITE || 'https://aihub.071129.xyz';

let browser;
try {
  browser = await chromium.connectOverCDP(`http://127.0.0.1:${PORT}`);
} catch (e) {
  console.log('❌ CDP 连接失败: ' + e.message);
  process.exit(1);
}

const ctx = browser.contexts()[0];
if (!ctx) { console.log('❌ 无浏览器上下文'); process.exit(1); }

const pages = ctx.pages();
const page = pages.find(p => p.url().includes('sign-in')) || pages[0];
if (!page) { console.log('❌ 无可用页面'); process.exit(1); }

console.log('  已接管: ' + page.url().replace(SITE, ''));

if (!page.url().includes('sign-in')) {
  await page.goto(SITE + '/sign-in', { waitUntil: 'domcontentloaded', timeout: 60000 });
}

const readToken = () => page.evaluate(() => {
  const el = document.querySelector('input[name="cf-turnstile-response"]');
  return el ? (el.value || '') : '';
}).catch(() => '');

let token = '', waited = 0;
while (waited < 75) {
  token = await readToken();
  if (token) break;
  await page.waitForTimeout(3000);
  waited += 3;
  if (waited % 15 === 0) {
    const n = await page.evaluate(() => document.querySelectorAll('iframe').length).catch(() => -1);
    console.log(`  等待中 ${waited}s (iframe=${n})`);
  }
}

if (!token) {
  console.log('❌ 75s 内未取得 Turnstile token');
  const diag = await page.evaluate(() => {
    const el = document.querySelector('input[name="cf-turnstile-response"]');
    return { has: !!el, iframes: document.querySelectorAll('iframe').length };
  }).catch(() => ({}));
  console.log('  诊断: ' + JSON.stringify(diag));
  process.exit(1);
}

fs.writeFileSync(OUT, token, { mode: 0o600 });
console.log(`  ✓ token 已取得 (len=${token.length}, ${waited}s)`);
process.exit(0);
