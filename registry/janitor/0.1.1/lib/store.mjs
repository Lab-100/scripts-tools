// lib/store.mjs — хранилище чистильщика: SQLite (WAL) либо JSON-фолбэк.
//
// Движок выбирается автоматически:
//   * Node 22.5+  — встроенный модуль node:sqlite (таблицы counters, whitelist,
//     edges, meta; журнал действий отдельным append-only JSONL);
//   * Node 18–22  — чисто-Javascript хранилище с ТЕМ ЖЕ набором методов.
//     Состояние пишется в <dbPath>.json атомарно (временный файл + переименование).
// Формат данных и модель веса обращения одинаковы для обоих движков:
//   w = hits * decay^(дней с lastSeen); события старше windowDays отбрасываются.
// Иммунитет: w >= theta И lastSeen в окне И есть входящее ребро.
// Иммунитет только повышает вердикт до `keep`.

import fs from 'node:fs';
import path from 'node:path';

// Подавляем экспериментальное предупреждение node:sqlite, чтобы оно не
// попадало в табличный вывод. Фильтр ставится ДО импорта модуля.
const _origEmitWarning = process.emitWarning.bind(process);
process.emitWarning = (warning, ...args) => {
  const text = typeof warning === 'string' ? warning : (warning && warning.message) || '';
  if (String(text).includes('SQLite')) return;
  return _origEmitWarning(warning, ...args);
};

// Динамический импорт: на Node < 22.5 модуль отсутствует и выбрасывает
// ERR_UNKNOWN_BUILTIN_MODULE. Это НЕ ошибка — включается фолбэк.
let DatabaseSync = null;
try {
  ({ DatabaseSync } = await import('node:sqlite'));
} catch {
  DatabaseSync = null;
}

const DAY_MS = 86400000;

function iso(d) { return new Date(d).toISOString(); }
function edgeKey(src, dst) { return src + '\u0000' + dst; }

// --------------------------------------------------------------------------
// Адаптер SQLite (Node 22.5+). Поведение идентично хранилищу 0.1.0.
// --------------------------------------------------------------------------
function createSqliteAdapter(dbPath) {
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const db = new DatabaseSync(dbPath);
  db.exec('PRAGMA journal_mode = WAL');
  db.exec(`CREATE TABLE IF NOT EXISTS counters (
    path TEXT PRIMARY KEY, hits REAL NOT NULL DEFAULT 0,
    firstSeen TEXT, lastSeen TEXT)`);
  db.exec(`CREATE TABLE IF NOT EXISTS whitelist (
    path TEXT PRIMARY KEY, reason TEXT, addedAt TEXT, w REAL NOT NULL DEFAULT 0)`);
  db.exec(`CREATE TABLE IF NOT EXISTS edges (
    src TEXT NOT NULL, dst TEXT NOT NULL, PRIMARY KEY (src, dst))`);
  db.exec(`CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY, value TEXT)`);
  db.exec('CREATE INDEX IF NOT EXISTS idx_edges_dst ON edges(dst)');

  const stmts = {
    getCounter: db.prepare('SELECT path, hits, firstSeen, lastSeen FROM counters WHERE path = ?'),
    allCounters: db.prepare('SELECT path, hits, firstSeen, lastSeen FROM counters'),
    upsertCounter: db.prepare(`INSERT INTO counters (path, hits, firstSeen, lastSeen) VALUES (?, ?, ?, ?)
      ON CONFLICT(path) DO UPDATE SET hits = excluded.hits, lastSeen = excluded.lastSeen`),
    deleteCounter: db.prepare('DELETE FROM counters WHERE path = ?'),
    setWhitelist: db.prepare(`INSERT INTO whitelist (path, reason, addedAt, w) VALUES (?, ?, ?, ?)
      ON CONFLICT(path) DO UPDATE SET reason = excluded.reason, addedAt = excluded.addedAt, w = excluded.w`),
    getWhitelist: db.prepare('SELECT path, reason, addedAt, w FROM whitelist WHERE path = ?'),
    allWhitelist: db.prepare('SELECT path, reason, addedAt, w FROM whitelist'),
    deleteWhitelist: db.prepare('DELETE FROM whitelist WHERE path = ?'),
    hasIncoming: db.prepare('SELECT 1 AS x FROM edges WHERE dst = ? LIMIT 1'),
    addEdge: db.prepare('INSERT OR IGNORE INTO edges (src, dst) VALUES (?, ?)'),
    getMeta: db.prepare('SELECT value FROM meta WHERE key = ?'),
    setMeta: db.prepare('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value'),
  };

  return {
    raw: db,
    backend: 'sqlite',
    allCounters: () => stmts.allCounters.all(),
    getCounter: (p) => stmts.getCounter.get(p) || null,
    upsertCounter: (p, hits, first, last) => stmts.upsertCounter.run(p, hits, first, last),
    deleteCounter: (p) => stmts.deleteCounter.run(p),
    allWhitelist: () => stmts.allWhitelist.all(),
    getWhitelist: (p) => stmts.getWhitelist.get(p) || null,
    setWhitelist: (p, reason, addedAt, w) => stmts.setWhitelist.run(p, reason, addedAt, w),
    deleteWhitelist: (p) => stmts.deleteWhitelist.run(p),
    hasIncoming: (p) => !!stmts.hasIncoming.get(p),
    addEdge: (src, dst) => stmts.addEdge.run(src, dst).changes > 0,
    getMeta: (k) => { const r = stmts.getMeta.get(k); return r ? r.value : null; },
    setMeta: (k, v) => stmts.setMeta.run(k, String(v)),
    batch: (fn) => fn(),
    vacuum: () => {
      try { db.exec('PRAGMA wal_checkpoint(TRUNCATE)'); db.exec('VACUUM'); return 'ok'; }
      catch (e) { return 'skip: ' + e.message; }
    },
    close: () => { try { db.close(); } catch { /* ignore */ } },
  };
}

