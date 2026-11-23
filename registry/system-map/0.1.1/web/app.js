/* system-map 0.1.1 UI: ванильный JS + SVG, без внешних библиотек. */
const $ = (s) => document.querySelector(s);
const svg = $('#graph');
const gEdges = $('#edges');
const gNodes = $('#nodes');
const tooltip = $('#tooltip');

const LS_LAYOUT = 'system-map-layout-v1';
const LS_FILTERS = 'system-map-filters-v1';

const STATE_LABEL = {
  active: 'работает', idle: 'простаивает', unloaded: 'выгружен',
  'need-guard': 'нужен, но недоступен', fault: 'упал', starting: 'подъём',
  blocked: 'ограничен', detached: 'фоновый', reaped: 'зачищен', unknown: 'неизвестно',
};

let current = null;
let selected = null;
let positions = {};
let filters = { idle: false, unloaded: false }; // false = показывать
let drag = null;
const measureCtx = document.createElement('canvas').getContext('2d');

function fmt(v, digits = 1) {
  if (v === null || v === undefined || v === '') return '—';
  if (typeof v === 'number') return Number(v).toFixed(digits).replace(/\.0+$/, '');
  return String(v);
}
function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function kv(k, v) { return `<div class="kv"><span>${esc(k)}</span><b>${esc(v)}</b></div>`; }
function bar(pct, color) {
  const p = Math.max(0, Math.min(100, Number(pct) || 0));
  return `<div class="bar"><i style="width:${p}%;${color ? 'background:' + color : ''}"></i></div>`;
}

function lsGet(key, fallback) {
  try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : fallback; }
  catch (_) { return fallback; }
}
function lsSet(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch (_) {}
}

function buildLegend(snap) {
  const colors = snap.meta?.colors || {};
  $('#legend').innerHTML = Object.entries(STATE_LABEL)
    .filter(([k]) => colors[k])
    .map(([k, label]) => `<span><i class="dot" style="background:${colors[k]}"></i>${label}</span>`)
    .join('');
}

/* ---------- геометрия узлов: подпись ВСЕГДА внутри фигуры ---------- */
function labelText(n) {
  const s = String(n.label || n.id || '');
  return s.length > 26 ? s.slice(0, 25) + '…' : s;
}
function textWidth(text, size) {
  measureCtx.font = `600 ${size}px "Segoe UI", system-ui, sans-serif`;
  return measureCtx.measureText(text).width;
}
function nodeGeometry(n) {
  const label = labelText(n);
  let size = 10.5;
  let w = textWidth(label, size);
  if (w > 150) { size = 9; w = textWidth(label, size); }
  const boxW = Math.max(56, Math.min(168, w + 20));
  const boxH = 26;
  if (['core', 'resource'].includes(n.type)) {
    const rx = Math.max(28, boxW / 2 + 6);
    const ry = Math.max(22, boxH / 2 + 8);
    return { kind: 'ellipse', rx, ry, label, size, textW: w };
  }
  if (['agent', 'model'].includes(n.type)) {
    const hw = Math.max(34, boxW / 2 + 8);
    const hh = Math.max(22, boxH / 2 + 6);
    return { kind: 'diamond', hw, hh, label, size, textW: w };
  }
  return { kind: 'rect', w: boxW, h: boxH, label, size, textW: w };
}
function shapeMarkup(n, g) {
  const c = n.color || '#64748b';
  const alarm = ['fault', 'need-guard'].includes(n.state) ? ' alarm' : '';
  const dim = ['unloaded', 'reaped'].includes(n.state) ? ' opacity="0.55"' : '';
  const light = ['fault', 'need-guard', 'blocked', 'unloaded', 'reaped'].includes(n.state);
  let shape = '';
  if (g.kind === 'ellipse') {
    shape = `<ellipse class="shape${alarm}" cx="0" cy="0" rx="${g.rx.toFixed(1)}" ry="${g.ry.toFixed(1)}" fill="${c}" stroke="#0b1220" stroke-width="2"${dim}/>`;
  } else if (g.kind === 'diamond') {
    shape = `<path class="shape${alarm}" d="M 0 ${-g.hh.toFixed(1)} L ${g.hw.toFixed(1)} 0 L 0 ${g.hh.toFixed(1)} L ${-g.hw.toFixed(1)} 0 Z" fill="${c}" stroke="#0b1220" stroke-width="2"${dim}/>`;
  } else {
    shape = `<rect class="shape${alarm}" x="${(-g.w / 2).toFixed(1)}" y="${(-g.h / 2).toFixed(1)}" width="${g.w.toFixed(1)}" height="${g.h.toFixed(1)}" rx="6" fill="${c}" stroke="#0b1220" stroke-width="2"${dim}/>`;
  }
  // textLength сжимает подпись, если она всё же шире фигуры — обрезки нет.
  const maxText = g.kind === 'rect' ? g.w - 14 : (g.kind === 'diamond' ? g.hw * 1.65 : g.rx * 1.8);
  const tl = g.textW > maxText && maxText > 16 ? ` textLength="${maxText.toFixed(1)}" lengthAdjust="spacingAndGlyphs"` : '';
  const text = `<text class="node-text${light ? ' light' : ''}" x="0" y="0" text-anchor="middle" dominant-baseline="central" font-size="${g.size}"${tl}>${esc(g.label)}</text>`;
  return shape + text;
}

