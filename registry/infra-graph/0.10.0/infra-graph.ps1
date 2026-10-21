#requires -Version 7.0
<#
  infra-graph.ps1 - карта графов всей инфраструктуры оркестратора
  Окно рисует граф: открытые сессии opencode, провайдеры моделей, MCP-серверы,
  сервисы (ollama/docker/browsertool), пул Lab100, каталог отката, GitHub.
  Индикация на узле: работает/запущен/завис/остановлен + время работы.
  Сворачивается в трей. Запускать В ИНТЕРАКТИВНОЙ СЕССИИ (из opencode окна не видны).
  Режимы:
    без аргументов   - GUI-окно с графом и треем
    -Status          - разовый текстовый статус всех узлов (для проверки)
    -Shot <png>      - отрисовать граф в PNG (offline-рендер, можно звать из opencode)
    -Daemon          - монитор БЕЗ окна: тик 3 с, состояние + персистентность
    -Daemon -Once    - один тик и выход (для тестов)

  Модель 0.7.0: очки у ВСЕХ действующих лиц + ЯВНОЕ состояние (причина) + владение
  и интент + персистентность очков в state\nodes.json.
    Классы узлов (определяют пол очков и допустимость выгрузки):
      core    - oc, watchdog, guardian, monitor: пол 1.0, НЕ гаснут,
                выгрузка ЗАПРЕЩЕНА в коде; вместо свежести — здоровье и молчание
      agent   - субагенты/роутеры (openrouter, gordon, invr): пол 0.0, гаснут,
                0% = unloaded, подъём через вотчдог (Request-AgentWake)
      demand  - инструменты по требованию (browsertool, firecrawl, local-llm,
                MCP_DOCKER, doc-extract, backup-util, resolve-tools, gordon-setup,
                browser): пол 0.0, 0% = unloaded (НЕ поломка), есть интент и владелец
      service - постоянные службы/хранилища (ollama, ollama-prov, docker, lab,
                rollback, gh, cloud, janitor): пол 0.5, не гаснут
    Состояния: active | idle | unloaded | need-guard | fault
    Ключевое правило: инструмент с интентом none/down, который не запущен, —
    это `unloaded` и СЕРЫЙ, а НЕ `red`. Красный = реально упал и его ждут.

  Модель 0.9.3: СКОРОСТЬ, РЕСУРСЫ, ПОНЯТНОСТЬ карты.
    Кэш кадра: подпись кадра (Get-FrameSignature) считает состояния, очки,
      подписи узлов, кандидатов, фильтр и раскладку. Пока подпись не изменилась,
      кадр НЕ перерисовывается — выводится из offscreen-битмапа одним DrawImage.
      Если жива анимация (змейки по рёбрам, мигание «завис», пульс бейджа агентов),
      кадр рисуется целиком и кэш сбрасывается — иначе анимация застыла бы.
      Режим -Shot кэшем не пользуется (рендер одноразовый).
    Сводка ресурсов: одна строка в подвале карты и в -Status — сумма RAM/CPU по
      узлам с телеметрией (из уже посчитанного $script:perf) плюс счётчики
      состояний (из $script:nodeState). Своих измерений эта строка не делает.
    Причина состояния: наведение мыши на узел показывает подсказку — id, класс,
      состояние, очки, владелец, интент, pid(ы), RAM/CPU и ПОСЛЕДНЮЮ причину из
      журнала events.log (читается хвост, кэш по метке времени файла).
    Фильтр «только активные» (клавиша U или пункт меню трея): скрывает узлы
      классов demand/agent в состоянии unloaded. По умолчанию выключен.
    Сопоставление процессов с узлом идёт по трём признакам сразу: имя образа,
      путь к образу и командная строка (защита от переиспользования PID).

  Модель 0.9.4: ДОРАБОТКА ПО ТИКЕТУ (сводка, снимок, утечки, подсказки).
    Снимок -Shot стал ПОЛНЫМ: рисуется ровно то же окно, что и на экране —
      граф + легенда цветов + сводка ресурсов + подпись механизма (раньше легенда и
      сводка жили только в GUI, поэтому снимок был «голая» сетка без подписей).
    Позиции узлов зажаты в границы сцены (Clamp-PosToScene): узел, руками
      перетащенный к краю, раньше обрезался краем PNG.
    -Status меряет CPU ДВАЖДЫ с паузой: одноразовый запуск иначе всегда показывал
      CPU 0% (дельты не от чего было считать).
    Гарантированный освобождение GDI в Invoke-DrawGraph (try/finally), убраны
      неиспользуемые кисти, освобождаются иконка трея, битмап и меню при выходе.
    Подсказка горячей клавиши видна в окне всегда («U — только активные узлы»),
      а не только когда фильтр уже включён.

  Модель 0.9.5: КОНТРОЛЬ МЕСТА НА ДИСКЕ (сегодня том C: заполнялся до 0 байт, из-за
  чего падали и демон карты, и .NET-процессы).
    Свободное место тома, на котором лежит каталог состояния (обычно C:), видно
      строкой в подвале карты и в режиме -Status: «Диск C: 3,5 / 119 ГБ (3%)».
      Цвет строки: зелёный — свободно больше 5 ГБ, жёлтый — 2…5 ГБ, красный — меньше 2 ГБ.
    В nodes.json добавлено поле КОРНЯ "disk" = { root, freeGb, totalGb, freePct,
      updatedAt }. Прежние поля не менялись и не переименовывались, схема осталась
      'invr.nodes/1': карта и дашборд фабрики читают файл как раньше, "disk" — дополнение.
    Защита от переполнения: при свободном месте меньше 1,5 ГБ кадр карты
      перерисовывается не чаще одного раза в 10 минут, при меньше 0,5 ГБ — не
      перерисовывается вовсе. nodes.json (телеметрия) обновляется ВСЕГДА. При возврате
      места обычный режим включается автоматически. Место на диске руками НЕ
      освобождается — это зона владельца, инструмент только показывает и предупреждает.
    Ротация СВОИХ журналов: events.log (журнал причин) и infra-graph.err.log при
      превышении ~1 МБ уходят в архив с суффиксом .1 (одна архивная копия, старая
      перезаписывается). Логи других инструментов не трогаются.

  Модель 0.9.0: ПЕРЕНОСИМОСТЬ — машинные пути больше не зашиты в код.
  Все внешние каталоги задаются переменными окружения, а если они не заданы,
  вычисляются ОТ РАСПОЛОЖЕНИЯ: $PSScriptRoot -> <версия> -> registry -> <tools>
  -> <workspace> (родитель корня инструментов — обычное место для данных).
  Порядок разрешения: переменная окружения (процесс, затем уровень User) →
  позиционный резерв → пусто (узел показывается как отсутствующий/неизвестный,
  а не как зелёный).
    Переменные окружения (НОВЫЕ в 0.9.0, плюс INVR_JANITOR_DIR из 0.10.0;
    читаются и из User-окружения):
      INVR_LAB_DIR           - каталог пула Lab100 (поиск/суммаризация ИИ).
                              Резерв: <workspace>\Lab100, <tools>\Lab100, .\Lab100.
      INVR_ROLLBACK_ROOT     - каталог каталога откатов (журнал изменений).
                              Резерв: INVR_VM_ROOT, <tools>\rollback-catalog.
      INVR_VM_ROOT           - дополнительный корень виртуальных дисков/хранилищ
                              (используется как запасной источник для rollback).
      INVR_OLLAMA_MODELS_DIR - каталог моделей ollama (для размера на диске).
                              Резерв: <workspace>\OllamaModels, %USERPROFILE%\.ollama\models.
      DOCKER_WSL_DATA_DIRS   - ДОПОЛНИТЕЛЬНЫЕ кандидаты файла данных Docker WSL
                              (ext4.vhdx), список через ';'. По умолчанию ПУСТО —
                              диски E:/D: автоматически НЕ проверяются. Штатный
                              переносимый кандидат ($env:LOCALAPPDATA\Docker\wsl\
                              data\ext4.vhdx) проверяется всегда.
      INVR_JANITOR_DIR       - каталог чистильщика мусора opencode (узел janitor:
                              config.json с autoStart + замок janitor.lock).
                              Резерв: $XDG_CONFIG_HOME\opencode\janitor,
                              затем ~/.config\opencode\janitor.
  Уже существовавшие переменные (для справки, поведение не менялось):
      INVR_LOG_DIR           - каталог журналов демона-стража (резерв <tools>\Logs).
      INFRAGRAPH_STATE_FILE  - путь к nodes.json.
      INFRAGRAPH_INTENTS_FILE- путь к файлам интентов.

  Модель 0.10.0: узел janitor — чистильщик мусора opencode (фоновый демон
  node <каталог>\janitor.mjs --watch, одиночный экземпляр, замок janitor.lock).
    Состояние узла — по замку janitor.lock (pid жив + сверка startedAt со стартом
    процесса -> uptime из startedAt). autoStart из config.json чистильщика —
    ИСТОЧНИК ИНТЕНТА узла: true -> up (незапущенный демон = need-guard
    «нужен, но не работает»), false -> none (незапущенный = unloaded, серый,
    НЕ поломка); конфига/каталога нет — жёлтый «данных нет» либо серый.
    Класс узла janitor — service (пол 0.5, выгрузка не подлежит).
    Каталог чистильщика — переносимый: INVR_JANITOR_DIR ->
    $XDG_CONFIG_HOME\opencode\janitor -> ~/.config\opencode\janitor.
#>
param(
  [switch]$Status,
  [string]$Shot,
  [switch]$Daemon,
  [switch]$Once,
  [string]$StateFile,
  [string]$IntentsFile,
  [int]$FlushSec = 60,
  [int]$MaxAgeSec = 1800,
  [int]$BusyTimeoutSec = 600,
  [int]$UnloadAfterSec = 900
)
# --- UTF-8: кириллица в выводе pwsh 7 (OEMCP 866 ломает чтение) ---------

$ErrorActionPreference = 'Continue'

try {

  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

  [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)

  $OutputEncoding = [System.Text.UTF8Encoding]::new($false)

  $env:PYTHONUTF8 = '1'

  $env:PYTHONIOENCODING = 'utf-8'

} catch { }

# ------------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$off = [System.Text.Encoding]::UTF8
# Переносимые корни (машинные пути не зашиты)
$regRoot    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$toolsRoot  = Split-Path $regRoot -Parent
$logDirEnv  = if ($env:INVR_LOG_DIR) { $env:INVR_LOG_DIR } else { [Environment]::GetEnvironmentVariable('INVR_LOG_DIR', 'User') }
$logDir     = if ($logDirEnv) { $logDirEnv } else { Join-Path $toolsRoot 'Logs' }
$LogPath = Join-Path $env:USERPROFILE '.local\share\opencode\log\opencode.log'
$WdPath  = Join-Path $toolsRoot 'mcp-watchdog\state\current.json'
$WdLog   = Join-Path $logDir 'mcp-watchdog.log'
# каталог рантайм-состояния карты — ВНЕ каталога версии (версия в реестре неизменяема)
$StateDir = Join-Path $toolsRoot 'monitor\state'

# ---------- переносимые пути (0.9.0) ----------
# МАШИННЫХ ПУТЕЙ В КОДЕ НЕТ. Каждый внешний каталог задаётся переменной окружения,
# а при её отсутствии вычисляется ОТ РАСПОЛОЖЕНИЯ: $PSScriptRoot -> корень
# реестра -> корень инструментов -> родитель корня инструментов (обычное место
# для данных). Если ничего не найдено — путь остаётся пустым, а узел показывается
# ОТСУТСТВУЮЩИМ/НЕИЗВЕСТНЫМ (серый или жёлтый), а не «зелёным».
function Get-EnvValue([string]$name) {
  $v = [Environment]::GetEnvironmentVariable($name, 'Process')
  if (-not $v) { $v = [Environment]::GetEnvironmentVariable($name, 'User') }
  if ($v) { return "$v".Trim() }
  return $null
}
function Resolve-EnvPath([string]$name, [string[]]$fallbacks) {
  $v = Get-EnvValue $name
  if ($v) { return $v }
  foreach ($fb in $fallbacks) {
    if ($fb -and "$fb".Trim()) { return "$fb".Trim() }
  }
  return $null
}
$workspaceRoot = Split-Path $toolsRoot -Parent
$cwdPath = try { (Get-Location).ProviderPath } catch { $null }

# пул Lab100 (узел lab, размер на диске). Резерв: Lab100 рядом с корнем
# инструментов (обычное место для данных), затем внутри корня, затем в текущем каталоге.
$LabDir = Resolve-EnvPath 'INVR_LAB_DIR' @(
  (Join-Path $workspaceRoot 'Lab100'),
  (Join-Path $toolsRoot 'Lab100'),
  $(if ($cwdPath) { Join-Path $cwdPath 'Lab100' } else { $null })
)

# каталог откатов (узел rollback). Запасной источник — INVR_VM_ROOT: на некоторых
# машинах каталог откатов лежит рядом с виртуальными дисками.
$RollbackRoot = Resolve-EnvPath 'INVR_ROLLBACK_ROOT' @(
  (Get-EnvValue 'INVR_VM_ROOT'),
  (Join-Path $toolsRoot 'rollback-catalog'),
  (Join-Path $workspaceRoot 'rollback-catalog')
)

# каталог моделей ollama (только размер на диске; пусто = узел без метрики dsk)
$OllamaModelsDir = Resolve-EnvPath 'INVR_OLLAMA_MODELS_DIR' @(
  (Join-Path $workspaceRoot 'OllamaModels'),
  $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.ollama\models' } else { $null })
)

# каталог чистильщика мусора opencode (узел janitor; 0.10.0). Машинного пути в
# коде НЕТ: INVR_JANITOR_DIR -> $XDG_CONFIG_HOME\opencode\janitor -> ~/.config\opencode\janitor
$JanitorDir = Resolve-EnvPath 'INVR_JANITOR_DIR' @(
  $(if ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME 'opencode\janitor' } else { $null }),
  $(if ($HOME) { Join-Path $HOME '.config\opencode\janitor' } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.config\opencode\janitor' } else { $null })
)

# кандидаты файла данных Docker WSL (ext4.vhdx): сначала ЯВНО заданные
# (DOCKER_WSL_DATA_DIRS, список через ';'), затем переносимые штатные.
# Диски вида E:/D: по умолчанию НЕ проверяются — только если их указали в переменной.
$DockerWslCandidates = @()
foreach ($d in @((Get-EnvValue 'DOCKER_WSL_DATA_DIRS') -split ';' | Where-Object { $_ })) {
  $DockerWslCandidates += $d.Trim()
}
if ($env:LOCALAPPDATA) { $DockerWslCandidates += Join-Path $env:LOCALAPPDATA 'Docker\wsl\data\ext4.vhdx' }
$DockerWslCandidates += Join-Path $workspaceRoot 'Libraries\DockerDesktopWSL\main\ext4.vhdx'

# ---------- рабочие файлы состояния (персистентность) ----------
# по умолчанию <tools>\monitor\state\nodes.json; путь переопределяется -StateFile
$script:statePath = if ($StateFile) {
  $StateFile
} else {
  [Environment]::GetEnvironmentVariable('INFRAGRAPH_STATE_FILE', 'User')
}
if (-not $script:statePath) { $script:statePath = Join-Path $StateDir 'nodes.json' }
$script:eventsPath   = Join-Path (Split-Path $script:statePath -Parent) 'events.log'
# скорость убывания востребованности (меню карты): общий файл для карты и демона
$script:DecayPath    = Join-Path (Split-Path $script:statePath -Parent) 'decay.json'
$script:FlushSec     = $FlushSec
$script:MaxAgeSec    = $MaxAgeSec
$script:BusyTimeoutSec = $BusyTimeoutSec
$script:UnloadAfterSec  = $UnloadAfterSec
# файлы интентов: browsertool.json ({"desired":"up|down"}) + общий intents.json
$script:intentsPath  = if ($IntentsFile) { $IntentsFile } else { [Environment]::GetEnvironmentVariable('INFRAGRAPH_INTENTS_FILE', 'User') }
$WdIntentPath        = if ($script:intentsPath) { $script:intentsPath } else { Join-Path $toolsRoot 'mcp-watchdog\state\browsertool.json' }
$WdGenericIntent     = if ($script:intentsPath) { $script:intentsPath } else { Join-Path $toolsRoot 'mcp-watchdog\state\intents.json' }
# журнал ошибок обработчиков WinForms — тоже вне версии
$script:ErrLogPath   = Join-Path $StateDir 'infra-graph.err.log'
$script:PosFileNew   = Join-Path $StateDir 'infra-graph.positions.json'
$script:PosFileLegacy = Join-Path $PSScriptRoot 'infra-graph.positions.json'
$script:runMode = if ($Daemon) { 'daemon' } elseif ($Status) { 'status' } elseif ($Shot) { 'shot' } else { 'gui' }

