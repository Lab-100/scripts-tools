#!/usr/bin/env node
// janitor.mjs — «чистильщик мусора» opencode. Версия 0.1.0.
//
// Безопасен по построению: по умолчанию — СУХОЙ ПРОГОН (dryRun=true),
// ничего не удаляется и не перемещается. Реальное действие — только с флагом
// `--yes` (и только через карантин, после прохождения ВСЕХ гвардов) И при
// "dryRun": false в config.json.
//
// Команды: scan | clean | purge | restore <id|path> | status | explain <path> |
//          compact | --watch [--interval-min N]
// Флаги:   --dry-run, --yes, --watch, --interval-min N, --all, --json
//
// --json: каждая команда печатает результат ОДНОЙ строкой JSON в stdout
// ({"ok":true,"command":"...","data":{...}} либо {"ok":false,"command":"...","error":"..."}),
// человекочитаемый вывод при этом полностью подавляется. Режим нужен для
// машинных потребителей (MCP-сервер janitor).

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as core from './lib/core.mjs';
import { createStore } from './lib/store.mjs';
import { buildGraph, startEtw } from './lib/refs.mjs';

const VERSION = '0.1.0';
const DIR = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = path.join(DIR, 'config.json');
const RULES_PATH = path.join(DIR, 'rules.json');
const DB_PATH = path.join(DIR, 'refs.db');
const JSONL_PATH = path.join(DIR, 'actions.jsonl');
const QUAR_DIR = path.join(DIR, 'quarantine');
const LOCK_PATH = path.join(DIR, 'janitor.lock');
function loadJson(p) { return JSON.parse(fs.readFileSync(p, 'utf8')); }

// Единый выключатель реального действия: боевой режим — только при явном --yes (confirm:true),
// флаге --dry-run и "dryRun": false в config.json. config.dryRun=true запрещает действие всегда.
function isReal(args, config) { return !!args.yes && !args.dryRun && config.dryRun !== true; }

// ---------------------------------------------------------------------------
// Корни сканирования
// ---------------------------------------------------------------------------

// Каталог конфигурации opencode — тот, где лежит janitor/ (janitor/ -> ../).
const CONFIG_DIR = path.resolve(DIR, '..');

// Корни по умолчанию — используются, если в config.json массив roots пуст
// или отсутствует:
//   1) каталог конфигурации opencode;
//   2) рабочий каталог opencode во временной папке (TEMP/TMP, иначе
//      %USERPROFILE%\AppData\Local\Temp).
// Захардкоженных персональных путей нет: всё выводится из окружения и из
// расположения самого файла, поэтому конфигурация переносима между машинами.
function defaultRoots() {
  const roots = [CONFIG_DIR];
  const tempBase = process.env.TEMP || process.env.TMP
    || (process.env.USERPROFILE ? path.join(process.env.USERPROFILE, 'AppData', 'Local', 'Temp') : null);
  if (tempBase) roots.push(path.join(tempBase, 'opencode'));
  return roots;
}

// Приоритет: непустой roots из конфига → иначе корни по умолчанию.
// Элементы конфига раскрывают переменные окружения (%VAR%, ${VAR}, $VAR);
// относительные пути отсчитываются от каталога конфигурации (не от cwd —
// MCP-сервер запускает CLI без задания рабочего каталога).
function resolveRoots(raw) {
  const list = Array.isArray(raw) ? raw.filter((r) => typeof r === 'string' && r.trim()) : [];
  if (!list.length) return defaultRoots();
  return list.map((r) => {
    const expanded = core.expandEnv(r.trim());
    return path.isAbsolute(expanded) ? expanded : path.resolve(CONFIG_DIR, expanded);
  });
}

const config = loadJson(CONFIG_PATH);
// Корни сканирования: явный список из конфига либо вычисленные по умолчанию.
config.roots = resolveRoots(config.roots);
const rulesDoc = loadJson(RULES_PATH);
const rules = rulesDoc.rules || [];
// Каталоги, в которые не заходим вовсе. node_modules/.git/secrets — обязательный
// минимум; остальное — каталоги зависимостей/кешей (в них нет наших правил).
const skipDirs = ['node_modules', '.git', 'secrets', 'janitor', '.venv', 'venv', '__pycache__', 'site-packages'];

