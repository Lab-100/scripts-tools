// UTF-8-обёртка терминала для OpenCode V2.
// Добавляет префикс UTF-8 к любой shell-команде и задаёт PYTHONUTF8/IOENCODING.
//
// V2-хуки:
//   tool.execute.before  -> ctx.tool.hook("execute.before", ...)
//   shell.env            -> ctx.shell.hook("create.before", ...)
//   event (session.idle) -> ctx.event.subscribe()
// Аргументы вызова инструмента лежат в событии (event.input или event.args),
// и мутируются ПО МЕСТУ (event.input.command = ...).

import { appendFileSync, mkdirSync } from "node:fs";

// Префикс UTF-8 для любой shell-команды: PowerShell по умолчанию отдаёт русский
// текст в OEMCP 866, клиент опенкода читает UTF-8 — получаются кракозябры.
const PRESET =
	"[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;" +
	"[Console]::InputEncoding=[System.Text.Encoding]::UTF8;" +
	"$OutputEncoding=[System.Text.Encoding]::UTF8;" +
	"$env:PYTHONUTF8='1';" +
	"$env:PYTHONIOENCODING='utf-8';\n";

const MARK = "[Console]::OutputEncoding";

// Каталог журнала переносимый: задаётся переменной INVR_LOG_DIR, иначе —
// каталог пользователя.
const LOG_DIR =
	process.env.INVR_LOG_DIR ||
	(process.env.USERPROFILE ? process.env.USERPROFILE + "\\.devstation\\logs" : ".");
const LOG_FILE = LOG_DIR + "\\utf8-console-plugin.log";

function mark(message) {
	try {
		mkdirSync(LOG_DIR, { recursive: true });
		appendFileSync(LOG_FILE, new Date().toISOString() + " " + message + "\n", "utf8");
	} catch {}
}

// Имя shell-инструмента различается между сборками.
function isShell(tool) {
	if (typeof tool !== "string") return false;
	const t = tool.toLowerCase();
	return t === "bash" || t === "shell" || t === "powershell" || t === "run";
}

let hooks = 0;
let shell = 0;
let wrapped = 0;

export default {
	id: "utf8-console",
	async setup(ctx) {
		mark("loaded v1.0.0 (V2)");

		await ctx.tool.hook("execute.before", (event) => {
			hooks += 1;
			const tool = event && event.tool !== undefined ? String(event.tool) : "?";
			if (!isShell(tool)) return;

			shell += 1;
			// Аргументы события: в V2 обычно event.input; держим резерв event.args.
			const args = event && (event.input || event.args);
			if (!args || typeof args !== "object") {
				if (shell <= 20) mark("noargs#" + shell + " tool=" + tool);
				return;
			}
			const command = args.command;
			if (typeof command !== "string" || command.length === 0) {
				if (shell <= 20) {
					mark("nocmd#" + shell + " type=" + typeof command + " keys=" + Object.keys(args).join(","));
				}
				return;
			}
			if (command.startsWith(MARK)) return; // уже с префиксом — не дублируем

			try {
				args.command = PRESET + command;
				if (args.command.startsWith(MARK)) {
					wrapped += 1;
					if (wrapped <= 5) mark("wrapped#" + wrapped + " ok len=" + command.length);
				} else {
					mark("verify-fail#" + shell + " присваивание не подтверждено");
				}
			} catch (e) {
				mark("assign-fail#" + shell + " " + (e && e.message ? e.message : String(e)));
			}
		});

		// Переменные окружения для shell-вызовов (python и терминалы).
		await ctx.shell.hook("create.before", (event) => {
			if (event && event.env) {
				event.env.PYTHONUTF8 = "1";
				event.env.PYTHONIOENCODING = "utf-8";
			}
		});

		// Признак жизни и накопленные счётчики.
		const controller = new AbortController();
		void (async () => {
			try {
				for await (const ev of ctx.event.subscribe({ signal: controller.signal })) {
					if (ev && ev.type === "session.idle") {
						mark("idle hooks=" + hooks + " shell=" + shell + " wrapped=" + wrapped);
					}
				}
			} catch {}
		})();

		return () => controller.abort();
	},
};
