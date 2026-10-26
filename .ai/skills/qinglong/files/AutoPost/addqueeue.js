/*
青龙面板 JS 定时任务脚本 - 无依赖版（纯 Node http/https）
--------------------------------
cron: 0 11 * * *
new Env('T100-库存同步任务')

说明：
- 每天 11:00 自动执行库存同步接口。
- 采用 Node 内置 http/https，无需 axios、request 等依赖。
*/

'use strict';

const path = require('path');
const { URL } = require('url');
const http = require('http');
const https = require('https');

const ENV = (k, d) => (process.env[k] ?? d);

const TASK_NAME = ENV('TASK_NAME', '新增自动过账单据');
const TIMEOUT_MS = Number(ENV('TIMEOUT_MS', '60000')) || 60000;
const RETRY = Number(ENV('RETRY', '2')) || 2;
const NOTIFY = String(ENV('NOTIFY', 'on')).toLowerCase() !== 'off';
const ONLY_NOTIFY_ON_ERROR = String(ENV('ONLY_NOTIFY_ON_ERROR', 'false')).toLowerCase() === 'true';

// ✅ 你的接口地址（按需修改）
const URLS = [
  // 'http://10.10.76.109:12000/autopost/queeue',
  // 'http://10.10.76.109:12010/autopost/queeue',
  'http://10.10.76.109:12020/autopost/queeue'
];

// ============ 尝试加载青龙通知 ============  
let qywxBotNotify = null;
try {
  qywxBotNotify = require('../notify').qywxBotNotify;
} catch (_) {
  console.log('未找到 notify.js，通知功能将不可用');
}

// ============ HTTP 请求核心函数 ============
function httpRequestRaw(targetUrl, timeoutMs) {
  return new Promise((resolve, reject) => {
    const u = new URL(targetUrl);
    const lib = u.protocol === 'https:' ? https : http;

    const opts = {
      protocol: u.protocol,
      hostname: u.hostname,
      port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: `${u.pathname}${u.search}`,
      method: 'GET',
      headers: {
        'User-Agent': 'QingLongScript/1.0 NodeNoDeps',
        'Accept': 'application/json,text/plain,*/*'
      },
    };

    const req = lib.request(opts, (res) => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve({ statusCode: res.statusCode, body: data });
        } else {
          reject(new Error(`HTTP ${res.statusCode} => ${data.slice(0, 200)}`));
        }
      });
    });

    req.on('error', (err) => reject(err));
    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error(`timeout ${timeoutMs}ms`));
    });
    req.end();
  });
}

async function requestWithRetry(url, retry = RETRY, waitMs = 1000) {
  let lastErr;
  for (let i = 0; i <= retry; i++) {
    try {
      const res = await httpRequestRaw(url, TIMEOUT_MS);
      let parsed;
      try { parsed = JSON.parse(res.body); } catch (_) { parsed = res.body; }
      return { ok: true, status: res.statusCode, data: parsed };
    } catch (err) {
      lastErr = err;
      if (i < retry) {
        await new Promise(r => setTimeout(r, waitMs * (i + 1)));
      }
    }
  }
  return { ok: false, status: 0, error: lastErr?.message || String(lastErr) };
}

// ============ 主流程 ============
async function main() {
  console.log(`\n=== ${TASK_NAME} 开始执行 ===`);
  const results = await Promise.all(URLS.map((u) => requestWithRetry(u)));

  const lines = results.map((r, i) => {
    if (r.ok) {
      const preview = typeof r.data === 'string'
        ? r.data.slice(0, 150)
        : JSON.stringify(r.data).slice(0, 150);
      return `接口${i + 1} 成功（HTTP ${r.status}）：${preview}`;
    }
    return `接口${i + 1} 失败：${r.error}`;
  });

  const okCount = results.filter(r => r.ok).length;
  const failCount = results.length - okCount;

  const title = `${TASK_NAME}｜成功 ${okCount} 失败 ${failCount}`;
  const body = lines.join('\n');

  console.log('\n===== 执行结果 =====');
  console.log(title);
  console.log(body);

  if (NOTIFY && (!ONLY_NOTIFY_ON_ERROR || failCount > 0) && qywxBotNotify) {
    // try { await qywxBotNotify(title, body); } catch (e) { console.log('发送通知失败：', e.message); }
  }

  if (failCount > 0) process.exitCode = 1;
}

main().catch((err) => {
  console.error('脚本异常：', err);
  process.exitCode = 1;
});
