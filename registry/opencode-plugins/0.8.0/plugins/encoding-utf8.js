const ENCODING_RULE = [
	"КОДИРОВКА — ОБЯЗАТЕЛЬНОЕ ИСПОЛНЕНИЕ (без кракозябр):",
	"1. Никогда не воспроизводи кракозябры (искажённый текст: Ð, Ñ, Ã, �) в ответах, выдержках, логах и терминальных сообщениях.",
	"2. Если вывод программы пришёл в искажённой кодировке — распознай исходную кодировку и приведи текст к корректному UTF-8; если распознать нельзя — явно скажи, что вывод повреждён, и не пытайся «пересказать» мусор как содержательный текст.",
	"3. При перенаправлении/перезаписи вывода (out-file, кодировки, байты) явно задавай UTF-8, а не кодовую страницу.",
	"4. Русский текст в комментариях, рассуждениях и ответах — всегда в корректной UTF-8 кириллице.",
].join("\n");

export const EncodingUtf8Plugin = async () => {
	return {
		"experimental.chat.system.transform": async (_input, output) => {
			if (!output || typeof output !== "object") return;
			const existing = Array.isArray(output.system) ? output.system : [];
			if (existing.includes(ENCODING_RULE)) return;
			output.system = [ENCODING_RULE, ...existing];
		},
	};
};

export default EncodingUtf8Plugin;
