import { appendFileSync, mkdirSync } from "node:fs";

// Префикс UTF-8 для любой shell-команды: PowerShell по умолчанию отдаёт русский
// текст в OEMCP 866, клиент opencode читает UTF-8 — получаются кракозябры.
const PRESET =
	"[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;" +
	"[Console]::InputEncoding=[System.Text.Encoding]::UTF8;" +
	"$OutputEncoding=[System.Text.Encoding]::UTF8;" +
	"$env:PYTHONUTF8='1';" +
	"$env:PYTHONIOENCODING='utf-8';\n";

// Каталог журнала переносимый: задаётся переменной INVR_LOG_DIR, иначе —
// стандартный каталог состояния пользователя. Конкретные пути машины
// владельца в публичном реестре не публикуются.
const LOG_DIR =
	process.env.INVR_LOG_DIR ||
	(process.env.USERPROFILE
		? process.env.USERPROFILE + "\\.devstation\\logs"
		: ".");
const LOG_FILE = LOG_DIR + "\\utf8-console-plugin.log";

function mark(message) {
	try {
		mkdirSync(LOG_DIR, { recursive: true });
		appendFileSync(LOG_FILE, new Date().toISOString() + " " + message + "\n", "utf8");
	} catch {}
}

// Имя shell-инструмента различается между версиями opencode (bash/shell),
// сравниваем без учёта регистра и по набору известных имён.
function isShell(tool) {
	if (typeof tool !== "string") return false;
	const t = tool.toLowerCase();
	return t === "bash" || t === "shell" || t === "powershell" || t === "run";
}

let hooks = 0;
let wrapped = 0;
let events = 0;

export const Utf8ConsolePlugin = async () => {
	mark("loaded v0.8.0");
	return {
		// Диагностика: первые вызовы хука пишем в журнал с именем инструмента,
		// чтобы отличить "хук не вызывается" от "инструмент называется иначе".
		"tool.execute.before": async (input, output) => {
			hooks += 1;
			if (hooks <= 10) {
				const argsKeys =
					output && typeof output === "object" && output.args && typeof output.args === "object"
						? Object.keys(output.args).join(",")
						: "нет args";
				const toolName = input && input.tool !== undefined ? String(input.tool) : "?";
				mark("hook#before tool=" + toolName + " args=" + argsKeys);
			}
			if (!input || !isShell(input.tool)) return;
			if (!output || typeof output !== "object") return;
			const base = output.args;
			if (!base || typeof base !== "object") return;
			const command = base.command;
			if (typeof command !== "string" || command.length === 0) return;
			if (command.startsWith("[Console]::OutputEncoding")) return;
			output.args = { ...base, command: PRESET + command };
			wrapped += 1;
			if (wrapped <= 3) mark("wrapped#" + wrapped + " " + command.slice(0, 80));
		},
		// Признак жизни плагина и контроль накопления счётчиков.
		event: async ({ event }) => {
			events += 1;
			if (events === 1) mark("event#first type=" + (event && event.type ? event.type : "?"));
			if (events % 10 === 0) mark("events=" + events + " hooks=" + hooks + " wrapped=" + wrapped);
		},
		// Переменные окружения для shell-вызовов (AI-инструменты и терминалы).
		"shell.env": async (_input, output) => {
			output.env.PYTHONUTF8 = "1";
			output.env.PYTHONIOENCODING = "utf-8";
		},
	};
};

export default Utf8ConsolePlugin;