# ---------- сбор статусов ----------
function Get-NodeStatus {
  $wd = $null
  if (Test-Path $WdPath) {
    try { $wd = Get-Content $WdPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $wd = $null }
  }
  # интенты нужны уже здесь: они решают gray (выгружен по требованию) против red (упал)
  Read-IntentFiles
  if (-not $script:procs) { $script:procs = Get-ProcsByNode }

  # открытые сессии opencode
  $oc = @(Get-Process OpenCode -ErrorAction SilentlyContinue)
  $ocUptime = '—'
  if ($oc.Count -gt 0) {
    $minStart = ($oc | ForEach-Object StartTime | Sort-Object | Select-Object -First 1)
    if ($minStart) { $ocUptime = ((Get-Date) - $minStart).ToString('h\:mm\:ss') }
  }
  $ocStatus = if ($oc.Count -gt 0) { 'green' } else { 'gray' }
  $ocDetail = if ($oc.Count -gt 0) { "сессий: $($oc.Count)" } else { 'не запущен' }

  # модель из хвоста лога
  $model = '?'
  if (Test-Path $LogPath) {
    $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $fs.Seek(-([Math]::Min(300000, $fs.Length)), [System.IO.SeekOrigin]::End) | Out-Null
      $sr = New-Object System.IO.StreamReader($fs, $off)
      $tail = $sr.ReadToEnd()
    } finally { $sr.Dispose(); $fs.Dispose() }
    if ($tail -match 'message="llm runtime selected".*? llm.model=(\S+)') { $model = $Matches[1] }
  }

  # MCP / сервисы из watchdog (status: ok, fail, ...)
  function Get-Wd($name) {
    if ($null -eq $wd) { return $null }
    $p = $wd.checks.$name
    if ($null -eq $p) { return $null }
    [pscustomobject]@{ Status = $p.status.ToString(); Detail = $p.detail.ToString() }
  }

  $nodes = @()
  function New-Node($id, $label, $status, $uptime, $detail) {
    [pscustomobject]@{ Id=$id; Label=$label; Status=$status; Uptime=$uptime; Detail=$detail }
  }

  # 1. оркестратор
  $nodes += New-Node 'oc' "opencode`nоркестратор`nмодель: $model" $ocStatus $ocUptime $ocDetail

  # 2. провайдеры моделей
  $nodes += New-Node 'ollama-prov' "ollama`nпровайдер (hermes3)"                'green'  '—' 'endpoint 11434'
  $nodes += New-Node 'cloud'      "opencode cloud`n(облачная модель)"           'green'  '—' 'big-pickle'
  $nodes += New-Node 'openrouter' "openrouter`n(free-резерв)"                   'gray'   '—' 'ключ: есть'

  # 2б. фабрика Lab-100 и её ИИ-провайдеры (ипостаси из config/settings.toml)
  $fabPid = $null; $fabUp = '—'
  try {
    $fabProc = @(Get-CimInstance Win32_Process -Filter "Name='factory.exe'" -ErrorAction Stop)
    if ($fabProc.Count -gt 0) {
      $fabPid = $fabProc[0].ProcessId
      $fabSw = Get-Process -Id $fabPid -ErrorAction SilentlyContinue
      if ($fabSw -and $fabSw.StartTime) { $fabUp = ((Get-Date) - $fabSw.StartTime).ToString('h\:mm\:ss') }
    }
  } catch {}
  $fabDet  = if ($fabPid) { "веб-панель pid $fabPid; 127.0.0.1:8787" } else { 'ui не запущен (micromonitor)' }
  $nodes += New-Node 'factory' "фабрика Lab-100`n(веб-панель ui)" $(if ($fabPid) { 'green' } else { 'gray' }) $fabUp $fabDet

  $provOn = @()
  $provToml = Join-Path $env:LOCALAPPDATA 'FactoryLab100\config\settings.toml'
  if (Test-Path -LiteralPath $provToml) {
    $curProv = $null
    foreach ($ln in (Get-Content -LiteralPath $provToml -Encoding UTF8 -ErrorAction SilentlyContinue)) {
      if ($ln -match '^\[providers\.([^\]]+)\]') { $curProv = $Matches[1] }
      elseif ($ln -match '^\[') { $curProv = $null }
      elseif ($curProv -and $ln -match '^\s*enabled\s*=\s*true') { $provOn += $curProv }
    }
  }
  $provSt  = if ($provOn.Count -gt 0) { 'green' } else { 'yellow' }
  $provDet = if ($provOn.Count -gt 0) { 'включены: ' + ($provOn -join ', ') } else { 'все ИИ-провайдеры выключены' }
  $nodes += New-Node 'fab-prov' "ИИ-провайдеры`n(ипостаси фабрики)" $provSt '—' $provDet

  # 3. MCP-серверы
  foreach ($mcp in @('local-llm','firecrawl','MCP_DOCKER')) {
    $w = Get-Wd $mcp
    $st = if ($w) { if ($w.Status -eq 'ok') { 'green' } else { 'red' } } else { 'gray' }
    $up = if ($w) { '' } else { '—' }
    $det = if ($w) { $w.Detail } else { 'нет данных (watchdog?)' }
    $nodes += New-Node $mcp "MCP $mcp" $st $up $det
  }

  # 4. сервисы
  $svc = @('ollama','browsertool')
  foreach ($s in $svc) {
    $w = Get-Wd $s
    $st = if ($w) { if ($w.Status -eq 'ok') { 'green' } else { 'red' } } else { 'gray' }
    $det = if ($w) { $w.Detail } else { 'нет данных' }
    $nodes += New-Node $s "сервис: $s" $st '' $det
  }
  $dw = $wd
  $dockerSt = if ($null -ne $dw -and $dw.checks.MCP_DOCKER -and $dw.checks.MCP_DOCKER.detail -match 'docker daemon:(True|False)') { if ($Matches[1] -eq 'True') { 'green' } else { 'yellow' } } else { 'gray' }
  $nodes += New-Node 'docker' "Docker Desktop`n(инфраструктура)" $dockerSt '' 'daemon: см. MCP_DOCKER'

  # 5. демон-страж mcp-watchdog (контролирует MCP-серверы и сервисы)
  $wdProc = @()
  $wdUp = '—'; $wdStatus = 'gray'
  try {
    $wdProc = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction Stop |
      Where-Object { $_.CommandLine -match 'mcp-watchdog' })
    if ($wdProc.Count -gt 0) {
      $wdStatus = 'green'
      $wdSw = Get-Process -Id $wdProc[0].ProcessId -ErrorAction SilentlyContinue
      if ($wdSw -and $wdSw.StartTime) { $wdUp = ((Get-Date) - $wdSw.StartTime).ToString('h\:mm\:ss') }
    }
  } catch { }
  # открытые заявки демона (тикеты проверки серверов)
  $openTk = 0
  $reqDir = Join-Path $toolsRoot 'mcp-watchdog\requests'
  if (Test-Path $reqDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $reqDir -Filter 'chk_*.json' -ErrorAction SilentlyContinue)) {
      try {
        $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
        if ($j.status -ne 'resolved') { $openTk++ }
      } catch { }
    }
  }
  $wdDet = if ($wdProc.Count -gt 0) {
    if ($openTk -gt 0) { "заявок: $openTk" } else { 'все сервисы в норме' }
  } else { 'демон не запущен' }
  $nodes += New-Node 'watchdog' "mcp-watchdog`nдемон-страж" $wdStatus $wdUp $wdDet

  # 5a. страж демона (core): поднимает mcp-watchdog, если тот умер
  $gProc = @()
  try {
    $gProc = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction Stop |
      Where-Object { $_.CommandLine -match 'mcp-watchdog-guardian' })
  } catch { }
  $gSt = if ($gProc.Count -gt 0) { 'green' } else { 'red' }
  $gUp = '—'
  if ($gProc.Count -gt 0) {
    $gSw = Get-Process -Id $gProc[0].ProcessId -ErrorAction SilentlyContinue
    if ($gSw -and $gSw.StartTime) { $gUp = ((Get-Date) - $gSw.StartTime).ToString('h\:mm\:ss') }
  }
  $gDet = if ($gProc.Count -gt 0) { "pid: $($gProc[0].ProcessId)" } else { 'страж не запущен' }
  $nodes += New-Node 'guardian' "mcp-watchdog-guardian`nстраж демона" $gSt $gUp $gDet

  # 5b. сам монитор карты (core, guard-required): держит состояние очков на диске
  $nodes += New-Node 'monitor' "infra-graph`nмонитор состояния" 'green' '—' "guard-required; режим: $($script:runMode); pid: $PID"

  # 5c. чистильщик мусора opencode (service): фоновый демон janitor --watch —
  # одиночный экземпляр, замок janitor.lock ({"pid":N,"startedAt":<epoch ms>}).
  # Живость — по замку: pid существует, процесс node/bun, старт процесса сходится
  # с startedAt (защита от переиспользованного pid); uptime берём из startedAt.
  # autoStart из config.json — источник интента (см. Set-JanitorIntent): true ->
  # up (незапущенный = need-guard «нужен, но не работает»), false -> none
  # (незапущенный = unloaded, серый, НЕ поломка). Конфига/каталога нет — жёлтый.
  $janUp = '—'
  $janDet  = ''
  $janAuto = $null
  if (-not $JanitorDir) {
    $janSt = 'gray'; $janDet = 'каталог чистильщика не задан (INVR_JANITOR_DIR)'
  } elseif (-not (Test-Path -LiteralPath $JanitorDir)) {
    $janSt = 'yellow'; $janDet = "нет каталога: $JanitorDir"
  } else {
    # конфиг чистильщика: autoStart поднимает демон плагином janitor-autostart
    $janCfgPath = Join-Path $JanitorDir 'config.json'
    if (Test-Path -LiteralPath $janCfgPath) {
      try {
        $janCfg = Get-Content -LiteralPath $janCfgPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($janCfg.PSObject.Properties['autoStart']) { $janAuto = [bool]$janCfg.autoStart }
      } catch { $janAuto = $null }
    }
    # замок одиночного экземпляра: {"pid":1476,"startedAt":<epoch ms>}
    $janPid = $null; $janStart = $null
    $janLockPath = Join-Path $JanitorDir 'janitor.lock'
    if (Test-Path -LiteralPath $janLockPath) {
      try {
        $janLock = Get-Content -LiteralPath $janLockPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($janLock.PSObject.Properties['pid'] -and $janLock.pid)             { $janPid   = [int]$janLock.pid }
        if ($janLock.PSObject.Properties['startedAt'] -and $janLock.startedAt) { $janStart = [long]$janLock.startedAt }
      } catch { }
    }
    # живость демона: pid существует, процесс node/bun, старта сходится с startedAt
    $janProc  = if ($janPid) { Get-Process -Id $janPid -ErrorAction SilentlyContinue } else { $null }
    $janAlive = $false
    if ($janProc -and ($janProc.ProcessName -match '^(node|bun)$')) {
      $janAlive = $true
      if ($janStart) {
        try {
          $janStartDt = [DateTimeOffset]::FromUnixTimeMilliseconds($janStart).LocalDateTime
          if ($janStartDt -gt (Get-Date).AddYears(-5)) {
            $janAlive = [Math]::Abs(($janProc.StartTime - $janStartDt).TotalSeconds) -lt 120
          }
        } catch { }
      }
    }
    if ($janAlive) {
      # демон запущен — зелёный; uptime из startedAt (резерв — старт процесса)
      $janSt = 'green'
      try {
        if ($janStart) { $janUp = ((Get-Date) - [DateTimeOffset]::FromUnixTimeMilliseconds($janStart).LocalDateTime).ToString('h\:mm\:ss') }
        elseif ($janProc.StartTime) { $janUp = ((Get-Date) - $janProc.StartTime).ToString('h\:mm\:ss') }
      } catch { }
      $janDet = "pid: $janPid; autoStart: " + $(if ($null -eq $janAuto) { 'нет конфига' } else { $janAuto.ToString().ToLower() })
    } elseif ($null -eq $janAuto) {
      # конфига нет — не знаем, нужен ли демон: ни «поломки», ни «выгрузки»
      $janSt = 'yellow'
      $janDet = if ($janPid) { "нет config.json; pid $janPid не найден" } else { 'нет config.json (autoStart неизвестен)' }
    } elseif ($janAuto) {
      # автозапуск включён, а демона нет: нужен, но не работает -> need-guard
      $janSt = 'gray'
      $janDet = if ($janPid) { "демон не запущен (pid $janPid мёртв); autoStart: true" } else { 'демон не запущен; autoStart: true' }
    } else {
      # autoStart: false — выключен намеренно: unloaded (серый), НЕ поломка
      $janSt = 'gray'
      $janDet = 'демон не запущен; autoStart: false (выключен намеренно)'
    }
  }
  Set-JanitorIntent $janAuto
  $nodes += New-Node 'janitor' "janitor`nчистильщик`nмусора" $janSt $janUp $janDet

  # 6. пул Lab100 (путь переносимый: INVR_LAB_DIR -> резерв от расположения)
  $labDet = if ($LabDir) { $LabDir } else { 'каталог не задан (INVR_LAB_DIR)' }
  if ($LabDir -and -not (Test-Path -LiteralPath $LabDir)) { $labDet = "$LabDet — нет каталога" }
  $poolSt = 'yellow'
  $nodes += New-Node 'lab' "Lab100`nпул ИИ-агентов" $poolSt '' $labDet

  # 7. хранилище / git
  # Каталог отката — переносимый путь (INVR_ROLLBACK_ROOT -> INVR_VM_ROOT -> резерв).
  # Каталога на этой машине может не быть: тогда узел показывается ОТСУТСТВУЮЩИМ
  # (жёлтый = настроен, но не найден) или НЕИЗВЕСТНЫМ (серый = не настроен вовсе),
  # а не «зелёным». Красный не ставим намеренно: узел класса service с интентом auto
  # иначе превратился бы в fault/заявку демона-стража (Resolve-NodeStatusColor).
  if (-not $RollbackRoot) {
    $rbSt = 'gray';   $rbLabel = "каталог отката`n(не настроен)"; $rbDet = 'задайте INVR_ROLLBACK_ROOT'
  } elseif (Test-Path -LiteralPath $RollbackRoot) {
    $rbSt = 'green';  $rbLabel = "каталог отката`n$RollbackRoot"; $rbDet = 'приватный репо'
  } else {
    $rbSt = 'yellow'; $rbLabel = "каталог отката`n$RollbackRoot"; $rbDet = 'каталог не найден'
  }
  $nodes += New-Node 'rollback' $rbLabel $rbSt '' $rbDet
  $nodes += New-Node 'gh' "GitHub`nLab-100/*" 'green' '' 'приватные репо'

  # 8. СВОИ УЗЛЫ ОПЕРАТОРА: трей/склад INVR, надзор фабрики, инструменты склада.
  # Раньше эти системы были на карте не видны вообще. Теперь они в составе ВСЕГДА:
  # остановленное = серый/unloaded («выгружен по требованию»), а НЕ красный — решение
  # об остановке у владельца узла, а не дефект карты (см. Resolve-NodeStatusColor).
  # Снимок процессов для всего блока — ОДИН Get-CimInstance: по кругу на каждый
  # инструмент мы НЕ опрашиваем систему.
  $selfProc = @()
  try { $selfProc = @(Get-CimInstance Win32_Process -ErrorAction Stop) } catch { $selfProc = @() }
  # процессы самой карты (текущий и его копии) в проверках не участвуют
  $selfProc = @($selfProc | Where-Object {
    $_.ProcessId -ne $PID -and -not ($_.CommandLine -and $_.CommandLine -match 'infra-graph')
  })

  # 8a. трей/склад INVR — инвентарь .devstation (трей + пульт)
  $invrProc = @($selfProc | Where-Object { $_.Name -eq 'pwsh.exe' -and $_.CommandLine -match 'invr-tray' })
  $invrSt  = if ($invrProc.Count -gt 0) { 'green' } else { 'gray' }
  $invrUp  = '—'
  if ($invrProc.Count -gt 0) {
    $invrSw = Get-Process -Id $invrProc[0].ProcessId -ErrorAction SilentlyContinue
    if ($invrSw -and $invrSw.StartTime) { $invrUp = ((Get-Date) - $invrSw.StartTime).ToString('h\:mm\:ss') }
  }
  $invrDet = if ($invrProc.Count -gt 0) { "pid: $($invrProc[0].ProcessId); трей/пульт" }
              else { 'выгружен по требованию (нет invr-tray.ps1)' }
  $nodes += New-Node 'invr' "INVR`nсклад .devstation`nтрей/пульт" $invrSt $invrUp $invrDet

  # 8b. надзор запуска фабрики (micromonitor + задача планировщика).
  # Оператор может остановить надзор осознанно — это серый, НЕ тревога.
  $fmProc = @($selfProc | Where-Object { $_.Name -eq 'pwsh.exe' -and $_.CommandLine -match 'micromonitor' })
  $fmTask = 'задачи нет'
  try {
    $fmT = Get-ScheduledTask -TaskName 'FactoryMicromonitor' -ErrorAction Stop
    $fmTask = if ("$($fmT.State)" -eq 'Disabled') { 'задача отключена' } else { "задача: $($fmT.State)" }
  } catch { $fmTask = 'задачи нет' }
  $fmSt = if ($fmProc.Count -gt 0) { 'green' } else { 'gray' }
  $fmUp = '—'; $fmMode = '—'
  if ($fmProc.Count -gt 0) {
    $fmSw = Get-Process -Id $fmProc[0].ProcessId -ErrorAction SilentlyContinue
    if ($fmSw -and $fmSw.StartTime) { $fmUp = ((Get-Date) - $fmSw.StartTime).ToString('h\:mm\:ss') }
    $fmMode = if (($fmProc[0].CommandLine -match 'Hidden') -or ($fmSw -and $fmSw.MainWindowHandle -eq 0)) {
      'фоновый'
    } else { 'оконный' }
  }
  $fmDet = if ($fmProc.Count -gt 0) { "pid: $($fmProc[0].ProcessId); $fmMode; $fmTask" }
            else { "надзор не запущен; $fmTask" }
  $nodes += New-Node 'factory-mon' "фабрика`nнадзор запуска`n(micromonitor)" $fmSt $fmUp $fmDet

  # 8c. инструменты склада из реестра _registry.json — ОДИН проход по реестру.
  # Уже представленные на карте (llm-mcp≈local-llm, infra-graph≈monitor,
  # mcp-watchdog≈watchdog, mcp-watchdog-guardian≈guardian, browsertool) и
  # служебные opencode-status/restart/plugins НЕ дублируем; gordon и gordon-chat —
  # одна система (один узел gordon). При сбое чтения реестра узлы просто не создаются.
  $haveIds = @($nodes | ForEach-Object { $_.Id })
  try {
    $regFile  = Join-Path $regRoot '_registry.json'
    $toolList = @()
    if (Test-Path -LiteralPath $regFile) {
      $regJ = Get-Content -LiteralPath $regFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      if ($regJ -and $regJ.tools) { $toolList = @($regJ.tools) }
    }
    foreach ($t in $toolList) {
      $tn = "$($t.name)"
      if (-not $tn) { continue }
      if ($script:toolSkip -contains $tn) { continue }
      if ($haveIds -contains $tn) { continue }
      $ver = "$($t.latest)"
      # имя инструмента ищем в НОРМАЛИЗОВАННОМ виде по трём признакам:
      # имя образа, путь к образу и командная строка (разделители -/_/. взаимозаменяем,
      # регистр не важен). Одной командной строки мало: при переиспользовании PID
      # она может совпасть с чужим процессом и узел покажет неверный статус.
      $pat = ((($tn -split '[-_]') | ForEach-Object { [regex]::Escape($_) }) -join '[-_.]?')
      $hit = @($selfProc | Where-Object {
        ($_.Name -and $_.Name -match $pat) -or
        ($_.ExecutablePath -and $_.ExecutablePath -match $pat) -or
        ($_.CommandLine -and $_.CommandLine -match $pat)
      })
      if ($hit.Count -gt 0) {
        $up = '—'
        $sw = Get-Process -Id $hit[0].ProcessId -ErrorAction SilentlyContinue
        if ($sw -and $sw.StartTime) { $up = ((Get-Date) - $sw.StartTime).ToString('h\:mm\:ss') }
        $nodes += New-Node $tn "$tn`nинструмент склада" 'green' $up "pid: $($hit[0].ProcessId); реестр: версия $ver"
      } else {
        $nodes += New-Node $tn "$tn`nинструмент склада" 'gray' '—' "выгружен по требованию (реестр: версия $ver)"
      }
      $haveIds += $tn
    }
  } catch { }

  # ЕДИНОЕ ПРАВИЛО цвета: инструмент с интентом none/down, который не запущен, —
  # это «выгружен по требованию» (серый), а НЕ поломка (красный).
  foreach ($n in $nodes) { $n.Status = Resolve-NodeStatusColor $n.Id $n.Status }

  return @{ Nodes = $nodes; Opencode = $oc; Model = $model }
}

# ---------- метрики производительности по узлам-агентам ----------
# сопоставление узла с (обычно парой) процессов по имени/командной строке.
# Возврат: id -> @{ Ram=байт; CpuPct=% (делится на ядра); Disk=байт; Where='CPU'|'GPU'}
function Get-ProcsByNode {
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $match = @{
    'oc'          = { $_.Name -eq 'OpenCode.exe' -or $_.Name -eq 'opencode.exe' }
    'ollama-prov' = { $_.Name -match 'ollama' }
    'ollama'      = { $_.Name -match 'ollama' }
    'local-llm'   = { $_.Name -eq 'python.exe' -and $_.CommandLine -match 'llm_mcp_server' }
    'firecrawl'   = { $_.Name -eq 'node.exe' -and $_.CommandLine -match 'firecrawl' }
    'MCP_DOCKER'  = { $_.CommandLine -match 'mcp\s+gateway' -or (($_.Name -eq 'node.exe' -or $_.Name -eq 'bun.exe') -and $_.CommandLine -match 'mcp' -and $_.CommandLine -notmatch 'firecrawl') }
    'docker'      = { $_.Name -match 'Docker Desktop' -or $_.Name -match 'com.docker.backend' -or $_.Name -match 'vpnkit' -or $_.Name -match 'wsl' }
    'browsertool' = { $_.Name -eq 'node.exe' -and $_.CommandLine -match 'driver.mjs' }
    'watchdog'    = { $_.Name -eq 'pwsh.exe' -and $_.CommandLine -match 'mcp-watchdog' -and $_.CommandLine -notmatch 'mcp-watchdog-guardian' }
    'guardian'    = { $_.Name -eq 'pwsh.exe' -and $_.CommandLine -match 'mcp-watchdog-guardian' }
    'monitor'     = { $_.ProcessId -eq $PID }
    'janitor'     = { ($_.Name -eq 'node.exe' -or $_.Name -eq 'bun.exe') -and $_.CommandLine -match 'janitor\.mjs' }
    'lab'         = { $_.Name -eq 'python.exe' -and $_.CommandLine -match 'lab100' }
    # свои узлы оператора: трей/склад INVR, надзор фабрики, агент gordon
    'invr'        = { $_.Name -eq 'pwsh.exe' -and $_.CommandLine -match 'invr-tray' }
    'factory-mon' = { $_.Name -eq 'pwsh.exe' -and $_.CommandLine -match 'micromonitor' }
    'gordon'      = { $_.CommandLine -and $_.CommandLine -match 'gordon' }
  }
  # инструменты склада без явной записи выше — сопоставляем УНИВЕРСАЛЬНО по имени из
  # реестра (разделители -/_/. взаимозаменяем, регистр не важен). Записи выше и
  # служебные opencode-* не трогаем: ContainsKey проверка не даёт их переписать.
  $toolIds = @()
  try {
    $regFile = Join-Path $regRoot '_registry.json'
    if (Test-Path -LiteralPath $regFile) {
      $regJ = Get-Content -LiteralPath $regFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      if ($regJ -and $regJ.tools) { $toolIds = @($regJ.tools | ForEach-Object { "$($_.name)" } | Where-Object { $_ }) }
    }
  } catch { $toolIds = @() }
  foreach ($tid in $toolIds) {
    if ($script:toolSkip -contains $tid) { continue }
    if ($match.ContainsKey($tid)) { continue }
    $pat = ((($tid -split '[-_]') | ForEach-Object { [regex]::Escape($_) }) -join '[-_.]?')
    # GetNewClosure обязателен: иначе все правила видели бы ПОСЛЕДНЕЮ переменную $pat
    $match[$tid] = {
      ($_.Name -and $_.Name -match $pat) -or
      ($_.ExecutablePath -and $_.ExecutablePath -match $pat) -or
      ($_.CommandLine -and $_.CommandLine -match $pat)
    }.GetNewClosure()
  }
  $out = @{}
  foreach ($k in $match.Keys) {
    $ps = @($all | Where-Object { & $match[$k] })
    if ($ps.Count -eq 0 -and $k -ne 'lab') { continue }
    $ram = ($ps | Measure-Object WorkingSetSize -Sum -ErrorAction SilentlyContinue).Sum
    $cpu = ($ps | Measure-Object -Property KernelModeTime -Sum -ErrorAction SilentlyContinue).Sum +
           ($ps | Measure-Object -Property UserModeTime -Sum -ErrorAction SilentlyContinue).Sum
    $out[$k] = [pscustomobject]@{
      Ram  = if ($ram) { [long]$ram } else { 0 }
      CpuTicks = if ($cpu) { [double]$cpu } else { 0.0 }   # накапливаемое время CPU в тиках
      Where = 'CPU'
      # pid-ы узла: переиспользуем ЭТОТ ЖЕ опрос для владения/персистентности,
      # второй Get-CimInstance не делаем
      Pids = (($ps.ProcessId | Sort-Object) -join ',')
      ProcCount = $ps.Count
    }
  }
  return $out
}
# кэш предыдущего замера CPU и текущих значений (пересчитывается в таймере)
$script:cpuPrev = @{}
$script:perf = @{}
$script:procs = $null     # последний снимок Get-ProcsByNode (переиспользуется)
$script:diskSizes = @{}
$script:perfLast = [DateTime]::MinValue

function Get-PerfText($nodeId) {
  # агрегация RAM и диска одного агента (ollama-prov и ollama делят процесс)
  $p = $script:perf
  if (-not $p -or -not $p.ContainsKey($nodeId)) { return '' }
  $m = $p[$nodeId]
  $parts = @()
  if ($m.Ram -gt 0) { $parts += ("ram:{0}" -f (Format-Size $m.Ram)) }
  # CPU показываем ВСЕГДА, даже когда он нулевой: раньше при CpuPct < 0.5 строка
  # обрывалась на голом «CPU» без числа — было не отличить «измерение есть, 0%»
  # от «процессор не считали».
  $parts += ("cpu:{0}%" -f [int][Math]::Max(0.0, [double]$m.CpuPct))
  if ($m.Disk -gt 0) { $parts += ("dsk:{0}" -f (Format-Size $m.Disk)) }
  $parts += $m.Where
  return ($parts -join '  ')
}

function Format-Size([long]$bytes) {
  if ($bytes -ge 1GB)  { return ('{0:f1}G' -f ($bytes/1GB)) }
  if ($bytes -ge 1MB)  { return ('{0:f0}M' -f ($bytes/1MB)) }
  return ('{0}K' -f [int]([Math]::Ceiling($bytes/1KB)))
}

# множитель скорости убывания в подписи карты («×1», «×0.25»).
# Объявлена ЗДЕСЬ, а не в GUI-части: подпись печатает и снимок -Shot, который
# отрабатывает раньше, чем до скрипта доходит определение в GUI-части.
function Format-Mult([double]$m) {
  if ($m -eq [Math]::Truncate($m)) { return ('×' + [int]$m) }
  return ('×' + $m.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture))
}

# ---------- СВОДКА ИНФРАСТРУКТУРЫ (одна строка на всё) ----------
# Суммы считаются по УЖЕ посчитанным хешам: $script:perf (RAM/CPU по узлам) и
# $script:nodeState (состояния). Своих обходов системы здесь нет — ни одного
# лишнего Get-CimInstance и ни одного повторного измерения.
# Возврат: @{ Ram; Cpu; With; Counts; Text } где With = число узлов с телеметрией.
function Get-InfraTotals {
  $ram = [long]0
  $cpu = 0.0
  $with = 0
  if ($script:perf) {
    foreach ($k in $script:perf.Keys) {
      $m = $script:perf[$k]
      $ram += [long]$m.Ram
      $cpu += [double]$m.CpuPct
      $with++
    }
  }
  $counts = @{ active = 0; idle = 0; unloaded = 0; 'need-guard' = 0; fault = 0 }
  if ($script:nodeState) {
    foreach ($k in $script:nodeState.Keys) {
      $s = "$($script:nodeState[$k].State)"
      if ($counts.ContainsKey($s)) { $counts[$s] = $counts[$s] + 1 }
    }
  }
  $txt = ('итого: {0} узлов с телеметрией · RAM {1} · CPU {2}% · active {3} / idle {4} / unloaded {5} / need-guard {6} / fault {7}' -f
    $with, (Format-Size $ram), [int]$cpu, $counts['active'], $counts['idle'],
    $counts['unloaded'], $counts['need-guard'], $counts['fault'])
  return @{ Ram = $ram; Cpu = $cpu; With = $with; Counts = $counts; Text = $txt }
}

# обновить метрики (вызывается по таймеру, каждые 3 с)
function Update-Perf {
  $now = [DateTime]::UtcNow
  $procs = Get-ProcsByNode
  $script:procs = $procs      # один опрос на тик: pid-ы/владение берём отсюда
  # раз в 5 минут и при первом запуске пересчитываем размеры на диске (до построения perf)
  if (($now - $script:perfLast).TotalMinutes -gt 5 -or $script:diskSizes.Count -eq 0) {
    $script:diskSizes = @{}
    # каталоги могут отсутствовать (или не заданы вовсе) — тогда метрика dsk = 0,
    # узел остаётся живым, просто без размера. Get-DirSize тоже проверяет путь.
    $script:diskSizes['ollama'] = if ($OllamaModelsDir -and (Test-Path -LiteralPath $OllamaModelsDir)) { Get-DirSize $OllamaModelsDir } else { 0 }
    $dockerVhdx = $null
    foreach ($cand in $DockerWslCandidates) {
      if (-not $cand) { continue }
      if (Test-Path -LiteralPath $cand) { $dockerVhdx = $cand; break }
    }
    $script:diskSizes['docker'] = if ($dockerVhdx) { Get-DirSize $dockerVhdx } else { 0 }
    $script:diskSizes['lab']    = if ($LabDir -and (Test-Path -LiteralPath $LabDir)) { Get-DirSize $LabDir } else { 0 }
    $script:perfLast = $now
  }
  $cores = [Math]::Max(1, [Environment]::ProcessorCount)
  $pct = @{}
  foreach ($k in $procs.Keys) {
    $m = $procs[$k]
    $prev = $script:cpuPrev[$k]
    $diff = 0.0
    if ($prev) {
      $dt = ($now - $prev.Time).TotalSeconds
      if ($dt -gt 0.1) { $diff = ($m.CpuTicks - $prev.Ticks) / ($dt * 10000000) }  # сек/сек
    }
    $script:cpuPrev[$k] = @{ Time = $now; Ticks = $m.CpuTicks }
    $pct[$k] = [Math]::Min(999, [Math]::Max(0.0, ($diff / $cores) * 100.0))
  }
  $script:perf = @{}
  foreach ($k in $procs.Keys) {
    $script:perf[$k] = [pscustomobject]@{
      Ram    = [long]$procs[$k].Ram
      CpuPct = $pct[$k]
      Disk   = $script:diskSizes[$k]
      Where  = 'CPU'
    }
  }
}

