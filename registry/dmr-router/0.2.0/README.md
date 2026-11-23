# dmr-router — роутер локальных моделей Docker Model Runner

Выбирает локальную модель под задачу и свободную память, держит каскад с реальной
пробой и возвращает готовый ответ (без накладных расходов `docker agent`).

## Запуск

```powershell
pwsh -NoProfile -File C:\Scripts\tools\dmr-router.ps1 -Ask 'привет'
pwsh -NoProfile -File C:\Scripts\tools\dmr-router.ps1 -Ask 'спроектируй архитектуру модуля' -Json
pwsh -NoProfile -File C:\Scripts\tools\dmr-router.ps1 -Ask 'напиши regex' -Mode lite -DryRun
```

| Параметр | Значение |
|---|---|
| `-Ask` | текст задачи (обязателен, позиционный) |
| `-Mode` | `auto` (по умолчанию) / `lite` / `heavy` / `fast` |
| `-Task` | `short` / `normal` / `deep` — влияет на порог памяти для heavy |
| `-DryRun` | только показать решение (роль, модель, причины), без генерации |
| `-Json` | машиночитаемый вывод: `model`, `role`, `text`, `seconds`, `tokensPerSecond`, `cascadeTried`, `reasons` |
| `-MaxTokens`, `-Temperature` | размер ответа и температура |

Конфиг: `dmr-router-config.json` рядом со скриптом; можно переопределить переменной
`INVR_DMR_ROUTER_CONFIG`.

## Как выбирает модель

1. **Классификатор** по ключевым словам (`classifier.keywords`): код, архитектура,
   отладка, рефакторинг, анализ, дизайн, ADR, тесты → признак тяжёлой задачи.
2. **Память**: heavy требует `memory.heavyMinFreeGB` (7 ГБ; `deep` — 9 ГБ), иначе
   понижение до lite. Модель, **уже загруженную в раннер** (резидентную), порог не
   выкидывает — память под неё уже выделена, решает проба.
3. **Каскад**: `heavy -> lite -> fallback`, каждая модель проверяется короткой пробой
   (`probeMaxTokens`), при сбое — следующая. Роль `fallback` всегда в хвосте каскада,
   в том числе при `-Mode lite`/`fast`.
4. **liveBlocked**: роль с `liveBlocked: true` в живом запросе пропускается с причиной;
   в `-DryRun` она выбирается — планирование остаётся честным.

## Модели на этой машине

| Роль | Модель | Состояние |
|---|---|---|
| `fast` | `ai/llama3.2:1B-Q4_0` | работает на GPU, ~80 ток/с |
| `lite` | `ai/qwen2.5:3B-Q4_K_M` | работает на GPU, ~33 ток/с |
| `heavy` | `ai/qwen3` (Qwen3-8B-Q4_K_M) | **liveBlocked**: VRAM GTX 1050 = 4 ГБ, веса 4,68 ГиБ → `ggml_vulkan: ErrorOutOfDeviceMemory`; на CPU своппится (~0,2 ток/с). Снять `liveBlocked` после установки модели, влезающей в 4 ГБ VRAM |
| `fallback` | `ai/smollm2` | аварийный мини-резерв (отвечает эхом) |

Все модели ставятся инструментом `dmr-model` (команды `docker model` в Docker Desktop 4.92 нет).

## Связь с Gordon

`gordon 0.4.0` использует роутер как фолбэк уровня 1: облачные провайдеры → **dmr-router**
→ `docker agent --model local`. Режим `gordon.ps1 -Prompt … -Local` идёт сразу в роутер.

## Проверка

```powershell
pwsh -NoProfile -File C:\Scripts\tests\dmr-router\harness.ps1        # без генерации
pwsh -NoProfile -File C:\Scripts\tests\dmr-router\harness.ps1 -Live  # с живой генерацией
```

Песочница проверяет структуру реестра, конфиг, поведение без раннера (код выхода 2),
DryRun-решения и (с `-Live`) живую генерацию.

## Коды выхода

`0` — успешно; `2` — раннер недоступен (подними Docker Desktop, порт 12434);
`3` — ни одна модель не подошла (смотри `reasons` в `-Json`).
