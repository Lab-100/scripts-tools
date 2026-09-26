import { readFileSync } from "node:fs";

const STATE = "C:/Scripts/tools/mcp-watchdog/state/current.json";
const SERVERS = ["local-llm", "firecrawl", "MCP_DOCKER", "ollama", "browsertool", "invr-stack"];

function readState() {
	try {
		return JSON.parse(readFileSync(STATE, "utf8"));
	} catch {
		return null;
	}
}

const RULE = (() => {
	const s = readState();
	const lines = ["СВОДКА ИНФРАСТРУКТУРЫ (актуальна, автообновление демоном mcp-watchdog):"];
	if (s && s.checks) {
		const parts = SERVERS.map((n) => {
			const c = s.checks[n];
			const st = c && c.status === "ok" ? "ok" : "FAIL";
			if (n === "browsertool" && c && c.detail) {
				const m = /интент:\s*(\w+)/.exec(c.detail);
				if (m) return `browsertool:${st}(интент:${m[1]})`;
			}
			return `${n}:${st}`;
		});
		lines.push(parts.join(" | "));
		lines.push(`Открытые тикеты: ${(s.openTickets && s.openTickets.length) ? s.openTickets.join(", ") : "нет"}`);
	} else {
		lines.push("статусы недоступны (current.json не читается) — проверить демон mcp-watchdog");
	}
	lines.push("Сигнализация в интерфейсе: ОБЯЗАТЕЛЬНО в начале КАЖДОГО ответа выводить компактную строку статусов, например: [ok local-llm] [ok firecrawl] [ok MCP_DOCKER] [ok ollama] [ok browsertool] [ok invr-stack].");
	lines.push("Активация командой: «подними <сервис>» (поднять/перезапустить), «browsertool up/down» (надзор демона), «статус» (подробная сводка).");
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