/* ---------- раскладка с minimized crossing ---------- */
function segmentsIntersect(a, b, c, d) {
  const ccw = (p, q, r) => (r.y - p.y) * (q.x - p.x) > (q.y - p.y) * (r.x - p.x);
  return ccw(a, c, d) !== ccw(b, c, d) && ccw(a, b, c) !== ccw(a, b, d);
}
function countCrossings(pos, edges, idx) {
  let total = 0;
  for (let i = 0; i < edges.length; i++) {
    for (let j = i + 1; j < edges.length; j++) {
      const e1 = edges[i], e2 = edges[j];
      if (e1.source === e2.source || e1.target === e2.target ||
          e1.source === e2.target || e1.target === e2.source) continue;
      const a = pos[idx[e1.source]], b = pos[idx[e1.target]];
      const c = pos[idx[e2.source]], d = pos[idx[e2.target]];
      if (a && b && c && d && segmentsIntersect(a, b, c, d)) total++;
    }
  }
  return total;
}
function radialStart(nodes, W, H, phase) {
  const cx = W / 2, cy = H / 2;
  const groups = {};
  nodes.forEach((n) => { const t = n.type || 'tool'; (groups[t] ||= []).push(n); });
  const order = { core: 0, mcp: 1, service: 2, agent: 3, tool: 4, plugin: 5, session: 6, subagent: 7, model: 8, resource: 9, ui: 10 };
  const types = Object.keys(groups).sort((a, b) => (order[a] ?? 20) - (order[b] ?? 20));
  const pos = {};
  const core = groups.core || [];
  core.forEach((n, i) => {
    const a = -Math.PI / 2 + phase + (i * 2 * Math.PI) / Math.max(1, core.length);
    pos[n.id] = { x: cx + Math.cos(a) * 70, y: cy + Math.sin(a) * 60 };
  });
  types.filter((t) => t !== 'core').forEach((type, ti) => {
    const arr = groups[type].slice().sort((a, b) => a.id.localeCompare(b.id));
    const radius = Math.min(W, H) * (0.22 + (ti % 4) * 0.08);
    arr.forEach((n, i) => {
      const a = phase + ti * 0.55 + (i * 2 * Math.PI) / Math.max(1, arr.length);
      pos[n.id] = {
        x: Math.max(70, Math.min(W - 70, cx + Math.cos(a) * radius * 1.35)),
        y: Math.max(48, Math.min(H - 48, cy + Math.sin(a) * radius)),
      };
    });
  });
  return pos;
}
function forcePass(pos, nodes, edges, W, H, iterations, phase) {
  const n = nodes.length;
  const idx = {};
  nodes.forEach((x, i) => { idx[x.id] = i; });
  const arr = nodes.map((x) => ({ ...pos[x.id] }));
  for (let it = 0; it < iterations; it++) {
    const disp = Array.from({ length: n }, () => ({ x: 0, y: 0 }));
    for (let i = 0; i < n; i++) {
      for (let j = i + 1; j < n; j++) {
        let dx = arr[i].x - arr[j].x, dy = arr[i].y - arr[j].y;
        let d2 = dx * dx + dy * dy + 0.01;
        let d = Math.sqrt(d2);
        if (d < 1) { dx = Math.cos(i + phase) || 1; dy = Math.sin(i + phase) || 1; d = 1; d2 = 1; }
        const f = Math.min(180, 2600 / d2);
        disp[i].x += (dx / d) * f; disp[i].y += (dy / d) * f;
        disp[j].x -= (dx / d) * f; disp[j].y -= (dy / d) * f;
      }
    }
    edges.forEach((e) => {
      const a = idx[e.source], b = idx[e.target];
      if (a === undefined || b === undefined) return;
      const dx = arr[b].x - arr[a].x, dy = arr[b].y - arr[a].y;
      const d = Math.hypot(dx, dy) || 1;
      const f = (d - 115) * 0.025;
      disp[a].x += (dx / d) * f; disp[a].y += (dy / d) * f;
      disp[b].x -= (dx / d) * f; disp[b].y -= (dy / d) * f;
    });
    const cool = 1 - it / iterations;
    for (let i = 0; i < n; i++) {
      disp[i].x += (W / 2 - arr[i].x) * 0.004;
      disp[i].y += (H / 2 - arr[i].y) * 0.004;
      const mag = Math.hypot(disp[i].x, disp[i].y) || 1;
      const step = Math.min(14, mag) * cool;
      arr[i].x += (disp[i].x / mag) * step;
      arr[i].y += (disp[i].y / mag) * step;
      arr[i].x = Math.max(70, Math.min(W - 70, arr[i].x));
      arr[i].y = Math.max(48, Math.min(H - 48, arr[i].y));
    }
  }
  const out = {};
  nodes.forEach((x, i) => { out[x.id] = arr[i]; });
  return out;
}
function optimizeLayout(nodes, edges, W, H) {
  const idx = {};
  nodes.forEach((x, i) => { idx[x.id] = i; });
  let best = null, bestCross = Infinity;
  for (let attempt = 0; attempt < 4; attempt++) {
    const phase = attempt * 0.47;
    const start = radialStart(nodes, W, H, phase);
    const candidate = forcePass(start, nodes, edges, W, H, 110, phase);
    const cross = countCrossings(candidate, edges, idx);
    if (cross < bestCross) { bestCross = cross; best = candidate; }
  }
  return { pos: best, crossings: bestCross };
}
function ensurePositions(snap) {
  const W = svg.clientWidth || 1000, H = svg.clientHeight || 700;
  const saved = lsGet(LS_LAYOUT, null);
  const ids = new Set((snap.nodes || []).map((n) => n.id));
  if (saved && saved.__w === W && saved.__h === H && saved.pos &&
      ids.size === Object.keys(saved.pos).length && [...ids].every((id) => saved.pos[id])) {
    positions = saved.pos;
    return;
  }
  const optimized = optimizeLayout(snap.nodes || [], snap.edges || [], W, H);
  positions = optimized.pos;
  lsSet(LS_LAYOUT, { __w: W, __h: H, pos: positions, crossings: optimized.crossings });
}

