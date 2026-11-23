# system-map 0.1.0

Живая карта всей инфраструктуры оркестратора в одном окне: направленный граф
связей + состояние узлов + метрики железа + доступность провайдеров.

## Запуск

```powershell
# Одноразовый сбор (консоль)
pwsh -NoProfile -File C:\Scripts\tools\system-map.ps1
pwsh -NoProfile -File C:\Scripts\tools\system-map.ps1 -Json

# Веб-интерфейс (фоново, через run-watch -Detach)
C:\Scripts\tools\start-system-map.cmd

# Веб-интерфейс в текущем окне
pwsh -NoProfile -File C:\Scripts\tools\system-map.ps1 -Serve -Port 8765
```

Адрес: http://127.0.0.1:8765 (только локальный интерфейс).

## Что показывает

- **Граф связей:** `guardian → watchdog/monitor/tray`, `watchdog → узлы`,
  `opencode → MCP/субагенты/плагины/роутеры`, `lab100 → каскад`, `gordon → провайдеры`,
  `host → CPU/RAM/GPU/диски`. Направление = поток управления или данных.
- **Состояния (цвет):** зелёный — работает; жёлтый — простаивает; серый — выгружен
  по требованию (не поломка); оранжевый — нужен, но недоступен; красный — упал,
  есть заявка; фиолетовый — ограничение провайдера; мигание у аварийных узлов.
- **Желево:** CPU %, ядра, RAM/файл подкачки, VRAM и загрузка GST (если доступны
  счётчики Windows),заполненность дисков C:/E:, накопленный ввод/вывод.
- **opencode:** активные сессии за 30 мин, дерево субагентов (`parent_id`),
  свежие вызовы инструментов из `part` (подсвечивают «горячие» рёбра).
- **Провайдеры:** заданные ключи, текущий сеанс Gordon, модели Ollama
  (все/загруженные), статус Lab100, эвристики блокировок (429/403/geo/unsupported model).
- **Демоны:** фаза watchdog, время последнего цикла, открытые заявки, дроссель
  памяти, состояние reaper.

## Источники (только чтение)

`mcp-watchdog\state\current.json`, `monitor\state\nodes.json`,
`mcp-watchdog-guardian\state\*`, `run-watch\state\run-watch.json`,
`opencode.db` (режим `mode=ro`), env/конфиг `gordon`, `firecrawl --status`,
`ollama list/ps`, `python -m lab100.cli status`, `psutil`, WMI/счётчики GPU.

Все изменения — только в `system-map\state\`. Машинные пути не зашиты:
`INVR_TOOLS_ROOT`, `INVR_NODE_EXE`, `INVR_OPENCODE_DB`, `INVR_LAB100_ROOT`, `INVR_PLUGINS_DIR`.