// --------------------------------------------------------------------------
// Адаптер JSON (Node 18–22, нет node:sqlite). Методы и семантика те же.
// --------------------------------------------------------------------------
function createJsonAdapter(dbPath) {
  const file = dbPath + '.json';
  fs.mkdirSync(path.dirname(file), { recursive: true });

  const counters = new Map();   // path -> { path, hits, firstSeen, lastSeen }
  const whitelist = new Map();  // path -> { path, reason, addedAt, w }
  const edges = new Map();      // edgeKey -> { src, dst }
  const incoming = new Set();   // dst -> есть ли входящее ребро
  const meta = new Map();       // key -> строковое значение

  try {
    const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
    for (const r of saved.counters || []) if (r && r.path != null) counters.set(r.path, r);
    for (const r of saved.whitelist || []) if (r && r.path != null) whitelist.set(r.path, r);
    for (const r of saved.edges || []) {
      if (r && r.src != null && r.dst != null) {
        edges.set(edgeKey(r.src, r.dst), r);
        incoming.add(r.dst);
      }
    }
    for (const kv of saved.meta || []) if (Array.isArray(kv)) meta.set(String(kv[0]), String(kv[1]));
  } catch { /* нет файла или он повреждён — начинаем с чистого хранилища */ }

  let dirty = false;
  let batchDepth = 0;
  function touch() { dirty = true; }
  function save() {
    if (!dirty || batchDepth > 0) return;
    const out = {
      schema: 'janitor.store/1',
      backend: 'json',
      counters: [...counters.values()],
      whitelist: [...whitelist.values()],
      edges: [...edges.values()],
      meta: [...meta.entries()],
    };
    const tmp = file + '.tmp';
    try {
      fs.writeFileSync(tmp, JSON.stringify(out), 'utf8');
      fs.renameSync(tmp, file);
      dirty = false;
    } catch { /* хранилище не должно ронять проход */ }
  }

  return {
    raw: { backend: 'json', file },
    backend: 'json',
    allCounters: () => [...counters.values()],
    getCounter: (p) => counters.get(p) || null,
    upsertCounter: (p, hits, first, last) => {
      counters.set(p, { path: p, hits, firstSeen: first, lastSeen: last }); touch(); save();
    },
    deleteCounter: (p) => { const had = counters.delete(p); if (had) { touch(); save(); } return had; },
    allWhitelist: () => [...whitelist.values()],
    getWhitelist: (p) => whitelist.get(p) || null,
    setWhitelist: (p, reason, addedAt, w) => {
      whitelist.set(p, { path: p, reason, addedAt, w }); touch(); save();
    },
    deleteWhitelist: (p) => { const had = whitelist.delete(p); if (had) { touch(); save(); } return had; },
    hasIncoming: (p) => incoming.has(p),
    addEdge: (src, dst) => {
      const k = edgeKey(src, dst);
      if (edges.has(k)) return false;
      edges.set(k, { src, dst }); incoming.add(dst); touch(); save();
      return true;
    },
    getMeta: (k) => meta.has(k) ? meta.get(k) : null,
    setMeta: (k, v) => { meta.set(k, String(v)); touch(); save(); },
    batch: (fn) => { batchDepth++; try { return fn(); } finally { batchDepth--; save(); } },
    vacuum: () => 'skip: JSON-хранилище не требует VACUUM',
    close: () => { batchDepth = 0; save(); },
  };
}

