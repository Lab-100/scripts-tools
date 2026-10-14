// Плагин-баннер инфраструктуры для OpenCode V2.
// V2: export default { id, setup(ctx) }, баннер встраивается в системный промпт
// через ctx.session.hook("context", ...) и обновляется на каждом запросе.
//
// Пути к состоянию выводим из INVR_TOOLS_ROOT (переносимость), с откатом на
// каталог пользователя. В прошлой версии здесь был жёстко зашит C:\Scripts\tools\...
// — на этой машине такого пути нет, из-за чего баннер всегда был «недоступен».

import { readFileSync } from "node:fs";

const TOOLS_ROOT =
	process.env.INVR_TOOLS_ROOT ||
	(process.env.USERPROFILE ? process.env.USERPROFILE + "\\.devstation\\tools" : "");

const STATE_CANDIDATES = [
	TOOLS_ROOT ? TOOLS_ROOT + "\\mcp-watchdog\\state\\current.json" : "",
	process.env.USERPROFILE ? process.env.USERPROFILE + "\\.devstation\\tools\\mcp-watchdog\\state\\current.json" : "",
	"C:/Scripts/tools/mcp-watchdog/state/current.json",
].filter(Boolean);

const NODES_CANDIDATES = [
	TOOLS_ROOT ? TOOLS_ROOT + "\\mcp-watchdog-guardian\\state\\current.json" : "",
	process.env.USERPROFILE ? process.env.USERPROFILE + "\\.devstation\\tools\\mcp-watchdog-guardian\\state\\current.json" : "",
	"C:/Scripts/tools/mcp-watchdog-guardian/state/current.json",
].filter(Boolean);

const SERVERS = [
	"local-llm",
	"firecrawl",
	"MCP_DOCKER",
	"ollama",
	"browsertool",
	"invr-stack",
	"guardian",
	"monitor",
];

function readFirst(paths) {
	for (const p of paths) {
		try {
			// current.json пишется демоном в UTF-8 С BOM — JSON.parse такой файл не
			// берёт, поэтому молча снимаем метку порядка байт.
			return JSON.parse(readFileSync(p, "utf8").replace(/^\uFEFF/, ""));
		} catch {}
	}
	return null;
}

// «Выключен по требованию» — это unloaded (СЕРЫЙ), а не поломка.
const STATE_RU = {
	active: "ок",
	idle: "свободен",
	unloaded: "выгружен",
	"need-guard": "нужен",
	fault: "СЛОМАНО",
};

function nodeTag(name, c) {
	if (!c) return `[нет данных ${name}]`;
	const st = c.state || (c.status === "ok" ? "active" : "fault");
	const label = STATE_RU[st] || st;
	let tag = `[${label} ${name}]`;
	if (c.val) tag = `[${label} ${name} ${c.val}]`;
	if (name === "browsertool" || name === "monitor") {
		const intent = c.intent && c.intent !== "auto" ? `:${c.intent}` : "";
		tag = `[${label} ${name}${intent}]`;
	}
	return tag;
}

const BANNER_MARK = "СВОДКА ИНФРАСТРУКТУРЫ";

function buildBanner() {
	const s = readFirst(STATE_CANDIDATES);
	const m = readFirst(NODES_CANDIDATES);
	const lines = ["СВОДКА ИНФРАСТРУКТУРЫ (актуальна, автообновление демоном mcp-watchdog):"];
	if (s && s.checks) {
		lines.push(SERVERS.map((n) => nodeTag(n, s.checks[n])).join(" "));
		const tickets = s.openTickets && s.openTickets.length ? s.openTickets.join(", ") : "нет";
		lines.push(`Открытые тикеты: ${tickets}`);
		const cands =
			s.unloadCandidates && s.unloadCandidates.length
				? s.unloadCandidates.map((c) => `${c.id}=${c.val}%`).join(", ")
				: "нет";
		lines.push(`Кандидаты на выгрузку: ${cands} (решает владелец, демон не завершает ничего сам)`);
	} else {
		lines.push("статусы недоступны (current.json не читается) — проверить демон mcp-watchdog");
	}
	if (m) {
		const mon = m.monitor || {};
		const wd = m.watchdog || {};
		const ages = mon.nodesAgeSec === null || mon.nodesAgeSec === undefined ? "?" : mon.nodesAgeSec;
		lines.push(
			`Зеркало монитора: живой=${mon.alive ? "да" : "нет"} (nodes.json ${ages}s назад), демон: живой=${wd.alive ? "да" : "нет"}`,
		);
	}
	lines.push(
		"Сигнализация в интерфейсе: ОБЯЗАТЕЛЬНО в начале КАЖДОГО ответа выводить компактную строку статусов, например: [ок local-llm] [ок firecrawl] [ок MCP_DOCKER] [ок ollama] [выгружен browsertool:none] [ок invr-stack] [ок guardian] [ок monitor].",
	);
	lines.push(
		"Состояния узлов: ок/свободен = работает; выгружен = «по требованию», НЕ поломка (не поднимаем); нужен = нужен прямо сейчас, упал; СЛОМАНО = упал и ждут. Автоматически ничего не выгружается: решение о завершении за владельцем узла. Ядро (oc, watchdog, guardian, monitor) выгрузке не подлежит.",
	);
	lines.push(
		"Активация командой: «подними <сервис>» (поднять/перезапустить), «browsertool up/down» (надзор демона), «статус» (подробная сводка).",
	);
	return lines.join("\n");
}

function blockText(block) {
	if (typeof block === "string") return block;
	if (block && typeof block.text === "string") return block.text;
	return "";
}

// Кэш баннера: состояние меняется демоном, но не чаще, чем нужно модели.
let cached = null;
let cachedAt = 0;
const CACHE_MS = 5000;

export default {
	id: "status-banner",
	async setup(ctx) {
		await ctx.session.hook("context", (event) => {
			const system = event && event.system;
			if (!Array.isArray(system)) return;
			const now = Date.now();
			if (!cached || now - cachedAt > CACHE_MS) {
				try {
					cached = buildBanner();
				} catch {
					cached = null;
				}
				cachedAt = now;
			}
			if (typeof cached !== "string" || !cached) return;
			if (system.some((b) => blockText(b).includes(BANNER_MARK))) return;
			system.unshift({ type: "text", text: cached });
		});
	},
};
