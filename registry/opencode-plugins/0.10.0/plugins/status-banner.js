import { readFileSync } from "node:fs";

const STATE = "C:/Scripts/tools/mcp-watchdog/state/current.json";
const NODES = "C:/Scripts/tools/mcp-watchdog-guardian/state/current.json";
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

function readJson(p) {
	try {
		// current.json пишется демоном в UTF-8 С BOM — JSON.parse такой файл не берёт,
		// поэтому молча снимаем метку порядка байт (иначе баннер всегда «недоступен»).
		return JSON.parse(readFileSync(p, "utf8").replace(/^\uFEFF/, ""));
	} catch {
		return null;
	}
}

// Состояние узла важнее статуса: «выключен по требованию» — это unloaded (СЕРЫЙ),
// а не поломка. Плагин 0.5.0 показывал browsertool как FAIL, потому что не знал
// про state; здесь читаем state и переводим в человеческие слова.
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
	const bits = [`[${label} ${name}]`];
	if (c.val) bits[0] = `[${label} ${name} ${c.val}]`;
	if (name === "browsertool" || name === "monitor") {
		const intent = c.intent && c.intent !== "auto" ? `:${c.intent}` : "";
		bits[0] = `[${label} ${name}${intent}]`;
	}
	return bits[0];
}

const RULE = (() => {
	const s = readJson(STATE);
	const m = readJson(NODES);
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
})();

export const StatusBannerPlugin = async () => {
	return {
		"experimental.chat.system.transform": async (_input, output) => {
			if (!output || typeof output !== "object") return;
			const existing = Array.isArray(output.system) ? output.system : [];
			if (existing.includes(RULE)) return;
			output.system = [RULE, ...existing];
		},
	};
};

export default StatusBannerPlugin;
