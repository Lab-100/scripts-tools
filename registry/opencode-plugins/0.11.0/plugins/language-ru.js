// Плагин языка для OpenCode V2 (движок 2.0.26+).
// V2: плагин — это export default { id, setup(ctx) }, а правило встраивается
// в системный промпт через ctx.session.hook("context", ...), который срабатывает
// НА КАЖДОМ запросе к модели (включая продолжения после вызовов инструментов).

const LANG_RULE = [
	"ЯЗЫК — ОБЯЗАТЕЛЬНОЕ ИСПОЛНЕНИЕ (РУССКИЙ по умолчанию; все сессии и агенты):",
	"1. ВСЕ внутренние рассуждения, планирование, разборы, thinking/reasoning, перебор вариантов и заметки в ходе работы веди ТОЛЬКО на русском языке (кириллица). Английский (или иной язык) в рассуждениях считается нарушением.",
	"2. Все комментарии, размышления, пояснения, сводки и ответы пользователю пиши по-русски (кириллица).",
	"3. Терминальные сообщения и сообщения для тестирования дублируй: сначала по-русски, затем по-английски (RU основной, EN дополнительно).",
	"4. Исключения (НЕ переводи): технический вывод программ и сервисов (JSON, логи, вывод CLI, коды ошибок, пути), имена команд и инструментов, цитаты исходных текстов и документов в оригинале.",
	"5. Ввод пользователя не переводи и не переписывай.",
	"6. Правило действует во всех сессиях, проектах, для модели Big Pickle и для всех агентов (включая субагентов) приложения OpenCode.",
	"7. Отступить от правила можно ТОЛЬКО по явному указанию пользователя в чате.",
	"8. ЧУЖАЯ РАСКЛАДКА (ввод набран русскими словами в иной языковой раскладке — латинице QWERTY, грузинской фонетической и т.п.): если текст пользователя выглядит бессмысленным набором символов чужого алфавита — СНАЧАЛА вызови инструмент layout-translate (детерминированный конвертер раскладок по позициям клавиш, БЕЗ догадок и творчества).",
	"9. После вызова layout-translate ОЦЕНИ результат: если среди вариантов есть осмысленный русский (или английский) текст — используй ЕГО как расшифровку ввода пользователя БЕЗ переспроса (положительная оценка: конвертер детерминирован).",
	"10. Если положительной оценки НЕТ (ни один вариант не осмыслен) ИЛИ инструмент недоступен — уточни текст у пользователя или расшифруй вручную по позициям клавиш.",
	"11. ПРОВЕРКА ЯЗЫКА ПЕРЕД ВЫВОДОМ (обязательный шаг): прежде чем положить ЛЮБОЙ текст в чат, проверь его язык. Если текст НЕ на русском (кроме исключений п.4) — сначала переведи его на русский и только потом отправляй. Никогда не отправляй в чат иностранный текст без перевода.",
	"12. ПРИКАЗ ПЕРЕД ОТВЕТОМ: начинай каждый свой ответ строкой-приказом «Отвечать и думать только по-русски» (формулировка свободная, смысл обязателен).",
].join("\n");

// Короткое «последнее слово» — ставится В КОНЕЦ системного промпта на каждом
// запросе. Нужно против сползания на английский в середине длинного ответа:
// модель сильнее всего следует последней инструкции.
const LANG_REMINDER = [
	"НАПОМИНАНИЕ О ЯЗЫКЕ (действует прямо сейчас, на каждом шаге, включая продолжения после вызовов инструментов):",
	"думай и пиши ТОЛЬКО по-русски. Прежде чем вывести текст — проверь его язык; если он не русский, переведи на русский и только потом выводи.",
	"Не переключайся на английский посреди ответа. Начни ответ строкой «Отвечать и думать только по-русски».",
].join(" ");

const RULE_MARK = "ЯЗЫК — ОБЯЗАТЕЛЬНОЕ ИСПОЛНЕНИЕ";

// ===== Детерминированный конвертер раскладок (БЕЗ ИИ; по позициям клавиш QWERTY) =====
const LAYOUT_FORWARD = {
	ru: {
		q: "й", w: "ц", e: "у", r: "к", t: "е", y: "н", u: "г", i: "ш", o: "щ", p: "з",
		"[": "х", "]": "ъ", "\\": "ё", "`": "ё",
		a: "ф", s: "ы", d: "в", f: "а", g: "п", h: "р", j: "о", k: "л", l: "д",
		";": "ж", "'": "э",
		z: "я", x: "ч", c: "с", v: "м", b: "и", n: "т", m: "ь", ",": "б", ".": "ю", "/": ".",
	},
	en: {
		q: "q", w: "w", e: "e", r: "r", t: "t", y: "y", u: "u", i: "i", o: "o", p: "p",
		a: "a", s: "s", d: "d", f: "f", g: "g", h: "h", j: "j", k: "k", l: "l",
		z: "z", x: "x", c: "c", v: "v", b: "b", n: "n", m: "m",
		";": ";", "'": "'", ",": ",", ".": ".", "/": "/", "[": "[", "]": "]", "\\": "\\", "`": "`",
	},
	ka: {
		q: "ქ", w: "ღ", e: "ე", r: "რ", t: "ტ", y: "ყ", u: "უ", i: "ი", o: "ო", p: "პ",
		a: "ა", s: "ს", d: "დ", f: "ფ", g: "გ", h: "ჰ", j: "ჯ", k: "კ", l: "ლ",
		z: "ზ", x: "ხ", c: "ც", v: "ვ", b: "ბ", n: "ნ", m: "მ",
	},
};