// ---------------------------------------------------------------------------
// Вспомогательное
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = { _: [], yes: false, dryRun: false, watch: false, all: false, intervalMin: null, json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--yes') args.yes = true;
    else if (a === '--dry-run') args.dryRun = true;
    else if (a === '--watch') args.watch = true;
    else if (a === '--all') args.all = true;
    else if (a === '--json') args.json = true;
    else if (a === '--interval-min') args.intervalMin = Number(argv[++i]);
    else if (a.startsWith('--interval-min=')) args.intervalMin = Number(a.split('=')[1]);
    else args._.push(a);
  }
  return args;
}

// Единая точка машинного вывода: одна строка JSON в stdout, человекочитаемый
// текст при --json не печатается вообще, а ошибки уходят в stdout (не stderr),
// чтобы потребитель (MCP-сервер janitor) парсил один поток.
function emitJson(command, data) {
  process.stdout.write(JSON.stringify({ ok: true, command, data }) + '\n');
}

function emitJsonError(command, error, code = 1) {
  process.stdout.write(JSON.stringify({ ok: false, command, error: String(error) }) + '\n');
  process.exitCode = code;
}

function findRoot(p) {
  const abs = core.normalizePath(p).toLowerCase();
  let best = null;
  for (const r of config.roots || []) {
    const rn = core.normalizePath(r).toLowerCase();
    if (abs === rn || abs.startsWith(rn + '/')) { if (!best || rn.length > best.length) best = core.normalizePath(r); }
  }
  return best;
}

function relDisplay(p) {
  const root = findRoot(p);
  if (root) { const rel = path.relative(root, p); if (!rel.startsWith('..')) return rel.replace(/\\/g, '/'); }
  return core.normalizePath(p);
}

// Короткая причина, по которой вынесен вердикт.
function shortReason(result) {
  if (result.verdict === 'candidate') return 'прошёл все гварды';
  const fails = result.reasons.filter((r) => r.pass === false);
  return fails.length ? fails[fails.length - 1].detail : 'оставлен';
}

function openStore() {
  return createStore({ dbPath: DB_PATH, jsonlPath: JSONL_PATH, decay: config.decay, windowDays: config.windowDays, theta: config.theta });
}

async function precomputePorts() {
  const ports = {};
  for (const r of rules) {
    if (r.servicePort != null && !(r.servicePort in ports)) ports[r.servicePort] = await core.portBusy(r.servicePort);
  }
  return ports;
}

function makeCtx(store, ports = {}) {
  return {
    now: Date.now(),
    config,
    rules,
    protect: config.protect || [],
    gitTracked: (p) => core.gitTracked(p, { disabled: config.git === false }),
    fileBusy: (p) => core.fileBusy(p),
    isImmune: (p) => store.isImmune(p, Date.now()),
    ports,
  };
}

// Полный прогон сканирования. Ничего не меняет на диске пользователя
// (трогает только собственный индекс refs.db).
async function runScan(store) {
  core.resetGitCaches(); // кеш устаревает в --watch, сбрасывается в начале каждого прохода
  store.decayAll(Date.now());
  const refsStats = buildGraph({ roots: config.roots, store, skipDirs });
  const ports = await precomputePorts();
  const ctx = makeCtx(store, ports);
  const decisions = [];
  for (const file of core.walkFiles(config.roots, { skipDirs })) {
    let stat = null;
    try { stat = fs.statSync(file); } catch { /* нет доступа — ниже */ }
    let result;
    try {
      if (!stat) throw new Error('stat недоступен');
      result = core.classify(file, stat, ctx);
    } catch (e) {
      result = { verdict: 'keep', ruleId: null, reasons: [{ step: 0, pass: false, detail: 'ошибка обработки: ' + e.message }] };
    }
    decisions.push({ path: file, bytes: stat ? stat.size : 0, mtimeMs: stat ? stat.mtimeMs : 0, result });
  }
  return { decisions, refsStats };
}

function summarize(decisions) {
  let keep = 0, keepBytes = 0, cand = 0, candBytes = 0;
  for (const d of decisions) {
    if (d.result.verdict === 'candidate') { cand++; candBytes += d.bytes; }
    else { keep++; keepBytes += d.bytes; }
  }
  return { keep, keepBytes, cand, candBytes, total: decisions.length };
}

