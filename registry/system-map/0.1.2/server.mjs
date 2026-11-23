// system-map — локальный веб-сервер снимка (только 127.0.0.1).
// Статический UI + /api/state: collector.py с кэшем 2 с.
// Внешних npm-зависимостей нет, Node >= 18.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';

const args = process.argv.slice(2);
function opt(name, fallback) {
  const i = args.indexOf('--' + name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
}
const here = path.dirname(fileURLToPath(import.meta.url));
const port = Number(opt('port', '8765'));
const toolsRoot = opt('tools-root', path.resolve(here, '..', '..', '..', '..'));
const python = opt('python', process.env.PYTHON || 'python');
const stateDir = path.join(toolsRoot, 'system-map', 'state');
const webDir = path.join(here, 'web');

let cache = { at: 0, body: null };
let refreshing = false;
const pending = [];
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
};

function collect(cb) {
  const now = Date.now();
  if (cache.body && now - cache.at < 2000) return cb(null, cache.body);
  const pyArgs = [
    path.join(here, 'collector.py'),
    '--json', '--tools-root', toolsRoot, '--state-dir', stateDir,
  ];
  execFile(python, pyArgs, { maxBuffer: 12 * 1024 * 1024, timeout: 25000 }, (err, stdout, stderr) => {
    if (err && !stdout) return cb(err || new Error(stderr || 'collector failed'));
    try {
      const parsed = JSON.parse(stdout);
      cache = { at: Date.now(), body: JSON.stringify(parsed) };
      cb(null, cache.body);
    } catch (e) {
      cb(e);
    }
  });
}

function refresh(cb) {
  // Параллельные запросы не должны получать пустое тело: ждём общий сбор.
  if (refreshing) { if (cb) pending.push(cb); return; }
  refreshing = true;
  collect((err, body) => {
    refreshing = false;
    const waiters = pending.splice(0);
    if (cb) cb(err, body);
    waiters.forEach((w) => w(err, body));
  });
}

function sendState(res, force) {
  if (force) cache = { at: 0, body: null };
  if (cache.body) {
    // Stale-while-revalidate: UI получает ответ сразу, свежий сбор идёт в фоне.
    res.writeHead(200, { 'Content-Type': MIME['.json'], 'Cache-Control': 'no-store' });
    res.end(cache.body);
    if (Date.now() - cache.at >= 2000 || force) refresh();
    return;
  }
  refresh((err, body) => {
    if (err) {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Ошибка сбора: ' + String(err.message || err));
      return;
    }
    res.writeHead(200, { 'Content-Type': MIME['.json'], 'Cache-Control': 'no-store' });
    res.end(body);
  });
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname === '/api/state' || url.pathname === '/api/refresh') {
    sendState(res, url.pathname === '/api/refresh');
    return;
  }
  if (url.pathname === '/api/health') {
    res.writeHead(200, { 'Content-Type': MIME['.json'] });
    res.end(JSON.stringify({ ok: true, port, toolsRoot, cached: !!cache.body, cacheAgeMs: Date.now() - cache.at }));
    return;
  }
  const rel = url.pathname === '/' ? 'index.html' : decodeURIComponent(url.pathname).replace(/^\/+/, '');
  const file = path.resolve(webDir, rel);
  if (!file.startsWith(webDir)) {
    res.writeHead(403); res.end('forbidden'); return;
  }
  fs.readFile(file, (err, data) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('не найдено: ' + rel);
      return;
    }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
    res.end(data);
  });
});

server.listen(port, '127.0.0.1', () => {
  console.log('system-map: http://127.0.0.1:' + port + '  (tools=' + toolsRoot + ')');
});
server.on('error', (e) => {
  console.error('system-map: ошибка сервера ' + e.message);
  process.exitCode = 1;
});