/* ---------- отрисовка графа ---------- */
function drawEdges(snap, visible) {
  const parts = [];
  (snap.edges || []).forEach((e) => {
    if (!visible.has(e.source) || !visible.has(e.target)) return;
    const a = positions[e.source], b = positions[e.target];
    if (!a || !b) return;
    const dx = b.x - a.x, dy = b.y - a.y;
    const len = Math.hypot(dx, dy) || 1;
    const bend = Math.min(30, len * 0.1);
    const mx = (a.x + b.x) / 2 - (dy / len) * bend;
    const my = (a.y + b.y) / 2 + (dx / len) * bend;
    const cls = ['edge', e.kind || '', e.hot ? 'hot' : ''].join(' ');
    parts.push(`<path class="${cls}" d="M ${a.x.toFixed(1)} ${a.y.toFixed(1)} Q ${mx.toFixed(1)} ${my.toFixed(1)} ${b.x.toFixed(1)} ${b.y.toFixed(1)}"/>`);
  });
  gEdges.innerHTML = parts.join('');
}
function renderGraph(snap) {
  if (!snap) return;
  ensurePositions(snap);
  let nodes = (snap.nodes || []).slice();
  if (filters.idle) nodes = nodes.filter((n) => n.state !== 'idle');
  if (filters.unloaded) nodes = nodes.filter((n) => !['unloaded', 'reaped'].includes(n.state));
  const visible = new Set(nodes.map((n) => n.id));
  const W = svg.clientWidth || 1000, H = svg.clientHeight || 700;
  svg.setAttribute('viewBox', `0 0 ${W} ${H}`);

  drawEdges(snap, visible);
  gNodes.innerHTML = nodes.map((n) => {
    const p = positions[n.id] || { x: W / 2, y: H / 2 };
    const g = nodeGeometry(n);
    return `<g class="node" data-id="${esc(n.id)}" transform="translate(${p.x.toFixed(1)},${p.y.toFixed(1)})">${shapeMarkup(n, g)}</g>`;
  }).join('');

  gNodes.querySelectorAll('.node').forEach((el) => {
    const n = nodes.find((x) => x.id === el.dataset.id);
    el.addEventListener('pointerdown', (ev) => startDrag(ev, el, n, snap));
    el.addEventListener('pointerenter', (ev) => {
      if (drag) return;
      tooltip.innerHTML = `<b>${esc(n.label)}</b><br>состояние: ${esc(STATE_LABEL[n.state] || n.state)}<br>тип: ${esc(n.type)} · источник: ${esc(n.source)}<br>${esc(n.detail)}`;
      tooltip.style.display = 'block';
      moveTooltip(ev);
    });
    el.addEventListener('pointermove', moveTooltip);
    el.addEventListener('pointerleave', () => { tooltip.style.display = 'none'; });
  });
}
function svgPoint(ev) {
  const pt = svg.createSVGPoint();
  pt.x = ev.clientX; pt.y = ev.clientY;
  const ctm = svg.getScreenCTM();
  return ctm ? pt.matrixTransform(ctm.inverse()) : { x: ev.clientX, y: ev.clientY };
}
function startDrag(ev, el, node, snap) {
  if (ev.button !== 0) return;
  ev.preventDefault();
  tooltip.style.display = 'none';
  const p = positions[node.id] || { x: 0, y: 0 };
  const start = svgPoint(ev);
  drag = { id: node.id, el, node, snap, dx: p.x - start.x, dy: p.y - start.y, moved: 0, startX: ev.clientX, startY: ev.clientY };
  try { el.setPointerCapture(ev.pointerId); } catch (_) {}
  el.classList.add('dragging');
  el.addEventListener('pointermove', onDragMove);
  el.addEventListener('pointerup', onDragEnd);
  el.addEventListener('pointercancel', onDragEnd);
}
function onDragMove(ev) {
  if (!drag) return;
  const p = svgPoint(ev);
  const W = svg.clientWidth || 1000, H = svg.clientHeight || 700;
  const x = Math.max(30, Math.min(W - 30, p.x + drag.dx));
  const y = Math.max(24, Math.min(H - 24, p.y + drag.dy));
  drag.moved = Math.max(drag.moved, Math.hypot(ev.clientX - drag.startX, ev.clientY - drag.startY));
  positions[drag.id] = { x, y };
  drag.el.setAttribute('transform', `translate(${x.toFixed(1)},${y.toFixed(1)})`);
  const visible = new Set((drag.snap.nodes || []).filter((n) =>
    (!filters.idle || n.state !== 'idle') && (!filters.unloaded || !['unloaded', 'reaped'].includes(n.state))
  ).map((n) => n.id));
  drawEdges(drag.snap, visible);
}
function onDragEnd(ev) {
  if (!drag) return;
  const d = drag;
  try { d.el.releasePointerCapture?.(ev.pointerId); } catch (_) {}
  d.el.classList.remove('dragging');
  d.el.removeEventListener('pointermove', onDragMove);
  d.el.removeEventListener('pointerup', onDragEnd);
  d.el.removeEventListener('pointercancel', onDragEnd);
  drag = null;
  if (d.moved < 4) { selected = d.id; renderDetail(d.snap); }
  lsSet(LS_LAYOUT, { __w: svg.clientWidth || 1000, __h: svg.clientHeight || 700, pos: positions });
}
function moveTooltip(ev) {
  const r = svg.getBoundingClientRect();
  tooltip.style.left = Math.max(4, Math.min(r.width - 310, ev.clientX - r.left + 12)) + 'px';
  tooltip.style.top = Math.max(4, Math.min(r.height - 110, ev.clientY - r.top + 12)) + 'px';
}

