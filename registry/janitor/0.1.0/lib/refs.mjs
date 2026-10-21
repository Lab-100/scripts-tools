// lib/refs.mjs — источник «обращений» (refs) для иммунитета.
//
// Источник №1 (реализован): статический граф ссылок по содержимому файлов.
//   Из текстов извлекаются ссылки require()/import/export ... from, {file:...},
//   include/extends и относительные/абсолютные пути; строятся рёбра src→dst в
//   SQLite. Новое ребро даёт +1 к счётчику dst (обращение к цели).
//
// Источник №2 (ЗАГЛУШКА, выключен): ETW Kernel-File (реальные события доступа).
//   Требует прав администратора; в v0.1.0 не реализован — только интерфейс.

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { walkFiles } from './core.mjs';

// Расширения, содержимое которых разбираем.
const TEXT_EXT = new Set(['.js', '.mjs', '.cjs', '.ts', '.json', '.jsonc', '.yaml', '.yml', '.ps1', '.md']);
const MAX_BYTES = 2 * 1024 * 1024; // файлы крупнее не разбираем
const MAX_REFS = 5000;

// Правила извлечения. mode: 'module' — модульный спецификатор, 'path' — путь к файлу.
// ВАЖНО: все регэкспы линейные (без вложенных необязательных квантификаторов),
// чтобы не было катастрофического бэктрекинга на больших JSON/MD-файлах.
// Форма `import ... from 'x'` и `export ... from 'x'` покрывается правилом `from`.
const REF_RULES = [
  { mode: 'module', re: /require\s*\(\s*['"]([^'"]+)['"]\s*\)/g },
  { mode: 'module', re: /\bfrom\s*['"]([^'"]+)['"]/g },
  { mode: 'module', re: /\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)/g },
  { mode: 'module', re: /^\s*import\s+['"]([^'"]+)['"]/gm },
  { mode: 'path', re: /\{file:\s*([^}]+)\}/g },
  { mode: 'path', re: /^\s*(?:include|extends)\s*[:=]\s*['"]?([^'"\n#]+)['"]?\s*$/gim },
  { mode: 'path', re: /['"]((?:\.{1,2}[\\/]|[\\/]|[A-Za-z]:[\\/]|~[\\/])[^'"\n]+)['"]/g },
];

// Извлекает сырые ссылки из текста (дедуп).
export function extractRefs(content) {
  const out = [];
  const seen = new Set();
  for (const rule of REF_RULES) {
    rule.re.lastIndex = 0;
    let m;
    while ((m = rule.re.exec(content)) !== null) {
      const spec = (m[1] || '').trim();
      if (!spec) continue;
      const key = rule.mode + '|' + spec;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({ spec, mode: rule.mode });
      if (out.length >= MAX_REFS) return out;
    }
  }
  return out;
}

// Пробуем разрешить путь: как есть, с расширениями, как index-файл.
function tryFile(p) {
  const cands = [p];
  if (!path.extname(p)) {
    for (const e of ['.js', '.mjs', '.cjs', '.ts', '.json', '.jsonc', '.yaml', '.yml', '.ps1']) cands.push(p + e);
  }
  cands.push(path.join(p, 'index.js'), path.join(p, 'index.mjs'));
  for (const c of cands) {
    try { if (fs.statSync(c).isFile()) return path.resolve(c).replace(/\\/g, '/'); } catch { /* нет */ }
  }
  return null;
}

// Разрешает ссылку в абсолютный путь существующего файла (или null).
export function resolveRef(spec, srcDir, roots, mode) {
  let s = String(spec).trim().replace(/^['"]|['"]$/g, '');
  if (s.startsWith('{file:')) s = s.slice(6).replace(/\}$/, '').trim();
  s = s.split('#')[0].trim();
  if (!s) return null;

  if (s.startsWith('~')) return tryFile(path.join(os.homedir(), s.slice(1)));
  if (path.isAbsolute(s) || /^[A-Za-z]:[\\/]/.test(s)) return tryFile(s);
  if (s.startsWith('./') || s.startsWith('../') || s.startsWith('.\\') || s.startsWith('..\\')) {
    return tryFile(path.resolve(srcDir, s));
  }
  // «Голый» спецификатор.
  if (mode === 'module') return null; // модуль из node_modules — не файл проекта
  return tryFile(path.resolve(srcDir, s)) || (roots || []).map((r) => tryFile(path.resolve(r, s))).find(Boolean) || null;
}

// Строит граф по корням и записывает рёбра/обращения в хранилище.
export function buildGraph({ roots, store, skipDirs, maxBytes = MAX_BYTES }) {
  let files = 0;
  let edges = 0;
  let newEdges = 0;
  const now = Date.now();
  for (const file of walkFiles(roots, { skipDirs })) {
    const ext = path.extname(file).toLowerCase();
    if (!TEXT_EXT.has(ext)) continue;
    let st;
    try { st = fs.statSync(file); } catch { continue; }
    if (st.size > maxBytes) continue;
    let content;
    try { content = fs.readFileSync(file, 'utf8'); } catch { continue; }
    files++;
    const src = path.resolve(file).replace(/\\/g, '/');
    for (const { spec, mode } of extractRefs(content)) {
      const dst = resolveRef(spec, path.dirname(file), roots, mode);
      if (!dst || dst === src) continue;
      const isNew = store.addEdge(src, dst);
      edges++;
      if (isNew) { newEdges++; store.bumpHits(dst, 1, now); }
    }
  }
  return { files, edges, newEdges };
}

// --- Заготовка ETW Kernel-File (источник №2) -------------------------------
// Реальные события доступа к файлам по ETW требуют прав администратора и
// нативной подписки. В v0.1.0 канал выключен и не активируется.

export function startEtw(config = {}) {
  if (!config || config.etw !== true) {
    return { active: false, reason: 'ETW выключен в конфиге (refs.etw=false)' };
  }
  return { active: false, reason: 'ETW не реализован в v0.1.0: требуются права администратора и нативная подписка Kernel-File' };
}

// Опрос событий ETW. Заглушка всегда пуста.
export function pollEtw() {
  return { events: [], note: 'ETW-канал не активен' };
}
