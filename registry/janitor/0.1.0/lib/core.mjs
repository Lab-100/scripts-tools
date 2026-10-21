// lib/core.mjs — чистые функции классификации для чистильщика (janitor).
//
// ВАЖНО: в этом модуле НЕТ удалений и перемещений файлов. Только чтение,
// сопоставление масок и вычисление вердикта. Модель решения:
//   keep      — не трогать;
//   candidate — можно переместить в карантин (при явном флаге и после всех гвардов);
//   delete    — физически снести из карантина по сроку (обрабатывается purge).
//
// Вердикт `candidate` выдаётся только если ВСЕ гварды пройдены. Любой «нет» → keep.

import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { spawnSync } from 'node:child_process';

// Порог возраста по умолчанию (сутки), если правило не задаёт keepDays/minAgeMin.
export const DEFAULT_KEEP_DAYS = 7;
const DAY_MS = 86400000;
const MIN_MS = 60000;

// ---------------------------------------------------------------------------
// Пути и маски
// ---------------------------------------------------------------------------

// Приводим путь к единому виду: абсолютный, со слэшами «/».
export function normalizePath(p) {
  return path.resolve(p).replace(/\\/g, '/');
}

// Раскрытие переменных окружения в пути: %VAR%, ${VAR}, $VAR.
// Неизвестная переменная остаётся как есть (нет молчаливой подстановки пустоты) —
// так опечатка в конфиге видна сразу, а не превращается в пустой путь.
// Нужен для переносимых конфигов: вместо C:\Users\<имя>\... можно написать %USERPROFILE%\...
export function expandEnv(p) {
  if (typeof p !== 'string' || !p) return p;
  return p
    .replace(/%([^%]+)%/g, (m, name) => (name in process.env ? process.env[name] : m))
    .replace(/\$\{([^}]+)\}/g, (m, name) => (name in process.env ? process.env[name] : m))
    .replace(/\$([A-Za-z_][A-Za-z0-9_]*)/g, (m, name) => (name in process.env ? process.env[name] : m));
}

// Перевод glob-маски в регулярное выражение.
// Поддерживаются `**`, `*`, `?`. Неякорная маска (не начинается с `/` или `**`)
// автоматически получает префикс `**/`, то есть ищется на любой глубине.
export function globToRegExp(glob) {
  let g = String(glob).replace(/\\/g, '/');
  if (!g.startsWith('/') && !g.startsWith('**')) g = '**/' + g;
  let re = '';
  for (let i = 0; i < g.length; i++) {
    const c = g[i];
    if (c === '*') {
      if (g[i + 1] === '*') {
        if (g[i + 2] === '/') { re += '(?:.*/)?'; i += 2; } // `**/` — ноль или более каталогов
        else { re += '.*'; i += 1; }                        // `**`  — что угодно, включая «/»
      } else {
        re += '[^/]*';                                      // `*`   — в пределах одного сегмента
      }
    } else if (c === '?') {
      re += '[^/]';
    } else if ('\\^$.|+()[]{}'.includes(c)) {
      re += '\\' + c;
    } else {
      re += c;
    }
  }
  // Флаг `i`: на Windows файловые системы регистронезависимы.
  return new RegExp('^' + re + '$', 'i');
}

const _globCache = new Map();

// Возвращает первую маску из списка, которая совпала с путём, иначе null.
// Возврат строки (а не boolean) удобен для протокола объяснений.
export function matchesAny(globs, p) {
  const target = normalizePath(p);
  for (const glob of globs || []) {
    let rx = _globCache.get(glob);
    if (!rx) { rx = globToRegExp(glob); _globCache.set(glob, rx); }
    if (rx.test(target)) return glob;
  }
  return null;
}