/* ---------- панели ---------- */
function renderDetail(snap) {
  const n = (snap.nodes || []).find((x) => x.id === selected);
  const box = $('#card-detail .body');
  if (!n) { box.innerHTML = '<span class="muted">нажмите на узел графа</span>'; return; }
  const incoming = (snap.edges || []).filter((e) => e.target === n.id).map((e) => e.source);
  const outgoing = (snap.edges || []).filter((e) => e.source === n.id).map((e) => e.target);
  box.innerHTML = kv('ид', n.id) + kv('состояние', STATE_LABEL[n.state] || n.state) +
    kv('намерение', n.intent) + kv('владелец', n.owner || '—') +
    kv('класс', n.nodeClass || '—') + kv('значение', n.val ?? '—') +
    kv('PID', n.pid || '—') + kv('источник', n.source) + kv('обновлён', n.lastSeen || '—') +
    `<div style="margin-top:5px">${esc(n.detail)}</div>` +
    `<div style="margin-top:5px" class="muted">входящие: ${esc(incoming.slice(0, 8).join(', ') || '—')}</div>` +
    `<div class="muted">исходящие: ${esc(outgoing.slice(0, 8).join(', ') || '—')}</div>`;
}
function renderPanels(snap) {
  const hw = snap.hardware || {}, cpu = hw.cpu || {}, mem = hw.memory || {};
  const p = (v) => fmt(v);
  $('#card-system .body').innerHTML =
    kv('время сбора', snap.collectedAt) +
    kv('ОС', hw.os?.system || '—') +
    kv('процессов', hw.os?.process_count ?? '—') +
    kv('время сбора данных', (snap.meta?.collectMs ?? '—') + ' мс') +
    kv('схема', snap.schema);
  $('#card-cpu .body').innerHTML =
    kv('загрузка', p(cpu.percent) + '%') + bar(cpu.percent, cpu.percent > 85 ? '#ef4444' : '#38bdf8') +
    kv('логических ядер', cpu.logical ?? '—') + kv('физических ядер', cpu.physical ?? '—') +
    kv('частота', cpu.freq_mhz ? p(cpu.freq_mhz, 0) + ' МГц' : '—') +
    Object.entries(snap.processes || {}).filter(([, v]) => v && v.count).slice(0, 5)
      .map(([k, v]) => kv(k, p(v.cpu_percent) + '% / ' + p(v.rss_mb, 0) + ' МБ')).join('');
  $('#card-memory .body').innerHTML =
    kv('использовано', p(mem.percent) + '%') + bar(mem.percent, mem.percent > 85 ? '#ef4444' : '#22c55e') +
    kv('всего', p(mem.total_gb) + ' ГБ') + kv('доступно', p(mem.available_gb) + ' ГБ') +
    kv('файл подкачки', p(mem.commit_used_gb) + ' / ' + p(mem.commit_total_gb) + ' ГБ');
  $('#card-gpu .body').innerHTML = '<div class="muted">загрузка GPU — общая по адаптерам; VRAM по WMI</div>' +
    ((hw.gpu || []).map((g) =>
      kv('адаптер', (g.name || '—').slice(0, 32)) +
      kv('загрузка', g.gpu_percent === null || g.gpu_percent === undefined ? '—' : p(g.gpu_percent) + '%') +
      (g.gpu_percent != null ? bar(g.gpu_percent, '#a855f7') : '') +
      kv('VRAM', g.vram_gb ? p(g.vram_gb) + ' ГБ' : '—') +
      kv('выделено', g.dedicated_mb != null ? p(g.dedicated_mb, 0) + ' МБ' : '—') +
      kv('драйвер', g.driver || '—') + '<hr style="border:0;border-top:1px solid #22334d">'
    ).join('') || '<span class="muted">нет данных</span>');
  $('#card-disks .body').innerHTML = (hw.disks || []).map((d) =>
    kv(d.mount, p(d.percent) + '% · свободно ' + p(d.free_gb) + ' ГБ') +
    bar(d.percent, d.percent > 90 ? '#ef4444' : '#38bdf8')
  ).join('') + (hw.io ? kv('прочитано', p(hw.io.read_mb, 0) + ' МБ') + kv('записано', p(hw.io.write_mb, 0) + ' МБ') : '');
  const o = snap.opencode || {};
  $('#card-opencode .body').innerHTML =
    kv('сессий всего', o.sessions_total ?? '—') +
    kv('активных (30 мин)', o.sessions_recent ?? '—') +
    kv('субагентов', o.subagents_total ?? '—') +
    kv('свежих вызовов', o.tool_calls_recent ?? '—') +
    Object.entries(o.tools || {}).slice(0, 6).map(([k, v]) => `<span class="tag">${esc(k)} ×${v}</span>`).join('') +
    '<div style="margin-top:5px">' + (o.active || []).slice(0, 4).map((s) =>
      `<div class="muted">${esc(s.id)} ${esc(s.agent || '')} · ${esc(s.model || '')}</div>`).join('') + '</div>';
  const pr = snap.providers || {};
  const keysOn = Object.entries(pr.keys || {}).filter(([, v]) => v === 'set').length;
  const keysAll = Object.keys(pr.keys || {}).length;
  $('#card-providers .body').innerHTML =
    kv('ключей задано', keysOn + ' / ' + keysAll) +
    kv('моделей ollama', (pr.ollama?.models || []).length) +
    kv('загружено моделей', (pr.ollama?.running || []).length) +
    kv('блокировок (эвристика)', (pr.blockedHints || []).length) +
    kv('Gordon сессия', (pr.gordon?.session_id || '—').slice(0, 12)) +
    kv('Lab100', pr.lab100?.available ? 'доступен' : 'недоступен') +
    (pr.lab100?.status || '').split('\n').filter((l) => /квота/.test(l)).slice(0, 6)
      .map((l) => `<div class="muted">${esc(l.trim())}</div>`).join('') +
    (pr.ollama?.running || []).map((m) => `<span class="tag">${esc(m)}</span>`).join('') +
    (pr.firecrawl_status ? `<div class="muted" style="margin-top:5px">${esc(pr.firecrawl_status.slice(0, 180))}</div>` : '');
  const wd = snap.sources?.watchdog || {};
  $('#card-daemons .body').innerHTML =
    kv('watchdog', wd.phase || '—') + kv('heartbeat', wd.heartbeatAt || '—') +
    kv('opencode обнаружен', wd.opencodeDetected ? 'да' : 'нет') +
    kv('открытых заявок', snap.stats?.openTickets ?? '—') +
    kv('свободно RAM', wd.resourceThrottle?.freeMemPct != null ? wd.resourceThrottle.freeMemPct + '%' : '—') +
    kv('режим дросселя', wd.resourceThrottle?.mode || '—') +
    kv('reaper', wd.policy?.reaper || '—');
  const alerts = [];
  (snap.nodes || []).filter((n) => ['fault', 'need-guard'].includes(n.state))
    .forEach((n) => alerts.push(`${STATE_LABEL[n.state]}: ${n.label}`));
  if ((snap.stats?.openTickets || 0) > 0) alerts.push('открытых заявок: ' + snap.stats.openTickets);
  (hw.disks || []).filter((d) => d.percent > 90).forEach((d) => alerts.push(`диск ${d.mount} заполнен на ${p(d.percent)}%`));
  $('#alerts').innerHTML = alerts.map((a) => `<span class="alert">${esc(a)}</span>`).join('');
  $('#footer-stat').textContent = `${snap.stats?.nodes || 0} узлов · ${snap.stats?.edges || 0} связей · ${snap.stats?.openTickets || 0} заявок`;
  $('#updated').textContent = 'обновлено ' + (snap.collectedAt || '').slice(11, 19);
}

