# opencode-improvements

Приватный репозиторий улучшений opencode для гибридной оркестрации (основной агент — оркестратор, локальные модели/инструменты — через MCP). Версия 0.3.0.

## Состав

- `plugins/` — плагины opencode (`language-ru.js`, `encoding-utf8.js`, `utf8-console.js`, `status-banner.js`).
- `tools/infra-graph.ps1` — граф инфраструктуры (GUI): карта узлов с живыми рёбрами-«змейками» (активность модели/агента), автоукладка без перекрытий, запоминание ручных позиций. Запуск: `infra-graph.cmd` (двойной клик), `-Status`/`-Shot` для текста/скриншота.
- `tools/opencode-status.ps1` — текстовой монитор: те же статусы, что и граф, но в консоли. Режимы: разовый (`-Once`), живое обновление (`-Watch N`, по умолчанию 3 с), машиночитаемый (`-Json`), без цветов (`-NoColor`). Запуск: `opencode-status.cmd`.
- `tools/opencode-monitor.ps1` — GUI-монитор opencode (хвост лога + статус), сворачивается в трей.

## Установка

`install.ps1` — инсталлер для Windows. Клонируйте репозиторий и запустите:

```powershell
pwsh -NoProfile -File .\install.ps1
```

Параметры:
| Параметр | По умолчанию | Назначение |
|---|---|---|
| `-ToolsDir` | `C:\Scripts\tools` | Целевой каталог утилит |
| `-PluginsDir` | `C:\Scripts\.opencode\plugins` | Целевой каталог плагинов |
| `-Force` | — | Создать целевые каталоги, если их нет |
| `-DryRun` | — | Показать, что будет сделано, без записи |
| `-CheckOnly` | — | Только проверка среды и источников |

Инсталлер раскладывает плагины и инструменты по целевым каталогам и
перегенерирует `infra-graph.cmd` / `opencode-monitor.cmd` под реальный путь
установки. После установки плагинов (.opencode/plugins) нужен перезапуск opencode.

Проверка среды: `pwsh -NoProfile -File .\install.ps1 -CheckOnly`

## Состав

### plugins/ — плагины opencode (JS, каталог `.opencode/plugins/`)
| Файл | Назначение |
|---|---|
| `language-ru.js` | Принудительный русский язык рассуждений и ответов (хук `experimental.chat.system.transform`). |
| `encoding-utf8.js` | Запрет «кракозябр»: модель обязана перекодировать искажённый вывод в UTF-8. |
| `utf8-console.js` | Автоматический префикс UTF-8 к каждой bash-команде (лечит cp866 русской локали Windows). |
| `status-banner.js` | Внедряет в system каждого запроса сводку статусов инфраструктуры из `state/current.json` демона mcp-watchdog. |

Плагины только на JavaScript: Desktop opencode (Electron/Node) не имеет bun и не загружает `.ts`.

### tools/ — утилиты оркестратора
| Файл | Назначение |
|---|---|
| `infra-graph.ps1` | GUI-карта инфраструктуры: узлы (opencode, провайдеры, MCP, сервисы) + активные рёбра. **Импульсные змейки**: одна змейка на каждое событие (запрос/ответ), ответ ползёт от ответчика к вопрошающему; затухание стрелки до серого за 5 с; автораскладка узлов без перекрытий; ручные позиции узлов запоминаются (`infra-graph.positions.json`). |
| `infra-graph.cmd` | Шима запуска: новая консоль + `-STA` (без `-WindowStyle Hidden` — иначе форма невидима). |
| `infra-graph.positions.json` | Сохранённая раскладка узлов (создаётся после первого перетаскивания). |
| `opencode-monitor.ps1` | Окно мониторинга opencode: живые процессы, модель, агент, активность по логу. |
| `opencode-monitor.cmd` | Шима запуска монитора. |

## Запуск графа инфраструктуры
```powershell
cmd /c start "" /min pwsh -NoProfile -STA -File C:\Scripts\tools\infra-graph.ps1
```
- ВАЖНО: не использовать `-WindowStyle Hidden` (наследуется в WinForms-форму, `vis=False`).
- `-STA` обязателен: pwsh по умолчанию MTA, WinForms-окно/трей разрушаются.
- Новая консоль (`cmd /c start`) — процесс не наследует консоль родителя и не умирает от `STATUS_CONTROL_C_EXIT`.

## Команды infra-graph.ps1
- `-Status` — текстовый статус всех узлов (без GUI).
- `-Shot <путь.png>` — offline-рендер карты в PNG.
- `-RestoreLayout` (не реализовано в 0.1.0) — сброс сохранённой раскладки.

## Режимы отката
Локальная установка инструментов — `C:\Scripts\tools\` (вне этого git). Изменения утилит поддержаны каталогом отката `E:\rollback-catalog` (инструмент `C:\Scripts\tools\backup-util.ps1`).