// Первое правило, чья mask-маска совпала с путём (или null).
export function findRule(rules, p) {
  for (const r of rules || []) {
    if (r && r.glob && matchesAny([r.glob], p)) return r;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Владелец файла: PID из имени или из содержимого lock-файла
// ---------------------------------------------------------------------------

// Ищем в имени файла числовую группу 2..7 цифр, берём последнюю как вероятный PID.
// 2..7 отсекает 8-значные даты (например 20261013).
export function readPidFromName(name) {
  const base = path.basename(String(name));
  const re = /(^|[^0-9])(\d{2,7})(?=[^0-9]|$)/g;
  let m;
  let last = null;
  while ((m = re.exec(base)) !== null) last = m[2];
  if (last === null) return null;
  const n = Number(last);
  return Number.isInteger(n) && n > 0 ? n : null;
}

// PID из содержимого lock-файла: JSON-поле pid, строка `pid: N` либо одинокое число.
export function readPidFromLock(filePath) {
  let txt;
  try { txt = fs.readFileSync(filePath, 'utf8'); } catch { return null; }
  try {
    const j = JSON.parse(txt);
    if (j && typeof j === 'object') {
      for (const k of ['pid', 'PID', 'Pid']) {
        if (j[k] != null) {
          const n = Number(j[k]);
          if (Number.isInteger(n) && n > 0) return n;
        }
      }
    }
  } catch { /* не JSON — разбираем как текст */ }
  let m = txt.match(/\bpid\b\s*[:=]?\s*(\d{2,7})/i);
  if (m) return Number(m[1]);
  m = txt.match(/^\s*(\d{2,7})\s*$/m);
  if (m) return Number(m[1]);
  return null;
}

// Жив ли процесс: true — существует, false — нет, null — неизвестно.
// EPERM означает, что процесс существует (нет прав на сигнал) → жив.
export function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return null;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    if (e && e.code === 'EPERM') return true;
    if (e && e.code === 'ESRCH') return false;
    return true; // неизвестная ошибка → консервативно считаем живым
  }
}

// Занят ли файл: пробуем эксклюзивно открыть на чтение-запись.
// Любая ошибка открытия (EBUSY/EPERM/EACCES/ENOENT/…) трактуется как «занят».
export function fileBusy(filePath) {
  let fd = null;
  try {
    fd = fs.openSync(filePath, 'r+');
    return false;
  } catch {
    return true;
  } finally {
    if (fd !== null) { try { fs.closeSync(fd); } catch { /* ignore */ } }
  }
}

// ---------------------------------------------------------------------------
// Git: отслеживается ли файл (результаты кешируются по каталогу/файлу)
// ---------------------------------------------------------------------------

const _gitRootCache = new Map();      // каталог → корень репозитория | null
const _gitTrackedSetCache = new Map(); // корень → Set(относительных путей в нижнем регистре)
const _gitTrackedCache = new Map();    // файл → { tracked, repo, reason }

// Корень репозитория ищем по наличию `.git` вверх по дереву (без запуска git).
// Это дешевле, чем запускать процесс git на каждый каталог.
function findGitRoot(dir) {
  const key = path.resolve(dir);
  if (_gitRootCache.has(key)) return _gitRootCache.get(key);
  let cur = key;
  let root = null;
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try { if (fs.existsSync(path.join(cur, '.git'))) { root = cur.replace(/\\/g, '/'); break; } } catch { /* ignore */ }
    const parent = path.dirname(cur);
    if (parent === cur) break;
    cur = parent;
  }
  _gitRootCache.set(key, root);
  return root;
}

// Множество отслеживаемых git файлов репозитория (один вызов `git ls-files` на репозиторий).
// Возвращает { set, failed, reason }: failed=true при исключении spawnSync, либо r.error
// (git не запустился), либо r.status!==0, либо stdout не строка; reason — деталь.
function loadTrackedSet(root, gitBin) {
  if (_gitTrackedSetCache.has(root)) return _gitTrackedSetCache.get(root);
  const set = new Set();
  try {
    const r = spawnSync(gitBin, ['-C', root, 'ls-files', '-z'], {
      encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, windowsHide: true,
    });
    if (r.status === 0 && typeof r.stdout === 'string') {
      for (const p of r.stdout.split('\0')) {
        if (p) set.add(p.replace(/\\/g, '/').toLowerCase());
      }
    } else {
      _gitTrackedSetCache.set(root, { set, failed: true, reason: r.error ? r.error.message : `git вернул статус ${r.status}` });
      return _gitTrackedSetCache.get(root);
    }
  } catch (e) {
    _gitTrackedSetCache.set(root, { set, failed: true, reason: e.message });
    return _gitTrackedSetCache.get(root);
  }
  _gitTrackedSetCache.set(root, { set, failed: false, reason: null });
  return _gitTrackedSetCache.get(root);
}

