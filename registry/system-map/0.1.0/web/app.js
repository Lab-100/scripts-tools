/* system-map UI: ванильный JS + SVG, без внешних библиотек. */
const $ = (s) => document.querySelector(s);
const svg = $('#graph');
const gEdges = $('#edges');
const gNodes = $('#nodes');
const tooltip = $('#tooltip');
let current = null;
let selected = null;

const STATE_LABEL = {
  active: 'работает', idle: 'простаивает', unloaded: 'выгружен',
  'need-guard': 'нужен, но недоступен', fault: 'упал', starting: 'подъём',
  blocked: 'ограничен', detached: 'фоновый', reaped: 'зачищен', unknown: 'неизвестно',
};

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

function buildLegend(snap) {
  const colors = snap.meta?.colors || {};
  $('#legend').innerHTML = Object.entries(STATE_LABEL)
    .filter(([k]) => colors[k])
    .map(([k, label]) => `<span><i class="dot" style="background:${colors[k]}"></i>${label}</span>`)
    .join('');
}

// Детерминированная раскладка: ядро в центре, остальные — по секторам вокруг.
function layout(nodes) {
  const W = svg.clientWidth || 1000, H = svg.clientHeight || 700;
  const cx = W / 2, cy = H / 2;
  const order = {
    core: 0, mcp: 1, service: 2, agent: 3, tool: 4,
    plugin: 5, session: 6, subagent: 7, model: 8, resource: 9, ui: 10,
  };
  const groups = {};
  nodes.forEach((n) => {
    const t = n.type || 'tool';
    (groups[t] ||= []).push(n);
  });
  const pos = {};
  const core = groups.core || [];
  core.forEach((n, i) => {
    const a = -Math.PI / 2 + (i * 2 * Math.PI) / Math.max(1, core.length);
    pos[n.id] = { x: cx + Math.cos(a) * 65, y: cy + Math.sin(a) * 58 };
  });
  const types = Object.keys(groups).filter((t) => t !== 'core').sort((a, b) => (order[a] ?? 20) - (order[b] ?? 20));
  types.forEach((type, ti) => {
    const arr = groups[type].slice().sort((a, b) => a.id.localeCompare(b.id));
    const radius = Math.min(W, H) * (0.20 + (ti % 4) * 0.085);
    const offset = ti * 0.55;
    arr.forEach((n, i) => {
      const a = offset + (i * 2 * Math.PI) / Math.max(1, arr.length);
      pos[n.id] = {
        x: Math.max(52, Math.min(W - 52, cx + Math.cos(a) * radius * 1.35)),
        y: Math.max(38, Math.min(H - 38, cy + Math.sin(a) * radius)),
      };
    });
  });
  return pos;
}

function shapeFor(n, x, y) {
  const c = n.color || '#64748b';
  const alarm = ['fault', 'need-guard'].includes(n.state) ? ' alarm' : '';
  const dim = n.state === 'unloaded' || n.state === 'reaped' ? ' opacity="0.5"' : '';
  if (['core', 'resource'].includes(n.type)) {
    const r = n.type === 'core' ? 17 : 14;
    return `<circle class="shape${alarm}" cx="${x}" cy="${y}" r="${r}" fill="${c}" stroke="#0b1220" stroke-width="2"${dim} filter="url(#glow)"/>`;
  }
  if (['agent', 'model'].includes(n.type)) {
    const s = 13;
    return `<path class="shape${alarm}" d="M ${x} ${y - s} L ${x + s} ${y} L ${x} ${y + s} L ${x - s} ${y} Z" fill="${c}" stroke="#0b1220" stroke-width="2"${dim}/>`;
  }
  const w = Math.max(52, Math.min(112, (n.label || '').length * 6.2 + 16)), h = 22;
  return `<rect class="shape${alarm}" x="${x - w / 2}" y="${y - h / 2}" width="${w}" height="${h}" rx="5" fill="${c}" stroke="#0b1220" stroke-width="2"${dim}/>`;
}