// --------------------------------------------------------------------------
// Общая логика хранилища, не зависящая от движка.
// --------------------------------------------------------------------------
export function createStore({ dbPath, jsonlPath, decay = 0.9, windowDays = 30, theta = 10 }) {
  const a = DatabaseSync ? createSqliteAdapter(dbPath) : createJsonAdapter(dbPath);

  function getCounter(p) { return a.getCounter(p); }

  // Вес обращения с учётом затухания; 0, если событие вне окна.
  function weight(c, now) {
    if (!c || c.lastSeen == null) return 0;
    const days = (now - new Date(c.lastSeen).getTime()) / DAY_MS;
    if (days > windowDays) return 0;
    return c.hits * Math.pow(decay, days);
  }

  function setCounter(p, hits, firstSeen, lastSeen) {
    a.upsertCounter(p, hits, firstSeen, lastSeen);
  }

  // Добавляет n обращений к счётчику пути (с предварительным затуханием).
  function bumpHits(p, n = 1, now = Date.now()) {
    const c = getCounter(p);
    if (!c) {
      setCounter(p, n, iso(now), iso(now));
    } else {
      const w = weight(c, now) + n;
      setCounter(p, w, c.firstSeen || iso(now), iso(now));
    }
  }

  // Материализует затухание и отбрасывает события вне окна.
  function decayAll(now = Date.now()) {
    let decayed = 0;
    let dropped = 0;
    a.batch(() => {
      for (const c of a.allCounters()) {
        const days = c.lastSeen == null ? Infinity : (now - new Date(c.lastSeen).getTime()) / DAY_MS;
        if (!isFinite(days) || days > windowDays) {
          a.deleteCounter(c.path);
          dropped++;
          continue;
        }
        const hits = c.hits * Math.pow(decay, days);
        a.upsertCounter(c.path, hits, c.firstSeen, iso(now));
        if (days > 0) decayed++;
      }
    });
    return { decayed, dropped };
  }

  function hasIncomingEdge(p) { return a.hasIncoming(p); }

  function addEdge(src, dst) { return a.addEdge(src, dst); }

  // Иммунитет по обращениям. theta/windowDays/decay — из конфига.
  function isImmune(p, now = Date.now(), thetaArg = theta) {
    const c = getCounter(p);
    if (!c) return false;
    const w = weight(c, now);
    if (w < thetaArg) return false;
    if (now - new Date(c.lastSeen).getTime() > windowDays * DAY_MS) return false;
    return hasIncomingEdge(p);
  }

  function addToWhitelist(p, reason = 'manual', w = 0, now = Date.now()) {
    a.setWhitelist(p, reason, iso(now), w);
  }

  function isWhitelisted(p) { return !!a.getWhitelist(p); }

  // Убирает «замороженные» записи: просроченные счётчики и старые whitelist-метки.
  function pruneFrozen(now = Date.now()) {
    const cutoff = now - windowDays * DAY_MS;
    let counters = 0;
    let whitelist = 0;
    a.batch(() => {
      for (const c of a.allCounters()) {
        if (c.lastSeen == null || new Date(c.lastSeen).getTime() < cutoff) { a.deleteCounter(c.path); counters++; }
      }
      for (const w of a.allWhitelist()) {
        if (w.addedAt == null || new Date(w.addedAt).getTime() < cutoff) { a.deleteWhitelist(w.path); whitelist++; }
      }
    });
    return { counters, whitelist };
  }

  // Журнал действий (append-only JSONL, UTF-8).
  function logAction(record) {
    try {
      fs.appendFileSync(jsonlPath, JSON.stringify(record) + '\n', 'utf8');
    } catch { /* журнал не должен ронять проход */ }
  }

  // Топ путей по весу обращения.
  function topCounters(limit = 20, now = Date.now()) {
    const rows = a.allCounters().map((c) => ({ path: c.path, hits: c.hits, lastSeen: c.lastSeen, w: weight(c, now) }))
      .filter((r) => r.w > 0)
      .sort((a, b) => b.w - a.w);
    return rows.slice(0, limit);
  }

  function immuneCount(now = Date.now()) {
    let n = 0;
    for (const c of a.allCounters()) if (isImmune(c.path, now)) n++;
    return n;
  }

  function getMeta(key) { return a.getMeta(key); }
  function setMeta(key, value) { a.setMeta(key, String(value)); }

  // Компакция: затухание, очистка, обрезка WAL/VACUUM (только для SQLite).
  function compact(now = Date.now()) {
    const dec = decayAll(now);
    const pruned = pruneFrozen(now);
    return { ...dec, ...pruned, vacuum: a.vacuum() };
  }

  function close() { a.close(); }

  return {
    raw: a.raw,
    backend: a.backend,
    getCounter, setCounter, bumpHits, decayAll, weight,
    hasIncomingEdge, addEdge, isImmune,
    addToWhitelist, isWhitelisted, pruneFrozen,
    logAction, topCounters, immuneCount,
    getMeta, setMeta, compact, close,
  };
}