// Отслеживается ли файл в git. Git вызывается массивом аргументов (без shell-строк),
// поэтому пробелы и кириллица в путях безопасны. Результат кешируется по файлу.
export function gitTracked(filePath, opts = {}) {
  const gitBin = opts.gitBin || 'git';
  if (opts.disabled) return { tracked: false, repo: null, reason: 'git отключён' };
  const abs = path.resolve(filePath);
  if (_gitTrackedCache.has(abs)) return _gitTrackedCache.get(abs);

  const root = findGitRoot(path.dirname(abs));
  let res;
  if (!root) {
    res = { tracked: false, repo: null, reason: 'не git-репозиторий' };
  } else {
    const rel = path.relative(root, abs).replace(/\\/g, '/').toLowerCase();
    if (rel.startsWith('..')) {
      res = { tracked: false, repo: root, reason: 'вне репозитория' };
    } else {
      const loaded = loadTrackedSet(root, gitBin);
      if (loaded.failed) {
        res = { tracked: true, repo: root, reason: 'git недоступен — считаем отслеживаемым (fail-closed): ' + loaded.reason };
      } else {
        const tracked = loaded.set.has(rel);
        res = { tracked, repo: root, reason: tracked ? 'отслеживается git' : 'не отслеживается git' };
      }
    }
  }
  _gitTrackedCache.set(abs, res);
  return res;
}

// Сброс git-кешей. Кеш устаревает в --watch, сбрасывается в начале каждого прохода.
export function resetGitCaches() {
  _gitRootCache.clear();
  _gitTrackedSetCache.clear();
  _gitTrackedCache.clear();
}

// ---------------------------------------------------------------------------
// Порты: занят ли локальный порт (сервис-владелец жив)
// ---------------------------------------------------------------------------

// Возвращает true, если на 127.0.0.1:port кто-то слушает (сервис жив → keep).
export function portBusy(port) {
  if (!port) return Promise.resolve(false);
  return new Promise((resolve) => {
    const sock = net.connect({ host: '127.0.0.1', port, timeout: 400 });
    let done = false;
    const finish = (v) => { if (done) return; done = true; try { sock.destroy(); } catch { /* ignore */ } resolve(v); };
    sock.on('connect', () => finish(true));
    sock.on('timeout', () => finish(false));
    sock.on('error', () => finish(false));
  });
}

// ---------------------------------------------------------------------------
// Обход файлов
// ---------------------------------------------------------------------------

function* walkDir(dir, skip) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isSymbolicLink()) continue; // не ходим по ссылкам (защита от циклов)
    if (e.isDirectory()) {
      if (skip.has(e.name.toLowerCase())) continue;
      yield* walkDir(full, skip);
    } else if (e.isFile()) {
      yield full;
    }
  }
}

// Синхронный генератор файлов по корням. Пропускает служебные каталоги
// (node_modules/.git/secrets/janitor по умолчанию) и символьные ссылки.
export function* walkFiles(roots, opts = {}) {
  const skip = new Set((opts.skipDirs || ['node_modules', '.git', 'secrets']).map((s) => String(s).toLowerCase()));
  for (const root of roots || []) {
    const abs = path.resolve(root);
    let st;
    try { st = fs.statSync(abs); } catch { continue; }
    if (st.isFile()) { yield abs; continue; }
    if (st.isDirectory()) yield* walkDir(abs, skip);
  }
}

// ---------------------------------------------------------------------------
// Классификация
// ---------------------------------------------------------------------------

// Порог возраста в мс по правилу.
export function ageThresholdMs(rule) {
  if (rule && rule.keepDays != null) return Number(rule.keepDays) * DAY_MS;
  if (rule && rule.minAgeMin != null) return Number(rule.minAgeMin) * MIN_MS;
  return DEFAULT_KEEP_DAYS * DAY_MS;
}

// «Оригинал» для файла резервной копии: часть имени до `.bak`.
function originalPath(abs) {
  const i = abs.lastIndexOf('.bak');
  return i >= 0 ? abs.slice(0, i) : null;
}