function Get-DirSize([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return 0 }
  try {
    if ((Get-Item -LiteralPath $path -Force).PSIsContainer) {
      return (Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    }
    return (Get-Item -LiteralPath $path -Force).Length
  } catch { return 0 }
}

# ---------- сцена + трансформ: центрирование графа в окне, масштаб ----------
$script:SceneW = 1040.0; $script:SceneH = 780.0   # виртуальная сцена (все координаты узлов)
$script:PosFrac = $null   # id -> @{ Xf; Yf } (доли сцены; ресайз решает трансформ)
$script:animT  = 0.0      # фаза анимации (змейки/пульс) по рёбрам
$script:edgeLast = @{}    # ребро "from|to" -> @{ Dir=1|-1; Last=[DateTime] } (последний реальный трафик)
$script:snakes = @()      # активные змейки-импульсы (по одной на запрос/ответ):
                          # @{ E='from|to'; Dir=1|-1; Start=[DateTime]; Sleep=0.0 (задержка старта) }
$script:edgeCursor = $null  # последний обработанный timestamp лога (дедуп событий)
$script:wdCursor   = $null  # то же для лога демона-стража (встречный трафик в граф)
$script:waking     = @{}    # id узла -> @{ Since=[DateTime] } — агенты, которых вотчдог включает

# ---------- классы узлов ----------
# Класс задаёт ПОЛ очков и допустимость выгрузки. Ключевая мысль 0.7.0:
# очки — это ЧИСЛО (насколько узел свежий/загружен), СОСТОЯНИЕ — это ПРИЧИНА
# (почему такое число), а КЛАСС — правила обращения с узлом.
$script:nodeClass = @{
  # core: пол 1.0, НЕ гаснут, выгрузка запрещена. Вместо свежести — здоровье/молчание
  'oc'       = 'core'
  'watchdog' = 'core'
  'guardian' = 'core'
  'monitor'  = 'core'
  # agent: пол 0.0, гаснут; 0% = unloaded, подъём через вотчдог
  'openrouter' = 'agent'
  'gordon'     = 'agent'
  'invr'       = 'agent'
  # demand: инструменты по требованию; пол 0.0; 0% = unloaded (НЕ дефект)
  'browsertool'   = 'demand'
  'firecrawl'     = 'demand'
  'local-llm'     = 'demand'
  'MCP_DOCKER'    = 'demand'
  'doc-extract'   = 'demand'
  'backup-util'   = 'demand'
  'resolve-tools' = 'demand'
  'gordon-setup'  = 'demand'
  'browser'       = 'demand'
  # остальные инструменты склада (узлы заводятся динамически по _registry.json):
  # по требованию — значит класс demand (гаснут, 0% = unloaded, выгрузка у владельца)
  'ai-provider-check' = 'demand'
  'dmr-model'         = 'demand'
  'dmr-router'        = 'demand'
  'firecrawl-key'     = 'demand'
  'layr'              = 'demand'
  'opencode-monitor'  = 'demand'
  'orch-metrics'      = 'demand'
  'run-watch'         = 'demand'
  'vmdisk'            = 'demand'
  # service: постоянные службы/хранилища; пол 0.5, не гаснут
  'ollama'      = 'service'
  'ollama-prov' = 'service'
  'docker'      = 'service'
  'lab'         = 'service'
  'rollback'    = 'service'
  'gh'          = 'service'
  'cloud'       = 'service'
  'factory-mon' = 'service'
  'janitor'     = 'service'
}
# инструменты реестра, у которых узел УЖЕ есть на карте под другим id, либо которые
# служебные (opencode-status/restart/plugins) и в узлы не выводятся
$script:toolSkip = @(
  'llm-mcp','infra-graph','mcp-watchdog','mcp-watchdog-guardian','browsertool',
  'opencode-status','opencode-restart','opencode-plugins','gordon-chat'
)
# владелец по умолчанию (интент-файлы перекрывают)
$script:nodeOwner = @{
  'oc' = 'user'; 'watchdog' = 'system'; 'guardian' = 'system'; 'monitor' = 'system'; 'janitor' = 'system'
}

# ---------- актуальность узлов (агентов/сервисов) ----------
# id -> @{ Val=1.0; Busy=$false; LastTouch=[DateTime]; LastReply=[DateTime]; Count=0; Err=0; Resolved=0; Fault=$false }
# Val: 100% на старте; затухание 0.5%/с (1% за 2с), ПОЛ задаётся классом узла;
# обращение x1.4 (кум.); пока узел "работает" (Busy) значения стоят; off при Val<=0.005.
$script:act = @{}
$script:actTick = (Get-Date)
$script:bootTime = (Get-Date)
$script:alarm = @{}   # id узла -> когда последний раз слали оркестратору сигнал «нет ответа/ошибка»
$script:tools = @('rollback','gh')   # инструменты оркестратора с двойным контуром (не гаснут до 0)
# состояние/владение/интенты (заполняется Update-NodeStates раз в тик)
$script:nodeState    = @{}   # id -> объект узла (Val/State/Intent/Owner/Class/Status/Pid)
$script:nodeStatePrev = @{}  # id -> предыдущее State (для журнала причин)
$script:candidates   = @()   # id кандидатов на выгрузку (НЕ выгружаем сами)
$script:intents      = @{}   # id -> @{ Desired; Owner; Since; Source }
$script:intentStamp  = @{}   # путь файла -> метка прочтения (чтобы не читать зря)
$script:restoredPids = @{}   # id -> pid, восстановленный из nodes.json
$script:evLast       = @{}   # id -> когда последний раз писали в events.log (троттлинг 10 с)
$script:evReason     = @{}   # id -> последняя строка журнала причин (для подсказки узла)
$script:evStamp      = 0     # метка времени events.log (журнал перечитываем только при смене)
# ---------- кэш кадра отрисовки и фильтр видимости (0.9.3) ----------
# frameBmp/frameSig — последний нарисованный кадр и его подпись: если подпись не
# изменилась, кадр НЕ перерисовывается, а просто выводится из кэша одним DrawImage.
# tickSig — подпись на последнем тике (3 с), чтобы не будить перерисовку вхолостую.
$script:frameBmp = $null
$script:frameSig = $null
$script:frameW = 0
$script:frameH = 0
$script:frameHits = 0        # кадров выведено из кэша (перерисовка не понадобилась)
$script:frameMiss = 0        # кадров перерисовано целиком
$script:tickSig = $null
$script:hideUnloaded = $false   # фильтр «только активные» (U): по умолчанию показываем всё
$script:hoverNode = $null       # узел под курсором (для подсказки с причиной состояния)
$script:hoverPt  = [System.Drawing.Point]::Empty
# фаза мигания «завис». Объявлена ЗДЕСЬ, а не в GUI-части: функциями рисования
# (Draw-FrameInto/Get-FrameSignature) пользуются все режимы, включая -Shot.
[bool]$script:pulse = $false
# персистентность: файла НЕ держим открытым — открыть/записать/закрыть, и только при изменении
$script:stateSig  = ''                       # подпись значимых полей (для «писать только при изменении»)
$script:stateLast = [DateTime]::MinValue     # когда последний раз писали
$script:stateDirty = $false
$script:PosFile = $script:PosFileNew        # запоминание ручной раскладки (вне каталога версии)

# шрифты и измерительная графика (рамки узлов считаются по тексту)
$script:fTitle = [System.Drawing.Font]::new('Segoe UI Semibold', 10.5)
$script:fSub   = [System.Drawing.Font]::new('Segoe UI', 8.2)
$script:fUp    = [System.Drawing.Font]::new('Consolas', 8)
$script:mBmp = [System.Drawing.Bitmap]::new(8, 8)
$script:mG   = [System.Drawing.Graphics]::FromImage($script:mBmp)

function Get-Transform([double]$W, [double]$H) {
  # единый масштаб + центрирование виртуальной сцены в реальном окне
  $scale = [Math]::Min($W / $script:SceneW, $H / $script:SceneH)
  $scale = [Math]::Min($scale, 1.5)
  return @{ Scale = $scale; Ox = ($W - $script:SceneW*$scale)/2; Oy = ($H - $script:SceneH*$scale)/2 }
}
function SceneToScreen($t, [double]$x, [double]$y) {
  [System.Drawing.PointF]::new($t.Ox + $x*$t.Scale, $t.Oy + $y*$t.Scale)
}
function ScreenToScene($t, [double]$x, [double]$y) {
  [System.Drawing.PointF]::new(($x - $t.Ox)/$t.Scale, ($y - $t.Oy)/$t.Scale)
}

# размер узла под его надписи (текст не выходит за рамку)
function Get-NodeSize($n) {
  $lines = $n.Label -split "`n"
  # единый вертикальный шаг строки — по высоте заголовочного шрифта (запас для подстрок)
  $step = [Math]::Ceiling($script:fTitle.Height)
  $w = 0.0
  for ($i=0; $i -lt $lines.Count; $i++) {
    $f = if ($i -eq 0) { $script:fTitle } else { $script:fSub }
    $sz = $script:mG.MeasureString($lines[$i], $f)
    if ($sz.Width -gt $w) { $w = $sz.Width }
  }
  $w = [int]($w + 34)   # маркер 8 + отступ 26
  $h = [int]($lines.Count * $step + 14)   # строки + вертикальные поля
  if ($n.Uptime -and $n.Uptime -ne '—') { $h += 16 }
  return @{ W = [Math]::Max($w, 150); H = [Math]::Max($h, 50) }
}

# автораскладка БЕЗ перекрытий: узлы выстраиваются по слоям (сверху вниз),
# внутри слоя — по центру сцены с реальными размерами и зазором; ширина слоя
# заранее суммируется, чтобы ни один узел не наехал на соседа.
function Get-DefaultPositions([array]$nodeObjs) {
  $layerIds = @(
    @('oc','watchdog','guardian','monitor'),
    @('ollama-prov','cloud','openrouter'),
    @('local-llm','firecrawl','MCP_DOCKER'),
    @('ollama','browsertool','docker','janitor'),
    @('lab','rollback','gh')
  )
  $m = @{}; if ($nodeObjs) { foreach ($n in $nodeObjs) { $m[$n.Id] = $n } }
  $pos = @{}
  $y = 24.0
  $gapH = 46.0; $gapV = 46.0
  foreach ($layer in $layerIds) {
    $row = @()
    foreach ($id in $layer) { if ($m.ContainsKey($id)) { $row += $m[$id] } }
    if ($row.Count -eq 0) { continue }
    $totalW = 0.0; $maxH = 0.0
    foreach ($n in $row) {
      $sz = Get-NodeSize $n
      $totalW += $sz.W
      if ($sz.H -gt $maxH) { $maxH = $sz.H }
    }
    $totalW += $gapH * ($row.Count - 1)
    $x = ($script:SceneW - $totalW) / 2
    foreach ($n in $row) {
      $sz = Get-NodeSize $n
      $pos[$n.Id] = Clamp-PosToScene $n.Id $x $y $sz.W $sz.H
      $x += $sz.W + $gapH
    }
    $y += $maxH + $gapV
  }
  # Узлы вне слоёв (свои узлы оператора + инструменты склада) впихиваем в СВОБОДНЫЕ
  # места сцены: сначала нижняя зона (снизу вверх — «полка» инструментов), затем,
  # если места нет, вся сцена сверху вниз. Место ищем сеткой с ПРОВЕРКОЙ ПЕРЕСЕЧЕНИЙ
  # с уже занятыми прямоугольниками, поэтому новый узел не наедет ни на сохранённый
  # узел оператора, ни на другой новый, и не вылезет за пределы сцены (обрезался бы).
  # Порядок — ИЗ ПОРЯДКА УЗЛОВ Get-NodeStatus: иначе раскладка гуляла бы от запуска.
  $gapHT = 14.0
  $stepX = 164.0        # минимальный узел 150 + зазор
  $stepY = 62.0         # минимальный узел 50  + зазор
  $taken = @()
  if ($script:PosFrac) {
    foreach ($k in $script:PosFrac.Keys) {
      if (-not $m.ContainsKey($k)) { continue }
      $f0 = $script:PosFrac[$k]
      $sz0 = Get-NodeSize $m[$k]
      $taken += ,([pscustomobject]@{ X = [double]$f0.Xf * $script:SceneW
                                     Y = [double]$f0.Yf * $script:SceneH
                                     W = $sz0.W; H = $sz0.H })
    }
  }
  $left = @()
  $tailNodes = if ($nodeObjs) { @($nodeObjs) } else { @() }
  foreach ($n in $tailNodes) { if (-not $pos.ContainsKey($n.Id)) { $left += ,$n } }
  # проход 0 — нижняя зона (снизу вверх), проход 1 — вся сцена (сверху вниз)
  foreach ($pass in 0, 1) {
    if ($left.Count -eq 0) { break }
    $ys = @()
    if ($pass -eq 0) {
      $yy = [Math]::Max($y, $script:SceneH - 90.0)
      while ($yy -ge 24.0) { $ys += $yy; $yy -= $stepY }
    } else {
      $yy = 24.0
      while ($yy -lt ($script:SceneH - 50.0)) { $ys += $yy; $yy += $stepY }
    }
    foreach ($n in @($left)) {
      $sz = Get-NodeSize $n
      $placed = $false
      foreach ($yy in $ys) {
        if ($placed) { break }
        $xx = 40.0
        while ($xx + $sz.W -le ($script:SceneW - 40.0)) {
          if ($yy + $sz.H -le ($script:SceneH - 20.0)) {
            $hit = $false
            foreach ($r in $taken) {
              if ($xx -lt ($r.X + $r.W) -and ($xx + $sz.W) -gt $r.X -and
                  $yy -lt ($r.Y + $r.H) -and ($yy + $sz.H) -gt $r.Y) { $hit = $true; break }
            }
            if (-not $hit) {
              $pos[$n.Id] = Clamp-PosToScene $n.Id $xx $yy $sz.W $sz.H
              $taken += ,([pscustomobject]@{ X = $xx; Y = $yy; W = $sz.W; H = $sz.H })
              $left = @($left | Where-Object { $_.Id -ne $n.Id })
              $placed = $true
              break
            }
          }
          $xx += $stepX
        }
      }
      # место не нашлось (сцена исчерпана) — ставим под слои, как раньше:
      # лучше видимый «лишний» узел, чем пропавший
      if (-not $placed) {
        $pos[$n.Id] = [System.Drawing.Point]::new(40, [int]($script:SceneH - 70))
        $left = @($left | Where-Object { $_.Id -ne $n.Id })
      }
    }
  }
  return $pos
}

function Save-Positions {
  try {
    $dir = Split-Path $script:PosFile -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj = @{}
    foreach ($k in $script:PosFrac.Keys) {
      $f = $script:PosFrac[$k]
      $obj[$k] = [pscustomobject]@{ Xf = [Math]::Round($f.Xf, 4); Yf = [Math]::Round($f.Yf, 4) }
    }
    $obj | ConvertTo-Json | Set-Content -LiteralPath $script:PosFile -Encoding utf8
  } catch { }
}

# ---------- зажатие позиции узла в границы сцены ----------
# Узел, который перетащили мышью к самому краю (или координата которого пришла
# из старого файла раскладки), раньше вылезал за сцену и обрезался краем PNG.
# Сдвигаем ТОЛЬКО вылезший узел: раскладку внутри сцены не трогаем, иначе карта
# «прыгала» бы при каждом запуске. Запас сверху/снизу — подписи «N%» над узлом
# и «N%» под ним.
# Поля неодинаковы: над узлом печатается «N% ram … CPU», а под ним — счётчик и
# uptime; плюс сам подвал карты (легенда и сводка) рисуется внизу окна. Сверху
# поэтому запасаем 40, снизу 32, по бокам 14 — иначе крайние узлы ложились бы
# прямо на подписи.
$script:PosPadL = 14.0
$script:PosPadR = 14.0
$script:PosPadT = 40.0
$script:PosPadB = 32.0
function Clamp-PosToScene([string]$id, [double]$x, [double]$y, [int]$w, [int]$h) {
  $maxX = [Math]::Max($script:PosPadL, ($script:SceneW - $script:PosPadR - $w))
  $maxY = [Math]::Max($script:PosPadT, ($script:SceneH - $script:PosPadB - $h))
  $cx = [Math]::Max($script:PosPadL, [Math]::Min($x, $maxX))
  $cy = [Math]::Max($script:PosPadT, [Math]::Min($y, $maxY))
  [System.Drawing.Point]::new([int]$cx, [int]$cy)
}

function Initialize-PosFrac([array]$nodeObjs) {
  $saved = $null
  # раскладка 0.6.x лежала в каталоге версии (версия в реестре неизменяема) —
  # читаем оттуда для совместимости, а пишем всегда в monitor\state
  $readPath = $script:PosFile
  if (-not (Test-Path $readPath) -and (Test-Path $script:PosFileLegacy)) { $readPath = $script:PosFileLegacy }
  if (Test-Path $readPath) {
    try { $saved = Get-Content -LiteralPath $readPath -Raw | ConvertFrom-Json } catch { $saved = $null }
  }
  if ($saved) {
    # позиции из файла: Xf/Yf — доли сцены (ресайз-безопасны, как и autolayout).
    # Каждую запись зажимаем в сцену по РАЗМЕРУ узла: в файле могли остаться
    # координаты от прежней раскладки, где узел уезжал за правый край.
    $szOf = @{}
    if ($nodeObjs) { foreach ($n in $nodeObjs) { $szOf[$n.Id] = Get-NodeSize $n } }
    $script:PosFrac = @{}
    foreach ($prop in $saved.PSObject.Properties) {
      $v = $prop.Value
      if ($null -eq $v) { continue }
      $xf = [double]$v.Xf; $yf = [double]$v.Yf
      if ($xf -is [double] -or $xf -is [int] -or $xf -is [long]) {
        $sz = if ($szOf.ContainsKey($prop.Name)) { $szOf[$prop.Name] } else { @{ W = 150; H = 50 } }
        $cp = Clamp-PosToScene $prop.Name ($xf * $script:SceneW) ($yf * $script:SceneH) $sz.W $sz.H
        $script:PosFrac[$prop.Name] = @{ Xf = $cp.X / $script:SceneW; Yf = $cp.Y / $script:SceneH }
      }
    }
    # узлы, которых нет в файле (новые) — добавить автораскладкой
    $def = Get-DefaultPositions $nodeObjs
    foreach ($id in $def.Keys) {
      if (-not $script:PosFrac.ContainsKey($id)) {
        $p = $def[$id]
        $script:PosFrac[$id] = @{ Xf = $p.X / $script:SceneW; Yf = $p.Y / $script:SceneH }
      }
    }
    return
  }
  $def = Get-DefaultPositions $nodeObjs
  $script:PosFrac = @{}
  foreach ($k in $def.Keys) {
    $p = $def[$k]
    $script:PosFrac[$k] = @{ Xf = $p.X / $script:SceneW; Yf = $p.Y / $script:SceneH }
  }
}

# позиции узлов в координатах СЦЕНЫ (не зависят от размера окна —
# центрирование/масштаб на окно делает трансформ по Render-Time)
function Resolve-PositionsScene([array]$nodeObjs = $null) {
  if ($null -eq $script:PosFrac) {
    if ($null -eq $nodeObjs -and $script:st) { $nodeObjs = $script:st.Nodes }
    Initialize-PosFrac $nodeObjs
  }
  $out = @{}
  foreach ($k in $script:PosFrac.Keys) {
    $f = $script:PosFrac[$k]
    $out[$k] = [System.Drawing.PointF]::new($f.Xf * $script:SceneW, $f.Yf * $script:SceneH)
  }
  return $out
}

# ---------- активность рёбер по логу ----------
# Каждое ребро "from|to" получает последний РЕАЛЬНЫЙ вектор трафика:
#   Dir =  1  запрос от источника к приёмнику (поток "вниз" по ребру)
#   Dir = -1  ответ от приёмника к источнику (поток "обратно")
#   Last = время последнего события. Древние события -> стрелка гаснет, серая.
function Update-EdgeActivity {
  if (-not (Test-Path $LogPath)) { return }
  try {
    $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $fs.Seek(-([Math]::Min(400000, $fs.Length)), [System.IO.SeekOrigin]::End) | Out-Null
      $sr = New-Object System.IO.StreamReader($fs, $off)
      $tail = $sr.ReadToEnd()
    } finally { $sr.Dispose(); $fs.Dispose() }
  } catch { return }

  # одна змейка на ОДНО реальное событие (запрос/ответ); дедуп — по курсору,
  # т.к. хвост лога перечитывается каждый тик
  $foundTs = $null

  foreach ($line in ($tail -split "`r?`n")) {
    if (-not $line.StartsWith('timestamp=')) { continue }
    $mTs = [regex]::Match($line, '^timestamp=(\S+)')
    if (-not $mTs.Success) { continue }
    $ts = $null
    try {
      $ts = [datetime]::Parse($mTs.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime()
    } catch { continue }
    if ($ts -lt ((Get-Date).AddMinutes(-5))) { continue }
    if ($script:edgeCursor -and $ts -le $script:edgeCursor) { continue }
    if (-not $foundTs -or $ts -gt $foundTs) { $foundTs = $ts }

    function Reg($p) { $mm = [regex]::Match($line, $p); if ($mm.Success) { $mm.Groups[1].Value } else { $null } }

    # --- ответ модели (stream): поток идёт обратно в opencode ---
    $provId = Reg 'providerID=(\S+)'
    if ($provId) {
      $node = switch ($provId) { 'opencode' { 'cloud' } 'openrouter' { 'openrouter' } 'ollama' { 'ollama-prov' } default { $null } }
      if ($node) {
        $key = "oc|$node"
        $script:edgeLast[$key] = @{ Dir = -1; Last = $ts }
        $script:snakes += @{ E = $key; Dir = -1; Start = $ts }
        Apply-EdgeAct $key -1
        if ($node -eq 'ollama-prov') {
          $script:edgeLast['ollama-prov|ollama'] = @{ Dir = -1; Last = $ts }
          $script:snakes += @{ E = 'ollama-prov|ollama'; Dir = -1; Start = $ts }
          Apply-EdgeAct 'ollama-prov|ollama' -1
        }
      }
    }
    # --- выбор LLM-рантайма перед запросом: поток вниз (запрос) ---
    $prov = Reg 'llm\.provider=(\S+)'
    if ($prov) {
      $node = switch ($prov) { 'opencode' { 'cloud' } 'openrouter' { 'openrouter' } 'ollama' { 'ollama-prov' } default { $null } }
      if ($node) {
        $key = "oc|$node"
        $script:edgeLast[$key] = @{ Dir = 1; Last = $ts }
        $script:snakes += @{ E = $key; Dir = 1; Start = $ts }
        Apply-EdgeAct $key 1
        if ($node -eq 'ollama-prov') {
          $script:edgeLast['ollama-prov|ollama'] = @{ Dir = 1; Last = $ts }
          $script:snakes += @{ E = 'ollama-prov|ollama'; Dir = 1; Start = $ts }
          Apply-EdgeAct 'ollama-prov|ollama' 1
        }
      }
    }
    # --- вызов инструмента (permission): запрос вниз ---
    $tool = Reg 'message=evaluated permission=(firecrawl_\w+|MCP_DOCKER_\w+|local-llm_\w+)'
    if ($tool) {
      if ($tool -like 'firecrawl_*') {
        $script:edgeLast['oc|firecrawl'] = @{ Dir = 1; Last = $ts }
        $script:snakes += @{ E = 'oc|firecrawl'; Dir = 1; Start = $ts }
        Apply-EdgeAct 'oc|firecrawl' 1
      } elseif ($tool -like 'MCP_DOCKER_*') {
        $script:edgeLast['oc|MCP_DOCKER'] = @{ Dir = 1; Last = $ts }
        $script:snakes += @{ E = 'oc|MCP_DOCKER'; Dir = 1; Start = $ts }
        $script:edgeLast['MCP_DOCKER|docker'] = @{ Dir = 1; Last = $ts }
        $script:snakes += @{ E = 'MCP_DOCKER|docker'; Dir = 1; Start = $ts }
        Apply-EdgeAct 'oc|MCP_DOCKER' 1
        Apply-EdgeAct 'MCP_DOCKER|docker' 1
      } elseif ($tool -like 'local-llm_*') {
        $script:edgeLast['oc|local-llm'] = @{ Dir = 1; Last = $ts }
        $script:snakes += @{ E = 'oc|local-llm'; Dir = 1; Start = $ts }
        $script:edgeLast['local-llm|ollama'] = @{ Dir = 1; Last = $ts }
        $script:snakes += @{ E = 'local-llm|ollama'; Dir = 1; Start = $ts }
        Apply-EdgeAct 'oc|local-llm' 1
        Apply-EdgeAct 'local-llm|ollama' 1
      }
    }
    # --- MCP-сервер отработал (server log): ответ обратно ---
    $srv = Reg 'message="MCP server log" server=(\S+)'
    if ($srv) {
      $node = switch ($srv) { 'firecrawl' { 'firecrawl' } 'MCP_DOCKER' { 'MCP_DOCKER' } 'local-llm' { 'local-llm' } default { $null } }
      if ($node) {
        $key = "oc|$node"
        $script:edgeLast[$key] = @{ Dir = -1; Last = $ts }
        $script:snakes += @{ E = $key; Dir = -1; Start = $ts }
        Apply-EdgeAct $key -1
        if ($node -eq 'MCP_DOCKER') {
          $script:edgeLast['MCP_DOCKER|docker'] = @{ Dir = -1; Last = $ts }
          $script:snakes += @{ E = 'MCP_DOCKER|docker'; Dir = -1; Start = $ts }
          Apply-EdgeAct 'MCP_DOCKER|docker' -1
        }
        if ($node -eq 'local-llm') {
          $script:edgeLast['local-llm|ollama'] = @{ Dir = -1; Last = $ts }
          $script:snakes += @{ E = 'local-llm|ollama'; Dir = -1; Start = $ts }
          Apply-EdgeAct 'local-llm|ollama' -1
        }
      }
    }
  }

  # продвинули курсор: события старше него повторно змейку не создадут
  if ($foundTs) {
    if (-not $script:edgeCursor -or $foundTs -gt $script:edgeCursor) { $script:edgeCursor = $foundTs }
  } elseif (-not $script:edgeCursor) {
    $script:edgeCursor = (Get-Date)
  }

  # --- встречный трафик "объект -> демон-страж" по логу самого демона ---
  # каждая строка CHECK/WARN по конкретному серверу = сервер передал демону свой статус,
  # поэтому змейка летит ОТ сервера К демону (reverse ctl-ребра "watchdog|server").
  if (Test-Path $WdLog) {
    try {
      $wfs = [System.IO.File]::Open($WdLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      try {
        $wfs.Seek(-([Math]::Min(200000, $wfs.Length)), [System.IO.SeekOrigin]::End) | Out-Null
        $wsr = New-Object System.IO.StreamReader($wfs, $off)
        $wtail = $wsr.ReadToEnd()
      } finally { $wsr.Dispose(); $wfs.Dispose() }
    } catch { $wtail = '' }

    $wdFoundTs = $null
    # соответствие имени сервера в логе демона -> id узла графа
    $wdNodes = @{ 'local-llm'='local-llm'; 'firecrawl'='firecrawl'; 'MCP_DOCKER'='MCP_DOCKER';
                  'ollama'='ollama'; 'browsertool'='browsertool'; 'docker'='docker'; 'lab'='lab' }
    foreach ($wline in ($wtail -split "`r?`n")) {
      if ($wline -notmatch '\[(CHECK|WARN|ERROR)\]') { continue }
      $wTm = [regex]::Match($wline, '\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]')
      if (-not $wTm.Success) { continue }
      $wts = $null
      try { $wts = [datetime]::ParseExact($wTm.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null) } catch { continue }
      if ($wts -lt ((Get-Date).AddMinutes(-5))) { continue }
      if ($script:wdCursor -and $wts -le $script:wdCursor) { continue }
      if (-not $wdFoundTs -or $wts -gt $wdFoundTs) { $wdFoundTs = $wts }

      $wSrv = [regex]::Match($wline, '\d{2}:\d{2}:\d{2} (local-llm|firecrawl|MCP_DOCKER|ollama|browsertool|docker|lab)\s*:')
      if (-not $wSrv.Success) { continue }
      $node = $wdNodes[$wSrv.Groups[1].Value]
      if (-not $node) { continue }
      $key = "watchdog|$node"
      $nowW = Get-Date
      $isOk = ($wline -match '\] \[?CHECK' -or $wline -match 'CHECK.*: OK')
      # рутинный CHECK: сервер передал демону статус -> встречная змейка от объекта к демону
      $script:edgeLast[$key] = @{ Dir = -1; Last = $nowW }
      $script:snakes += @{ E = $key; Dir = -1; Start = $nowW }
      # WARN/ERROR/автодействие демона: молния ОТ демона К агенту (сброс/подъём/перезапуск)
      # НЕ повышает актуальность: мониторинговые запросы вотчдога не считаются работой агента
      if (-not $isOk) {
        $script:edgeLast[$key] = @{ Dir = 1; Last = $nowW }
        $script:snakes += @{ E = $key; Dir = 1; Start = $nowW }
        # WARN/ERROR: фиксируем ошибку узла (эпизод не удваиваем, пока не закрыт)
        if (-not $script:act.ContainsKey($node)) { $script:act[$node] = New-ActEntry }
        $aN = $script:act[$node]
        if (-not $aN.Fault) { $aN.Fault = $true; $aN.Err = $aN.Err + 1 }
        # демон получил ошибку/нет ответа -> инфо оркестратору (прими решение):
        # молния watchdog -> oc; если на агенте была свежая работа (<=5 с) и она оборвалась —
        # оркестратор тут же подключается к вотчдогу узнать причину (молния oc -> watchdog)
        $freshWork = $false
        foreach ($rk in @($script:edgeLast.Keys)) {
          if ($rk -like "watchdog|*") { continue }
          if ($rk -notlike "*|$node") { continue }
          if (((Get-Date) - $script:edgeLast[$rk].Last).TotalSeconds -lt 5) { $freshWork = $true; break }
        }
        if ($script:alarm[$node] -and ((Get-Date) - $script:alarm[$node]).TotalSeconds -lt 15) {
          # сигнал по этому же узлу недавно уже слали — не спамим
        } else {
          $script:alarm[$node] = $nowW
          Add-Snake "watchdog|oc" 1 0.2 $true
          $script:edgeLast["watchdog|oc"] = @{ Dir = 1; Last = $nowW }
        }
        if ($freshWork) {
          Add-Snake "watchdog|oc" -1 0.5
          $script:edgeLast["watchdog|oc"] = @{ Dir = -1; Last = $nowW }
        }
      } elseif ($script:act.ContainsKey($node)) {
        # узел вернулся в норму (CHECK OK) — ошибка решена
        $aN = $script:act[$node]
        if ($aN.Fault) { $aN.Fault = $false; $aN.Resolved = $aN.Resolved + 1 }
      }
      # агент только что пробуждён и вотчдог увидел, что он работает (CHECK OK):
      # вотчдог передаёт оркестратору статус и разрешение -> молния watchdog -> oc
      if ($isOk -and (Is-Waking $node)) {
        $script:waking.Remove($node)
        if ($script:act.ContainsKey($node)) { $script:act[$node].Busy = $false; $script:act[$node].LastReply = $nowW }
        Add-Snake "watchdog|oc" 1 0.0 $true
        $script:edgeLast["watchdog|oc"] = @{ Dir = 1; Last = $nowW }
      }
    }
    if ($wdFoundTs) {
      if (-not $script:wdCursor -or $wdFoundTs -gt $script:wdCursor) { $script:wdCursor = $wdFoundTs }
    } elseif (-not $script:wdCursor) {
      $script:wdCursor = (Get-Date)
    }
  }

  # выкидываем отжившие змейки (старше 5 с) — пул не растёт
  $cut = (Get-Date).AddSeconds(-5)
  $script:snakes = @($script:snakes | Where-Object { $_.Start -ge $cut })
  if ($script:snakes.Count -gt 250) { $script:snakes = @($script:snakes | Select-Object -Last 250) }
}

# плавное смешение цвета (яркое -> серое) по свежести 0..1
function Lerp-Color($cA, $cB, $t) {
  $t = [Math]::Max(0.0, [Math]::Min(1.0, $t))
  [System.Drawing.Color]::FromArgb(
    [int]($cA.A + ($cB.A - $cA.A)*$t),
    [int]($cA.R + ($cB.R - $cA.R)*$t),
    [int]($cA.G + ($cB.G - $cA.G)*$t),
    [int]($cA.B + ($cB.B - $cA.B)*$t))
}

# ---------- актуальность узлов ----------
# ПОЛ очков задаётся КЛАССОМ узла (таблица $script:nodeClass):
#   core -> 1.0 (не гаснут), service -> 0.5 (не гаснут), agent/demand -> 0.0
# off (выгружен) наступает ТОЛЬКО при Val<=0.005.
function Get-NodeClass([string]$id) {
  if ($script:nodeClass.ContainsKey($id)) { return $script:nodeClass[$id] }
  return 'service'
}
function Get-Floor([string]$id) {
  switch (Get-NodeClass $id) {
    'core'    { return 1.0 }
    'service' { return 0.5 }
    default   { return 0.0 }   # agent / demand
  }
}
# очки с учётом класса: core-узлы ВСЕГДА 1.0 (у них нет свежести, есть здоровье)
function Get-EffVal([string]$id) {
  if ((Get-NodeClass $id) -eq 'core') { return 1.0 }
  return (Get-ActVal $id)
}

# фабрика записи актуальности/ошибок узла
# Err — число НЕРЕШЁННЫХ ошибок (эпизоды WARN/нет-ответа, доложенные оркестратору);
# Resolved — сколько из них обработано (узел вернулся в OK/ответил);
# Fault — узел прямо сейчас в состоянии ошибки (эпизод не удваиваем, пока не закрыт).
function New-ActEntry {
  @{ Val = 1.0; Busy = $false; LastTouch = $null; LastReply = (Get-Date);
     Count = 0; Err = 0; Resolved = 0; Fault = $false }
}

function Get-ActVal([string]$id, [bool]$create = $false) {
  if (-not $script:act.ContainsKey($id)) {
    if (-not $create) { return 1.0 }
    $script:act[$id] = New-ActEntry
  }
  return $script:act[$id].Val
}

# инициализация актуальности всех узлов (уже восстановленные из nodes.json не трогаем)
function Init-Actuality($nodes) {
  foreach ($n in $nodes) {
    if ($script:act.ContainsKey($n.Id)) { continue }
    $e = New-ActEntry
    $cls = Get-NodeClass $n.Id
    if ($cls -eq 'core') {
      $e.Val = 1.0                                   # оркестратор/страж/демон/монитор: всегда 100%
    } elseif ($cls -eq 'service') {
      $e.Val = 0.5                                   # службы: «пол-яркости», вспышка при обращении
    } elseif ($cls -eq 'agent') {
      # внешние роутеры/агенты: выгружены по умолчанию (серый, без памяти),
      # поднимаются по требованию оркестратора (Bump-OrWake при обращении)
      $e.Val = 0.0
    }
    $script:act[$n.Id] = $e
  }
}

# "к узлу обратились" (запрос) — актуальность растёт (x1.4, с пола подъём до 1.0),
# узел занят (пауза в затухании); счётчик обращений Count++
function Touch-NodeAct([string]$id, [switch]$Request) {
  if (-not $script:act.ContainsKey($id)) { $script:act[$id] = New-ActEntry }
  $a = $script:act[$id]
  if ($Request) {
    $floor = Get-Floor $id
    if ($a.Val -le $floor) {
      $a.Val = 1.0                                   # «включили»/обращение к полу: вспышка до 100%
    } else {
      $a.Val = [Math]::Min(1.0, $a.Val * 1.4)        # было активным: +40% от предыдущего значения
    }
    $a.Busy = $true                                 # узел работает: затухание на паузе
    $a.LastTouch = (Get-Date)
    $a.Count = $a.Count + 1                         # число обращений
  } else {
    $a.Busy = $false                                # узел ответил: с этого момента затухание
    $a.LastReply = (Get-Date)
    # узел был в ошибке и ответил — инцидент закрыт (решённая ошибка)
    if ($a.Fault) { $a.Fault = $false; $a.Resolved = $a.Resolved + 1 }
  }
}

# ---------- скорость убывания востребованности (меню карты) ----------
# Множитель к скорости затухания хранится в общем файле decay.json рядом с
# nodes.json: карта и демон монитора читают его с кэшем (не чаще 1 раза в 5 с),
# меню пишет — контур подхватывает новую скорость в течение секунд.
# ×1 — обычная скорость (0.5%/с), ×0 — убывание остановлено.
$script:DecayCache = @{ Mult = 1.0; At = [datetime]::MinValue }
function Get-DecayMult {
  $age = ((Get-Date) - $script:DecayCache.At).TotalSeconds
  if ($age -lt 5) { return $script:DecayCache.Mult }
  $script:DecayCache.At = (Get-Date)
  if (-not (Test-Path -LiteralPath $script:DecayPath)) { $script:DecayCache.Mult = 1.0; return 1.0 }
  try {
    $j = Get-Content -LiteralPath $script:DecayPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $m = [double]$j.mult
    if ($m -lt 0) { $m = 0.0 }
    if ($m -gt 20) { $m = 20.0 }
    $script:DecayCache.Mult = $m
  } catch { }
  return $script:DecayCache.Mult
}
function Set-DecayMult([double]$m) {
  if ($m -lt 0) { $m = 0.0 }
  if ($m -gt 20) { $m = 20.0 }
  $obj = [ordered]@{ mult = $m; updated = (Get-Date).ToString('o') }
  try { ConvertTo-Json -InputObject $obj | Set-Content -LiteralPath $script:DecayPath -Encoding UTF8 } catch { }
  $script:DecayCache.Mult = $m
  $script:DecayCache.At = (Get-Date)
}

# затухание актуальности: 1% за 2 секунды (0.5%/с) x множитель из меню; пол — по классу узла
function Update-Actuality {
  $now = Get-Date
  $dtSec = ($now - $script:actTick).TotalSeconds
  $script:actTick = $now
  if ($dtSec -le 0) { return }
  $decay = 0.005 * $dtSec * (Get-DecayMult)
  foreach ($k in @($script:act.Keys)) {
    $a = $script:act[$k]
    if ($a.Busy) { continue }                  # пока узел работает — значения стоят
    $floor = Get-Floor $k
    $a.Val = [Math]::Max($floor, $a.Val - $decay)
  }
  $timedOut = @()
  # запрошенный узел не ответил за 5 с -> сигнал оркестратору (прими решение) + фиксация ошибки
  foreach ($k in @($script:act.Keys)) {
    $a = $script:act[$k]
    if ($a.Busy -and $a.LastTouch) {
      $wait = ($now - $a.LastTouch).TotalSeconds
      if ($wait -gt 5.0) {
        $al = $script:alarm[$k]
        if (-not $al -or (($now - $al).TotalSeconds -gt 15)) {
          $script:alarm[$k] = $now
          if (-not $a.Fault) { $a.Fault = $true; $a.Err = $a.Err + 1 }   # новый инцидент
          Add-Snake "watchdog|oc" 1 0.0 $true
          $script:edgeLast["watchdog|oc"] = @{ Dir = 1; Last = $now }
          $script:edgeLast["watchdog|$k"] = @{ Dir = 1; Last = $now }
        }
      }
      # ТАЙМ-АУТ «ЗАНЯТ»: узел держит Busy дольше -BusyTimeoutSec без ответа —
      # снимаем занятость, иначе «занятый» агент вечно висит на 100%
      if ($script:BusyTimeoutSec -gt 0 -and $wait -gt $script:BusyTimeoutSec) {
        $a.Busy = $false
        $a.LastReply = $now
        $timedOut += $k
      }
    } elseif (-not $a.Busy) {
      $script:alarm[$k] = $null                # ответил/свободен — тревога снята
    }
  }
  # тайм-аут занят: тревогу ставим ПОСЛЕ цикла, иначе она тут же снимется
  foreach ($k in $timedOut) {
    $script:alarm[$k] = $now
    Add-Snake "watchdog|oc" 1 0.0 $true
    $script:edgeLast["watchdog|oc"] = @{ Dir = 1; Last = $now }
    $script:edgeLast["watchdog|$k"] = @{ Dir = 1; Last = $now }
  }
}

# ---------- протокол пробуждения агента через вотчдог ----------
# оркестратору нужен агент: oc запрашивает вотчдога -> тот включает агента (100%),
# агент отвечает статусом -> вотчдог передаёт oc разрешение -> далее прямая работа.
# Каскад змеек с задержками (Sleep), чтобы молния успела "долететь" до следующего шага.
# Ребро пары oc<->watchdog (ctl): ключ "watchdog|oc", Dir=1 = от watchdog к oc,
# Dir=-1 = от oc к watchdog (объект -> демон). ctl-ветка рисует оба направления.
function Add-Snake([string]$e, [int]$dir, [double]$sleep = 0.0, [bool]$grant = $false) {
  $now = Get-Date
  if ($sleep -gt 0) { $now = $now.AddSeconds($sleep) }
  $script:snakes += @{ E = $e; Dir = $dir; Start = $now; Sleep = $sleep; Grant = $grant }
}

# агент выключен (<=20%)/вотчдог должен его поднять: запускает каскад
# oc->[запрос]->watchdog->[включает]->agent->[статус]->watchdog->[разрешение]->oc
function Request-AgentWake([string]$id) {
  $ctlKey = "watchdog|$id"
  $ocKey  = "watchdog|oc"
  $script:waking[$id] = @{ Since = (Get-Date) }
  # 1) оркестратор просит вотчдога (молния oc -> watchdog)
  Add-Snake $ocKey -1 0.0
  $script:edgeLast[$ocKey] = @{ Dir = -1; Last = (Get-Date) }
  # 2) вотчдог включает агента: молния watchdog -> agent
  Add-Snake $ctlKey 1 0.6
  # 3) агент загрузился и отвечает статусом: агент -> watchdog
  Add-Snake $ctlKey -1 1.6
  # 4) вотчдог передаёт разрешение оркестратору: молния watchdog -> oc
  Add-Snake $ocKey 1 2.6
  $script:edgeLast[$ocKey] = @{ Dir = 1; Last = (Get-Date).AddSeconds(2.6) }
  # актуальность агента -> 100% (вотчдог дал полный запас), он работает
  if (-not $script:act.ContainsKey($id)) { $script:act[$id] = New-ActEntry }
  $script:act[$id].Val = 1.0
  $script:act[$id].Busy = $true
  $script:act[$id].LastTouch = (Get-Date)
}

# есть ли уже идущий процесс пробуждения узла (не старше 30 с)?
function Is-Waking([string]$id) {
  if (-not $script:waking.ContainsKey($id)) { return $false }
  return (((Get-Date) - $script:waking[$id].Since).TotalSeconds -lt 30)
}

# обработчик "к агенту обратились": если агент выключен - включаем через вотчдог,
# иначе - простой Touch (актуальность x1.4, busy).
# ИСКЛЮЧЕНИЕ (MCP-серверы firecrawl/local-llm/MCP_DOCKER): их МОНИТОРИТ вотчдог,
# но НЕ включает — в десктопном статусе они отключены/красные, поднимать должен
# только оркестратор/десктоп; обращение к ним = просто Touch (актуальность/счётчик).
function Bump-OrWake([string]$id) {
  if ($id -in @('firecrawl','local-llm','MCP_DOCKER')) {
    Touch-NodeAct $id -Request
    return
  }
  # core-узлы не «просыпаются» — они всегда 100%, обращение только считаем
  if ((Get-NodeClass $id) -eq 'core') {
    Touch-NodeAct $id -Request
    return
  }
  if ((Get-ActVal $id) -le 0.005 -and -not (Is-Waking $id)) {
    Request-AgentWake $id
  } else {
    Touch-NodeAct $id -Request
  }
}

# УНИВЕРСАЛЬНО: актуальность по любому рабочему ребру, единообразно для oc и агентов.
# Запрос (Dir=1) -> приёмник B начинает работать (busy+пауза, +40%; при выключ. - wake).
# Ответ (Dir=-1) -> приёмник B ответил (снятие busy, затухание с момента ответа).
# Ребра watchdog (<->) не считаются "работой" (мониторинг актуальность не двигает).
function Apply-EdgeAct([string]$key, [int]$dir) {
  $parts = $key -split '\|'
  if ($parts.Count -lt 2) { return }
  if ($parts[0] -eq 'watchdog' -or $parts[1] -eq 'watchdog') { return }
  $b = $parts[1]
  if ($b -in @('oc','watchdog')) { return }
  if ($dir -eq 1) { Bump-OrWake $b } else { Touch-NodeAct $b }
}

# ========================================================================
# 0.7.0: интенты, явное состояние, владение, персистентность, режим -Daemon
# ========================================================================

# ---------- интенты и владение ----------
# Источники:
#   browsertool.json - {"desired":"up|down","setBy":"...","since":"ISO"} (один узел)
#   intents.json     - {"<id>":{"desired":"up|down|none","owner":"...","since":"ISO"}}
# Отсутствие файла = интент auto (для demand) / auto (остальные).
# Читаем только при изменении метки времени файла — лишних опросов не делаем.
function Read-IntentFiles {
  $now = Get-Date
  foreach ($spec in @(
      @{ Path = $WdIntentPath;    Single = $true  },
      @{ Path = $WdGenericIntent; Single = $false }
    )) {
    $p = $spec.Path
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
    $j = $null
    try {
      $stamp = (Get-Item -LiteralPath $p -ErrorAction Stop).LastWriteTimeUtc.Ticks
      if ($script:intentStamp.ContainsKey($p) -and $script:intentStamp[$p] -eq $stamp) { continue }
      $script:intentStamp[$p] = $stamp
      $j = Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch { continue }
    if ($null -eq $j) { continue }

    $fresh = @{}
    if ($spec.Single) {
      $prop = $j.PSObject.Properties['desired']
      if ($prop) {
        $idProp = $j.PSObject.Properties['id']
        $id = if ($idProp) { "$($idProp.Value)" } else { [IO.Path]::GetFileNameWithoutExtension($p) }
        $owProp = $j.PSObject.Properties['owner']; if (-not $owProp) { $owProp = $j.PSObject.Properties['setBy'] }
        $siProp = $j.PSObject.Properties['since']
        $fresh[$id] = @{ Desired = "$($prop.Value)".ToLower()
                         Owner = $(if ($owProp) { "$($owProp.Value)" } else { $null })
                         Since = $(if ($siProp) { "$($siProp.Value)" } else { $now.ToString('o') })
                         Source = $p }
      }
    } else {
      foreach ($prop in $j.PSObject.Properties) {
        $v = $prop.Value
        if ($null -eq $v) { continue }
        $dProp = $v.PSObject.Properties['desired']
        if (-not $dProp) { continue }
        $owProp = $v.PSObject.Properties['owner']
        $siProp = $v.PSObject.Properties['since']
        $fresh[$prop.Name] = @{ Desired = "$($dProp.Value)".ToLower()
                                Owner = $(if ($owProp) { "$($owProp.Value)" } else { $null })
                                Since = $(if ($siProp) { "$($siProp.Value)" } else { $now.ToString('o') })
                                Source = $p }
      }
    }
    # узлы, убранные из файла, интент больше не задают
    foreach ($k in @($script:intents.Keys)) {
      if ($script:intents[$k].Source -eq $p -and -not $fresh.ContainsKey($k)) { $script:intents.Remove($k) }
    }
    foreach ($k in $fresh.Keys) { $script:intents[$k] = $fresh[$k] }
  }
}

# ---------- интент узла janitor: autoStart ЕГО ЖЕ конфига ----------
# autoStart=true  -> up: чистильщик нужен всегда, незапущенный демон = need-guard;
# autoStart=false -> none: его не просят, незапущенный = unloaded (серый, НЕ поломка).
# Явный интент из intents.json приоритетнее — конфигом его НЕ перетираем.
# Своя запись помечена Source "<config.json>#autoStart", поэтому Read-IntentFiles
# её не удаляет (удаление срабатывает только при совпадении Source с путём файла).
function Set-JanitorIntent($autoStart) {
  $src = if ($JanitorDir) { "$(Join-Path $JanitorDir 'config.json')#autoStart" } else { $null }
  $have = $script:intents.ContainsKey('janitor')
  if ($have) {
    $own = $src -and ($script:intents['janitor'].Source -eq $src)
    if (-not $own) { return }                                  # файловый интент главнее
    if (($null -eq $autoStart) -or (-not $src)) { $script:intents.Remove('janitor'); return }
    $janDesired = if ($autoStart) { 'up' } else { 'none' }
    $script:intents['janitor'].Desired = $janDesired
    return
  }
  if (($null -eq $autoStart) -or (-not $src)) { return }       # конфига нет — остаётся auto
  $janDesired = if ($autoStart) { 'up' } else { 'none' }
  $script:intents['janitor'] = @{
    Desired = $janDesired
    Owner   = 'system'
    Since   = ((Get-Date).ToString('o'))
    Source  = $src
  }
}

# интент узла: auto|up|down|none (none == «не запускать»)
function Get-NodeIntent([string]$id) {
  if ($script:intents.ContainsKey($id)) {
    $d = $script:intents[$id].Desired
    if ($d) { return $d }
  }
  return 'auto'
}

# владелец узла: opencode|guardian|user|system
function Get-NodeOwner([string]$id) {
  if ($script:intents.ContainsKey($id) -and $script:intents[$id].Owner) { return $script:intents[$id].Owner }
  if ($script:nodeOwner.ContainsKey($id)) { return $script:nodeOwner[$id] }
  switch (Get-NodeClass $id) {
    'demand' { return 'opencode' }
    'agent'  { return 'opencode' }
    default  { return 'system' }
  }
}

# ---------- ЯВНОЕ СОСТОЯНИЕ узла ----------
# Очки — это число. Состояние — это ПРИЧИНА, почему оно такое.
#   active      - Val > 0.5
#   idle        - 0 < Val <= 0.5
#   unloaded    - Val <= 0.005 (выгружен по требованию; НЕ дефект)
#   need-guard  - Val <= 0.005, но интент = up (кого-то надо прямо сейчас)
#   fault       - узел реально упал (красный) и его НЕ отпускают
# Инструмент с интентом none/down, который не запущен, = unloaded + СЕРЫЙ, не красный.
#
# ИНТЕНТ 'auto' (по умолчанию) трактуется ПО КЛАССУ узла (0.8.0):
#   core/service  — «нужен всегда»: красный = fault (страж/служба упали — это факт);
#   demand/agent  — «по требованию»: красный = unloaded (не запускали и не просим —
#                   это НЕ поломка; решение о запуске/завершении у владельца).
# Раньше 'auto' считался «нужным» для всех, из-за чего выключенный по требованию
# browsertool выглядел как fault. Теперь красным становится только реальная поломка.
function Test-NodeWanted([string]$id, [string]$intent) {
  if ($intent -eq 'up') { return $true }
  if ($intent -eq 'auto') {
    $cls = Get-NodeClass $id
    return ($cls -eq 'core' -or $cls -eq 'service')
  }
  return $false   # none, down, '' и всё прочее — «не просим»
}

function Get-NodeState([string]$id, [string]$status, [double]$val, [string]$intent, [string]$owner) {
  $wanted = Test-NodeWanted $id $intent
  # 0.8.0: сначала смотрим ФАКТ жизни узла, потом очки.
  # Раньше «очки ещё не истекли» маскировало остановленный узел как active.
  if ($status -eq 'red')   { if ($wanted) { return 'fault' } else { return 'unloaded' } }  # упал
  if ($status -eq 'gray')  { if ($intent -eq 'up') { return 'need-guard' } else { return 'unloaded' } }  # не запущен, а нужен
  # 0.8.1: узел ЖИВ (green/yellow) — решают очки. need-guard означает «нужен, но
  # не работает», поэтому живой узел с истёкшими очками = простаивает (idle),
  # а не «нужен». Иначе три живых MCP-сервера вечно светились бы «нужен».
  if ($val -gt 0.5)   { return 'active' }
  if ($val -gt 0.005) { return 'idle' }
  return $(if ($intent -eq 'up') { 'idle' } else { 'unloaded' })   # простаивает ИЛИ выгружен по требованию
}

# цвет статуса узла с учётом интента: «не запускали и не просим» — это не поломка
function Resolve-NodeStatusColor([string]$id, [string]$st) {
  if ($st -ne 'red') { return $st }
  if ((Get-NodeClass $id) -eq 'core') { return $st }   # core не маскируем: стража/демон упал — факт
  $intent = Get-NodeIntent $id
  if ($intent -eq 'none' -or $intent -eq 'down' -or $intent -eq 'auto') { return 'gray' }
  return $st
}

# ---------- кандидаты на выгрузку (БЕЗ самоубийства) ----------
# Выгружать можно ТОЛЬКО выгруженные узлы классов agent/demand, у которых интент
# не up. Core-узлы (oc/watchdog/guardian/monitor) и службы выгрузке НЕ подлежат —
# запрет зашит в коде, а не в настройке.
function Test-UnloadAllowed([string]$id) {
  if ($id -in @('oc','watchdog','guardian','monitor')) { return $false }
  $cls = Get-NodeClass $id
  if ($cls -eq 'core' -or $cls -eq 'service') { return $false }
  if ((Get-NodeIntent $id) -eq 'up') { return $false }
  return $true
}

# когда к узлу последний раз обращались (для оценки простоя)
function Get-NodeIdleSec([string]$id) {
  $last = $script:bootTime
  if ($script:act.ContainsKey($id)) {
    $a = $script:act[$id]
    if ($a.LastReply) { $last = $a.LastReply }
    if ($a.LastTouch -and $a.LastTouch -gt $last) { $last = $a.LastTouch }
  }
  return ((Get-Date) - $last).TotalSeconds
}

# pid-ы узла: из уже снятого снимка процессов, иначе восстановленные (если живы)
function Get-NodePid([string]$id) {
  if ($script:procs -and $script:procs.ContainsKey($id)) { return "$($script:procs[$id].Pids)" }
  if ($script:restoredPids.ContainsKey($id)) { return "$($script:restoredPids[$id])" }
  return ''
}

# ---------- журнал причин (кольцевой, до 500 строк) ----------
function Write-StateEvent([string]$id, [string]$old, [string]$neu, [string]$reason) {
  $now = Get-Date
  # троттлинг: не чаще 1 раза в 10 с на узел
  if ($script:evLast.ContainsKey($id) -and ($now - $script:evLast[$id]).TotalSeconds -lt 10) { return }
  $script:evLast[$id] = $now
  $line = '[{0}] {1}: {2} -> {3} ({4})' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $id, $old, $neu, $reason
  try {
    $lines = @()
    if (Test-Path -LiteralPath $script:eventsPath) {
      $lines = @(Get-Content -LiteralPath $script:eventsPath -ErrorAction SilentlyContinue)
      # файл есть и непустой, а прочитать не вышло (сбой чтения/памяти) —
      # журнал НЕ затираем: лучше пропустить запись, чем потерять историю причин
      if ($lines.Count -eq 0 -and (Get-Item -LiteralPath $script:eventsPath -ErrorAction SilentlyContinue).Length -gt 0) { return }
    }
    $lines += $line
    if ($lines.Count -gt 500) { $lines = @($lines | Select-Object -Last 500) }
    $tmp = "$($script:eventsPath).tmp"
    Set-Content -LiteralPath $tmp -Value $lines -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:eventsPath -Force
  } catch { }
}

# ---------- пересчёт состояний/владения раз в тик ----------
function Update-NodeStates {
  Read-IntentFiles
  $script:nodeState = @{}
  $cand = @()
  $unloadAfter = if ($script:UnloadAfterSec -gt 0) { $script:UnloadAfterSec } else { 900 }
  if (-not $script:st) { return }
  foreach ($n in $script:st.Nodes) {
    $id     = $n.Id
    $intent = Get-NodeIntent $id
    $owner  = Get-NodeOwner $id
    $val    = Get-EffVal $id
    $st     = Get-NodeState $id $n.Status $val $intent $owner
    $cls    = Get-NodeClass $id
    $script:nodeState[$id] = [pscustomobject]@{
      Id = $id; Val = [Math]::Round([double]$val, 4); State = $st
      Intent = $intent; Owner = $owner; Class = $cls
      Wanted = (Test-NodeWanted $id $intent)
      Status = $n.Status; Pid = (Get-NodePid $id)
      IdleSec = [int](Get-NodeIdleSec $id)
    }
    # журнал причин — только на СМЕНУ состояния
    if ($script:nodeStatePrev.ContainsKey($id)) {
      $prev = $script:nodeStatePrev[$id]
      if ($prev -ne $st) {
        Write-StateEvent $id $prev $st ("val={0}%; интент={1}; {2}" -f [int]($val*100), $intent, $n.Detail)
      }
    }
    # кандидат на выгрузку: unloaded + агент/инструмент по требованию + давно простаивает
    if ($st -eq 'unloaded' -and (Test-UnloadAllowed $id) -and (Get-NodeIdleSec $id) -gt $unloadAfter) {
      $cand += $id
    }
  }
  $script:nodeStatePrev = @{}
  foreach ($k in $script:nodeState.Keys) { $script:nodeStatePrev[$k] = $script:nodeState[$k].State }
  $script:candidates = @($cand)
}

# ---------- предупреждения карты (журнал ошибок, вне каталога версии) ----------
# Троттлинг 10 минут на сообщение. Нужен для отказов, которые иначе не видны:
# Save-NodesState глотает свои исключения, и без этого молчания карта выглядела
# бы «просто не пишет», пока оператор не заметил бы, что nodes.json устарел.
$script:warnLast = @{}
function Write-GraphWarn([string]$msg) {
  $now = Get-Date
  if ($script:warnLast.ContainsKey('w') -and ($now - $script:warnLast['w']).TotalMinutes -lt 10) { return }
  $script:warnLast['w'] = $now
  try { "[$($now.ToString('yyyy-MM-dd HH:mm:ss'))] $msg" | Add-Content -LiteralPath $script:ErrLogPath -Encoding utf8 } catch { }
}

# ---------- свободное место на диске состояния (0.9.5) ----------
# Зачем: сегодня том C: заполнялся до 0 байт — падали и демон карты, и .NET-процессы.
# Место руками НЕ освобождаем (это зона владельца): инструмент только ПОКАЗЫВАЕТ
# остаток, ПРЕДУПРЕЖДАЕТ в своём журнале и бережёт остаток — при нехватке места
# карта реже перерисовывает кадр, а при критическом остатке не перерисовывает вовсе.
# nodes.json (телеметрия) при этом пишется ВСЕГДА: состояние важнее картинки.
$script:DiskWarnGb     = 5.0      # ниже — строка на карте ЖЁЛТАЯ
$script:DiskCritGb     = 2.0      # ниже — строка КРАСНАЯ
$script:DiskThrottleGb = 1.5      # ниже — кадр рисуем не чаще DiskPngMinSec
$script:DiskStopGb     = 0.5      # ниже — кадр не рисуем вовсе (nodes.json пишем)
$script:DiskPngMinSec  = 600      # 10 минут — минимальный интервал кадра при нехватке места
$script:DiskCacheSec   = 30       # опрос тома — не чаще одного раза в 30 с
$script:DiskLogMaxBytes = 1048576  # ~1 МБ: порог ротации собственных журналов
$script:diskWarnLast = @{}        # ключ режима -> когда последний раз писали предупреждение
$script:diskInfo     = $null      # @{ Root; FreeGb; TotalGb; FreePct; UpdatedAt }
$script:diskRoot     = $null      # корень тома состояния (вычисляется лениво, один раз)
$script:diskAt       = [DateTime]::MinValue
$script:diskLevel    = 'normal'   # normal | throttle | stop — режим экономии места
$script:lastFrameAt  = [DateTime]::MinValue   # когда последний раз отдавали разрешение на кадр
$script:rotAt        = [DateTime]::MinValue   # когда последний раз проверяли размер журналов

function Write-DiskWarn([string]$key, [string]$msg) {
  $now = Get-Date
  if ($script:diskWarnLast.ContainsKey($key) -and ($now - $script:diskWarnLast[$key]).TotalMinutes -lt 10) { return }
  $script:diskWarnLast[$key] = $now
  try { "[$($now.ToString('yyyy-MM-dd HH:mm:ss'))] диск: $msg" | Add-Content -LiteralPath $script:ErrLogPath -Encoding utf8 } catch { }
}

# Том, на котором лежит каталог состояния (обычно C:). Каталога может ещё не быть —
# поднимаемся до первого существующего родителя, иначе GetPathRoot по строке.
function Get-StateDiskRoot {
  try {
    $dir = Split-Path $script:statePath -Parent
    if (-not $dir) { return $null }
    $up = $dir
    while ($up -and -not (Test-Path -LiteralPath $up)) { $up = Split-Path $up -Parent }
    if ($up) { $dir = $up }
    $root = [System.IO.Path]::GetPathRoot($dir)
    if ($root) { return $root }
  } catch { }
  return $null
}

# Данные тома. Опрос дешёвый, но тик идёт каждые 3 с — держим кэш DiskCacheSec секунд.
# Возврат: @{ Root; FreeGb; TotalGb; FreePct; UpdatedAt } либо $null, если том не опознан.
function Get-DiskInfo([switch]$Force) {
  $now = Get-Date
  if (-not $Force -and $script:diskInfo -and ($now - $script:diskAt).TotalSeconds -lt $script:DiskCacheSec) {
    return $script:diskInfo
  }
  $script:diskAt = $now
  # корень запоминаем один раз: путь состояния за время работы не меняется
  if (-not $script:diskRoot) { $script:diskRoot = Get-StateDiskRoot }
  $info = $null
  if ($script:diskRoot) {
    try {
      $drv = [System.IO.DriveInfo]::new($script:diskRoot)
      $free  = [double]$drv.AvailableFreeSpace
      $total = [double]$drv.TotalSize
      if ($total -gt 0) {
        $info = [pscustomobject]@{
          Root      = "$($script:diskRoot)".TrimEnd('\')
          FreeGb    = [Math]::Round($free / 1GB, 2)
          TotalGb   = [Math]::Round($total / 1GB, 2)
          FreePct   = [Math]::Round(100.0 * $free / $total, 1)
          UpdatedAt = $now.ToString('o')
        }
      }
    } catch { $info = $null }
  }
  $script:diskInfo = $info
  return $info
}

# Число гигабайт по-русски: целое — без дробей, иначе одна цифра после запятой
# («119» / «3,5»). Разделитель — запятая: строка показывается оператору на карте.
function Format-GbText([double]$gb) {
  $v = if ([Math]::Abs($gb - [Math]::Round($gb)) -lt 0.05) { '{0:0}' -f $gb } else { '{0:0.0}' -f $gb }
  return $v.Replace('.', ',')
}

# Строка карты и -Status: «Диск C: 3,5 / 119 ГБ (3%)»
function Get-DiskText {
  $d = Get-DiskInfo
  if (-not $d) { return 'Диск: нет данных (том состояния не опознан)' }
  return ('Диск {0} {1} / {2} ГБ ({3}%)' -f $d.Root, (Format-GbText $d.FreeGb), (Format-GbText $d.TotalGb), [int][Math]::Round($d.FreePct))
}

# Уровень по месту: ok (> 5 ГБ), warning (2…5 ГБ), critical (< 2 ГБ)
function Get-DiskWarnLevel([double]$freeGb) {
  if ($freeGb -lt $script:DiskCritGb) { return 'critical' }
  if ($freeGb -lt $script:DiskWarnGb) { return 'warning' }
  return 'ok'
}

# Цвет строки о диске: зелёный / жёлтый / красный — те же цвета, что в легенде карты
function Get-DiskColor {
  $d = Get-DiskInfo
  if (-not $d) { return [System.Drawing.Color]::FromArgb(90, 96, 106) }
  switch (Get-DiskWarnLevel ([double]$d.FreeGb)) {
    'critical' { return [System.Drawing.Color]::FromArgb(235, 60, 60) }
    'warning'  { return [System.Drawing.Color]::FromArgb(235, 185, 40) }
    default    { return [System.Drawing.Color]::FromArgb(0, 200, 90) }
  }
}

# Режим экономии места: normal — обычная работа; throttle — кадр не чаще 10 минут;
# stop — кадр не рисуем вовсе (nodes.json всё равно пишется).
function Get-DiskSaveMode([double]$freeGb) {
  if ($freeGb -lt $script:DiskStopGb) { return 'stop' }
  if ($freeGb -lt $script:DiskThrottleGb) { return 'throttle' }
  return 'normal'
}

# Пересчёт режима + одна строка предупреждения в свой журнал на каждый переход.
# Возврат: 'normal' | 'throttle' | 'stop'
function Update-DiskGuard {
  $d = Get-DiskInfo
  if (-not $d) { return $script:diskLevel }
  $freeGb = [double]$d.FreeGb
  $mode = Get-DiskSaveMode $freeGb
  if ($mode -ne $script:diskLevel) {
    $script:diskLevel = $mode
    if ($mode -eq 'stop') {
      Write-DiskWarn 'stop' ('критически мало места на {0}: свободно {1} ГБ — кадр не перерисовываем, nodes.json продолжаем писать' -f $d.Root, (Format-GbText $freeGb))
    } elseif ($mode -eq 'throttle') {
      Write-DiskWarn 'throttle' ('мало места на диске {0}: свободно {1} ГБ — кадр перерисовываем не чаще раза в {2} мин' -f $d.Root, (Format-GbText $freeGb), [int]($script:DiskPngMinSec / 60))
    } else {
      Write-DiskWarn 'normal' ('место на диске {0} восстановлено: свободно {1} ГБ — обычный режим' -f $d.Root, (Format-GbText $freeGb))
    }
  }
  return $script:diskLevel
}

# Словами — уровень места (для -Status): коротко и без догадок оператора
function Get-DiskLevelText {
  $d = Get-DiskInfo
  if (-not $d) { return 'нет данных о томе' }
  switch (Get-DiskWarnLevel ([double]$d.FreeGb)) {
    'critical' { return 'критически мало места (< 2 ГБ)' }
    'warning'  { return 'мало места (2…5 ГБ)' }
    default    { return 'места достаточно (> 5 ГБ)' }
  }
}

# Словами — режим экономии места (для -Status)
function Get-DiskModeText {
  switch ($script:diskLevel) {
    'stop'     { return ('режим экономии: кадр НЕ перерисовывается (свободно < {0} ГБ), nodes.json пишется всегда' -f (Format-GbText $script:DiskStopGb)) }
    'throttle' { return ('режим экономии: кадр не чаще раза в {0} мин (свободно < {1} ГБ), nodes.json пишется всегда' -f [int]($script:DiskPngMinSec / 60), (Format-GbText $script:DiskThrottleGb)) }
    default    { return 'обычный режим' }
  }
}

# Можно ли сейчас перерисовывать кадр карты? Ограничение — только про КАДР:
# запись nodes.json от него не зависит (телеметрия важнее картинки).
function Test-FrameDrawAllowed {
  if ($script:diskLevel -eq 'stop') { return $false }
  if ($script:diskLevel -eq 'throttle') {
    return (((Get-Date) - $script:lastFrameAt).TotalSeconds -ge $script:DiskPngMinSec)
  }
  return $true
}

# То же, но с отметкой момента: вызывающий получает разрешение и «тратит» его.
function Approve-FrameDraw {
  if ($script:diskLevel -eq 'stop') { return $false }
  if ($script:diskLevel -eq 'throttle') {
    $sec = ((Get-Date) - $script:lastFrameAt).TotalSeconds
    if ($sec -lt $script:DiskPngMinSec) { return $false }
  }
  $script:lastFrameAt = Get-Date
  return $true
}

# ---------- ротация СОБСТВЕННЫХ журналов (0.9.5) ----------
# Журнал причин (events.log) и журнал отказов карты (infra-graph.err.log) не должны
# расти бесконечно. При превышении ~1 МБ файл уходит в архив с суффиксом .1 —
# РОВНО ОДНА архивная копия, прежний архив перезаписывается. Логи чужих инструментов
# не трогаем: список для ротации — только свой.
function Invoke-LogRotation([string]$path, [long]$maxBytes = 1048576) {
  if (-not $path) { return $false }
  try {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $path -Force).Length -le $maxBytes) { return $false }
    Move-Item -LiteralPath $path -Destination "$path.1" -Force
    return $true
  } catch { return $false }
}

# Обход собственных журналов. Возврат: сколько файлов убрано в архив.
function Update-LogRotation {
  $n = 0
  if (Invoke-LogRotation $script:eventsPath $script:DiskLogMaxBytes) { $n++ }
  if (Invoke-LogRotation $script:ErrLogPath   $script:DiskLogMaxBytes) { $n++ }
  if ($n -gt 0) {
    try { "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] журнал(ы) превысили $([int]($script:DiskLogMaxBytes/1KB)) КБ и убраны в архив .1 (файлов: $n)" | Add-Content -LiteralPath $script:ErrLogPath -Encoding utf8 } catch { }
  }
  return $n
}

# ---------- персистентность ----------
# Подпись ЗНАЧИМЫХ полей: если не изменилась — файл не трогаем вообще.
# LastTouch/LastReply в подпись не входят (они меняются вместе с Val/Count).
function Get-StateSignature {
  $parts = @()
  foreach ($id in ($script:nodeState.Keys | Sort-Object)) {
    $ns = $script:nodeState[$id]
    $a = $null
    if ($script:act.ContainsKey($id)) { $a = $script:act[$id] }
    if ($null -eq $a) { $parts += "${id}:0:0:0:0:0:0:$($ns.State):" ; continue }
    $parts += ('{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}:{8}' -f $id,
      [Math]::Round([double]$a.Val, 4), $a.Busy, $a.Count, $a.Err, $a.Resolved, $a.Fault,
      $ns.State, $ns.Pid)
  }
  # место на диске входит в подпись (с точностью 0.1 ГБ): если остаток заметно
  # изменился, nodes.json перезаписывается и поле disk обновляется
  $di = Get-DiskInfo
  $dpart = if ($di) { [Math]::Round([double]$di.FreeGb, 1) } else { '?' }
  return ($parts -join '|') + '#cand=' + (@($script:candidates) -join ',') + '#disk=' + $dpart
}

# Диск в подписи состояния: чтобы nodes.json обновил и поле "disk", когда место
# изменилось заметно (шаг 0.1 ГБ). Мелкий шум (мегабайты) запись не будит.
function Get-DiskSignature {
  $d = Get-DiskInfo
  if (-not $d) { return 'none' }
  return ('{0}:{1}' -f $d.Root, [Math]::Round([double]$d.FreeGb, 1))
}

function ConvertTo-IsoOrNull($v) {
  if ($null -eq $v) { return $null }
  try { return ([datetime]$v).ToString('o') } catch { return $null }
}

# Обратное преобразование. ConvertFrom-Json сам отдаёт [datetime] для ISO-строк,
# поэтому строковое представление теряет смещение, а повторный Parse + ToLocalTime
# сдвигает время второй раз. Значение без Kind считаем уже локальным.
function ConvertTo-LocalDate($v) {
  if ($null -eq $v) { return $null }
  $d = $null
  if ($v -is [datetime]) { $d = $v }
  else {
    try { $d = [datetime]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
  }
  if ($d.Kind -eq 'Unspecified') { return [datetime]::SpecifyKind($d, 'Local') }
  return $d.ToLocalTime()
}

# Запись состояния на диск: только при изменении значимых полей И не чаще
# -FlushSec секунд; атомарно (tmp + Move-Item). Файл не держим открытым.
function Save-NodesState {
  if (-not $script:nodeState -or $script:nodeState.Count -eq 0) { return }
  $sig = Get-StateSignature
  if ($sig -eq $script:stateSig) { $script:stateDirty = $false; return }
  $now = Get-Date
  if ($script:FlushSec -gt 0) {
    if (($now - $script:stateLast).TotalSeconds -lt $script:FlushSec) { $script:stateDirty = $true; return }
  }
  $nodesObj = [ordered]@{}
  foreach ($id in ($script:nodeState.Keys | Sort-Object)) {
    $ns = $script:nodeState[$id]
    $a = $null
    if ($script:act.ContainsKey($id)) { $a = $script:act[$id] }
    $nodesObj[$id] = [ordered]@{
      Val       = [Math]::Round([double]$(if ($a) { $a.Val } else { 0 }), 4)
      Busy      = [bool]$(if ($a) { $a.Busy } else { $false })
      LastTouch = $(if ($a) { ConvertTo-IsoOrNull $a.LastTouch } else { $null })
      LastReply = $(if ($a) { ConvertTo-IsoOrNull $a.LastReply } else { $null })
      Count     = [int]$(if ($a) { $a.Count } else { 0 })
      Err       = [int]$(if ($a) { $a.Err } else { 0 })
      Resolved  = [int]$(if ($a) { $a.Resolved } else { 0 })
      Fault     = [bool]$(if ($a) { $a.Fault } else { $false })
      State     = $ns.State
      Owner     = $ns.Owner
      Intent    = $ns.Intent
      Class     = $ns.Class
      Wanted    = [bool]$ns.Wanted
      IdleSec   = $ns.IdleSec
      Pid       = $ns.Pid
    }
  }
  # свободное место на томе состояния (0.9.5): попадает в КОРЕНЬ файла, чтобы карта
  # и дашборд видели остаток диска. Прежние поля не тронуты — схема та же.
  $di = Get-DiskInfo
  $diskRec = [ordered]@{
    root      = if ($di) { "$($di.Root)" } else { '' }
    freeGb    = if ($di) { $di.FreeGb } else { 0 }
    totalGb   = if ($di) { $di.TotalGb } else { 0 }
    freePct   = if ($di) { $di.FreePct } else { 0 }
    updatedAt = if ($di) { "$($di.UpdatedAt)" } else { $now.ToString('o') }
  }
  $doc = [ordered]@{
    schema     = 'invr.nodes/1'
    savedAt    = $now.ToString('o')
    disk       = $diskRec
    nodes      = $nodesObj
    candidates = @($script:candidates)
  }
  try {
    $dir = Split-Path $script:statePath -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $doc | ConvertTo-Json -Depth 6
    $tmp = "$($script:statePath).tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8 -NoNewline
    # Страховка от «сорванной» записи (нехватка памяти/место на диске): при
    # ErrorActionPreference=Continue ошибка Set-Content не прерывает скрипт, и
    # следующий Move-Item перенёс бы ПУСТОЙ tmp поверх рабочего nodes.json —
    # карта молча потеряла бы файл. Поэтому пустой/подозрительно короткий tmp
    # удаляем и оставляем прежнее состояние на диске.
    if ((Get-Item -LiteralPath $tmp -ErrorAction Stop).Length -lt 32) {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      Write-GraphWarn "состояние НЕ записано: временный файл вышел пустым (обычно кончилось место на диске) — $tmp"
      return
    }
    Move-Item -LiteralPath $tmp -Destination $script:statePath -Force
    $script:stateSig = $sig
    $script:stateDirty = $false
    $script:stateLast = $now
  } catch {
    Write-GraphWarn "состояние не записано: $($_.Exception.Message)"
  }
}

# Загрузка очков при старте: файл свежий (не старше -MaxAgeSec) — берём очки,
# счётчики и ошибки; pid проверяем на живость, мёртвый сбрасываем.
function Restore-NodesState {
  $p = $script:statePath
  if (-not $p -or -not (Test-Path -LiteralPath $p)) { return $false }
  $j = $null
  try { $j = Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
  if ($null -eq $j) { return $false }
  if ("$($j.schema)" -ne 'invr.nodes/1') { return $false }
  $ageOk = $false
  try {
    $saved = ConvertTo-LocalDate $j.savedAt
    $age = ((Get-Date) - $saved).TotalSeconds
    # будущая метка времени тоже считаем битой (часы спешат/разъехались зоны)
    $ageOk = ($saved -and $age -le $script:MaxAgeSec -and $age -ge -300)
  } catch { $ageOk = $false }
  if (-not $ageOk) { return $false }
  if (-not $j.nodes) { return $false }

  # одной проверкой узнаём, какие pid из файла ещё живы
  $want = @()
  foreach ($prop in $j.nodes.PSObject.Properties) {
    if ("$($prop.Value.Pid)") { $want += ("$($prop.Value.Pid)" -split ',') }
  }
  $alive = @{}
  if ($want.Count -gt 0) {
    foreach ($pp in @(Get-Process -Id ($want | Sort-Object -Unique) -ErrorAction SilentlyContinue)) { $alive[[int]$pp.Id] = $true }
  }

  $n = 0
  foreach ($prop in $j.nodes.PSObject.Properties) {
    $rec = $prop.Value
    $id = $prop.Name
    $e = New-ActEntry
    try { $e.Val = [double]$rec.Val } catch { }
    $e.Busy = [bool]$rec.Busy
    $e.Count = [int]$rec.Count
    $e.Err = [int]$rec.Err
    $e.Resolved = [int]$rec.Resolved
    $e.Fault = [bool]$rec.Fault
    if ($rec.LastTouch) { $e.LastTouch = ConvertTo-LocalDate $rec.LastTouch }
    if ($rec.LastReply) { $e.LastReply = ConvertTo-LocalDate $rec.LastReply }
    # core-узлы всегда 100% — восстановленное значение не имеет силы
    if ((Get-NodeClass $id) -eq 'core') { $e.Val = 1.0 }
    $script:act[$id] = $e
    # pid восстанавливаем только живой (мёртвый — сброс, как будто его не было)
    $pv = "$($rec.Pid)"
    if ($pv) {
      $pids = @($pv -split ',' | Where-Object { $alive.ContainsKey([int]$_) })
      if ($pids.Count -gt 0) { $script:restoredPids[$id] = ($pids -join ',') }
    }
    $n++
  }
  if ($n -gt 0) {
    $script:actTick = (Get-Date)   # затухание считаем от момента старта
    return $true
  }
  return $false
}

# ---------- один тик состояния (общий для -Daemon и GUI) ----------
function Invoke-StateTick {
  Update-Perf
  Update-EdgeActivity
  $script:st = Get-NodeStatus
  Update-Actuality        # затухание очков (после свежих касаний)
  Update-NodeStates       # явное состояние + владение + интент + кандидаты
  $null = Update-DiskGuard   # место на диске: режим экономии включается/снимается сам
  # свои журналы проверяем на размер не чаще раза в минуту (ротация в .1 при > 1 МБ)
  if (((Get-Date) - $script:rotAt).TotalSeconds -ge 60) { $script:rotAt = Get-Date; $null = Update-LogRotation }
  Save-NodesState         # на диск — только при изменении и не чаще FlushSec
}

# ---------- текстовый статус ----------
if ($Once -and -not $Daemon) {
  "ключ -Once работает только вместе с -Daemon (один тик демона и выход)"
  exit 1
}
if ($Status) {
  $null = Restore-NodesState
  # CPU здесь — ДЕЛЬТА между двумя опросами (Update-Perf держит базу в cpuPrev).
  # Разовый запуск делал ровно один опрос, и сумма всегда выходила «CPU 0%», т.е.
  # сводка ресурсов показывала ноль даже под нагрузкой. Поэтому: опрос-засор ->
  # пауза -> опрос с настоящей дельтой.
  Update-Perf
  Start-Sleep -Milliseconds 1200
  Update-Perf
  $st = Get-NodeStatus
  $script:st = $st
  Init-Actuality $st.Nodes
  Update-NodeStates
  "Граф инфраструктуры (модель: $($st.Model)):"
  "id            статус состояние  очки  класс    интент владелец  uptime      детали"
  $counts = @{ active = 0; idle = 0; unloaded = 0; 'need-guard' = 0; fault = 0 }
  $st.Nodes | ForEach-Object {
    $ns = $script:nodeState[$_.Id]
    $state = if ($ns) { $ns.State } else { '?' }
    $val   = if ($ns) { $ns.Val } else { 0 }
    if ($counts.ContainsKey($state)) { $counts[$state] = $counts[$state] + 1 }
    $mark = switch ($_.Status) { 'green' { 'OK  ' } 'yellow' { 'UP  ' } 'red' { 'FAIL' } 'gray' { 'STOP' } default { ' ?  ' } }
    $perfTxt = Get-PerfText $_.Id
    $line = "{0,-13} {1} {2,-11} {3,3}% {4,-8} {5,-6} {6,-9} {7,-10} {8}" -f `
      $_.Id, $mark, $state, [int]($val * 100), (Get-NodeClass $_.Id), (Get-NodeIntent $_.Id), (Get-NodeOwner $_.Id), $_.Uptime, $_.Detail
    if ($perfTxt) { $line += "  |  $perfTxt" }
    $line
  }
  ""
  $tot = Get-InfraTotals
  "Сводка: active=$($counts['active']) idle=$($counts['idle']) unloaded=$($counts['unloaded']) need-guard=$($counts['need-guard']) fault=$($counts['fault'])"
  "Ресурсы (сумма по узлам с телеметрией): $($tot.Text)"
  "Кандидаты на выгрузку (простой > $($script:UnloadAfterSec) с, только agent/demand): " +
    $(if ($script:candidates.Count -gt 0) { @($script:candidates) -join ', ' } else { 'нет' })
  "core-узлы (выгрузка запрещена): oc, watchdog, guardian, monitor"
  $null = Update-DiskGuard
  "$(Get-DiskText) — $(Get-DiskLevelText); $(Get-DiskModeText)"
  "Файл состояния: $($script:statePath)"
  exit 0
}

# ---------- один граф — одно окно ----------
# Функция определёна ДО веток режимов: демон уходит в бесконечный цикл и до
# поздних определений никогда не доходит. Карта закрывает прежние КАРТЫ,
# демон — прежних ДЕМОНОВ; друг друга они НЕ трогают (иначе подъём демона
# прятал окно карты, и получалась петля перезапусков).
function Stop-OtherGraphWindows {
  param([string]$Kind = 'map')   # 'map' — прежние карты; 'daemon' — прежние демоны
  foreach ($pr in @(Get-Process pwsh, powershell -ErrorAction SilentlyContinue)) {
    if ($pr.Id -eq $PID) { continue }
    $isGraph = $false
    # ищем по командной строке — старый экземпляр может быть СПРЯТАН в трее
    # (после Hide у процесса нет MainWindowHandle, найти его можно только по cmdline)
    try {
      $cm = (Get-CimInstance Win32_Process -Filter "ProcessId=$($pr.Id)" -ErrorAction SilentlyContinue).CommandLine
      if ($cm -and $cm -match 'infra-graph\.ps1') {
        if ($Kind -eq 'daemon') {
          if ($cm -match '-Daemon') { $isGraph = $true }
        } else {
          if ($cm -notmatch '-Daemon' -and $cm -notmatch '-Status' -and $cm -notmatch '-Shot') { $isGraph = $true }
        }
      }
    } catch {}
    if (-not $isGraph -and $Kind -ne 'daemon') {
      # по заголовку опознаём только КАРТЫ (для демона это ловушка:
      # он «видел» окно карты и закрывал его, хотя должен — только демонов)
      try { if ($pr.MainWindowTitle -like 'Карта инфраструктуры*') { $isGraph = $true } } catch {}
    }
    if (-not $isGraph) { continue }
    try {
      "закрываю старый экземпляр графа (pid $($pr.Id))" | Add-Content -LiteralPath $script:ErrLogPath -Encoding utf8
      $null = $pr.CloseMainWindow()                     # мягко (но обработчик прячет в трей)
      if (-not $pr.WaitForExit(2500)) {                 # если остался жив — принудительно
        Stop-Process -Id $pr.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
      }
    } catch {}
  }
}

# ---------- режим -Daemon: монитор БЕЗ окна ----------
if ($Daemon) {
  $null = Restore-NodesState
  $st = Get-NodeStatus
  Init-Actuality $st.Nodes
  $script:st = $st
  Update-NodeStates
  $null = Update-DiskGuard   # 0.9.5: режим экономии места — до первого тика
  Save-NodesState
  if ($Once) {
    "тик выполнен (daemon -once); состояние: $($script:statePath)"
    exit 0
  }
  # один демон — один процесс: подъём нового демона закрывает прежнего (но НЕ карту)
  Stop-OtherGraphWindows -Kind 'daemon'
  "демон карты запущен (тик 3 с); состояние: $($script:statePath); Ctrl+C — выход"
  while ($true) {
    Start-Sleep -Seconds 3
    try { Invoke-StateTick } catch { }
  }
}

# скруглённый прямоугольник (тень, фон, рамка узла, подсказка).
# Функция ВЕРХНЕГО уровня (0.9.3): раньше она была объявлена внутри
# Invoke-DrawGraph и из подсказки узла не была видна — вызов падал в обработчике
# Paint. Область видимости общая, вызов из Invoke-DrawGraph не изменился.
function Get-RoundedRectPath($x, $y, $w, $h, $r) {
  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $d = $r * 2
  $path.AddArc($x, $y, $d, $d, 180, 90)
  $path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  return $path
}

# ---------- GDI+ рендер ----------
function Invoke-DrawGraph($g, $nodes, [bool]$pulse) {
  $W = $g.VisibleClipBounds.Width
  $H = $g.VisibleClipBounds.Height
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'AntiAliasGridFit'

  # карта статусов -> цвет
  $col = @{
    green  = [System.Drawing.Color]::FromArgb(0, 200, 90)
    yellow = [System.Drawing.Color]::FromArgb(235, 185, 40)
    red    = [System.Drawing.Color]::FromArgb(235, 60, 60)
    gray   = [System.Drawing.Color]::FromArgb(90, 96, 106)
  }
  # состояние -> цвет: unloaded = СЕРЫЙ (выгружен по требованию), а не красный
  $stateCol = @{
    'active'     = $col['green']
    'idle'       = $col['yellow']
    'need-guard' = $col['yellow']
    'fault'      = $col['red']
    'unloaded'   = [System.Drawing.Color]::FromArgb(122, 132, 148)
  }

  # трансформ: масштаб + центрирование виртуальной сцены в реальном окне
  $t   = Get-Transform $W $H
  $g.TranslateTransform($t.Ox, $t.Oy)
  $g.ScaleTransform($t.Scale, $t.Scale)
  $pos = Resolve-PositionsScene $nodes

  # связи (from -> to)
  # watchdog (демон-страж) контролирует: MCP-серверы, сервисы, docker, пул
  $edges = @(
    @('oc','ollama-prov'), @('oc','cloud'), @('oc','openrouter'),
    @('oc','local-llm'), @('oc','firecrawl'), @('oc','MCP_DOCKER'),
    @('ollama-prov','ollama'), @('local-llm','ollama'),
    @('firecrawl','ollama'), @('MCP_DOCKER','docker'),
    @('oc','browsertool'), @('oc','lab'), @('lab','rollback'), @('lab','gh'),
    # демон-страж -> кого контролирует
    @('watchdog','oc','ctl'), @('watchdog','local-llm','ctl'), @('watchdog','firecrawl','ctl'),
    @('watchdog','MCP_DOCKER','ctl'), @('watchdog','ollama','ctl'), @('watchdog','browsertool','ctl'),
    @('watchdog','docker','ctl'), @('watchdog','lab','ctl'),
    # пул ИИ -> какие модели/пулы использует в каскаде
    @('lab','ollama-prov'), @('lab','cloud'),
    # openrouter — внешний роутер: канал включения по требованию оркестратора
    @('watchdog','openrouter','ctl'),
    # страж демона -> демон; демон -> монитор карты; монитор -> оркестратор
    @('guardian','watchdog','ctl'), @('watchdog','monitor','ctl'), @('monitor','oc','ctl'),
    # свои узлы оператора: склад INVR обслуживает состав, надзор фабрики и агент
    # gordon — под контролем демона-стража (подъём через вотчдог)
    @('oc','invr'), @('watchdog','factory-mon','ctl'), @('watchdog','gordon','ctl'),
    # оркестратор поднимает чистильщика автозапуском (plugin janitor-autostart)
    @('oc','janitor','ctl')
  )

  $nodeMap = @{}; foreach ($n in $nodes) { $nodeMap[$n.Id] = $n }

  # координаты центров узлов в сцене
  $cen = @{}
  foreach ($n in $nodes) {
    if (-not $pos.ContainsKey($n.Id)) { continue }
    $sz = Get-NodeSize $n
    $p  = $pos[$n.Id]
    $cen[$n.Id] = @{ X = $p.X + $sz.W/2; Y = $p.Y + $sz.H/2; W = $sz.W; H = $sz.H }
  }

  # рисуем связи
  # РАБОЧАЯ связь = оба узла живые (не red/не gray) -> направленная анимация
  # (змейка летит строго по вектору запроса: от источника к приёмнику).
  # Нерабочая связь -> сухая пунктирная линия, БЕЗ анимации.
  $iEdge = 0
  foreach ($e in $edges) {
    if (-not $cen.ContainsKey($e[0]) -or -not $cen.ContainsKey($e[1])) { $iEdge++; continue }
    $cA = $cen[$e[0]]; $cB = $cen[$e[1]]
    $nA = $nodeMap[$e[0]]; $nB = $nodeMap[$e[1]]
    $actA = Get-EffVal $e[0]; $actB = Get-EffVal $e[1]
    # связь рабочая только если оба узла НЕ выключены (актуальность выше 0%)
    $aliveA = ($null -ne $nA) -and ($nA.Status -notin @('red','gray')) -and ($actA -gt 0.005)
    $aliveB = ($null -ne $nB) -and ($nB.Status -notin @('red','gray')) -and ($actB -gt 0.005)
    $x1 = $cA.X; $y1 = $cA.Y + $cA.H/2          # низ источника
    $x2 = $cB.X; $y2 = $cB.Y - $cB.H/2          # верх приёмника

    # контрольные рёбра демона-стража: пунктирная лиловая линия (не трафик)
    if ($e.Count -gt 2 -and $e[2] -eq 'ctl') {
      $ctlOn  = [System.Drawing.Color]::FromArgb(168, 120, 235)
      $ctlOff = [System.Drawing.Color]::FromArgb(78, 64, 110)
      $ctlFade = 0.0; if ($nA.Status -eq 'gray') { $ctlFade = 1.0 }
      # встречный трафик "объект -> демон": свежий статус от сервера подсвечивает ребро
      $ctlKey = "watchdog|$($e[1])"
      $wAct = $script:edgeLast[$ctlKey]
      $wFresh = 0.0
      if ($wAct) {
        $wAge = ((Get-Date) - $wAct.Last).TotalSeconds
        $wFresh = [Math]::Max(0.0, 1.0 - $wAge/5.0)
      }
      $ctlC = Lerp-Color $ctlOn $ctlOff $ctlFade
      if ($wFresh -gt 0.05) { $ctlC = Lerp-Color ([System.Drawing.Color]::FromArgb(235, 190, 120)) $ctlOn (1 - $wFresh) }
      $penCtl = [System.Drawing.Pen]::new($ctlC, 1.4)
      $penCtl.DashStyle = 'Dot'
      $g.DrawLine($penCtl, $x1, $y1, $x2, $y2)
      # маленький кубик-маркер "контроль" в середине ребра
      $mx = ($x1+$x2)/2; $my = ($y1+$y2)/2
      $cb = [System.Drawing.SolidBrush]::new($ctlC)
      $g.FillRectangle($cb, ($mx-2), ($my-2), 4, 4)
      $cb.Dispose()
      # змейка встречного трафика: сервер передал демону статус -> летит ОТ объекта К демону
      if ($wFresh -gt 0.05) {
        $wLen = [Math]::Sqrt(($x2-$x1)*($x2-$x1) + ($y2-$y1)*($y2-$y1))
        if ($wLen -gt 0.1) {
          $wIx  = ($x2-$x1)/$wLen; $wIy = ($y2-$y1)/$wLen
          $wNow = Get-Date
          $wSnOn  = [System.Drawing.Color]::FromArgb(235, 190, 120)
          $wSnOff = [System.Drawing.Color]::FromArgb(96, 102, 112)
          foreach ($wsn in $script:snakes) {
            if ($wsn.E -ne $ctlKey) { continue }
            $wsAge = ($wNow - $wsn.Start).TotalSeconds
            if ($wsAge -gt 5.0) { continue }
            if ($wsAge -lt 0.0) { continue }
            $wsProg = [Math]::Min(1.0, $wsAge / 1.2)
            $wsAl = 1.0 - $wsAge / 5.0
            # объект -> демон: стартуем с $x2 (объект) и несём в сторону $x1 (демон)
            $gX = $x2; $gY = $y2; $gT = -1.0
            if ($wsn.Dir -eq 1) { $gX = $x1; $gY = $y1; $gT = 1.0 }
            for ($s=0; $s -lt 10; $s++) {
              $d = $wsProg - $s*0.028
              if ($d -lt 0) { $d += 1 }
              $px = $gX + $wIx*$gT*$wLen*$d
              $py = $gY + $wIy*$gT*$wLen*$d
              $wave = [Math]::Sin($s*1.1 - $script:animT*7.0) * 5
              $px += -$wIy*$gT*$wave; $py += $wIx*$gT*$wave
              $aa = (230 * [Math]::Max(0.0, (1 - $s/12)))
              $snC = Lerp-Color $wSnOn $wSnOff (1 - $wsAl)
              $snA = [System.Drawing.Color]::FromArgb([int]($aa * $wsAl), $snC.R, $snC.G, $snC.B)
              $rc = 1.6 + (2.4 * (1 - $s/12))
              $ib = [System.Drawing.SolidBrush]::new($snA)
              $g.FillEllipse($ib, ($px-$rc), ($py-$rc), ($rc*2), ($rc*2))
              $ib.Dispose()
            }
          }
        }
      }
      $penCtl.Dispose()
      $iEdge++
      continue
    }

    if (-not ($aliveA -and $aliveB)) {
      # нерабочая связь: пунктир, без свечения/змейки/стрелки
      $penDead = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(60, 70, 85), 1.2)
      $penDead.DashStyle = 'Dash'
      $g.DrawLine($penDead, $x1, $y1, $x2, $y2)
      $penDead.Dispose()
      $iEdge++
      continue
    }

    # --- РАБОЧАЯ связь: свечение + базовая линия ---
    # активность ребра по логу (реальные запросы/ответы)
    $actKey = "$($e[0])|$($e[1])"
    $act = $script:edgeLast[$actKey]
    $fresh = 0.0
    if ($act) {
      $ageSec = ((Get-Date) - $act.Last).TotalSeconds
      $fresh  = [Math]::Max(0.0, 1.0 - $ageSec/5.0)   # свежий вектор -> 1, гаснет за 5 с
    }
    $dirFlip = if ($act -and $fresh -gt 0.1) { if ($act.Dir -eq -1) { -1 } else { 1 } } else { 1 }
    # при "ответе" поток идёт в обратную сторону (от приёмника к источнику)
    $sX = $x1; $sY = $y1; $tX = $x2; $tY = $y2
    if ($dirFlip -eq -1) { $sX = $x2; $sY = $y2; $tX = $x1; $tY = $y1 }

    $colBright = [System.Drawing.Color]::FromArgb(90, 190, 235)
    $colDim    = [System.Drawing.Color]::FromArgb(82, 88, 98)
    $colArwOn  = [System.Drawing.Color]::FromArgb(205, 225, 245)
    $colArwOff = [System.Drawing.Color]::FromArgb(66, 72, 82)

    # свечение под линией - гасится с потерей свежести
    $glowC = Lerp-Color ([System.Drawing.Color]::FromArgb(45, 90, 130)) ([System.Drawing.Color]::FromArgb(24, 27, 33)) (1 - $fresh)
    $penGlow = [System.Drawing.Pen]::new($glowC, 8)
    $g.DrawLine($penGlow, $x1, $y1, $x2, $y2)
    $edgeC = Lerp-Color ([System.Drawing.Color]::FromArgb(120, 150, 200)) ([System.Drawing.Color]::FromArgb(62, 68, 78)) (1 - $fresh)
    $penEdge = [System.Drawing.Pen]::new($edgeC, 1.6)
    $g.DrawLine($penEdge, $x1, $y1, $x2, $y2)
    $penEdge.Dispose(); $penGlow.Dispose()
    # змейки-импульсы: по одной на КАЖДОЕ событие (запрос/ответ).
    # события, которые ещё не "проползли" 5 сек, визуально идут по ребру
    # строго по вектору события; ответ (Dir=-1) ползёт от ответчика к источнику.
    $len = [Math]::Sqrt(($x2-$x1)*($x2-$x1) + ($y2-$y1)*($y2-$y1))
    if ($len -lt 0.1) { $iEdge++; continue }
    $ix  = ($x2-$x1)/$len; $iy = ($y2-$y1)/$len   # единичный вектор по ребру (сверху вниз)
    $now = Get-Date
    $snakeOn  = [System.Drawing.Color]::FromArgb(80, 220, 255)
    $snakeOff = [System.Drawing.Color]::FromArgb(96, 102, 112)
    foreach ($sn in $script:snakes) {
      if ($sn.E -ne $actKey) { continue }
      $age = ($now - $sn.Start).TotalSeconds
      if ($age -gt 5.0) { continue }              # отжившая — уже вычищена, но на всякий случай
      if ($age -lt 0.0) { continue }              # будущая (задержка каскада) — ждём старта
      $prog = [Math]::Min(1.0, $age / 1.2)        # сама змейка пробегает ребро ~1.2 с
      $snAl = 1.0 - $age / 5.0                    # свечение события гаснет за 5 с
      # источник/приёмник по направлению события
      $gX = $x1; $gY = $y1; $gT = 1.0
      if ($sn.Dir -eq -1) { $gX = $x2; $gY = $y2; $gT = -1.0 }
      # хвост змейки из 10 точек позади головы, с поперечной "волной"
      for ($s=0; $s -lt 10; $s++) {
        $d = $prog - $s*0.028
        if ($d -lt 0) { $d += 1 }
        $px = $gX + $ix*$gT*$len*$d
        $py = $gY + $iy*$gT*$len*$d
        $wave = [Math]::Sin($s*1.1 - $script:animT*7.0) * 5
        $px += -$iy*$gT*$wave; $py += $ix*$gT*$wave
        $aa = (230 * [Math]::Max(0.0, (1 - $s/12)))
        $snC = Lerp-Color $snakeOn $snakeOff (1 - $snAl)
        $snA = [System.Drawing.Color]::FromArgb([int]($aa * $snAl), $snC.R, $snC.G, $snC.B)
        $rc = 1.6 + (2.4 * (1 - $s/12))
        $ib = [System.Drawing.SolidBrush]::new($snA)
        $g.FillEllipse($ib, ($px-$rc), ($py-$rc), ($rc*2), ($rc*2))
        $ib.Dispose()
      }
    }
    # стрелка направления на конце реального потока (гаснет до серой при простое)
    $ang = [Math]::Atan2($tY - $sY, $tX - $sX)
    $arr = 9
    $arrC = Lerp-Color $colArwOn $colArwOff (1 - $fresh)
    $arrowBrush = [System.Drawing.SolidBrush]::new($arrC)
    $g.FillPolygon($arrowBrush, [System.Drawing.Point[]]@(
      [System.Drawing.Point]::new([int]($tX), [int]($tY)),
      [System.Drawing.Point]::new([int]($tX - $arr*[Math]::Cos($ang - 0.4)), [int]($tY - $arr*[Math]::Sin($ang - 0.4))),
      [System.Drawing.Point]::new([int]($tX - $arr*[Math]::Cos($ang + 0.4)), [int]($tY - $arr*[Math]::Sin($ang + 0.4)))
    ))
    $arrowBrush.Dispose()
    $iEdge++
  }

  # скруглённый прямоугольник (для тени, фона и рамки узла) — см. Get-RoundedRectPath выше

# рисуем узлы (размеры по надписям).
# Кисть фона и шрифт метрик живут до конца отрисовки, остальные объекты создаются
# и освобождаются по месту. try/finally — гарантия освобождения, даже если Paint
# прервётся ошибкой: иначе GDI-хэндлы накапливались бы до упора в памяти.
  $brushBg = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(28, 32, 40))
  $fMeta   = [System.Drawing.Font]::new('Segoe UI', $script:fTitle.Size)
  try {
  foreach ($n in $nodes) {
    $p = $pos[$n.Id]
    if (-not $p) { continue }
    $sz = Get-NodeSize $n
    $ns = $script:nodeState[$n.Id]
    $state = if ($ns) { $ns.State } else { '' }
    if (-not $state) { $state = Get-NodeState $n.Id $n.Status (Get-EffVal $n.Id) (Get-NodeIntent $n.Id) (Get-NodeOwner $n.Id) }
    $c = $col[$n.Status]; if (-not $c) { $c = $col['gray'] }
    # явное состояние важнее цвета статуса:
    #   unloaded  — серый (выгружен по требованию), а НЕ красный;
    #   need-guard — жёлтый (выгружен, но его ждут прямо сейчас);
    #   fault     — красный (упал и его не отпускают).
    if ($state -eq 'unloaded') { $c = $stateCol['unloaded'] }
    elseif ($state -eq 'need-guard') { $c = $stateCol['need-guard'] }
    if ($n.Status -eq 'red' -and -not $pulse) { $c = [System.Drawing.Color]::FromArgb(120, 32, 32) }

    # очки: core всегда 100%, у остальных — по классу (пол 0.5/0.0)
    $isCore = ((Get-NodeClass $n.Id) -eq 'core')
    $isTool = ($script:tools -contains $n.Id)   # инструменты оркестратора (двойной контур)
    $val  = Get-EffVal $n.Id
    $off  = ($val -le 0.005)
    $dim  = [Math]::Min(1.0, [Math]::Max(0.0, $val))      # 1.0 (яркий) -> 0 (тёмный/off)
    $dimC = [System.Drawing.Color]::FromArgb(30, 33, 40)   # цвет "выключенности"
    $gray = [System.Drawing.Color]::FromArgb(118, 124, 134) # выгруженный узел: нейтральный серый

    # очки + метрики НАД прямоугольником (одна строка, тот же шрифт, что заголовок)
    $pctTxt = '{0}%' -f [int]($val * 100)
    $perfTxt = if ($off) { $null } else { Get-PerfText $n.Id }
    $topTxt = if ($perfTxt) { "$pctTxt  $perfTxt" } else { $pctTxt }
    $topCol = if ($off) { $gray } else { [System.Drawing.Color]::FromArgb(120, 200, 170) }
    $psz = $script:mG.MeasureString($topTxt, $fMeta)
    $gdiTop = [System.Drawing.SolidBrush]::new($topCol)
    $g.DrawString($topTxt, $fMeta, $gdiTop,
      ($p.X + ($sz.W - $psz.Width)/2), [Math]::Max(0.0, ($p.Y - $psz.Height - 3)))
    $gdiTop.Dispose()

    # кружок-счётчик ОШИБОК над правым верхним углом узла: "нерешённые/решённые"
    # (решённые — зелёным через слэш). Показывается, если были инциденты.
    if ($script:act.ContainsKey($n.Id)) {
      $en = $script:act[$n.Id]
      if (($en.Err -gt 0) -or ($en.Resolved -gt 0)) {
        $bCx = $p.X + $sz.W - 14
        $bCy = $p.Y - 4
        $bR  = 12.0
        $bErrCol = if ($en.Err -gt 0) { [System.Drawing.Color]::FromArgb(235, 90, 90) } else { [System.Drawing.Color]::FromArgb(120, 130, 140) }
        $bP = Get-RoundedRectPath ($bCx - $bR) ($bCy - $bR/2) (2*$bR) ($bR + 2) 8
        $gdiBb = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(22, 26, 32)); $g.FillPath($gdiBb, $bP); $gdiBb.Dispose()
        $gdiBp = [System.Drawing.Pen]::new($bErrCol, 1.6); $g.DrawPath($gdiBp, $bP); $gdiBp.Dispose()
        $bP.Dispose()
        $errTxt = '{0}/' -f $en.Err
        $resTxt = '{0}' -f $en.Resolved
        $fBadge = [System.Drawing.Font]::new('Consolas', 8.0)
        $eSz = $script:mG.MeasureString($errTxt, $fBadge)
        $rSz = $script:mG.MeasureString($resTxt, $fBadge)
        $tW = $eSz.Width + $rSz.Width
        $tX = $bCx - $tW/2; $tY = $bCy - 2
        $gdiE = [System.Drawing.SolidBrush]::new($bErrCol); $g.DrawString($errTxt, $fBadge, $gdiE, $tX, $tY); $gdiE.Dispose()
        $gdiR = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(110, 205, 140)); $g.DrawString($resTxt, $fBadge, $gdiR, ($tX + $eSz.Width), $tY); $gdiR.Dispose()
        $fBadge.Dispose()
      }
    }
    # над ОРКЕСТРАТОРОМ — мигающий бейдж: сколько агентов сейчас в работе (переданы задания)
    if ($n.Id -eq 'oc') {
      $active = 0
      foreach ($ak in @($script:act.Keys)) {
        $aa = $script:act[$ak]
        if ($aa.Busy -and $aa.Val -gt 0.005) { $active++ }
      }
      if ($active -gt 0) {
        $bTxt = "агентов в работе: $active"
        $fWs = [System.Drawing.Font]::new('Segoe UI Semibold', 9.0)
        $tw = $script:mG.MeasureString($bTxt, $fWs)
        $bx = $p.X + ($sz.W - $tw.Width)/2
        $by = [Math]::Max(0.0, ($p.Y - 34))
        $glow = 200 + [int](55 * [Math]::Sin($script:animT * 5.0))   # пульсация
        $gb = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($glow, 120, 210, 130))
        $g.DrawString($bTxt, $fWs, $gb, $bx, $by)
        $fWs.Dispose(); $gb.Dispose()
      }
    }

    # тень (скруглённая, со смещением)
    $rr = 12.0
    $shadowPath = Get-RoundedRectPath ($p.X+3) ($p.Y+3) $sz.W $sz.H $rr
    $shadowBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(10,12,16))
    $g.FillPath($shadowBrush, $shadowPath)
    $shadowBrush.Dispose(); $shadowPath.Dispose()
    # фон узла (скруглённый)
    $bgPath = Get-RoundedRectPath $p.X $p.Y $sz.W $sz.H $rr
    $g.FillPath($brushBg, $bgPath)
    # рамка по статусу; выключенный (0%) - нейтральный серый
    $wb = if ($n.Status -eq 'red' -and $pulse) { 3.2 } else { 2.0 }
    $brdC = if ($off) { $gray } else { Lerp-Color $c $dimC (1 - $dim) }
    $penN = [System.Drawing.Pen]::new($brdC, $wb)
    $g.DrawPath($penN, $bgPath)
    # НЕ-агенты: двойной контур (вторая рамка внутри, цвета статуса)
    if ($isTool) {
      $inPen = [System.Drawing.Pen]::new((Lerp-Color $c $dimC (1 - $dim)), 1.2)
      $inPath = Get-RoundedRectPath ($p.X+3.5) ($p.Y+3.5) ($sz.W-7) ($sz.H-7) 8.0
      $g.DrawPath($inPen, $inPath)
      $inPen.Dispose(); $inPath.Dispose()
    }
    $penN.Dispose(); $bgPath.Dispose()
    # маркер-точка статуса (при выключении - серый)
    $mc = if ($off) { $gray } else { Lerp-Color $c $dimC (1 - $dim) }
    $gdiMc = [System.Drawing.SolidBrush]::new($mc); $g.FillEllipse($gdiMc, $p.X + 8, $p.Y + 10, 10, 10); $gdiMc.Dispose()
    # текст (рамка узла точно оборачивает надписи)
    $lines = $n.Label -split "`n"
    $fgC  = Lerp-Color ([System.Drawing.Color]::FromArgb(230, 234, 240)) $dimC (1 - $dim)
    $dC   = Lerp-Color ([System.Drawing.Color]::FromArgb(150, 158, 170)) $dimC (1 - $dim)
    $ttx  = $p.X + 26
    $tty  = $p.Y + 8
    if ($off) {
      # выключенный узел: нейтральный серый текст (вне памяти графа)
      $fgC = $gray
      $dC  = $gray
    }
    $gdiL0 = [System.Drawing.SolidBrush]::new($fgC); $g.DrawString($lines[0], $script:fTitle, $gdiL0, $ttx, $tty); $gdiL0.Dispose()
    if ($lines.Count -gt 1) { $gdiL1 = [System.Drawing.SolidBrush]::new($dC); $g.DrawString($lines[1], $script:fSub, $gdiL1, $ttx, $tty + [Math]::Ceiling($script:fTitle.Height)); $gdiL1.Dispose() }
    if ($lines.Count -gt 2) { $gdiL2 = [System.Drawing.SolidBrush]::new($dC); $g.DrawString($lines[2], $script:fSub, $gdiL2, $ttx, $tty + 2*[Math]::Ceiling($script:fTitle.Height)); $gdiL2.Dispose() }
    # явное состояние ПЕРЕД прямоугольником (слева от узла) — вместо прежних on/off
    $stCol = if ($state -eq 'unloaded') { $gray }
             elseif ($state -eq 'need-guard') { [System.Drawing.Color]::FromArgb(235, 185, 40) }
             elseif ($state -eq 'fault') { $col['red'] }
             else { [System.Drawing.Color]::FromArgb(120, 200, 150) }
    $stBrush = [System.Drawing.SolidBrush]::new($stCol)
    $stTxt = switch ($state) {
      'active'     { 'on' }
      'idle'       { 'idle' }
      'unloaded'   { 'off' }
      'need-guard' { 'need' }
      'fault'      { 'fail' }
      default      { '' }
    }
    $stSz = $script:mG.MeasureString($stTxt, $script:fUp)
    $g.DrawString($stTxt, $script:fUp, $stBrush, ($p.X - $stSz.Width - 4), ($p.Y + $sz.H/2 - $stSz.Height/2))
    $stBrush.Dispose()
    # ПОД прямоугольником: инструменты оркестратора — число обращений, остальные — очки
    if ($isTool) {
      $cnt = if ($script:act.ContainsKey($n.Id)) { $script:act[$n.Id].Count } else { 0 }
      $actTxt = '{0}' -f $cnt
      $actCol = [System.Drawing.Color]::FromArgb(205, 175, 110)   # янтарный: число обращений
    } else {
      $actTxt = '{0}%' -f [int]($val * 100)
      $actCol = if ($off) { $gray } else { $dC }
    }
    $actSz  = $script:mG.MeasureString($actTxt, $script:fUp)
    $gdiAc = [System.Drawing.SolidBrush]::new($actCol); $g.DrawString($actTxt, $script:fUp, $gdiAc, ($p.X + ($sz.W - $actSz.Width)/2), ($p.Y + $sz.H + 6)); $gdiAc.Dispose()
    # uptime (внизу рамки, по центру ширины)
    if ($n.Uptime -and $n.Uptime -ne '—' -and -not $off) {
      $upBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(120, 200, 150))
      $upTxt = 'up ' + $n.Uptime
      $upSz  = $script:mG.MeasureString($upTxt, $script:fUp)
      $g.DrawString($upTxt, $script:fUp, $upBrush, ($p.X + ($sz.W - $upSz.Width)/2), ($p.Y + $sz.H - 18))
      $upBrush.Dispose()
    }
  }
  } finally {
    $fMeta.Dispose(); $brushBg.Dispose()
    # вернуть трансформ (легенда поверх рисуется в реальных координатах)
    $g.ResetTransform()
  }
}

# Подпись с полупрозрачной подложкой. Служебные строки подвала (кандидаты,
# механизм, горячая клавиша) рисуются поверх сцены; без подложки они сливались
# с подписями «N% ram … CPU» над узлами, стоящими у верхнего края. $maxX — правая
# граница окна: строка прижимается к правому краю, но не выезжает за него.
function Draw-BackdropText($g, $font, [string]$text, $color, [double]$x, [double]$y, [double]$maxX) {
  if (-not $text) { return }
  $sz = $script:mG.MeasureString($text, $font)
  $bx = $x
  if ($maxX -gt 0) { $bx = [Math]::Min($x, ($maxX - $sz.Width - 8)) }
  $bd = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(175, 16, 19, 25))
  $fg = [System.Drawing.SolidBrush]::new($color)
  try {
    $g.FillRectangle($bd, ($bx - 4), ($y - 2), ($sz.Width + 8), ($sz.Height + 4))
    $g.DrawString($text, $font, $fg, $bx, $y)
  } finally { $fg.Dispose(); $bd.Dispose() }
}

# ---------- легенда, сводка ресурсов и подписи подвала ----------
# Отдельная функция: её зовут И окно карты, И режим -Shot — снимок должен быть
# таким же полным, как окно, иначе PNG остаётся «голой» сеткой без сводки.
# $pw/$ph — размеры области рисования в пикселях (у окна это размер панели,
# у снимка — размер битмапа), $withTip — рисовать ли подсказку узла (окно).
function Draw-LegendAndTotals($g, [double]$pw, [double]$ph, [bool]$withTip) {
  $legFont = [System.Drawing.Font]::new('Segoe UI', 8.5)
  try {
    # легенда цветов
    $items = @('работает','запущен','завис / ошибка','остановлен','выгружен по требованию')
    $cols  = @([System.Drawing.Color]::FromArgb(0,200,90), [System.Drawing.Color]::FromArgb(235,185,40),
               [System.Drawing.Color]::FromArgb(235,60,60), [System.Drawing.Color]::FromArgb(90,96,106),
               [System.Drawing.Color]::FromArgb(122,132,148))
    $x = 14.0; $y = $ph - 26.0
    for ($i=0; $i -lt $items.Count; $i++) {
      $gdiLg = [System.Drawing.SolidBrush]::new($cols[$i]); $g.FillEllipse($gdiLg, $x, $y-6, 10, 10); $gdiLg.Dispose()
      $legBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(190,196,206))
      $g.DrawString($items[$i], $legFont, $legBrush, ($x + 16), ($y - 11))
      $legBrush.Dispose()
      $x += 30 + ($items[$i].Length * 7.4)
    }
    # СВОДКА РЕСУРСОВ инфраструктуры (одна строка, по центру подвала):
    # сумма RAM/CPU по узлам с телеметрией + счётчики состояний
    $totTxt = (Get-InfraTotals).Text
    $totSz  = $script:mG.MeasureString($totTxt, $legFont)
    Draw-BackdropText $g $legFont $totTxt ([System.Drawing.Color]::FromArgb(150, 215, 200)) `
      ([Math]::Max(8.0, (($pw - $totSz.Width)/2))) ($ph - 44) 0
    # СВОБОДНОЕ МЕСТО НА ДИСКЕ состояния (0.9.5): строка видна и в окне, и в снимке.
    # Цвет: зелёный > 5 ГБ, жёлтый 2…5 ГБ, красный < 2 ГБ. При нехватке места к
    # строке добавляется «режим экономии» — тогда кадр рисуется реже или не рисуется.
    $diskTxt = Get-DiskText
    if ($script:diskLevel -ne 'normal') { $diskTxt += '  ·  режим экономии места' }
    Draw-BackdropText $g $legFont $diskTxt (Get-DiskColor) 14.0 ($ph - 60) 0
    # счётчики: кандидаты на выгрузку + тревоги — в углу, чтобы видеть «кого можно снять».
    # Список кандидатов бывает длинным (все выгруженные инструменты склада), поэтому
    # показываем первые пять и «ещё N», а строку обрезаем по ширине окна — иначе
    # она уезжала за левый край и слипалась со строкой механизма.
    $cand = @($script:candidates)
    $candTxt = if ($cand.Count -gt 0) {
      $head = if ($cand.Count -gt 5) { (@($cand | Select-Object -First 5) -join ', ') + ", ещё $($cand.Count - 5)" }
              else { $cand -join ', ' }
      "кандидаты на выгрузку: $head"
    } else { "кандидаты на выгрузку: нет" }
    $maxW = [double]($pw * 0.92)
    $guard = 0
    while ($candTxt.Length -gt 10 -and $guard -lt 300 -and $script:mG.MeasureString($candTxt, $legFont).Width -gt $maxW) {
      $candTxt = $candTxt.Substring(0, $candTxt.Length - 1); $guard++
    }
    if ($candTxt -notmatch 'нет$') { $candTxt = $candTxt.TrimEnd() + '…' }
    Draw-BackdropText $g $legFont $candTxt ([System.Drawing.Color]::FromArgb(205, 175, 110)) `
      ($pw - $script:mG.MeasureString($candTxt, $legFont).Width - 14) 10 $pw
    # подпись механизма: % над узлом — востребованность, скорость — из меню карты
    $hitAll = $script:frameHits + $script:frameMiss
    $hitTxt = if ($hitAll -gt 0) { ' · кэш кадра {0}%' -f [int](100 * $script:frameHits / $hitAll) } else { '' }
    $decTxt = ('% над узлом — востребованность (гаснет при простое), скорость ' + (Format-Mult (Get-DecayMult)) + $hitTxt)
    Draw-BackdropText $g $legFont $decTxt ([System.Drawing.Color]::FromArgb(140, 160, 190)) `
      ($pw - $script:mG.MeasureString($decTxt, $legFont).Width - 14) 28 $pw
    # ПОДСКАЗКА ГОРЯЧЕЙ КЛАВИШИ видна всегда: когда фильтр выключен — серым
    # («U — только активные узлы»), когда включён — жёлтым, чтобы «пропавшие»
    # узлы читались как действие оператора, а не как сбой карты.
    $fTxt = if ($script:hideUnloaded) { 'фильтр: только активные (U)' } else { 'U — только активные узлы' }
    Draw-BackdropText $g $legFont $fTxt `
      $(if ($script:hideUnloaded) { [System.Drawing.Color]::FromArgb(235, 185, 40) }
        else { [System.Drawing.Color]::FromArgb(120, 138, 166) }) `
      ($pw - $script:mG.MeasureString($fTxt, $legFont).Width - 14) 46 $pw
    # подсказка узла под курсором — с ПОСЛЕДНЕЙ причиной состояния из журнала
    if ($withTip -and $script:hoverNode) { Draw-NodeTip $g $legFont $script:hoverNode }
  } finally {
    $legFont.Dispose()
  }
}

# ---------- offline render: -Shot ----------
if ($Shot) {
  $null = Restore-NodesState
  # два опроса с паузой — иначе сводка на снимке всегда показывала «CPU 0%»
  Update-Perf
  Start-Sleep -Milliseconds 1200
  Update-Perf
  Update-EdgeActivity
  $st = Get-NodeStatus
  $script:st = $st
  Init-Actuality $st.Nodes
  Update-NodeStates          # состояния нужны для цвета/подписи узлов на PNG
  # 0.9.5: снимок — разовый запрос оператора, но и он бережёт место. При критическом
  # остатке (< 0,5 ГБ) PNG не создаём вовсе; при нехватке (жёлтый/режим экономии)
  # пишем предупреждение в свой журнал и всё равно делаем снимок.
  $null = Update-DiskGuard
  if ($script:diskLevel -eq 'stop') {
    Write-DiskWarn 'shot-stop' ('снимок -Shot не создан из-за критически малого места: {0}' -f (Get-DiskText))
    Write-Output ("снимок не создан: критически мало места на диске (" + (Get-DiskText) + ")")
    exit 0
  }
  if ($script:diskLevel -eq 'throttle') {
    Write-DiskWarn 'shot-throttle' ('снимок -Shot сделан при малом запасе места: {0}' -f (Get-DiskText))
  }
  $sw = 1000; $sh = 620
  $bmp = [System.Drawing.Bitmap]::new($sw, $sh)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.Clear([System.Drawing.Color]::FromArgb(18, 20, 26))
    Invoke-DrawGraph $g $st.Nodes $false
    # легенда + сводка ресурсов + подписи: снимок должен совпадать с окном карты
    Draw-LegendAndTotals $g ([double]$sw) ([double]$sh) $false
  } finally { $g.Dispose() }
  try { $bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
  Write-Output "снимок сохранён: $Shot (узлов: $(@($st.Nodes).Count))"
  exit 0
}

# ---------- GUI ----------
# Необработанные ошибки в обработчиках WinForms всплывают как JIT-диалог —
# перехватываем на уровне потока и пишем в лог состояния (вне каталога версии).
$ErrLog = $script:ErrLogPath
try {
  $errDir = Split-Path $ErrLog -Parent
  if (-not (Test-Path -LiteralPath $errDir)) { New-Item -ItemType Directory -Path $errDir -Force | Out-Null }
} catch { }
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
  param($s, $e)
  try { "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] $($e.Exception)" | Add-Content -LiteralPath $ErrLog -Encoding utf8 } catch {}
})
# очки переживают перезапуск GUI: сначала восстанавливаем, потом опрашиваем
$null = Restore-NodesState
Update-Perf
$st = Get-NodeStatus
Init-Actuality $st.Nodes
$script:st = $st
Update-NodeStates
$null = Update-DiskGuard   # 0.9.5: сразу знаем, можно ли тратить место на кадр
Save-NodesState

# один граф — одно окно (функция определена выше, до ветки демона):
# при старте GUI закрываем прежнюю карту (старое окно могло остаться в трее
# из-за Hide на закрытие), и ТОЛЬКО потом открываем новое.
if ($runMode -eq 'gui') {
  Stop-OtherGraphWindows -Kind 'map'
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Карта инфраструктуры | оркестратор'
$form.StartPosition = 'Manual'
$form.Size = [System.Drawing.Size]::new(1040, 680)
$form.MinimumSize = [System.Drawing.Size]::new(760, 520)
$form.Location = [System.Drawing.Point]::new(30, 30)
$form.FormBorderStyle = 'Sizable'
$form.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 26)

# панель графа - рисуем сами (DoubleBuffered против мерцания)
$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = 'Fill'
$panel.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 26)
$panel.GetType().GetProperty('DoubleBuffered',[System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($panel,$true)
$form.Controls.Add($panel)

# перетаскивание узлов мышью (координаты СЦЕНЫ -> переживает ресайз,
# захват в точке клика без скачков)
$script:dragNode = $null
$script:dragOffset = [System.Drawing.PointF]::new(0, 0)
# ---------- фильтр «только активные» (горячая клавиша U) ----------
# По умолчанию видно ВСЁ (как раньше). При включении скрываются узлы классов
# demand/agent в состоянии unloaded — то есть «выгруженные по требованию» строки.
# Ядро (core), службы (service) и всё, что НЕ unloaded, остаются видимыми.
# Скрытые узлы не рисуются и автоматически выпадают из рёбер: Invoke-DrawGraph
# строит рёбра по переданному списку узлов.
function Test-NodeVisible([string]$id) {
  if (-not $script:hideUnloaded) { return $true }
  $cls = Get-NodeClass $id
  if ($cls -ne 'demand' -and $cls -ne 'agent') { return $true }
  $ns = $null
  if ($script:nodeState -and $script:nodeState.ContainsKey($id)) { $ns = $script:nodeState[$id] }
  if (-not $ns) { return $true }                 # состояние ещё не посчитано — узел не прячем
  return ("$($ns.State)" -ne 'unloaded')
}
function Get-VisibleNodes([array]$nodes) {
  if (-not $nodes) { return @() }
  if (-not $script:hideUnloaded) { return $nodes }
  return @($nodes | Where-Object { Test-NodeVisible $_.Id })
}

# ---------- причина состояния: последняя строка журнала по узлу ----------
# Журнал перечитываем ТОЛЬКО при изменении метки времени файла и только хвост
# (200 строк кольца), разбор — в $script:evReason (id -> строка). Наведение мыши
# на узел не порождает ни одного лишнего чтения файла.
function Get-NodeReason([string]$id) {
  $p = $script:eventsPath
  if (-not $p -or -not $id) { return '' }
  try {
    $st = (Get-Item -LiteralPath $p -ErrorAction Stop).LastWriteTimeUtc.Ticks
    if ($st -ne $script:evStamp -or $script:evReason.Count -eq 0) {
      $script:evStamp = $st
      $map = @{}
      foreach ($ln in @(Get-Content -LiteralPath $p -Tail 200 -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($ln -match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]\s+([^:]+):') {
          $map[$Matches[1].Trim()] = "$ln".Trim()
        }
      }
      $script:evReason = $map
    }
  } catch { return '' }
  if ($script:evReason.ContainsKey($id)) { return "$($script:evReason[$id])" }
  return ''
}

# ---------- содержимое всплывающей подсказки узла ----------
function Get-NodeTipLines([string]$id) {
  if (-not $id) { return @() }
  $lines = @()
  $ns = $null
  if ($script:nodeState -and $script:nodeState.ContainsKey($id)) { $ns = $script:nodeState[$id] }
  $state = if ($ns) { "$($ns.State)" } else { '?' }
  $detail = ''
  if ($script:st) {
    foreach ($n in $script:st.Nodes) { if ($n.Id -eq $id) { $detail = "$($n.Detail)"; break } }
  }
  $perf = Get-PerfText $id
  $lines += "узел: $id"
  $lines += ("класс: {0}   состояние: {1}" -f (Get-NodeClass $id), $state)
  $lines += ("очки: {0}%   детали: {1}" -f [int]((Get-EffVal $id) * 100), $detail)
  $lines += ("владелец: {0}   интент: {1}" -f (Get-NodeOwner $id), (Get-NodeIntent $id))
  $lines += ("pid: {0}   {1}" -f (Get-NodePid $id), $(if ($perf) { $perf } else { 'нет телеметрии' }))
  $rsn = Get-NodeReason $id
  $lines += ("причина: {0}" -f $(if ($rsn) { $rsn } else { 'переходов состояния ещё не было' }))
  return $lines
}

# ---------- кэш кадра отрисовки ----------
# Кадр дорогой: десятки GDI-объектов на 33 узла + рёбра + легенда. Если с прошлого
# кадра ничего не изменилось (подпись состояния та же, размер окна тот же), мы НЕ
# перерисовываем сцену заново, а выводим готовое изображение одним DrawImage.
# Битмап живёт в $script:frameBmp и пересоздаётся только при смене размера окна.
function Get-FrameBitmap([int]$w, [int]$h) {
  if ($script:frameBmp -and $script:frameW -eq $w -and $script:frameH -eq $h) { return $script:frameBmp }
  if ($script:frameBmp) { try { $script:frameBmp.Dispose() } catch { }; $script:frameBmp = $null }
  $bmp = [System.Drawing.Bitmap]::new([Math]::Max(1, $w), [Math]::Max(1, $h),
           [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
  $script:frameBmp = $bmp
  $script:frameW = $w
  $script:frameH = $h
  $script:frameSig = $null      # смена размера = прежний кадр больше не годится
  return $bmp
}

# Подпись кадра: состояния и очки (Get-StateSignature) + то, что видно на экране:
# подписи/детали узлов, кандидаты, скорость убывания, фильтр, узел под курсором,
# раскладка узлов и размер окна. Пока строка не изменилась — кадр прежний.
function Get-FrameSignature {
  $p = @()
  if ($script:st) {
    foreach ($n in $script:st.Nodes) {
      $p += ("{0}|{1}|{2}|{3}|{4}" -f $n.Id, $n.Status, $n.Uptime, $n.Label, $n.Detail)
    }
  }
  $sig = ($p -join ';') + '#st=' + (Get-StateSignature)
  $sig += '#pulse=' + [int]$script:pulse
  $sig += '#cand=' + (@($script:candidates) -join ',')
  $sig += '#decay=' + (Get-DecayMult)
  $sig += '#only=' + [int]$script:hideUnloaded
  $sig += ('#hov={0},{1},{2}' -f $script:hoverNode, $script:hoverPt.X, $script:hoverPt.Y)
  if ($script:PosFrac) {
    $pp = @()
    foreach ($k in ($script:PosFrac.Keys | Sort-Object)) {
      $f = $script:PosFrac[$k]
      $pp += ("{0}:{1},{2}" -f $k, $f.Xf, $f.Yf)
    }
    $sig += '#pos=' + ($pp -join ';')
  }
  return $sig
}

# Есть ли ЖИВАЯ анимация (змейки по рёбрам, мигание «завис», пульс бейджа
# «агентов в работе»)? Пока она есть, кадр обязан рисоваться целиком каждый раз —
# иначе змейки и пульс застынут. Кэш при этом сбрасывается.
function Test-FrameAnimated {
  if ($script:snakes -and @($script:snakes).Count -gt 0) { return $true }
  if ($script:pulse -and $script:st) {
    foreach ($n in $script:st.Nodes) { if ($n.Status -eq 'red') { return $true } }
  }
  foreach ($ak in @($script:act.Keys)) {
    $a = $script:act[$ak]
    if ($a.Busy -and $a.Val -gt 0.005) { return $true }
  }
  return $false
}

# ---------- отрисовка подсказки узла (причина состояния и т.д.) ----------
$script:tipCache = @{ Id = ''; Lines = @(); At = [datetime]::MinValue }
function Get-TipLinesCached([string]$id, $font, [double]$maxW) {
  $now = Get-Date
  if ($script:tipCache.Id -eq $id -and ($now - $script:tipCache.At).TotalSeconds -lt 5) {
    return $script:tipCache.Lines
  }
  $script:tipCache.Id = $id
  $script:tipCache.At = $now
  $out = @()
  foreach ($ln in (Get-NodeTipLines $id)) {
    $t = "$ln"
    # обрезка по ширине: слишком длинная причина из журнала не должна вылезать за окно
    $guard = 0
    while ($t.Length -gt 6 -and $guard -lt 400) {
      $w2 = $script:mG.MeasureString($t + '…', $font).Width
      if ($w2 -le $maxW) { break }
      $t = $t.Substring(0, $t.Length - 1)
      $guard++
    }
    if ($t.Length -lt "$ln".Length) { $t = $t.TrimEnd() + '…' }
    $out += $t
  }
  $script:tipCache.Lines = $out
  return $out
}
function Draw-NodeTip($g, $font, [string]$id) {
  $lines = @(Get-TipLinesCached $id $font ([double]($panel.Width - 40)))
  if ($lines.Count -eq 0) { return }
  $wTxt = 0.0
  foreach ($ln in $lines) {
    $sz = $script:mG.MeasureString($ln, $font)
    if ($sz.Width -gt $wTxt) { $wTxt = $sz.Width }
  }
  $lh  = [Math]::Ceiling($font.Height) + 2
  $w   = [int]([Math]::Min($wTxt + 18, $panel.Width - 12))
  $h   = [int]($lh * $lines.Count + 12)
  $x   = [double]($script:hoverPt.X + 16)
  $y   = [double]($script:hoverPt.Y + 18)
  if ($x + $w -gt ($panel.Width - 6)) { $x = [Math]::Max(4.0, $script:hoverPt.X - $w - 12) }
  if ($y + $h -gt ($panel.Height - 6)) { $y = [Math]::Max(4.0, $script:hoverPt.Y - $h - 12) }
  $path = Get-RoundedRectPath $x $y $w $h 8
  $bg  = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(238, 20, 24, 31))
  $bd  = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(110, 175, 210), 1.2)
  $fg  = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(228, 234, 242))
  try {
    $g.FillPath($bg, $path)
    $g.DrawPath($bd, $path)
    $ty = $y + 6
    foreach ($ln in $lines) { $g.DrawString($ln, $font, $fg, ($x + 9), $ty); $ty += $lh }
  } finally {
    $fg.Dispose(); $bd.Dispose(); $bg.Dispose(); $path.Dispose()
  }
}

# ---------- кадр целиком: граф + легенда + сводка ресурсов + подсказка ----------
function Draw-FrameInto($g, [bool]$toCache) {
  if ($script:st) { Invoke-DrawGraph $g (Get-VisibleNodes $script:st.Nodes) $script:pulse }
  # подвал (легенда, сводка ресурсов, подписи, подсказка) рисует общая функция —
  # ровно та же, что и в снимке -Shot, поэтому карта и PNG не расходятся
  Draw-LegendAndTotals $g ([double]$panel.Width) ([double]$panel.Height) $true
}

function Get-NodeAt([System.Drawing.Point]$pt) {
  $t   = Get-Transform $panel.Width $panel.Height
  $spt = ScreenToScene $t $pt.X $pt.Y
  $pos = Resolve-PositionsScene
  if (-not $script:st) { return $null }
  foreach ($n in $script:st.Nodes) {
    # скрытый фильтром узел не нарисован — ловить его мышью нельзя
    if (-not (Test-NodeVisible $n.Id)) { continue }
    $pk = $pos[$n.Id]
    if (-not $pk) { continue }
    $sz = Get-NodeSize $n
    if ($spt.X -ge $pk.X -and $spt.X -le ($pk.X + $sz.W) -and $spt.Y -ge $pk.Y -and $spt.Y -le ($pk.Y + $sz.H)) {
      return $n.Id
    }
  }
  return $null
}
$panel.Add_MouseDown({
  param($s,$e)
  try {
  if ($e.Button -eq 'Left') {
    $script:dragNode = Get-NodeAt $e.Location
    if ($script:dragNode) {
      # смещение точки клика относительно левого верхнего угла узла (в сцене) —
      # чтобы узел не "прыгал", а двигался ровно под курсором
      $t   = Get-Transform $panel.Width $panel.Height
      $spt = ScreenToScene $t $e.X $e.Y
      $pk  = (Resolve-PositionsScene)[$script:dragNode]
      $script:dragOffset = [System.Drawing.PointF]::new($spt.X - $pk.X, $spt.Y - $pk.Y)
    }
    $panel.Cursor = 'SizeAll'
  }
  } catch {
    try { "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] Mouse: $($_.Exception.Message)" | Add-Content -LiteralPath $script:ErrLogPath -Encoding utf8 } catch {}
  }
})
$panel.Add_MouseMove({
  param($s,$e)
  try {
  if ($script:dragNode) {
    $f = $script:PosFrac[$script:dragNode]
    if ($f) {
      $t   = Get-Transform $panel.Width $panel.Height
      $spt = ScreenToScene $t $e.X $e.Y
      $nx  = [Math]::Max(0.0, [Math]::Min(1.0, ($spt.X - $script:dragOffset.X) / $script:SceneW))
      $ny  = [Math]::Max(0.0, [Math]::Min(1.0, ($spt.Y - $script:dragOffset.Y) / $script:SceneH))
      # прижимаем узел к границам сцены по его размеру: иначе узел, который
      # перетащили к краю, обрезался краем окна (и краем PNG в снимке)
      $dNode = $null
      if ($script:st) { foreach ($nn in $script:st.Nodes) { if ($nn.Id -eq $script:dragNode) { $dNode = $nn; break } } }
      if ($dNode) {
        $szD = Get-NodeSize $dNode
        $cp  = Clamp-PosToScene $script:dragNode (($spt.X - $script:dragOffset.X)) (($spt.Y - $script:dragOffset.Y)) $szD.W $szD.H
        $f.Xf = [Math]::Round($cp.X / $script:SceneW, 4)
        $f.Yf = [Math]::Round($cp.Y / $script:SceneH, 4)
      } else {
        $f.Xf = [Math]::Round($nx, 4)
        $f.Yf = [Math]::Round($ny, 4)
      }
      $panel.Invalidate()
    }
  } elseif ($null -eq $script:dragNode) {
    # наведение мыши: подсветка курсора + всплывающая подсказка узла
    # (id, класс, состояние, очки, владелец, интент, pid, RAM/CPU, причина)
    $hId = Get-NodeAt $e.Location
    $panel.Cursor = if ($hId) { 'Hand' } else { 'Default' }
    if ($hId -ne $script:hoverNode) {
      $script:hoverNode = $hId          # сменился узел — перерисовать подсказку
      $script:hoverPt = [System.Drawing.Point]::new($e.X, $e.Y)
      $panel.Invalidate()
    } elseif ($hId) {
      $script:hoverPt = [System.Drawing.Point]::new($e.X, $e.Y)
    }
  }
  } catch {
    try { "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] Mouse: $($_.Exception.Message)" | Add-Content -LiteralPath $script:ErrLogPath -Encoding utf8 } catch {}
  }
})
$panel.Add_MouseUp({
  param($s,$e)
  try {
  if ($script:dragNode) { Save-Positions }   # узел реально тянули — запомнить раскладку
  $script:dragNode = $null
  $script:dragOffset = [System.Drawing.PointF]::new(0, 0)
  $panel.Cursor = 'Default'
  } catch {
    try { "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] Mouse: $($_.Exception.Message)" | Add-Content -LiteralPath $script:ErrLogPath -Encoding utf8 } catch {}
  }
})
$panel.Add_Resize({ $panel.Invalidate() })
# мышь ушла с карты — подсказку убираем (иначе она «залипает» на последнем узле)
$panel.Add_MouseLeave({
  $script:hoverNode = $null
  $panel.Invalidate()
})

# иконка трея. Кисть и битмап освобождаем сразу: Icon из GetHicon держит СВОЮ
# копию, поэтому хэндл остаётся валидным, а временные GDI-объекты не текут.
$iconBmp = New-Object System.Drawing.Bitmap 16,16
$ig = [System.Drawing.Graphics]::FromImage($iconBmp)
try {
  $ig.Clear([System.Drawing.Color]::Transparent)
  $icoBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(0,200,90))
  try { $ig.FillEllipse($icoBrush, 1, 1, 14, 14) } finally { $icoBrush.Dispose() }
} finally { $ig.Dispose() }
$trayIcon = [System.Drawing.Icon]::FromHandle($iconBmp.GetHicon())
$iconBmp.Dispose()

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $trayIcon
$tray.Text = 'Карта инфраструктуры'
$tray.Visible = $true

# ---------- меню карты: скорость убывания востребованности ----------
# Пункты скорости пишут множитель в decay.json (общий файл карты и демона).
$script:DecaySpeeds = @(
  @{ M = 0.0;  Label = '×0 — убывание остановлено' },
  @{ M = 0.25; Label = '×0.25 — очень медленно' },
  @{ M = 0.5;  Label = '×0.5 — медленно' },
  @{ M = 1.0;  Label = '×1 — обычная (0.5%/с)' },
  @{ M = 2.0;  Label = '×2 — быстро' },
  @{ M = 4.0;  Label = '×4 — очень быстро' }
)
function Add-DecaySpeedItems($owner) {
  $cur = Get-DecayMult
  $miSpeed = New-Object System.Windows.Forms.ToolStripMenuItem(('Востребованность — скорость убывания: ' + (Format-Mult $cur)))
  foreach ($s in $script:DecaySpeeds) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($s.Label)
    $mi.Tag = [double]$s.M
    $mi.Checked = ([Math]::Abs([double]$s.M - $cur) -lt 0.0001)
    [void]$miSpeed.DropDownItems.Add($mi)
  }
  $miSpeed.Add_DropDownOpening({
    $c = Get-DecayMult
    $this.Text = 'Востребованность — скорость убывания: ' + (Format-Mult $c)
    foreach ($it in $this.DropDownItems) { if ($it.Tag -ne $null) { $it.Checked = ([Math]::Abs([double]$it.Tag - $c) -lt 0.0001) } }
  })
  # единый обработчик: значение скорости — в Tag пункта ($this = пункт)
  foreach ($it in $miSpeed.DropDownItems) {
    $it.Add_Click({
      Set-DecayMult ([double]$this.Tag)
      $ownerDd = $this.Owner
      if ($ownerDd) {
        $c = Get-DecayMult
        foreach ($x in $ownerDd.Items) { if ($x.Tag -ne $null) { $x.Checked = ([Math]::Abs([double]$x.Tag - $c) -lt 0.0001) } }
        $oi = $ownerDd.OwnerItem
        if ($oi) { $oi.Text = 'Востребованность — скорость убывания: ' + (Format-Mult $c) }
      }
      $tray.Text = 'Карта инфраструктуры — скорость ' + (Format-Mult (Get-DecayMult))
      $panel.Invalidate()
    })
  }
  [void]$owner.Items.Add($miSpeed)
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = New-Object System.Windows.Forms.ToolStripMenuItem('Показать')
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem('Выход')
$menu.Items.Add($miShow) | Out-Null
Add-DecaySpeedItems $menu
# ---------- фильтр «только активные» (U) ----------
# Скрывает узлы demand/agent в состоянии unloaded («выгружены по требованию»).
# По умолчанию выключен — карта показывает всё, как раньше.
function Toggle-ActiveOnly([bool]$on) {
  $script:hideUnloaded = $on
  $script:frameSig = $null        # кэш кадра больше не годен: набор узлов изменился
  $script:tipCache.Id = ''
  if ($miOnly) { $miOnly.Checked = $on }
  if ($tray) {
    $tray.Text = $(if ($on) { 'Карта инфраструктуры — только активные' } else { 'Карта инфраструктуры' })
  }
  $panel.Invalidate()
}
$miOnly = New-Object System.Windows.Forms.ToolStripMenuItem('Только активные узлы (U)')
$miOnly.Checked = $false
$miOnly.Add_Click({ Toggle-ActiveOnly (-not $script:hideUnloaded) })
$menu.Items.Add($miOnly) | Out-Null
# горячая клавиша U — переключение фильтра прямо на карте
$keyFilter = {
  try {
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::U) {
      Toggle-ActiveOnly (-not $script:hideUnloaded)
    }
  } catch {
    try { "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] Key: $($_.Exception.Message)" | Add-Content -LiteralPath $script:ErrLogPath -Encoding utf8 } catch {}
  }
}
$form.Add_KeyDown($keyFilter)
$panel.Add_KeyDown($keyFilter)
$menu.Items.Add($miExit) | Out-Null
$tray.ContextMenuStrip = $menu
$miShow.Add_Click({ $form.Show(); $form.Activate() })
$miExit.Add_Click({ $tray.Visible = $false; $form.Close() })
$tray.Add_DoubleClick({ $form.Show(); $form.Activate() })
# правый клик по самой карте — то же меню (скорость управляется без трея)
$form.ContextMenuStrip = $menu

# пульсация "завис" (красный) - мигает рамкой; $script:pulse объявлен в блоке переменных

$panel.Add_Paint({
  param($s, $e)
  try {
  $g = $e.Graphics
  $g.SmoothingMode = 'AntiAlias'
  $w = $panel.Width; $h = $panel.Height
  if ($w -le 0 -or $h -le 0) { return }
  if (Test-FrameAnimated) {
    # ЖИВАЯ анимация (змейки по рёбрам, мигание «завис», пульс бейджа агентов):
    # кадр рисуется целиком каждый раз — иначе змейки застынут. Кэш при этом
    # помечаем недействительным и вернёмся к нему, когда анимация закончится.
    $script:frameSig = $null
    Draw-FrameInto $g $false
    return
  }
  $sig = Get-FrameSignature
  if ($script:frameSig -eq $sig -and $script:frameBmp -and $script:frameW -eq $w -and $script:frameH -eq $h) {
    $g.DrawImage($script:frameBmp, 0, 0)   # кадр не изменился — выводим из кэша
    $script:frameHits++
    return
  }
  # кадр изменился: рисуем сцену ОДИН раз в offscreen-битмап и кладём в кэш,
  # на экну он выводится одним DrawImage. Все GDI-объекты освобождаются в Draw-FrameInto.
  $bmp = Get-FrameBitmap $w $h
  $gb = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $gb.SmoothingMode = 'AntiAlias'
    $gb.TextRenderingHint = 'AntiAliasGridFit'
    $gb.Clear([System.Drawing.Color]::FromArgb(18, 20, 26))
    Draw-FrameInto $gb $true
  } finally { $gb.Dispose() }
  $g.DrawImage($bmp, 0, 0)
  $script:frameSig = $sig
  $script:frameMiss++
  } catch {
    try { "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] Paint: $($_.Exception.Message)" | Add-Content -LiteralPath $script:ErrLogPath -Encoding utf8 } catch {}
  }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
  try {
  $prev = @{}; if ($script:st) { foreach ($n in $script:st.Nodes) { $prev[$n.Id] = $n.Status } }
  Update-Perf
  Update-EdgeActivity
  $script:st    = Get-NodeStatus
  Update-Actuality       # затухание актуальности узлов (после свежих касаний)
  Update-NodeStates      # явное состояние + владение + интент + кандидаты
  $null = Update-DiskGuard   # 0.9.5: место на диске — режим экономии включается сам
  Save-NodesState        # очки на диск (только при изменении, не чаще FlushSec)
  $script:pulse = (-not $script:pulse)
  $changed = $false
  if ($script:st) {
    foreach ($n in $script:st.Nodes) {
      if ($prev[$n.Id] -ne $n.Status) { $changed = $true; break }
      if ($n.Status -eq 'red') { $changed = $true; break }
      $ns = $script:nodeState[$n.Id]
      if ($ns -and $ns.State -eq 'need-guard') { $changed = $true; break }
    }
  }
  # кэш кадра: будим перерисовку только если кадр РЕАЛЬНО изменился либо жива
  # анимация. Фазу пульса из сравнения убираем — она мигает сама по себе, иначе
  # тик всегда считал бы кадр «новым» и кэш не работал бы вовсе.
  $fsig = (Get-FrameSignature) -replace '#pulse=[01]', '#pulse=-'
  $needDraw = $changed -or -not $prev.Count -or (Test-FrameAnimated) -or ($fsig -ne $script:tickSig)
  $script:tickSig = $fsig
  # 0.9.5: при нехватке места кадр перерисовываем реже (throttle) или не
  # перерисовываем вовсе (stop). nodes.json выше записан В ЛЮБОМ случае —
  # телеметрия важнее картинки, вернувшееся место снимает ограничение само.
  if ($needDraw -and (Approve-FrameDraw)) { $panel.Invalidate() }
  } catch {
    try { "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] Timer: $($_.Exception.Message)" | Add-Content -LiteralPath $script:ErrLogPath -Encoding utf8 } catch {}
  }
})
$timer.Start()

# анимация направленных связей ("змейки" бегут по рёбрам) и пульсация красных
$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 60
$animTimer.Add_Tick({
  try {
  $script:animT = ($script:animT + 0.02) % 1000
  # 0.9.5: при нехватке места места живая анимация выключена (иначе 16 кадров/с
  # сводят на нет всю экономию) — кадр обновит только таймер 3 с, и то по разрешению
  if ($script:diskLevel -eq 'normal') { $panel.Invalidate() }
  } catch {
    try { "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] AnimTimer: $($_.Exception.Message)" | Add-Content -LiteralPath $script:ErrLogPath -Encoding utf8 } catch {}
  }
})
$animTimer.Start()

$form.Add_FormClosing({
  param($s, $e)
  if ($e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; $form.Hide() }
})

[System.Windows.Forms.Application]::Run($form)
$tray.Visible = $false
# освобождение GDI-ресурсов при выходе: кэш кадра, измерительная графика и шрифты.
# Иначе за ночь-другой процесс держит дескрипторы и память зря.
try { $timer.Stop(); $animTimer.Stop() } catch { }
try { if ($script:frameBmp) { $script:frameBmp.Dispose(); $script:frameBmp = $null } } catch { }
try { $script:mG.Dispose(); $script:mBmp.Dispose() } catch { }
try { $script:fTitle.Dispose(); $script:fSub.Dispose(); $script:fUp.Dispose() } catch { }
# значки трея, меню и окно — тоже освобождаем: процесс живёт часами, а каждый
# неосвобождённый GDI-хэндл Windows считает за утечку дескрипторов
try { $tray.Visible = $false; $tray.Dispose() } catch { }
try { $trayIcon.Dispose() } catch { }
try { $menu.Dispose() } catch { }
try { $form.Dispose() } catch { }
