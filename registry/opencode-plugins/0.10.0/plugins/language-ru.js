const LANG_RULE = [
	"ЯЗЫК — ОБЯЗАТЕЛЬНОЕ ИСПОЛНЕНИЕ (РУССКИЙ по умолчанию; все сессии и агенты):",
	"1. ВСЕ внутренние рассуждения, планирование, разборы, thinking/reasoning, перебор вариантов и заметки в ходе работы веди ТОЛЬКО на русском языке (кириллица). Английский (или иной язык) в рассуждениях считается нарушением.",
	"2. Все комментарии, выкопки, изыскания, размышления, пояснения, сводки и ответы пользователю пиши по-русски (кириллица).",
	"3. Терминальные сообщения и сообщения для тестирования дублируй: сначала по-русски, затем по-английски (RU основной, EN дополнительно).",
	"4. Исключения (НЕ переводи): технический вывод программ и сервисов (JSON, логи, вывод CLI, коды ошибок, пути), имена команд и инструментов, цитаты исходных текстов и документов в оригинале.",
	"5. Ввод пользователя не переводи и не переписывай.",
	"6. Правило действует во всех сессиях, проектах и для всех агентов (включая субагентов) приложения.",
	"7. Отступить от правила можно ТОЛЬКО по явному указанию пользователя в чате.",
	"8. ЧУЖАЯ РАСКЛАДКА (ввод набран русскими словами в иной языковой раскладке — латинице QWERTY, грузинской фонетической и т.п.): если текст пользователя выглядит бессмысленным набором символов чужого алфавита — СНАЧАЛА вызови инструмент layout-translate (детерминированный конвертер раскладок по позициям клавиш, БЕЗ догадок и творчества).",
	"9. После вызова layout-translate ОЦЕНИ результат: если среди вариантов есть осмысленный русский (или английский) текст — используй ЕГО как расшифровку ввода пользователя БЕЗ переспроса (это положительная оценка: конвертер детерминирован, ты лишь подтверждаешь осмысленность).",
	"10. Если положительной оценки НЕТ (ни один вариант не осмыслен) ИЛИ инструмент недоступен / нечего распознавать — действуй ПО-ПРЕЖНЕМУ: уточни текст у пользователя или расшифруй вручную по позициям клавиш.",
].join("\n");

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

export const LanguageRuPlugin = async () => {
	let tool = null;
	try {
		const m = await import("@opencode-ai/plugin");
		tool = m.tool;
	} catch {}

	const hooks = {
		"experimental.chat.system.transform": async (_input, output) => {
			if (!output || typeof output !== "object") return;
			const existing = Array.isArray(output.system) ? output.system : [];
			if (existing.includes(LANG_RULE)) return;
			output.system = [LANG_RULE, ...existing];
		},
	};

	if (tool) {
		hooks.tool = {
			"layout-translate": tool({
				description: LAYOUT_DESC,
				args: { text: tool.schema.string().describe("Строка ввода пользователя как есть") },
				async execute(args) {
					return JSON.stringify(buildCandidates(args.text || ""));
				},
			}),
		};
	}

	return hooks;
};

export default LanguageRuPlugin;