function sumBytes(items) { return items.reduce((a, d) => a + (d.bytes || 0), 0); }

// Компактное представление решения для машинного вывода (--json).
function briefDecision(d) {
  return { path: d.path, verdict: d.result.verdict, ruleId: d.result.ruleId || null, reason: shortReason(d.result), bytes: d.bytes };
}

function human(bytes) {
  const u = ['Б', 'КБ', 'МБ', 'ГБ'];
  let i = 0, v = bytes;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(i === 0 ? 0 : 2)} ${u[i]}`;
}

function printTable(rows) {
  const cols = ['ВЕРДИКТ', 'ПРАВИЛО', 'ПРИЧИНА', 'ПУТЬ'];
  const widths = [9, 17, 52, 0];
  const line = (vals) => vals.map((v, i) => (i === 3 ? String(v) : String(v).padEnd(widths[i]))).join(' ');
  process.stdout.write(line(cols) + '\n');
  process.stdout.write(widths.map((w, i) => (i === 3 ? '─'.repeat(30) : '─'.repeat(w))).join(' ') + '\n');
  for (const r of rows) process.stdout.write(line(r) + '\n');
}

// ---------------------------------------------------------------------------
// Команды
// ---------------------------------------------------------------------------

async function cmdScan(args, store) {
  const { decisions, refsStats } = await runScan(store);
  const real = isReal(args, config);
  const s = summarize(decisions);

  if (args.json) {
    emitJson('scan', {
      mode: real ? 'real' : 'dry',
      roots: config.roots || [],
      refs: refsStats,
      summary: { keep: s.keep, cand: s.cand, total: s.total, bytes: { keep: s.keepBytes, cand: s.candBytes } },
      decisions: decisions.map(briefDecision),
    });
    store.setMeta('lastScanAt', new Date().toISOString());
    store.setMeta('lastCounts', JSON.stringify({ keep: s.keep, candidate: s.cand, bytesCandidate: s.candBytes, total: s.total }));
    return decisions;
  }

  const cand = decisions.filter((d) => d.result.verdict === 'candidate');
  const keep = decisions.filter((d) => d.result.verdict !== 'candidate');
  const showAll = args.all || decisions.length <= 400;
  const rows = showAll ? [...cand, ...keep] : cand;

  process.stdout.write(`Чистильщик v${VERSION} — команда scan (прогон ${real ? 'БОЕВОЙ' : 'СУХОЙ'}).\n`);
  process.stdout.write(`Корни: ${(config.roots || []).join(' | ')}\n`);
  process.stdout.write(`Ссылок разобрано: ${refsStats.files} файлов, рёбер ${refsStats.edges} (новых ${refsStats.newEdges}).\n\n`);
  printTable(rows.map((d) => [d.result.verdict, d.result.ruleId || '—', shortReason(d.result), relDisplay(d.path)]));
  if (!showAll) process.stdout.write(`\n… всего файлов ${decisions.length}; показаны только кандидаты (--all — показать все).\n`);

  process.stdout.write(`\nСВОДКА: всего ${s.total}; KEEP ${s.keep} (${human(s.keepBytes)}); CANDIDATE ${s.cand} (${human(s.candBytes)}).\n`);
  if (!real) process.stdout.write('Сухой прогон: ни один файл не перемещён и не удалён.\n');

  return decisions;
}

async function cmdClean(args, store) {
  const { decisions } = await runScan(store);
  const candidates = decisions.filter((d) => d.result.verdict === 'candidate');
  const real = isReal(args, config);
  const plan = candidates.map((d) => ({
    path: core.normalizePath(d.path),
    display: relDisplay(d.path),
    ruleId: d.result.ruleId || null,
    reason: shortReason(d.result),
    bytes: d.bytes,
  }));

  if (!candidates.length) {
    if (args.json) return emitJson('clean', { real, candidates: [], moved: 0, skipped: 0, message: 'кандидатов нет' });
    process.stdout.write('Кандидатов нет. Ничего не перемещаем.\n');
    return;
  }
  if (!real) {
    if (args.json) return emitJson('clean', { real: false, confirmRequired: true, candidates: plan, moved: 0, skipped: 0 });
    if (args.yes) {
      process.stdout.write(`План перемещения в карантин (сухой прогон: config.dryRun=true в config.json). Кандидатов: ${candidates.length}.\n\n`);
    } else {
      process.stdout.write(`План перемещения в карантин (нужен --yes). Кандидатов: ${candidates.length}.\n\n`);
    }
    printTable(candidates.map((d) => ['candidate', d.result.ruleId || '—', shortReason(d.result), relDisplay(d.path)]));
    process.stdout.write('\nСухой прогон: ничего не перемещено.\n');
    return;
  }

  const dateStr = new Date().toISOString().slice(0, 10);
  let moved = 0, skipped = 0;
  const movedFiles = [];
  for (const d of candidates) {
    if (core.fileBusy(d.path)) { skipped++; continue; } // финальная проверка занятости
    const root = findRoot(d.path) || path.parse(d.path).root;
    const rel = path.relative(root, d.path);
    let dst = path.join(QUAR_DIR, dateStr, rel);
    // Пункт 4: цикл подбора свободного имени с проверкой перед renameSync
    if (fs.existsSync(dst)) {
      const base = dst; let n = 0;
      while (fs.existsSync(dst)) { n++; dst = `${base}.${Date.now().toString(36)}-${n}`; }
    }
    // Пункт 7: запишем намерение ДО перемещения
    const id = 'q-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8);
    store.logAction({ id, ts: new Date().toISOString(), action: 'quarantine', status: 'moving', src: d.path, dst, ruleId: d.result.ruleId, bytes: d.bytes });
    try {
      fs.mkdirSync(path.dirname(dst), { recursive: true });
      // Финальная защита: ещё раз проверить, не появился ли приёмник между проверкой и renameSync
      if (fs.existsSync(dst)) {
        if (!args.json) process.stderr.write(`предупреждение: приёмник появился в процессе ${d.path} — пропускаем\n`);
        store.logAction({ id, ts: new Date().toISOString(), action: 'quarantine', status: 'skipped_collision', src: d.path, dst, ruleId: d.result.ruleId, bytes: d.bytes });
        skipped++;
        continue;
      }
      fs.renameSync(d.path, dst);
    } catch (e) {
      store.logAction({ id, ts: new Date().toISOString(), action: 'quarantine', status: 'failed', src: d.path, dst, error: e.code || e.message });
      if (!args.json) process.stderr.write(`не удалось переместить ${d.path}: ${e.code || e.message}\n`);
      skipped++;
      continue;
    }
    // Пункт 7: допишем результат после перемещения
    store.logAction({ id, ts: new Date().toISOString(), action: 'quarantine', status: 'moved', src: d.path, dst, ruleId: d.result.ruleId, bytes: d.bytes });
    if (!args.json) process.stdout.write(`→ карантин: ${relDisplay(d.path)}  →  ${path.relative(DIR, dst)}\n`);
    movedFiles.push({ id, path: core.normalizePath(d.path), display: relDisplay(d.path), dst: core.normalizePath(dst), bytes: d.bytes });
    moved++;
  }
  if (args.json) return emitJson('clean', { real: true, candidates: plan, moved, skipped, movedFiles });
  process.stdout.write(`\nПеремещено в карантин: ${moved}; пропущено: ${skipped}.\n`);
}

function listQuarantineFiles() {
  const out = [];
  for (const f of core.walkFiles([QUAR_DIR], { skipDirs: [] })) {
    try { const st = fs.statSync(f); out.push({ path: f, size: st.size, mtimeMs: st.mtimeMs }); } catch { /* ignore */ }
  }
  return out;
}

function pruneEmptyDirs(root) {
  let entries;
  try { entries = fs.readdirSync(root, { withFileTypes: true }); } catch { return false; }
  let empty = entries.length === 0;
  for (const e of entries) {
    if (e.isDirectory() && pruneEmptyDirs(path.join(root, e.name))) empty = true;
    else empty = false;
  }
  if (empty) { try { fs.rmdirSync(root); } catch { /* ignore */ } }
  return empty;
}

async function cmdPurge(args, store) {
  const real = isReal(args, config);
  const days = Number(config.quarantineDays || 30);
  const thr = Date.now() - days * 86400000;
  const files = listQuarantineFiles();
  const old = files.filter((f) => f.mtimeMs < thr);
  const oldPlan = old.map((f) => ({ path: core.normalizePath(f.path), display: relDisplay(f.path), size: f.size }));

  if (args.json && !old.length) return emitJson('purge', { real, days, files: files.length, old: 0, deleted: 0, plan: [], message: 'удалять нечего' });
  if (!args.json) process.stdout.write(`Карантин: файлов ${files.length}, старше ${days} сут — ${old.length}.\n`);
  if (!old.length) { if (!args.json) process.stdout.write('Удалять нечего.\n'); return; }
  if (!real) {
    if (args.json) return emitJson('purge', { real: false, confirmRequired: true, days, files: files.length, old: old.length, deleted: 0, plan: oldPlan });
    process.stdout.write(`План удаления из карантина (нужен --yes):\n`);
    for (const f of old) process.stdout.write(`  delete  ${relDisplay(f.path)}  (${human(f.size)})\n`);
    process.stdout.write('Сухой прогон: ничего не удалено.\n');
    return;
  }
  let deleted = 0;
  for (const f of old) {
    try { fs.rmSync(f.path, { force: true }); } catch (e) { if (!args.json) process.stderr.write(`не удалось удалить ${f.path}: ${e.message}\n`); continue; }
    store.logAction({ id: 'p-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8), ts: new Date().toISOString(), action: 'purge', src: f.path, bytes: f.size });
    deleted++;
  }
  pruneEmptyDirs(QUAR_DIR);
  if (args.json) return emitJson('purge', { real: true, days, files: files.length, old: old.length, deleted, plan: oldPlan });
  process.stdout.write(`Удалено из карантина: ${deleted}.\n`);
}

function readActions() {
  try {
    return fs.readFileSync(JSONL_PATH, 'utf8').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  } catch { return []; }
}

async function cmdRestore(target, args, store) {
  const fail = (msg, code) => {
    if (args.json) emitJsonError('restore', msg);
    else process.stderr.write(msg + '\n');
    process.exitCode = code;
  };
  if (!target) return fail('укажите id или путь: restore <id|path>', 2);
  const records = readActions().filter((r) => r.action === 'quarantine');
  let rec = null;
  if (/^q-/.test(target)) rec = records.find((r) => r.id === target);
  else {
    const abs = core.normalizePath(target).toLowerCase();
    rec = records.filter((r) => r.src && core.normalizePath(r.src).toLowerCase() === abs).pop();
  }
  if (!rec) return fail('запись о карантине не найдена.', 1);
  if (!fs.existsSync(rec.dst)) return fail('файл в карантине отсутствует: ' + rec.dst, 1);
  if (fs.existsSync(rec.src)) return fail('на исходном месте уже есть файл: ' + rec.src, 1);

  const real = isReal(args, config);
  if (!real) {
    if (args.json) return emitJson('restore', { target, id: rec.id, real: false, confirmRequired: true, restored: false, src: core.normalizePath(rec.src), dst: core.normalizePath(rec.dst) });
    if (args.yes) {
      process.stdout.write(`План восстановления (сухой прогон: config.dryRun=true в config.json):\n  ${rec.dst}\n  → ${rec.src}\n`);
    } else {
      process.stdout.write(`План восстановления (нужен --yes):\n  ${rec.dst}\n  → ${rec.src}\n`);
    }
    return;
  }
  try {
    fs.mkdirSync(path.dirname(rec.src), { recursive: true });
    fs.renameSync(rec.dst, rec.src);
  } catch (e) { return fail('ошибка восстановления: ' + e.message, 1); }
  store.logAction({ id: 'r-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8), ts: new Date().toISOString(), action: 'restore', src: rec.dst, dst: rec.src, ruleId: rec.ruleId });
  if (args.json) return emitJson('restore', { target, id: rec.id, real: true, restored: true, src: core.normalizePath(rec.src), dst: core.normalizePath(rec.dst) });
  process.stdout.write(`Восстановлено: ${rec.src}\n`);
}

async function cmdStatus(args, store) {
  const files = listQuarantineFiles();
  const qBytes = files.reduce((a, f) => a + f.size, 0);
  const counts = JSON.parse(store.getMeta('lastCounts') || 'null');
  const lastScan = store.getMeta('lastScanAt');
  const top = store.topCounters(20);
  const immune = store.immuneCount();
  const etw = startEtw(config.refs);

  if (args.json) {
    return emitJson('status', {
      version: VERSION,
      dir: core.normalizePath(DIR),
      roots: config.roots,
      lastScanAt: lastScan || null,
      lastCounts: counts,
      quarantine: { files: files.length, bytes: qBytes, humanBytes: human(qBytes) },
      immune,
      theta: config.theta,
      windowDays: config.windowDays,
      decay: config.decay,
      etw: { active: etw.active, reason: etw.reason },
      top: top.map((t) => ({ path: core.normalizePath(t.path), display: relDisplay(t.path), w: Number(t.w.toFixed(6)), hits: t.hits, lastSeen: t.lastSeen })),
      quarantineFiles: files.map((f) => ({ path: core.normalizePath(f.path), display: relDisplay(f.path), size: f.size, mtimeMs: f.mtimeMs })),
    });
  }

  process.stdout.write(`Чистильщик v${VERSION} — статус\n`);
  process.stdout.write(`Каталог данных: ${DIR}\n`);
  process.stdout.write(`Корни: ${config.roots.join(' | ')}\n`);
  process.stdout.write(`Последний прогон: ${lastScan || '—'}\n`);
  process.stdout.write(`Последний scan: keep ${counts ? counts.keep : '—'}, candidate ${counts ? counts.candidate : '—'}, всего ${counts ? counts.total : '—'}\n`);
  process.stdout.write(`Карантин: файлов ${files.length}, размер ${human(qBytes)}\n`);
  process.stdout.write(`Иммунных путей: ${immune} (theta=${config.theta}, windowDays=${config.windowDays}, decay=${config.decay})\n`);
  process.stdout.write(`ETW: ${etw.active ? 'активен' : 'выключен'} — ${etw.reason}\n`);
  process.stdout.write(`\nТоп-${top.length} путей по весу обращений (w):\n`);
  if (!top.length) process.stdout.write('  (пусто — обращений не зафиксировано)\n');
  for (const t of top) process.stdout.write(`  ${t.w.toFixed(2).padStart(8)}  ${relDisplay(t.path)}\n`);
}

async function cmdExplain(target, args, store) {
  if (!target) {
    if (args.json) { emitJsonError('explain', 'укажите путь: explain <path>'); process.exitCode = 2; }
    else { process.stderr.write('укажите путь: explain <path>\n'); process.exitCode = 2; }
    return;
  }
  const abs = path.resolve(target);
  let stat = null;
  try { stat = fs.statSync(abs); } catch { /* нет */ }
  const ctx = makeCtx(store);
  const res = core.classify(abs, stat || { mtimeMs: Date.now(), size: 0 }, ctx);

  if (args.json) {
    return emitJson('explain', {
      path: core.normalizePath(abs),
      exists: !!stat,
      verdict: res.verdict,
      ruleId: res.ruleId || null,
      reasons: res.reasons,
    });
  }

  process.stdout.write(`Разбор вердикта: ${abs}\n`);
  if (!stat) {
    process.stdout.write('Файл недоступен (нет файла или нет прав) → вердикт keep.\n');
  }
  for (const r of res.reasons) {
    const mark = r.pass ? 'OK ' : 'НЕТ';
    process.stdout.write(`  [${mark}] шаг ${r.step}: ${r.detail}\n`);
  }
  process.stdout.write(`ИТОГ: ${res.verdict}${res.ruleId ? ' (правило ' + res.ruleId + ')' : ''}\n`);
}

async function cmdCompact(store) {
  const r = store.compact();
  process.stdout.write(`Компакция выполнена: затухание ${r.decayed}, отброшено счётчиков ${r.dropped}, замороженных ${r.counters}, whitelist ${r.whitelist}, vacuum ${r.vacuum}.\n`);
}

// ---------------------------------------------------------------------------
// Одиночный экземпляр (для --watch)
// ---------------------------------------------------------------------------

function acquireLock() {
  if (fs.existsSync(LOCK_PATH)) {
    let holder = null;
    try { holder = JSON.parse(fs.readFileSync(LOCK_PATH, 'utf8')); } catch { /* ignore */ }
    const alive = holder && holder.pid ? core.pidAlive(holder.pid) : false;
    if (holder && alive === true) return { ok: false, holder, reason: `держатель PID ${holder.pid} жив — замок не считается протухшим` };
  }
  fs.writeFileSync(LOCK_PATH, JSON.stringify({ pid: process.pid, startedAt: Date.now() }), 'utf8');
  return { ok: true };
}

function releaseLock() {
  try {
    const holder = JSON.parse(fs.readFileSync(LOCK_PATH, 'utf8'));
    if (holder && holder.pid === process.pid) fs.rmSync(LOCK_PATH, { force: true });
  } catch { /* ignore */ }
}

// Heartbeat: перезаписать janitor.lock только если текущий владелец наш pid (иначе noop).
function touchLock() {
  try {
    const holder = JSON.parse(fs.readFileSync(LOCK_PATH, 'utf8'));
    if (holder && holder.pid === process.pid) {
      fs.writeFileSync(LOCK_PATH, JSON.stringify({ pid: process.pid, startedAt: holder.startedAt || Date.now() }), 'utf8');
    }
  } catch { /* ignore — noop */ }
}

async function cmdWatch(args, store) {
  const lock = acquireLock();
  if (!lock.ok) {
    const reason = lock.reason || `держатель PID ${lock.holder.pid} жив`;
    const msg = `Чистильщик уже запущен (PID ${lock.holder.pid}) — ${reason}. Выход.\n`;
    process.stderr.write(msg);
    // Дозапись в janitor.log (append)
    try {
      fs.appendFileSync(path.join(DIR, 'janitor.log'), `[${new Date().toISOString()}] ${msg}`);
    } catch { /* ignore */ }
    process.exitCode = 1;
    return;
  }
  process.on('exit', releaseLock);
  process.on('SIGINT', () => { releaseLock(); process.exit(0); });

  const intervalMin = args.intervalMin || config.intervalMin || 60;
  const real = isReal(args, config);
  const tick = async () => {
    touchLock(); // heartbeat в начале каждого тика
    const stamp = new Date().toISOString();
    process.stdout.write(`[${stamp}] тик: прогон (${real ? 'боевой' : 'сухой'}), интервал ${intervalMin} мин.\n`);
    const { decisions } = await runScan(store);
    const s = summarize(decisions);
    process.stdout.write(`[${stamp}] keep ${s.keep}, candidate ${s.cand}.\n`);
    if (real && s.cand) await cmdClean(args, store);
    store.setMeta('lastScanAt', new Date().toISOString());
    store.setMeta('lastCounts', JSON.stringify({ keep: s.keep, candidate: s.cand, total: s.total }));
  };
  await tick();
  setInterval(() => { tick().catch((e) => process.stderr.write('ошибка тика: ' + e.message + '\n')); }, intervalMin * 60000);
  process.stdout.write(`Фоновый режим запущен: PID ${process.pid}, интервал ${intervalMin} мин. Ctrl+C — остановка.\n`);
}

// ---------------------------------------------------------------------------
// Точка входа
// ---------------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cmd = args._[0] || 'scan';
  const store = openStore();
  try {
    if (args.watch || cmd === 'watch') { await cmdWatch(args, store); return; }
    switch (cmd) {
      case 'scan': await cmdScan(args, store); break;
      case 'clean': await cmdClean(args, store); break;
      case 'purge': await cmdPurge(args, store); break;
      case 'restore': await cmdRestore(args._[1], args, store); break;
      case 'status': await cmdStatus(args, store); break;
      case 'explain': await cmdExplain(args._[1], args, store); break;
      case 'compact': await cmdCompact(store); break;
      case 'version':
        if (args.json) emitJson('version', { version: VERSION });
        else process.stdout.write(`janitor v${VERSION}\n`);
        break;
      default:
        if (args.json) emitJsonError(cmd, `неизвестная команда: ${cmd}`);
        else {
          process.stderr.write(`неизвестная команда: ${cmd}\n`);
          process.stderr.write('команды: scan | clean | purge | restore <id|path> | status | explain <path> | compact | version | --watch\n');
        }
        process.exitCode = 2;
    }
  } catch (e) {
    // При --json ошибку тоже отдаём машинночитаемо (MCP-сервер её распарсит).
    if (args.json) emitJsonError(cmd, (e && e.message) || String(e));
    else throw e;
  } finally {
    if (!args.watch && cmd !== 'watch') store.close();
  }
}

main().catch((e) => { process.stderr.write('фатальная ошибка: ' + (e && e.stack || e) + '\n'); process.exitCode = 1; });
