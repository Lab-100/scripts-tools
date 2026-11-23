/* system-map 0.1.2 UI: ванильный JS + SVG, без внешних библиотек. */
const $ = (s) => document.querySelector(s);
const svg = $('#graph');
const gEdges = $('#edges');
const gNodes = $('#nodes');
const tooltip = $('#tooltip');

const LS_LAYOUT = 'system-map-layout-v1';
const LS_FILTERS = 'system-map-filters-v1';
const GAP = 6; // запас 1 px на округление координат до 0,1 — гарантирует ≥5 px на экране
const VIEW_PAD = 24;
const LOUPE_SIDE = 180;
const MIN_ZOOM = 0.5;
const MAX_ZOOM = 6;

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
let crossingCount = 0;
let layoutReset = false;
let baseViewBox = { x: 0, y: 0, w: 1000, h: 700 };
let viewBox = { ...baseViewBox };
let zoomFactor = 1;
let loupeOn = false;
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
function halfSizes(n) {
  const g = nodeGeometry(n);
  if (g.kind === 'ellipse') return { hx: g.rx, hy: g.ry };
  if (g.kind === 'diamond') return { hx: g.hw, hy: g.hh };
  return { hx: g.w / 2, hy: g.h / 2 };
}
function clampPoint(x, y, hx, hy, W, H) {
  const pad = 6;
  const loX = Math.min(hx + pad, W / 2), hiX = Math.max(W - hx - pad, W / 2);
  const loY = Math.min(hy + pad, H / 2), hiY = Math.max(H - hy - pad, H / 2);
  return { x: Math.max(loX, Math.min(hiX, x)), y: Math.max(loY, Math.min(hiY, y)) };
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
/* Считаем пересечения по тем же квадратичным кривым, что реально рисует
   drawEdges(): хорды между центрами дают неверную оценку «на экране». */
function orient(a, b, c) {
  const v = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
  return Math.abs(v) < 1e-9 ? 0 : (v > 0 ? 1 : -1);
}
function segmentsIntersect(a, b, c, d) {
  const o1 = orient(a, b, c), o2 = orient(a, b, d);
  const o3 = orient(c, d, a), o4 = orient(c, d, b);
  return o1 !== o2 && o3 !== o4;
}
function edgePolyline(a, b, bendSign, samples) {
  const dx = b.x - a.x, dy = b.y - a.y;
  const len = Math.hypot(dx, dy) || 1;
  const bend = Math.min(30, len * 0.1) * bendSign;
  const mx = (a.x + b.x) / 2 - (dy / len) * bend;
  const my = (a.y + b.y) / 2 + (dx / len) * bend;
  const pts = [];
  for (let k = 0; k <= samples; k++) {
    const t = k / samples, u = 1 - t;
    pts.push({ x: u * u * a.x + 2 * u * t * mx + t * t * b.x,
               y: u * u * a.y + 2 * u * t * my + t * t * b.y });
  }
  return pts;
}
function countCrossings(pos, edges, idx, samples = 8) {
  const seen = new Map();
  const curves = [];
  edges.forEach((e) => {
    const a = pos[idx[e.source]], b = pos[idx[e.target]];
    if (!a || !b) return;
    const key = [e.source, e.target].sort().join('|');
    const n = seen.get(key) || 0;
    seen.set(key, n + 1);
    curves.push({ e, pts: edgePolyline(a, b, n % 2 ? -1 : 1, samples) });
  });
  let total = 0;
  for (let i = 0; i < curves.length; i++) {
    for (let j = i + 1; j < curves.length; j++) {
      const e1 = curves[i].e, e2 = curves[j].e;
      if (e1.source === e2.source || e1.target === e2.target ||
          e1.source === e2.target || e1.target === e2.source) continue;
      let hit = false;
      for (let p = 0; p < samples && !hit; p++) {
        for (let q = 0; q < samples; q++) {
          if (segmentsIntersect(curves[i].pts[p], curves[i].pts[p + 1],
                                curves[j].pts[q], curves[j].pts[q + 1])) { hit = true; break; }
        }
      }
      if (hit) total++;
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
  const sizes = nodes.map(halfSizes);
  const arr = nodes.map((x) => ({ x: pos[x.id]?.x ?? W / 2, y: pos[x.id]?.y ?? H / 2 }));
  for (let it = 0; it < iterations; it++) {
    const disp = Array.from({ length: n }, () => ({ x: 0, y: 0 }));
    for (let i = 0; i < n; i++) {
      for (let j = i + 1; j < n; j++) {
        let dx = arr[i].x - arr[j].x, dy = arr[i].y - arr[j].y;
        let d2 = dx * dx + dy * dy + 0.01;
        let d = Math.sqrt(d2);
        if (d < 1) { dx = Math.cos(i + phase) || 1; dy = Math.sin(i + phase) || 1; d = 1; d2 = 1; }
        const minD = Math.hypot(sizes[i].hx, sizes[i].hy) + Math.hypot(sizes[j].hx, sizes[j].hy) + GAP;
        let f = Math.min(180, 2600 / d2);
        if (d < minD) f = Math.max(f, Math.min(180, (minD - d) * 0.6));
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
      const c = clampPoint(arr[i].x, arr[i].y, sizes[i].hx, sizes[i].hy, W, H);
      arr[i].x = c.x;
      arr[i].y = c.y;
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
function separateOverlaps(nodes, pos, W, H, fixedIds = null) {
  const sizes = new Map(nodes.map((n) => [n.id, halfSizes(n)]));
  const list = nodes.filter((n) => validPoint(pos[n.id]));
  let changed = false;
  for (let it = 0; it < 80; it++) {
    let overlap = false;
    for (let i = 0; i < list.length; i++) {
      for (let j = i + 1; j < list.length; j++) {
        const a = list[i], b = list[j];
        const pa = pos[a.id], pb = pos[b.id];
        const sa = sizes.get(a.id), sb = sizes.get(b.id);
        let dx = pa.x - pb.x, dy = pa.y - pb.y;
        const ox = sa.hx + sb.hx + GAP - Math.abs(dx);
        const oy = sa.hy + sb.hy + GAP - Math.abs(dy);
        if (ox <= 0 || oy <= 0) continue;
        const aFixed = fixedIds?.has(a.id), bFixed = fixedIds?.has(b.id);
        if (aFixed && bFixed) continue;
        if (Math.abs(dx) < 0.001) dx = (i % 2 ? 1 : -1) * 0.001;
        if (Math.abs(dy) < 0.001) dy = (j % 2 ? 1 : -1) * 0.001;
        const moveA = aFixed ? 0 : (bFixed ? 1 : 0.5);
        const moveB = bFixed ? 0 : (aFixed ? 1 : 0.5);
        if (ox <= oy) {
          const d = (dx >= 0 ? 1 : -1) * ox;
          pa.x += d * moveA; pb.x -= d * moveB;
        } else {
          const d = (dy >= 0 ? 1 : -1) * oy;
          pa.y += d * moveA; pb.y -= d * moveB;
        }
        overlap = true;
        changed = true;
      }
    }
    list.forEach((n) => {
      const s = sizes.get(n.id);
      const c = clampPoint(pos[n.id].x, pos[n.id].y, s.hx, s.hy, W, H);
      if (c.x !== pos[n.id].x || c.y !== pos[n.id].y) {
        pos[n.id].x = c.x;
        pos[n.id].y = c.y;
        changed = true;
      }
    });
    if (!overlap) break;
  }
  return changed;
}
function validPoint(p) {
  return !!p && Number.isFinite(p.x) && Number.isFinite(p.y);
}
function visibleNodes(snap) {
  let nodes = (snap.nodes || []).slice();
  if (filters.idle) nodes = nodes.filter((n) => n.state !== 'idle');
  if (filters.unloaded) nodes = nodes.filter((n) => !['unloaded', 'reaped'].includes(n.state));
  return nodes;
}
function ensurePositions(snap) {
  const nodes = snap.nodes || [], edges = snap.edges || [];
  const W = svg.clientWidth || 1000, H = svg.clientHeight || 700;
  const resetting = layoutReset;
  layoutReset = false;
  if (resetting) positions = {};
  const saved = lsGet(LS_LAYOUT, null);
  if (!resetting && saved && saved.pos) {
    for (const [id, p] of Object.entries(saved.pos)) {
      if (nodes.some((n) => String(n.id) === id) && validPoint(p) && !validPoint(positions[id])) {
        positions[id] = { x: p.x, y: p.y };
      }
    }
  }
  const missing = nodes.filter((n) => !validPoint(positions[n.id]));
  const missingIds = new Set(missing.map((n) => n.id));
  if (missing.length) {
    const subEdges = edges.filter((e) => missingIds.has(e.source) && missingIds.has(e.target));
    Object.assign(positions, optimizeLayout(missing, subEdges, W, H).pos);
  }
  positions = Object.fromEntries(nodes.map((n) => [n.id, { x: positions[n.id].x, y: positions[n.id].y }]));
  // Разделяем все узлы: сохранённая раскладка старшей версии могла содержать наложения.
  const moved = separateOverlaps(nodes, positions, W, H);
  const idx = {};
  nodes.forEach((n, i) => { idx[n.id] = i; });
  if (resetting || missing.length || moved || !Number.isFinite(saved?.crossings)) {
    crossingCount = countCrossings(positions, edges, idx);
  } else {
    crossingCount = saved.crossings;
  }
}

/* ---------- вписывание, масштаб и лупа ---------- */
function updateBaseViewBox(nodes) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  nodes.forEach((n) => {
    const p = positions[n.id];
    if (!validPoint(p)) return;
    const s = halfSizes(n);
    minX = Math.min(minX, p.x - s.hx);
    maxX = Math.max(maxX, p.x + s.hx);
    minY = Math.min(minY, p.y - s.hy);
    maxY = Math.max(maxY, p.y + s.hy);
  });
  if (!Number.isFinite(minX)) {
    baseViewBox = { x: 0, y: 0, w: svg.clientWidth || 1000, h: svg.clientHeight || 700 };
  } else {
    baseViewBox = {
      x: minX - VIEW_PAD, y: minY - VIEW_PAD,
      w: Math.max(1, maxX - minX + 2 * VIEW_PAD),
      h: Math.max(1, maxY - minY + 2 * VIEW_PAD),
    };
  }
}
function writeViewBox() {
  svg.setAttribute('viewBox', `${viewBox.x.toFixed(2)} ${viewBox.y.toFixed(2)} ${viewBox.w.toFixed(2)} ${viewBox.h.toFixed(2)}`);
  svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
}
function refreshViewBox() {
  const cx = viewBox.x + viewBox.w / 2, cy = viewBox.y + viewBox.h / 2;
  const bx = baseViewBox.x + baseViewBox.w / 2, by = baseViewBox.y + baseViewBox.h / 2;
  const w = baseViewBox.w / zoomFactor, h = baseViewBox.h / zoomFactor;
  viewBox = { x: bx + (cx - bx) - w / 2, y: by + (cy - by) - h / 2, w, h };
  writeViewBox();
}
function setZoom(next, anchor) {
  next = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, next));
  if (Math.abs(next - zoomFactor) < 1e-6) return;
  const a = anchor || { x: viewBox.x + viewBox.w / 2, y: viewBox.y + viewBox.h / 2 };
  const rx = (a.x - viewBox.x) / viewBox.w, ry = (a.y - viewBox.y) / viewBox.h;
  const w = baseViewBox.w / next, h = baseViewBox.h / next;
  viewBox = { x: a.x - rx * w, y: a.y - ry * h, w, h };
  zoomFactor = next;
  writeViewBox();
}
function fitViewBox() {
  zoomFactor = 1;
  viewBox = { ...baseViewBox };
  writeViewBox();
}
function ensureGraphLayer() {
  let layer = $('#graphLayer');
  if (!layer) {
    layer = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    layer.id = 'graphLayer';
    svg.insertBefore(layer, svg.firstChild);
    layer.appendChild(gEdges);
    layer.appendChild(gNodes);
  }
  return layer;
}
function initLoupe() {
  const loupe = $('#loupe'), loupeSvg = $('#loupeSvg'), button = $('#loupeToggle');
  if (loupeSvg && !loupeSvg.querySelector('use')) {
    const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', '#graphLayer');
    use.setAttributeNS('http://www.w3.org/1999/xlink', 'xlink:href', '#graphLayer');
    loupeSvg.appendChild(use);
  }
  button?.addEventListener('click', () => {
    loupeOn = !loupeOn;
    loupe?.classList.toggle('on', loupeOn);
    button.classList.toggle('on', loupeOn);
    button.textContent = loupeOn ? 'лупа: вкл' : 'лупа: выкл';
    loupe?.setAttribute('aria-hidden', loupeOn ? 'false' : 'true');
  });
  svg.addEventListener('pointermove', (ev) => {
    if (!loupeOn || !loupeSvg) return;
    const p = svgPoint(ev);
    const side = LOUPE_SIDE / zoomFactor;
    loupeSvg.setAttribute('viewBox',
      `${(p.x - side / 2).toFixed(2)} ${(p.y - side / 2).toFixed(2)} ${side.toFixed(2)} ${side.toFixed(2)}`);
    const r = svg.getBoundingClientRect();
    loupe.style.left = (ev.clientX - r.left - LOUPE_SIDE / 2) + 'px';
    loupe.style.top = (ev.clientY - r.top - LOUPE_SIDE / 2) + 'px';
  });
}
function persistLayout() {
  lsSet(LS_LAYOUT, { pos: positions, baseViewBox, crossings: crossingCount });
}

/* ---------- отрисовка графа ---------- */
function drawEdges(snap, visible) {
  const parts = [];
  const parallel = new Map();
  (snap.edges || []).forEach((e) => {
    if (!visible.has(e.source) || !visible.has(e.target)) return;
    const a = positions[e.source], b = positions[e.target];
    if (!a || !b) return;
    const key = [e.source, e.target].sort().join('|');
    const n = parallel.get(key) || 0;
    parallel.set(key, n + 1);
    const pts = edgePolyline(a, b, n % 2 ? -1 : 1, 8);
    const mx = pts[4].x, my = pts[4].y;
    const cls = ['edge', e.kind || '', e.hot ? 'hot' : ''].join(' ');
    parts.push(`<path class="${cls}" data-edge="${esc(e.source)}>${esc(e.target)}:${esc(e.kind || 'link')}:${n}" d="M ${a.x.toFixed(1)} ${a.y.toFixed(1)} Q ${mx.toFixed(1)} ${my.toFixed(1)} ${b.x.toFixed(1)} ${b.y.toFixed(1)}"/>`);
  });
  gEdges.innerHTML = parts.join('');
}
function renderGraph(snap) {
  if (!snap) return;
  ensurePositions(snap);
  const nodes = visibleNodes(snap);
  const visible = new Set(nodes.map((n) => n.id));
  const W = svg.clientWidth || 1000, H = svg.clientHeight || 700;
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
  updateBaseViewBox(nodes);
  if (zoomFactor === 1) fitViewBox(); else refreshViewBox();
  persistLayout();
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
function constrainDragTarget(x, y, nodes, W, H) {
  const g = halfSizes(drag.node);
  let px = x, py = y;
  for (let pass = 0; pass < 4; pass++) {
    let adjusted = false;
    nodes.forEach((other) => {
      if (other.id === drag.id || !validPoint(positions[other.id])) return;
      const s = halfSizes(other);
      const op = positions[other.id];
      const dx = px - op.x, dy = py - op.y;
      const ox = g.hx + s.hx + GAP - Math.abs(dx);
      const oy = g.hy + s.hy + GAP - Math.abs(dy);
      if (ox <= 0 || oy <= 0) return;
      if (ox <= oy) px += (dx >= 0 ? 1 : -1) * ox;
      else py += (dy >= 0 ? 1 : -1) * oy;
      adjusted = true;
    });
    if (!adjusted) break;
  }
  return clampPoint(px, py, g.hx, g.hy, W, H);
}
function onDragMove(ev) {
  if (!drag) return;
  const p = svgPoint(ev);
  const W = svg.clientWidth || 1000, H = svg.clientHeight || 700;
  const target = constrainDragTarget(p.x + drag.dx, p.y + drag.dy, visibleNodes(drag.snap), W, H);
  drag.moved = Math.max(drag.moved, Math.hypot(ev.clientX - drag.startX, ev.clientY - drag.startY));
  positions[drag.id] = target;
  drag.el.setAttribute('transform', `translate(${target.x.toFixed(1)},${target.y.toFixed(1)})`);
  drawEdges(drag.snap, new Set(visibleNodes(drag.snap).map((n) => n.id)));
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
  if (d.moved >= 4) {
    const W = svg.clientWidth || 1000, H = svg.clientHeight || 700;
    const nodes = visibleNodes(d.snap);
    separateOverlaps(nodes, positions, W, H);
    const idx = {};
    nodes.forEach((n, i) => { idx[n.id] = i; });
    crossingCount = countCrossings(positions, d.snap.edges || [], idx);
    gNodes.querySelectorAll('.node').forEach((el) => {
      const p = positions[el.dataset.id];
      if (p) el.setAttribute('transform', `translate(${p.x.toFixed(1)},${p.y.toFixed(1)})`);
    });
    drawEdges(d.snap, new Set(nodes.map((n) => n.id)));
    updateBaseViewBox(nodes);
    refreshViewBox();
    updateFooterStat();
  } else {
    selected = d.id;
    renderDetail(d.snap);
  }
  persistLayout();
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
function updateFooterStat() {
  const s = current?.stats || {};
  $('#footer-stat').textContent = `${s.nodes || 0} узлов · ${s.edges || 0} связей · ${s.openTickets || 0} заявок · пересечений: ${crossingCount}`;
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
  updateFooterStat();
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
ensureGraphLayer();
initLoupe();
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
  layoutReset = true;
  positions = {};
  zoomFactor = 1;
  renderGraph(current);
  fitViewBox();
  updateFooterStat();
});
$('#zoomIn').addEventListener('click', () => setZoom(zoomFactor * 1.25));
$('#zoomOut').addEventListener('click', () => setZoom(zoomFactor / 1.25));
$('#zoomFit').addEventListener('click', fitViewBox);
svg.addEventListener('wheel', (ev) => {
  ev.preventDefault();
  setZoom(zoomFactor * (ev.deltaY < 0 ? 1.15 : 1 / 1.15), svgPoint(ev));
}, { passive: false });
$('#refresh').addEventListener('click', () => load(true));
let resizeTimer = null;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (!current) return;
    updateBaseViewBox(visibleNodes(current));
    refreshViewBox();
    persistLayout();
  }, 250);
});
load();
setInterval(() => load(false), 2000);
