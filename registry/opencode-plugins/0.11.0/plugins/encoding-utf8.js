// Плагин кодировки для OpenCode V2: правило против кракозябр.
// V2: export default { id, setup(ctx) }, правило встраивается через
// ctx.session.hook("context", ...) на каждом запросе к модели.

const ENCODING_RULE = [
	"КОДИРОВКА — ОБЯЗАТЕЛЬНОЕ ИСПОЛНЕНИЕ (без кракозябр):",
	"1. Никогда не воспроизводи кракозябры (искажённый текст: Ð, Ñ, Ã, �) в ответах, выдержках, логах и терминальных сообщениях.",
	"2. Если вывод программы пришёл в искажённой кодировке — распознай исходную кодировку и приведи текст к корректному UTF-8; если распознать нельзя — явно скажи, что вывод повреждён, и не пытайся «пересказать» мусор как содержательный текст.",
	"3. При перенаправлении/перезаписи вывода (out-file, кодировки, байты) явно задавай UTF-8, а не кодовую страницу.",
	"4. Русский текст в комментариях, рассуждениях и ответах — всегда в корректной UTF-8 кириллице.",
].join("\n");

const MARK = "КОДИРОВКА — ОБЯЗАТЕЛЬНОЕ ИСПОЛНЕНИЕ";

function blockText(block) {
	if (typeof block === "string") return block;
	if (block && typeof block.text === "string") return block.text;
	return "";
}

export default {
	id: "encoding-utf8",
	async setup(ctx) {
		await ctx.session.hook("context", (event) => {
			const system = event && event.system;
			if (!Array.isArray(system)) return;
			if (system.some((b) => blockText(b).includes(MARK))) return;
			system.unshift({ type: "text", text: ENCODING_RULE });
		});
	},
};