/* ---------- кнопки и загрузка ---------- */
function applyFilterButtons() {
  const idleBtn = $('#filterIdle'), unloadedBtn = $('#filterUnloaded');
  idleBtn.textContent = filters.idle ? 'спящие: показать' : 'спящие: скрыть';
  idleBtn.classList.toggle('off', filters.idle);
  unloadedBtn.textContent = filters.unloaded ? 'неактивные: показать' : 'неактивные: скрыть';
  unloadedBtn.classList.toggle('off', filters.unloaded);
}
async function load(force = false) {
  try {
    const r = await fetch(force ? '/api/refresh' : '/api/state', { cache: 'no-store' });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const snap = await r.json();
    current = snap;
    buildLegend(snap);
    renderGraph(snap);
    renderPanels(snap);
    renderDetail(snap);
  } catch (e) {
    $('#updated').textContent = 'ошибка: ' + e.message;
  }
}
filters = { ...filters, ...lsGet(LS_FILTERS, {}) };
applyFilterButtons();
$('#filterIdle').addEventListener('click', () => {
  filters.idle = !filters.idle;
  lsSet(LS_FILTERS, filters);
  applyFilterButtons();
  renderGraph(current);
});
$('#filterUnloaded').addEventListener('click', () => {
  filters.unloaded = !filters.unloaded;
  lsSet(LS_FILTERS, filters);
  applyFilterButtons();
  renderGraph(current);
});
$('#resetLayout').addEventListener('click', () => {
  try { localStorage.removeItem(LS_LAYOUT); } catch (_) {}
  positions = {};
  renderGraph(current);
});
$('#refresh').addEventListener('click', () => load(true));
let resizeTimer = null;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => { positions = {}; try { localStorage.removeItem(LS_LAYOUT); } catch (_) {} renderGraph(current); }, 250);
});
load();
setInterval(() => load(false), 2000);