function renderGraph(snap) {
  let nodes = snap.nodes || [];
  if (!$('#showIdle').checked) nodes = nodes.filter((n) => n.state !== 'idle');
  if (!$('#showUnloaded').checked) nodes = nodes.filter((n) => n.state !== 'unloaded');
  const visible = new Set(nodes.map((n) => n.id));
  const pos = layout(nodes);
  const H = svg.clientHeight || 700, W = svg.clientWidth || 1000;
  svg.setAttribute('viewBox', `0 0 ${W} ${H}`);

  const edgeHtml = (snap.edges || []).filter((e) => visible.has(e.source) && visible.has(e.target)).map((e) => {
    const a = pos[e.source], b = pos[e.target];
    if (!a || !b) return '';
    const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
    const dx = b.x - a.x, dy = b.y - a.y;
    const bend = Math.min(35, Math.hypot(dx, dy) * 0.12);
    const len = Math.hypot(dx, dy) || 1;
    const qx = mx - (dy / len) * bend, qy = my + (dx / len) * bend;
    const cls = ['edge', e.kind || '', e.hot ? 'hot' : ''].join(' ');
    return `<path class="${cls}" d="M ${a.x.toFixed(1)} ${a.y.toFixed(1)} Q ${qx.toFixed(1)} ${qy.toFixed(1)} ${b.x.toFixed(1)} ${b.y.toFixed(1)}"/>`;
  }).join('');
  gEdges.innerHTML = edgeHtml;

  gNodes.innerHTML = nodes.map((n) => {
    const p = pos[n.id];
    const label = (n.label || '').slice(0, 17);
    return `<g class="node" data-id="${esc(n.id)}" transform="translate(${p.x.toFixed(1)},${p.y.toFixed(1)})">
      ${shapeFor(n, 0, 0)}
      <text class="node-label" x="0" y="32" text-anchor="middle">${esc(label)}</text>
    </g>`;
  }).join('');

  gNodes.querySelectorAll('.node').forEach((el) => {
    const n = nodes.find((x) => x.id === el.dataset.id);
    el.addEventListener('mouseenter', (ev) => {
      tooltip.innerHTML = `<b>${esc(n.label)}</b><br>состояние: ${esc(STATE_LABEL[n.state] || n.state)}<br>тип: ${esc(n.type)} · источник: ${esc(n.source)}<br>${esc(n.detail)}`;
      tooltip.style.display = 'block';
      moveTooltip(ev);
    });
    el.addEventListener('mousemove', moveTooltip);
    el.addEventListener('mouseleave', () => { tooltip.style.display = 'none'; });
    el.addEventListener('click', () => { selected = n.id; renderDetail(snap); });
  });
}
function moveTooltip(ev) {
  const r = svg.getBoundingClientRect();
  tooltip.style.left = Math.min(r.width - 300, ev.clientX - r.left + 12) + 'px';
  tooltip.style.top = Math.min(r.height - 100, ev.clientY - r.top + 12) + 'px';
}

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

  $('#card-gpu .body').innerHTML = '<div class="muted">загрузка GPU — общая по адаптерам; VRAM по WMI</div>' + (hw.gpu || []).map((g) =>
    kv('adapter', (g.name || '—').slice(0, 32)) +
    kv('загрузка', g.gpu_percent === null || g.gpu_percent === undefined ? '—' : p(g.gpu_percent) + '%') +
    (g.gpu_percent != null ? bar(g.gpu_percent, '#a855f7') : '') +
    kv('VRAM', g.vram_gb ? p(g.vram_gb) + ' ГБ' : '—') +
    kv('выделено', g.dedicated_mb != null ? p(g.dedicated_mb, 0) + ' МБ' : '—') +
    kv('драйвер', g.driver || '—') + '<hr style="border:0;border-top:1px solid #22334d">'
  ).join('') || '<span class="muted">нет данных</span>';

  $('#card-disks .body').innerHTML = (hw.disks || []).map((d) =>
    kv(d.mount, p(d.percent) + '% · free ' + p(d.free_gb) + ' ГБ') +
    bar(d.percent, d.percent > 90 ? '#ef4444' : '#38bdf8')
  ).join('') + (hw.io ? kv('I/O прочитано', p(hw.io.read_mb, 0) + ' МБ') + kv('I/O записано', p(hw.io.write_mb, 0) + ' МБ') : '');

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

$('#refresh').addEventListener('click', () => load(true));
$('#showIdle').addEventListener('change', () => current && renderGraph(current));
$('#showUnloaded').addEventListener('change', () => current && renderGraph(current));
window.addEventListener('resize', () => current && renderGraph(current));
load();
setInterval(() => load(false), 2000);