const LAYOUT_REVERSE = {};
for (const layout of Object.keys(LAYOUT_FORWARD)) {
	LAYOUT_REVERSE[layout] = {};
	for (const [key, ch] of Object.entries(LAYOUT_FORWARD[layout])) {
		LAYOUT_REVERSE[layout][ch] = key;
	}
	if (layout !== "ka") {
		for (const [ch, key] of Object.entries(LAYOUT_REVERSE[layout])) {
			const up = ch.toUpperCase();
			if (up !== ch) LAYOUT_REVERSE[layout][up] = key;
		}
	}
}

function charClass(ch) {
	if (/^[\u10A0-\u10FF]$/.test(ch)) return "ka";
	if (/^[\u0400-\u04FF]$/.test(ch)) return "ru";
	if (/^[a-zA-Z]$/.test(ch)) return "en";
	return null;
}

function detectLayout(text) {
	const counts = { ru: 0, en: 0, ka: 0 };
	for (const ch of text) {
		const c = charClass(ch);
		if (c) counts[c]++;
	}
	const total = counts.ru + counts.en + counts.ka;
	if (total === 0) return null;
	if (counts.ru >= counts.en && counts.ru >= counts.ka) return "ru";
	if (counts.en >= counts.ka) return "en";
	return "ka";
}

function recode(text, from, to) {
	let out = "";
	for (const ch of text) {
		const key = LAYOUT_REVERSE[from][ch];
		if (key == null) { out += ch; continue; }
		let t = LAYOUT_FORWARD[to][key];
		if (t == null) { out += ch; continue; }
		if (to !== "ka" && ch === ch.toUpperCase() && ch !== ch.toLowerCase()) {
			t = t.toUpperCase();
		}
		out += t;
	}
	return out;
}

function buildCandidates(text) {
	const from = detectLayout(text);
	if (!from) return { detected: null, candidates: [] };
	const candidates = [];
	for (const to of Object.keys(LAYOUT_FORWARD)) {
		if (to === from) continue;
		const t = recode(text, from, to);
		if (t !== text) candidates.push({ from, to, text: t });
	}
	return { detected: from, candidates };
}

const LAYOUT_DESC = [
	"Детерминированный перевод ввода пользователя из чужой раскладки клавиатуры",
	"(ru / en / грузинская фонетическая) по позициям клавиш. НЕ использует догадки ИИ.",
	"Возвращает JSON: detected (исходная раскладка) и candidates (варианты",
	"перекодировки from/to/text). Используй при подозрении на ввод в иной раскладке",
	"и оцени осмысленность вариантов по контексту (см. правила языка).",
].join(" ");

// Текст блока системного промпта (совместимость со строкой и с {type,text}).
function blockText(block) {
	if (typeof block === "string") return block;
	if (block && typeof block.text === "string") return block.text;
	return "";
}

export default {
	id: "language-ru",
	async setup(ctx) {
		// Основной механизм: на каждом запросе к модели добавляем правило.
		await ctx.session.hook("context", (event) => {
			const system = event && event.system;
			if (!Array.isArray(system)) return;
			const hasRule = system.some((b) => blockText(b).includes(RULE_MARK));
			if (!hasRule) system.unshift({ type: "text", text: LANG_RULE });
			const hasReminder = system.some((b) => blockText(b) === LANG_REMINDER);
			if (!hasReminder) system.push({ type: "text", text: LANG_REMINDER });
		});

		// Инструмент расшифровки чужой раскладки.
		await ctx.tool.transform((editor) => {
			editor.add({
				name: "layout-translate",
				description: LAYOUT_DESC,
				input: {
					type: "object",
					properties: {
						text: { type: "string", description: "Строка ввода пользователя как есть" },
					},
					required: ["text"],
					additionalProperties: false,
				},
				async execute(input) {
					const text = input && typeof input.text === "string" ? input.text : "";
					return { content: JSON.stringify(buildCandidates(text)) };
				},
			});
		});
	},
};
