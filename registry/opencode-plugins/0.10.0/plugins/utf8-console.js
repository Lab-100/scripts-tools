import { appendFileSync, mkdirSync } from "node:fs";

// Префикс UTF-8 для любой shell-команды: PowerShell по умолчанию отдаёт русский
// текст в OEMCP 866, клиент opencode читает UTF-8 — получаются кракозябры.
const PRESET =
	"[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;" +
	"[Console]::InputEncoding=[System.Text.Encoding]::UTF8;" +
	"$OutputEncoding=[System.Text.Encoding]::UTF8;" +
	"$env:PYTHONUTF8='1';" +
	"$env:PYTHONIOENCODING='utf-8';\n";

// Маркер уже применённого префикса.
const MARK = "[Console]::OutputEncoding";

// Каталог журнала переносимый: задаётся переменной INVR_LOG_DIR, иначе —
// каталог пользователя. Конкретные пути машины в реестре не публикуются.
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

// Имя shell-инструмента различается между сборками opencode.
function isShell(tool) {
	if (typeof tool !== "string") return false;
	const t = tool.toLowerCase();
	return t === "bash" || t === "shell" || t === "powershell" || t === "run";
}

let hooks = 0;
let bash = 0;
let wrapped = 0;
let failed = 0;

export const Utf8ConsolePlugin = async () => {
	mark("loaded v0.9.0");
	return {
		// Мутация выполняется ПО МЕСТУ (output.args.command = ...), а не заменой
		// объекта output.args: в opencode 1.18.x args неизменяем по ссылке,
		// и подмена объекта молча терялась (счётчик wrapped оставался 0).
		// Любая ошибка пишется в журнал — иначе opencode глушит исключение хука.
		"tool.execute.before": async (input, output) => {
			hooks += 1;
			const tool = input && input.tool !== undefined ? String(input.tool) : "?";
			if (!isShell(tool)) return;

			bash += 1;
			const base = output ? output.args : undefined;
			if (!base || typeof base !== "object") {
				if (bash <= 20) mark("noargs#" + bash + " tool=" + tool + " outputType=" + typeof output);
				return;
			}
			const command = base.command;
			if (typeof command !== "string" || command.length === 0) {
				if (bash <= 20) {
					mark(
						"nocmd#" + bash +
							" type=" + typeof command +
							" keys=" + Object.keys(base).join(",") +
							" frozenArgs=" + Object.isFrozen(base) +
							" frozenOut=" + Object.isFrozen(output),
					);
				}
				return;
			}
			if (command.startsWith(MARK)) return; // уже с префиксом — не дублируем

			if (bash <= 20) {
				mark(
					"bash#" + bash +
						" len=" + command.length +
						" frozenArgs=" + Object.isFrozen(base) +
						" head=" + JSON.stringify(command.slice(0, 60)),
				);
			}
			try {
				base.command = PRESET + command;
				if (base.command.startsWith(MARK)) {
					wrapped += 1;
					if (wrapped <= 5) mark("wrapped#" + wrapped + " ok");
				} else {
					failed += 1;
					mark("verify-fail#" + bash + " присваивание не подтверждено");
				}
			} catch (e) {
				failed += 1;
				mark(
					"assign-fail#" + bash + " " +
						(e && e.message ? e.message : String(e)) +
						" frozenArgs=" + Object.isFrozen(base),
				);
			}
		},
		// Признак жизни и накопленные счётчики.
		event: async ({ event }) => {
			if (event && event.type === "session.idle") {
				mark("idle hooks=" + hooks + " bash=" + bash + " wrapped=" + wrapped + " failed=" + failed);
			}
		},
		// Переменные окружения для shell-вызовов (python и терминалы).
		"shell.env": async (_input, output) => {
			output.env.PYTHONUTF8 = "1";
			output.env.PYTHONIOENCODING = "utf-8";
		},
	};
};

export default Utf8ConsolePlugin;