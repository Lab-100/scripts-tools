// browsertool driver.mjs — HTTP-драйвер локального headless-браузера.
// Работает на patchright + системный Edge (или Chrome);
// слушает 127.0.0.1:8123, отвечает JSON. Один браузер и одна страница на весь процесс.
//
// Контракт (используется пулом Lab100: lab100/providers/local_browser.py):
//   GET  /            → {ok:true} (пинг, жизнь процесса)
//   POST /  JSON      → {cmd:"nav", url, wait}          навигация (+ожидание, мс)
//                     → {cmd:"eval", js}                выполнить JS в странице → {res:…}
//                     → {cmd:"get", url, timeout}       навигация + текст страницы → {text:…}
// Дополнительно (для UI-автоверификации):
//   open  — алиас nav (url обязателен)
//   click {selector}                — клик по CSS-селектору
//   fill  {selector, value}         — ввод значения в поле
//   type  {selector, text}          — печать текста в поле с задержкой
//   press {key}                     — нажатие клавиши (Enter, Tab, …)
//   snap  {}                        — {url,title,refs:[{id:"@eN",tag,text,sel}]} снимок интерактивных элементов
//   shot  {}                        — скриншот PNG base64 → {png}
// Ошибки → HTTP 200 и тело {error:"…"} (клиент-пул это обрабатывает).

import { chromium } from 'patchright';
import http from 'node:http';
import { readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const PORT = Number(process.env.BROWSERTOOL_PORT || 8123);
const HOST = '127.0.0.1';
const BROWSER_CHANNEL = process.env.BROWSERTOOL_CHANNEL || 'msedge'; // msedge | chrome
const LOG = path.join(path.dirname(fileURLToPath(import.meta.url)), 'driver.log');

function log(...args) {
  const line = `[${new Date().toISOString()}] ${args.join(' ')}`;
  try { appendFileSync(LOG, line + '\n'); } catch {}
}

let browser = null;
let page = null;
let launching = null;

function getBrowser() {
  if (browser) return Promise.resolve(browser);
  if (!launching) {
    launching = (async () => {
      log('launch patchright chromium channel=' + BROWSER_CHANNEL);
      browser = await chromium.launch({ headless: true, channel: BROWSER_CHANNEL });
      const ctx = await browser.newContext({
        viewport: { width: 1280, height: 900 },
        userAgent:
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      });
      page = await ctx.newPage();
      await page.setDefaultNavigationTimeout(60000);
      page.on('error', (e) => log('page error:', String(e)));
      log('browser ready');
      return browser;
    })().catch((e) => {
      log('launch FAILED:', String(e));
      browser = null;
      launching = null;
      throw e;
    });
  }
  return launching;
}

function safe(value) {
  // снять функции/циклы и BigInt, чтобы body был чистым JSON
  try { return JSON.parse(JSON.stringify(value)); } catch { return String(value); }
}

async function cmdNav({ url, wait }) {
  const b = await getBrowser();
  if (!url) return { error: 'nav: url обязателен' };
  log('nav', url);
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  if (wait && wait > 0) await new Promise((r) => setTimeout(r, wait));
  return { ok: true, url: page.url(), title: await page.title() };
}

async function cmdEval({ js }) {
  if (!js) return { error: 'eval: js обязателен' };
  await getBrowser();
  const res = await page.evaluate(js);
  return { res: safe(res), url: page.url(), title: await page.title() };
}

async function cmdGet({ url, timeout }) {
  const b = await getBrowser();
  if (url) {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: Number(timeout) || 60000 });
  } else if (!page) {
    return { error: 'get: url обязателен на первом запросе' };
  }
  const text = await page.evaluate(() => String(document.body?.innerText || '').replace(/\s{2,}/g, '\n'));
  return { ok: true, url: page.url(), title: await page.title(), text };
}

async function cmdClick({ selector }) {
  if (!selector) return { error: 'click: selector обязателен' };
  await getBrowser();
  const locator = page.locator(selector).first();
  await locator.scrollIntoViewIfNeeded();
  await locator.click({ timeout: 15000 });
  return { ok: true, url: page.url() };
}

async function cmdFill({ selector, value }) {
  if (!selector || value === undefined) return { error: 'fill: selector и value обязательны' };
  await getBrowser();
  await page.fill(selector, String(value));
  return { ok: true };
}

async function cmdType({ selector, text }) {
  if (!selector || text === undefined) return { error: 'type: selector и text обязательны' };
  await getBrowser();
  await page.click(selector);
  await page.keyboard.type(String(text), { delay: 12 });
  return { ok: true };
}

async function cmdPress({ key }) {
  if (!key) return { error: 'press: key обязательна' };
  await getBrowser();
  await page.keyboard.press(String(key));
  return { ok: true, url: page.url() };
}

async function cmdSnap() {
  await getBrowser();
  const data = await page.evaluate(() => {
    const els = [...document.querySelectorAll(
      'a[href], button, input:not([type="hidden"]), textarea, select, [role="button"], [role="link"]'
    )];
    return els.slice(0, 80).map((el, i) => {
      const tag = el.tagName.toLowerCase();
      let sel;
      if (el.id) sel = `#${CSS.escape(el.id)}`;
      else if (tag === 'a' && el.getAttribute('href')) sel = `a[href="${CSS.escape(el.getAttribute('href'))}"]`;
      else {
        const same = [...document.querySelectorAll(tag)];
        const n = same.indexOf(el) + 1;
        sel = n ? `${tag}:nth-of-type(${n})` : tag;
      }
      return {
        id: `@e${i + 1}`,
        tag,
        text: (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 80),
        sel,
      };
    });
  });
  return { url: page.url(), title: await page.title(), refs: data };
}

async function cmdShot() {
  await getBrowser();
  const buf = await page.screenshot({ type: 'png' });
  return { url: page.url(), png: buf.toString('base64') };
}

const dispatch = {
  nav: cmdNav,
  open: cmdNav,
  eval: cmdEval,
  get: cmdGet,
  click: cmdClick,
  fill: cmdFill,
  type: cmdType,
  press: cmdPress,
  snap: cmdSnap,
  shot: cmdShot,
};

const server = http.createServer(async (req, res) => {
  const send = (code, body) => {
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(body));
  };

  if (req.method === 'GET') return send(200, { ok: true, service: 'browsertool', port: PORT });

  if (req.method === 'POST') {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    let payload = {};
    try { payload = raw ? JSON.parse(raw) : {}; } catch { return send(200, { error: 'невалидный JSON' }); }

    const fn = dispatch[payload.cmd];
    if (!fn) return send(200, { error: `неизвестная команда: ${payload.cmd}` });

    try {
      const out = await fn(payload);
      return send(200, out);
    } catch (e) {
      const msg = String(e && e.message ? e.message : e).slice(0, 500);
      log('cmd', payload.cmd, 'ERROR:', msg);
      return send(200, { error: `${payload.cmd}: ${msg}` });
    }
  }

  return send(405, { error: 'метод не поддерживается' });
});

server.listen(PORT, HOST, () => {
  log(`browsertool driver listening on http://${HOST}:${PORT} (channel=${BROWSER_CHANNEL})`);
  console.log(`browsertool driver listening on http://${HOST}:${PORT}`);
});

process.on('SIGTERM', async () => {
  try { await browser?.close(); } catch {}
  process.exit(0);
});
process.on('SIGINT', async () => {
  try { await browser?.close(); } catch {}
  process.exit(0);
});