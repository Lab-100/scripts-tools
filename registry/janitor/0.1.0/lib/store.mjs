// lib/store.mjs — хранилище чистильщика: SQLite (WAL) + журнал действий JSONL.
//
// Таблицы:
//   counters(path TEXT PRIMARY KEY, hits REAL, firstSeen, lastSeen)
//   whitelist(path TEXT PRIMARY KEY, reason, addedAt, w REAL)
//   edges(src TEXT, dst TEXT, PRIMARY KEY(src,dst))
//   meta(key TEXT PRIMARY KEY, value TEXT)   — служебные метки (последний прогон и т.п.)
//
// Модель веса обращения: w = hits * decay^(дней с lastSeen); события старше
// windowDays отбрасываются. Иммунитет: w ≥ theta И lastSeen в окне И есть
// входящее ребро. Иммунитет только повышает вердикт до `keep`.

import fs from 'node:fs';
import path from 'node:path';

// Подавляем единственное экспериментальное предупреждение node:sqlite,
// чтобы оно не попадало в табличный вывод. Ставим фильтр ДО импорта модуля.
const _origEmitWarning = process.emitWarning.bind(process);
process.emitWarning = (warning, ...args) => {
  const text = typeof warning === 'string' ? warning : (warning && warning.message) || '';
  if (String(text).includes('SQLite')) return;
  return _origEmitWarning(warning, ...args);
};

const { DatabaseSync } = await import('node:sqlite');

const DAY_MS = 86400000;

function iso(d) { return new Date(d).toISOString(); }

// Создаёт хранилище. Возвращает объект с методами; обязательно close().
export function createStore({ dbPath, jsonlPath, decay = 0.9, windowDays = 30, theta = 10 }) {
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
    deleteEdgesFrom: db.prepare('DELETE FROM edges WHERE src = ?'),
    allEdges: db.prepare('SELECT src, dst FROM edges'),
    getMeta: db.prepare('SELECT value FROM meta WHERE key = ?'),
    setMeta: db.prepare('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value'),
  };

  function getCounter(p) { return stmts.getCounter.get(p) || null; }

  // Вес обращения с учётом затухания; 0, если событие вне окна.
  function weight(c, now) {
    if (!c || c.lastSeen == null) return 0;
    const days = (now - new Date(c.lastSeen).getTime()) / DAY_MS;
    if (days > windowDays) return 0;
    return c.hits * Math.pow(decay, days);
  }

  function setCounter(p, hits, firstSeen, lastSeen) {
    stmts.upsertCounter.run(p, hits, firstSeen, lastSeen);
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
    for (const c of stmts.allCounters.all()) {
      const days = c.lastSeen == null ? Infinity : (now - new Date(c.lastSeen).getTime()) / DAY_MS;
      if (!isFinite(days) || days > windowDays) {
        stmts.deleteCounter.run(c.path);
        dropped++;
        continue;
      }
      const hits = c.hits * Math.pow(decay, days);
      stmts.upsertCounter.run(c.path, hits, c.firstSeen, iso(now));
      if (days > 0) decayed++;
    }
    return { decayed, dropped };
  }

  function hasIncomingEdge(p) { return !!stmts.hasIncoming.get(p); }

  function addEdge(src, dst) {
    const r = stmts.addEdge.run(src, dst);
    return r.changes > 0;
  }

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
    stmts.setWhitelist.run(p, reason, iso(now), w);
  }

  function isWhitelisted(p) { return !!stmts.getWhitelist.get(p); }

  // Убирает «замороженные» записи: просроченные счётчики и старые whitelist-метки.
  function pruneFrozen(now = Date.now()) {
    const cutoff = now - windowDays * DAY_MS;
    let counters = 0;
    for (const c of stmts.allCounters.all()) {
      if (c.lastSeen == null || new Date(c.lastSeen).getTime() < cutoff) { stmts.deleteCounter.run(c.path); counters++; }
    }
    let whitelist = 0;
    for (const w of stmts.allWhitelist.all()) {
      if (w.addedAt == null || new Date(w.addedAt).getTime() < cutoff) { stmts.deleteWhitelist.run(w.path); whitelist++; }
    }
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
    const rows = stmts.allCounters.all().map((c) => ({ path: c.path, hits: c.hits, lastSeen: c.lastSeen, w: weight(c, now) }))
      .filter((r) => r.w > 0)
      .sort((a, b) => b.w - a.w);
    return rows.slice(0, limit);
  }

  function immuneCount(now = Date.now()) {
    let n = 0;
    for (const c of stmts.allCounters.all()) if (isImmune(c.path, now)) n++;
    return n;
  }

  function getMeta(key) { const r = stmts.getMeta.get(key); return r ? r.value : null; }
  function setMeta(key, value) { stmts.setMeta.run(key, String(value)); }

  // Компакция: затухание, очистка, обрезка WAL, VACUUM.
  function compact(now = Date.now()) {
    const dec = decayAll(now);
    const pruned = pruneFrozen(now);
    let vacuum = 'ok';
    try { db.exec('PRAGMA wal_checkpoint(TRUNCATE)'); db.exec('VACUUM'); } catch (e) { vacuum = 'skip: ' + e.message; }
    return { ...dec, ...pruned, vacuum };
  }

  function close() { try { db.close(); } catch { /* ignore */ } }

  return {
    raw: db,
    getCounter, setCounter, bumpHits, decayAll, weight,
    hasIncomingEdge, addEdge, isImmune,
    addToWhitelist, isWhitelisted, pruneFrozen,
    logAction, topCounters, immuneCount,
    getMeta, setMeta, compact, close,
  };
}