// Главная функция. ctx содержит зависимости:
//   now, config, rules[], protect[], ports{}, gitTracked(p), fileBusy(p), isImmune(p)
// Возвращает { verdict, ruleId, reasons: [{ step, pass, detail }] }.
export function classify(filePath, stat, ctx) {
  const now = ctx.now != null ? ctx.now : Date.now();
  const reasons = [];
  const push = (step, pass, detail) => reasons.push({ step, pass, detail });
  const abs = path.resolve(filePath);
  const out = (verdict, ruleId) => ({ verdict, ruleId: ruleId || null, reasons });

  // Гвард 1: защитный список (deny-доминирование — сильнее любого правила).
  const protHit = matchesAny(ctx.protect || [], abs);
  push(1, !protHit, protHit ? `в защитном списке (маска: ${protHit})` : 'нет в защитном списке');
  if (protHit) return out('keep');

  // Гвард 2: не должен отслеживаться git.
  const g = ctx.gitTracked ? ctx.gitTracked(abs) : { tracked: false, reason: 'git не подключён' };
  push(2, !g.tracked, g.tracked ? `отслеживается git (${g.repo})` : (g.reason || 'не отслеживается git'));
  if (g.tracked) return out('keep');

  // Гвард 3: должно сработать известное правило. Неизвестное — не удаляем.
  const rule = findRule(ctx.rules, abs);
  push(3, !!rule, rule ? `сработало правило «${rule.id}» (${rule.kind})` : 'нет подходящего правила — не удаляем');
  if (!rule) return out('keep');
  const ruleId = rule.id;

  // Гвард 4: владелец мёртв (если правило требует признак владельца).
  if (rule.requireDeadPid) {
    let pid = readPidFromName(abs);
    if (pid == null) pid = readPidFromLock(abs);
    if (pid == null) {
      push(4, false, 'владелец не определён (PID не найден) — не удаляем');
      return out('keep', ruleId);
    }
    const alive = pidAlive(pid);
    if (alive !== false) {
      push(4, false, `владелец жив (PID ${pid})`);
      return out('keep', ruleId);
    }
    push(4, true, `владелец мёртв (PID ${pid})`);
  } else {
    push(4, true, 'признак владельца не требуется');
  }

  // Гвард 5: файл не занят.
  const busy = ctx.fileBusy ? ctx.fileBusy(abs) : fileBusy(abs);
  push(5, !busy, busy ? 'файл занят или недоступен' : 'файл свободен');
  if (busy) return out('keep', ruleId);

  // Гвард 6: возраст старше порога правила (+ порог размера, если задан rotateAtMb).
  const ageMs = now - (stat && stat.mtimeMs != null ? stat.mtimeMs : now);
  const thr = ageThresholdMs(rule);
  let passAge = ageMs > thr;
  let detailAge = `возраст ${(ageMs / DAY_MS).toFixed(2)} сут ${passAge ? '>' : '<='} порога ${(thr / DAY_MS).toFixed(2)} сут`;
  if (rule.rotateAtMb != null) {
    const sizeMb = ((stat && stat.size) || 0) / (1024 * 1024);
    const passSize = sizeMb > Number(rule.rotateAtMb);
    detailAge += `; размер ${sizeMb.toFixed(2)} МБ ${passSize ? '>' : '<='} порога ротации ${rule.rotateAtMb} МБ`;
    passAge = passAge && passSize;
  }
  push(6, passAge, detailAge);
  if (!passAge) return out('keep', ruleId);

  // Гвард 7: нет иммунитета по обращениям.
  const immune = ctx.isImmune ? ctx.isImmune(abs) : false;
  push(7, !immune, immune ? 'в иммунитете по обращениям (w ≥ theta и есть входящее ребро)' : 'нет иммунитета по обращениям');
  if (immune) return out('keep', ruleId);

  // Гвард 8: сервис-владелец не держит порт.
  if (rule.servicePort != null) {
    const pb = !!(ctx.ports && ctx.ports[rule.servicePort]);
    push(8, !pb, pb ? `порт ${rule.servicePort} занят — сервис жив` : `порт ${rule.servicePort} свободен`);
    if (pb) return out('keep', ruleId);
  } else {
    push(8, true, 'порт сервиса не задан');
  }

  // Дополнительный гвард (для правил с requireOriginal): оригинал должен существовать.
  if (rule.requireOriginal) {
    const orig = originalPath(abs);
    const exists = !!(orig && fs.existsSync(orig));
    push('original', exists, exists ? `оригинал на месте: ${path.basename(orig)}` : 'оригинал не найден — не удаляем');
    if (!exists) return out('keep', ruleId);
  }

  return out('candidate', ruleId);
}
