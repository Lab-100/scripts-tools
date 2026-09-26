import { appendFileSync, mkdirSync } from "node:fs";

const PRESET =
	"[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;" +
	"[Console]::InputEncoding=[System.Text.Encoding]::UTF8;" +
	"$OutputEncoding=[System.Text.Encoding]::UTF8;" +
	"$env:PYTHONUTF8='1';" +
	"$env:PYTHONIOENCODING='utf-8';\n";

const LOG_DIR = "C:\\Scripts\\Logs";
const LOG_FILE = LOG_DIR + "\\utf8-console-plugin.log";

function mark(message) {
	try {
		mkdirSync(LOG_DIR, { recursive: true });
		appendFileSync(LOG_FILE, new Date().toISOString() + " " + message + "\n", "utf8");
	} catch {}
}

let wrapped = 0;

export const Utf8ConsolePlugin = async () => {
	mark("loaded");
	return {
		"tool.execute.before": async (input, output) => {
			if (!input || input.tool !== "bash") return;
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
	};
};

export default Utf8ConsolePlugin;
