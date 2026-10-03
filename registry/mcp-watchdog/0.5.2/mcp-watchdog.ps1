# mcp-watchdog.ps1 — демон-страж инфраструктуры оркестратора
# Запускается в фоне вместе с сессией opencode (оркестратор запускает по правилу Always-on).
# Каждые -IntervalSec секунд проверяет:
#   1) что opencode жив (иначе штатное завершение с записью причины);
#   2) все серверы/инструменты: local-llm, firecrawl, MCP_DOCKER, ollama,
#      browsertool, стек агентов INVR (+ Docker daemon);
#   3) при неисправности создаёт заявку-«сессию проверки» requests\chk_<id>.json,
#      а оркестратор читает её, исправляет и закрывает (status=resolved);
#   4) автовосстановление: сам поднимает Docker Desktop, ollama, local-llm,
#      firecrawl, MCP_DOCKER gateway и browsertool (с троттлингом; browsertool —
#      только если driver.mjs уже подготовлен, а интент в state\browsertool.json
#      равен 'up').
# Управляемый жизненный цикл browsertool (инструмент «по требованию»):
#   - файл-команда state\browsertool.json: {"desired":"up"} — следить и держать
#     поднятым (автоподъём при падении); {"desired":"down"} — демон завершает
#     работающий driver.mjs и больше не поднимает; файла нет/другое — только
#     мониторинг, ничего не поднимаем и не тикетируем.
#   - заявки по browsertool НИКОГДА не создаются (это не дефект, а отсутствие
#     по требованию).
# Всё логируется от запуска до завершения.
#
# МОДЕЛЬ СОСТОЯНИЙ И ОЧКОВ (версия 0.4.0):
#   Демон больше не путает «выключен по требованию» и «упал». Для каждого узла
#   считается ЯВНОЕ СОСТОЯНИЕ, и только оно решает судьбу узла:
#     active     — работает;
#     idle       — жив, но свободен;
#     unloaded   — выгружен/не запущен по требованию (интент none/down) — НЕ дефект,
#                  заявка НЕ создаётся, автоподъём НЕ делается;
#     need-guard — выключен, но интент 'up' (кто-то нужен прямо сейчас) — дефект;
#     fault      — реально упал (для узлов с интентом up/auto-нужных) — заявка + автоподъём.
#   Где берётся информация:
#     - факты о жизни (процесс/порт) — собственные проверки демона;
#     - интенты (desired up/down/none) — state\intents.json (общий) и
#       state\browsertool.json (совместимость), по умолчанию интент берётся
#       из $AlwaysOn (эти узлы нужны всегда);
#     - очки и класс узла — из nodes.json монитора (по умолчанию
#       <корень инструментов>\monitor\state\nodes.json; переопределяется
#       -NodesFile или переменной INVR_NODES_FILE), если файл есть; демон
#       только читает и публикует.
#   ЗАЩИТА ЯДРА: opencode (oc), сам демон (watchdog), guardian и monitor — класс
#   'core'. Их выгрузка ЗАПРЕЩЕНА: демон не имеет права их останавливать ни при
#   каких очках. Решение о завершении процессов принимает ВЛАДЕЛЕЦ (владелец
#   узла = opencode для субагентов, guardian/вотчдог для служебных, пользователь
#   для самого ядра). Демон публикует кандидатов (unloadCandidates) и ждёт решения.
#   Автоматически демон НИЧЕГО не завершает, кроме явной команды 'down'
#   в state\browsertool.json (это команда владельца).

#Requires -Version 7

param(
    [int]$IntervalSec = 30,
    [string]$ProcessName = 'OpenCode',
    [int]$ThrottleSec = 180,
    [switch]$Once,
    [string]$RuntimeDir = '',
    [string]$BrowserDriverPath = '',
    [string]$NodesFile = '',
    [string]$IntentsFile = '',
    [int]$UnloadLogSec = 600,
    [switch]$AllowUnload
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
# Переносимые корни (машинные пути не зашиты): скрипт лежит в
# registry\<tool>\<version>, каталог инструментов — уровнем выше реестра,
# рабочее пространство — уровнем выше каталога инструментов.
$regRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$toolsRoot = Split-Path $regRoot -Parent
$wsRoot    = Split-Path $toolsRoot -Parent
$BaseDir   = if ($RuntimeDir) { $RuntimeDir } else { $PSScriptRoot }
$StateDir  = Join-Path $BaseDir 'state'
$ReqDir    = Join-Path $BaseDir 'requests'
# Файл состояния узлов монитора. Раньше был зашит на <tools-root>\...,
# что ломало переносимость на другие машины и раскладки дистрибутива.
# Порядок: -NodesFile > env INVR_NODES_FILE > env INVR_TOOLS_ROOT (каталог шима,
# его выставляет resolve-tools) > вычисленный корень инструментов.
if (-not $NodesFile) {
    $toolsRootEnv = if ($env:INVR_TOOLS_ROOT -and (Test-Path -LiteralPath $env:INVR_TOOLS_ROOT)) {
        [IO.Path]::GetFullPath($env:INVR_TOOLS_ROOT)
    } else { $toolsRoot }
    $NodesFile = if ($env:INVR_NODES_FILE) { $env:INVR_NODES_FILE }
                 else { Join-Path $toolsRootEnv 'monitor\state\nodes.json' }
}
# Журналы: env INVR_LOG_DIR (процесс, затем User) > <корень инструментов>\Logs
$logDirEnv = if ($env:INVR_LOG_DIR) { $env:INVR_LOG_DIR } else { [Environment]::GetEnvironmentVariable('INVR_LOG_DIR', 'User') }
$LogDir    = if ($logDirEnv) { $logDirEnv } else { Join-Path $toolsRoot 'Logs' }
$LogFile   = Join-Path $LogDir 'mcp-watchdog.log'

$DockerExe       = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
$OllamaServerCmd = Join-Path $wsRoot 'ollama-server.cmd'
$BrowserPort     = 8123
$NodeExe         = 'C:\Program Files\nodejs\node.exe'
$driverLocal  = Join-Path $BaseDir 'browsertool\driver.mjs'
$driverShared = Join-Path $toolsRoot 'browsertool\driver.mjs'
$BrowserDriver   = if ($BrowserDriverPath) { $BrowserDriverPath }
                   elseif (Test-Path -LiteralPath $driverLocal) { $driverLocal }
                   elseif (Test-Path -LiteralPath $driverShared) { $driverShared }
                   else { $driverLocal }

$PidFile   = Join-Path $StateDir 'watchdog.pid'
$CurFile   = Join-Path $StateDir 'current.json'
$MyStamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
if (-not $IntentsFile) { $IntentsFile = Join-Path $StateDir 'intents.json' }

# ---- модель классов/состояний (0.4.0) ----
# core    — выгрузка ЗАПРЕЩЕНА (opencode, сам демон, guardian, монитор);
# demand  — по требованию: работает, пока нужен; не работает = unloaded (не дефект);
# service — нужен всегда: не работает = fault;
# agent   — агент: гаснет по очкам, не работает = unloaded.
$ServerClass = [ordered]@{
    'local-llm'  = 'demand'
    'firecrawl'  = 'demand'
    'MCP_DOCKER' = 'demand'
    'browsertool'= 'demand'
    'ollama'     = 'service'
    'invr-stack' = 'service'
    'guardian'   = 'core'
    'monitor'    = 'core'
}
# узлы, которые нужны всегда: их падение = fault (заявка + автоподъём, если демон умеет).
# browsertool сюда НЕ входит — он по требованию (интент из browsertool.json/intents.json).
# guardian/monitor нужны всегда, но автоподъёмом занимается guardian, не демон:
# для них создаётся заявка (сигнал оркестратору), решение принимает владелец.
$AlwaysOn     = @('local-llm','firecrawl','MCP_DOCKER','ollama','invr-stack','guardian','monitor')
# охраняемое ядро: демон не имеет права их останавливать
$CoreProtect  = @('oc','watchdog','guardian','monitor')
$script:nodesCache   = @{ at = [DateTime]::MinValue; data = $null }
$script:intentCache = @{ at = [DateTime]::MinValue; data = $null }
$script:lastUnloadLog = [DateTime]::MinValue
$script:unloadReport  = @()

foreach ($d in @($StateDir, $ReqDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

if (-not $Once) { Set-Content -LiteralPath $PidFile -Value $PID -Encoding ascii }

function Write-Log {
    param([string]$Level, [string]$Msg)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg"
    Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8BOM
    Write-Output $line
}

# глобальный перехват любой неизвестной ошибки: демон НИКОГДА не умирает молча
trap {
    Write-Log 'FATAL' "необработанная ошибка: $($_.Exception.Message) | $($_.InvocationInfo.PositionMessage)"
    exit 1
}

# 0.4.4+/0.5.1: ОДИН снимок процессов на цикл (раньше Get-CimInstance вызывался для
# каждого узла — 8+ запросов подряд; WMI на этой машине периодически отказывал, и
# проверка guardian/monitor получала «процессов: 0» при живом процессе → ложная заявка).
$script:procSnap = @{ at = [DateTime]::MinValue; data = @() }

function Update-ProcSnapshot {
    $maxAge = 20   # секунд: снимок считается свежим
    if (((Get-Date) - $script:procSnap.at).TotalSeconds -lt $maxAge -and $script:procSnap.data.Count -gt 0) { return }
    foreach ($attempt in 1..2) {
        try {
            $script:procSnap.data = @(Get-CimInstance Win32_Process -ErrorAction Stop)
            $script:procSnap.at = Get-Date
            return
        } catch {
            if ($attempt -eq 2) { Write-Log 'WARN' "Auto-heal: снимок процессов не получен (WMI: $($_.Exception.Message)) — проверяю по pid-файлам." }
            Start-Sleep 2
        }
    }
    $script:procSnap.data = @()
    $script:procSnap.at = Get-Date
}

function Get-ProcessByCmdline {
    param([string]$Needle)
    Update-ProcSnapshot
    @($script:procSnap.data | Where-Object {
        $_.CommandLine -and
        $_.CommandLine.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        # 0.4.2: одноразовые проверки из консоли (pwsh -Command «... mcp-watchdog ...»)
        # не считаются сервисами — иначе демон «видит» сам себя проверяющим
        $_.CommandLine -notmatch '\s-(Command|command|c)\s' -and
        $_.ProcessId -ne $PID
    })
}

# живой ли pid И его командная строка соответствует ожидаемой (резервная проверка,
# когда снимок процессов недоступен или устарел)
function Test-PidAlive([int]$ProcId, [string]$Needle = '') {
    if ($ProcId -le 0) { return $false }
    if (-not (Get-Process -Id $ProcId -ErrorAction SilentlyContinue)) { return $false }
    if (-not $Needle) { return $true }
    try {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction SilentlyContinue).CommandLine
        return [bool]($cmd -and $cmd.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    } catch { return $false }
}

function Get-OpencodeAlive {
    param([string]$Name)
    $p = Get-Process -Name $Name -ErrorAction SilentlyContinue
    return [bool]$p
}

function Test-Port {
    param([int]$Port)
    $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    return [bool]$c
}

function Test-DockerDaemon {
    $v = $null
    try {
        & docker version --format '{{.Server.Version}}' *> $null
        $up = ($LASTEXITCODE -eq 0)
        if ($up) { $v = (& docker version --format '{{.Server.Version}}') -join '' }
        return @($up, $(if ($v) { "daemon $v" } else { 'down' }))
    } catch { return @($false, $_.Exception.Message) }
}

function Test-OllamaServer {
    $listen = Test-Port 11434
    $p = Get-Process -Name 'ollama' -ErrorAction SilentlyContinue
    $detail = "порт 11434:$(if ($listen) {'listen'} else {'closed'}); процесс ollama:$(if ($p) {'yes'} else {'no'})"
    return @($listen, $detail)
}

function Get-BrowserDriverProcs {
    # driver.mjs может быть запущен как «node.exe driver.mjs» (без пути/слова browsertool в cmdline)
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'driver\.mjs' })
    } catch { return @() }
}

function Test-Browsertool {
    $listen = Test-Port $BrowserPort
    $proc   = @(Get-BrowserDriverProcs).Count
    $intend = Get-BrowsertoolIntend
    $detail = "порт ${BrowserPort}:$(if ($listen) {'listen'} else {'closed'}); процесс driver.mjs: $proc; интент: $intend"
    return @($listen, $detail)
}

function Get-OpencodeDir {
    # каталог конфигурации opencode: рабочее пространство, иначе профиль
    foreach ($c in @((Join-Path $wsRoot '.opencode'), (Join-Path $env:USERPROFILE '.opencode'))) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return (Join-Path $wsRoot '.opencode')
}

function Test-InvrStack {
    $ocDir = Get-OpencodeDir
    $files = @(
        (Join-Path $ocDir 'agent\invr-lead.md'),
        (Join-Path $ocDir 'agent\invr-analyst.md'),
        (Join-Path $ocDir 'agent\invr-architect.md'),
        (Join-Path $ocDir 'agent\invr-coder.md'),
        (Join-Path $ocDir 'agent\invr-reviewer.md'),
        (Join-Path $ocDir 'agent\invr-qa.md'),
        (Join-Path $ocDir 'agent\invr-devops.md'),
        (Join-Path $ocDir 'agent\invr-docs.md'),
        (Join-Path $ocDir 'command\invr.md'),
        (Join-Path $ocDir 'command\providers.md')
    )
    $missing = @($files | Where-Object { -not (Test-Path $_) })
    $detail = "агенты/команды INVR: есть $($files.Count - $missing.Count) из $($files.Count); отсутствуют: $(if ($missing) { $missing -join '; ' } else { 'нет' })"
    return @(($missing.Count -eq 0), $detail)
}

function Test-DockerDaemon {
    try { $null = (& docker info 2>$null); return ($LASTEXITCODE -eq 0) } catch { return $false }
}

# 0.5.2: последний успешный перезапуск WSL — чтобы не делать его каждый цикл
$script:lastWslRestart = [DateTime]::MinValue

function Test-DockerDesktopRunning {
    # живой ли уже Docker Desktop (главный экземпляр) — чтобы НЕ плодить копии
    @(Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue).Count -gt 0
}

function Start-DockerDesktop {
    if (-not (Test-Path $DockerExe)) { Write-Log 'WARN' "Auto-heal: Docker Desktop не найден ($DockerExe)"; return $false }
    # 0.5.2: если Docker Desktop уже запущен — НЕ запускаем новый экземпляр, просто ждём
    # daemon. Раньше каждый цикл (30 с) создавался новый процесс: 7+ копий,
    # backend не мог подняться (backend process exited) — порочный круг.
    if (Test-DockerDesktopRunning) {
        Write-Log 'INFO' 'Auto-heal: Docker Desktop уже запущен — жду daemon (новый экземпляр не создаю).'
    } else {
        Write-Log 'INFO' 'Auto-heal: запуск Docker Desktop…'
        Start-Process -FilePath $DockerExe | Out-Null
    }
    for ($i = 0; $i -lt 18; $i++) {
        Start-Sleep 5
        if (Test-DockerDaemon) { Write-Log 'INFO' 'Auto-heal: Docker daemon поднялся.'; return $true }
    }
    # 0.5.1: известный сбой на русской локали Windows — vpnkit-bridge получает
    # русскоязычный вывод при перечислении дисков («удалось подключить диск ...»)
    # и завершает backend («backend process exited»). Лечится перезапуском WSL.
    # 0.5.2: не чаще раза в 10 мин (иначе цикл лечения сам себе мешает).
    $sinceLast = ((Get-Date) - $script:lastWslRestart).TotalSeconds
    if ($sinceLast -lt 600) {
        Write-Log "WARN" "Auto-heal: Docker daemon не поднялся за ~90с; перезапуск WSL пропущен (прошло только $([int]$sinceLast)с из 600) — жду следующего цикла."
        return $false
    }
    Write-Log 'WARN' 'Auto-heal: Docker daemon не поднялся за ~90с → перезапуск WSL (wsl --shutdown) и вторая попытка.'
    try {
        $script:lastWslRestart = Get-Date
        & wsl.exe --shutdown 2>&1 | Out-Null
        Start-Sleep 5
        Get-Process -Name 'Docker Desktop','com.docker.backend' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Process -FilePath $DockerExe | Out-Null
        for ($i = 0; $i -lt 18; $i++) {
            Start-Sleep 5
            if (Test-DockerDaemon) { Write-Log 'INFO' 'Auto-heal: Docker daemon поднялся после перезапуска WSL.'; return $true }
        }
    } catch { Write-Log 'WARN' "Auto-heal: перезапуск WSL не удался: $($_.Exception.Message)" }
    Write-Log 'WARN' 'Auto-heal: Docker daemon не поднялся даже после перезапуска WSL.'
    return $false
}

function Start-OllamaServer {
    if (-not (Test-Path $OllamaServerCmd)) { Write-Log 'WARN' "Auto-heal: $OllamaServerCmd не найден"; return $false }
    Write-Log 'INFO' "Auto-heal: запуск ollama ($OllamaServerCmd)…"
    Start-Process -FilePath $env:ComSpec -ArgumentList '/c', $OllamaServerCmd -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep 5
        if (Test-Port 11434) { Write-Log 'INFO' 'Auto-heal: ollama слушает 11434.'; return $true }
    }
    Write-Log 'WARN' 'Auto-heal: ollama не поднялся за ~60с.'
    return $false
}

function Start-Browsertool {
    if (-not (Test-Path $NodeExe)) { Write-Log 'WARN' "Auto-heal: node.exe не найден ($NodeExe)"; return $false }
    if (-not (Test-Path $BrowserDriver)) {
        Write-Log 'WARN' "Auto-heal: driver.mjs не найден ($BrowserDriver) — драйвер должен подготовить оркестратор по заявке."
        return $false
    }
    Write-Log 'INFO' "Auto-heal: запуск browsertool ($BrowserDriver)…"
    Start-Process -FilePath $NodeExe -ArgumentList $BrowserDriver -WorkingDirectory (Split-Path $BrowserDriver) -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep 5
        if (Test-Port $BrowserPort) {
            Write-Log 'INFO' "Auto-heal: browsertool слушает $BrowserPort."
            return $true
        }
    }
    Write-Log 'WARN' "Auto-heal: browsertool не поднялся за ~60с."
    return $false
}

function Start-LocalLlm {
    # Проект Hermes: env HERMES_PROJECT_DIR > рабочее пространство > профиль
    $hermes = if ($env:HERMES_PROJECT_DIR) { $env:HERMES_PROJECT_DIR }
              elseif (Test-Path (Join-Path $wsRoot 'hermes-project')) { Join-Path $wsRoot 'hermes-project' }
              else { Join-Path $env:USERPROFILE 'hermes-project' }
    $py  = Join-Path $hermes '.venv-mcp\Scripts\python.exe'
    $srv = Join-Path $hermes 'scripts\llm_mcp_server.py'
    if (-not (Test-Path -LiteralPath $py) -or -not (Test-Path -LiteralPath $srv)) {
        Write-Log 'WARN' "Auto-heal: скрипты local-llm не найдены ($py / $srv) — файлы должен подготовить оркестратор."
        return $false
    }
    Write-Log 'INFO' 'Auto-heal: запуск local-llm (llm_mcp_server.py)…'
    Start-Process -FilePath $py -ArgumentList $srv -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep 3
        if (@(Get-ProcessByCmdline 'llm_mcp_server.py').Count -gt 0) { Write-Log 'INFO' 'Auto-heal: local-llm процесс поднят.'; return $true }
    }
    Write-Log 'WARN' 'Auto-heal: local-llm не поднялся за ~30с.'
    return $false
}

function Start-FirecrawlMcp {
    $idx = Join-Path (Split-Path $NodeExe -Parent) 'node_modules\firecrawl-mcp\dist\index.js'
    if (-not (Test-Path -LiteralPath $idx)) {
        Write-Log 'WARN' "Auto-heal: firecrawl-mcp index.js не найден ($idx) — модуль должен установить оркестратор."
        return $false
    }
    Write-Log 'INFO' 'Auto-heal: запуск firecrawl-mcp…'
    Start-Process -FilePath $NodeExe -ArgumentList "`"$idx`"" -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep 3
        if (@(Get-ProcessByCmdline 'firecrawl-mcp').Count -gt 0) { Write-Log 'INFO' 'Auto-heal: firecrawl-mcp процесс поднят.'; return $true }
    }
    Write-Log 'WARN' 'Auto-heal: firecrawl-mcp не поднялся за ~30с.'
    return $false
}

function Start-McpDockerGateway {
    $dock = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dock) { Write-Log 'WARN' 'Auto-heal: docker недоступен в PATH'; return $false }
    Write-Log 'INFO' 'Auto-heal: запуск docker mcp gateway (profile dev_workflow)…'
    Start-Process -FilePath $dock.Source -ArgumentList 'mcp','gateway','run','--profile','dev_workflow' -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep 3
        $daemon = Test-DockerDaemon
        if ((@(Get-ProcessByCmdline 'mcp gateway run').Count -gt 0) -and $daemon[0]) {
            Write-Log 'INFO' 'Auto-heal: MCP_DOCKER gateway поднят.'
            return $true
        }
    }
    Write-Log 'WARN' 'Auto-heal: MCP_DOCKER gateway не поднялся за ~36с.'
    return $false
}

function Stop-Browsertool {
    $procs = @(Get-BrowserDriverProcs)
    $killed = 0
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $killed++ } catch {}
    }
    Start-Sleep 2
    if ($killed -gt 0) { Write-Log 'INFO' "Управление: завершены процессы browsertool (driver.mjs): $killed шт." }
    return $killed
}

function Get-BrowsertoolIntend {
    $f = Join-Path $StateDir 'browsertool.json'
    if (-not (Test-Path $f)) { return 'none' }
    try {
        $c = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        $d = ([string]$c.desired).Trim().ToLower()
        if ($d -eq 'up' -or $d -eq 'down') { return $d }
    } catch {}
    return 'none'
}

function Test-Guardian {
    $procs = @(Get-ProcessByCmdline 'mcp-watchdog-guardian')
    $pidFile = Join-Path (Split-Path $BaseDir -Parent) 'mcp-watchdog-guardian\state\guardian.pid'
    $pidInfo = ''
    $pidOk = $false
    if (Test-Path -LiteralPath $pidFile) {
        try {
            $gp = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim())
            # 0.5.1: резервная проверка по pid-файлу (живой процесс И его cmdline = guardian)
            $pidOk = Test-PidAlive $gp 'mcp-watchdog-guardian'
            $pidInfo = "; guardian.pid=$gp$(if ($pidOk) { '(жив)' } else { '(МЁРТВ)' })"
        } catch { }
    }
    $detail = "процесс mcp-watchdog-guardian: $($procs.Count)$pidInfo"
    return @((($procs.Count -gt 0) -or $pidOk), $detail)
}

function Test-Monitor {
    # монитор состояния (infra-graph -Daemon): процесс ИЛИ свежий nodes.json
    $procs = @(Get-ProcessByCmdline 'infra-graph')
    $age = $null
    if (Test-Path -LiteralPath $NodesFile) {
        try {
            $fi = Get-Item -LiteralPath $NodesFile
            $age = [int]((Get-Date) - $fi.LastWriteTime).TotalSeconds
        } catch { }
    }
    # 0.5.1: резерв — pid монитора из nodes.json (записан самим монитором)
    $pidOk = $false; $pidTxt = ''
    try {
        if (Test-Path -LiteralPath $NodesFile) {
            $nj = Get-Content -LiteralPath $NodesFile -Raw | ConvertFrom-Json
            $mp = [string]$nj.nodes.monitor.Pid
            if ($mp) {
                $first = ($mp -split ',')[0].Trim()
                $pidOk = Test-PidAlive ([int]$first)
                $pidTxt = "; monitor.pid=$first$(if ($pidOk) { '(жив)' } else { '(МЁРТВ)' })"
            }
        }
    } catch { }
    $ageTxt = if ($null -ne $age) { "${age}s" } else { 'нет файла' }
    $detail = "процесс infra-graph: $($procs.Count)$pidTxt; nodes.json: $ageTxt"
    # монитор считается живым, если процесс ИЛИ pid из nodes.json ИЛИ файл состояния свежий (< 5 мин)
    $ok = ($procs.Count -gt 0) -or $pidOk -or (($null -ne $age) -and ($age -lt 300))
    return @($ok, $detail)
}

# ---- интенты (намерения владельца): кто что хочет видеть поднятым ----
function Get-Intents {
    # общий файл state\intents.json: {"<id>":{"desired":"up|down","owner":"...","since":"ISO"}}
    $c = $script:intentCache
    if (((Get-Date) - $c.at).TotalSeconds -lt 5) { return $c.data }
    $data = @{}
    if (Test-Path -LiteralPath $IntentsFile) {
        try {
            $j = Get-Content -LiteralPath $IntentsFile -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                $d = ([string]$p.Value.desired).Trim().ToLower()
                if ($d -eq 'up' -or $d -eq 'down') {
                    $data[$p.Name] = [pscustomobject]@{ Desired = $d; Owner = [string]$p.Value.owner; Since = [string]$p.Value.since }
                }
            }
        } catch {}
    }
    $script:intentCache = @{ at = (Get-Date); data = $data }
    return $data
}

function Get-Intent {
    param([string]$Id)
    $map = Get-Intents
    # ВАЖНО: для browsertool главный источник — его файл-команда влад��льца
    # (state\browsertool.json), общий intents.json его НЕ перекрывает.
    if ($Id -eq 'browsertool') {
        $d = Get-BrowsertoolIntend
        if ($d -eq 'up' -or $d -eq 'down') { return [pscustomobject]@{ Desired = $d; Owner = 'orchestrator'; Since = $null } }
    }
    if ($map.ContainsKey($Id)) { return $map[$Id] }
    # по умолчанию: нужные всегда узлы = 'up', остальные = 'none' (по требованию)
    if ($Id -in $AlwaysOn) { return [pscustomobject]@{ Desired = 'up'; Owner = 'watchdog(default)'; Since = $null } }
    return [pscustomobject]@{ Desired = 'none'; Owner = 'none'; Since = $null }
}

# Намерения по умолчанию публикуются ОДИН раз при старте демона: тем же файлом
# пользуется монитор (infra-graph), чтобы «нужен» значил одно и то же у обоих.
# Существующие ключи НЕ трогаем — решение владельца главнее.
function Initialize-IntentDefaults {
    if (-not (Test-Path -LiteralPath $IntentsFile)) {
        $body = [ordered]@{}
        $body | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $IntentsFile -Encoding utf8BOM
    }
    $cur = $null
    try { $cur = Get-Content -LiteralPath $IntentsFile -Raw | ConvertFrom-Json } catch { $cur = $null }
    $map = [ordered]@{}
    if ($cur) { foreach ($p in $cur.PSObject.Properties) { $map[$p.Name] = $p.Value } }
    $added = @()
    foreach ($id in $AlwaysOn) {
        if (-not $map.Contains($id)) {
            $map[$id] = [ordered]@{ desired = 'up'; owner = 'watchdog(default)'; since = (Get-Date -Format 'o'); note = 'нужен всегда: без него opencode теряет инструменты' }
            $added += $id
        }
    }
    # browsertool сюда НЕ пишем: его намерение живёт в state\browsertool.json (команда владельца)
    if ($added.Count -gt 0) {
        $map | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $IntentsFile -Encoding utf8BOM
        Write-Log 'INFO' "Намерения по умолчанию опубликованы в $IntentsFile : $($added -join ', ')"
    }
}

# ---- очки/класс узла из nodes.json монитора (демон только читает) ----
function Get-NodesFact {
    param([string]$Id)
    $c = $script:nodesCache
    if ($c.data -and ((Get-Date) - $c.at).TotalSeconds -lt 5) {
        if ($c.data.nodes -and $c.data.nodes.PSObject.Properties.Name -contains $Id) { return $c.data.nodes.$Id }
        return $null
    }
    $data = $null
    if (Test-Path -LiteralPath $NodesFile) {
        try { $data = Get-Content -LiteralPath $NodesFile -Raw | ConvertFrom-Json } catch { $data = $null }
    }
    $script:nodesCache = @{ at = (Get-Date); data = $data }
    if ($data -and $data.nodes -and ($data.nodes.PSObject.Properties.Name -contains $Id)) { return $data.nodes.$Id }
    return $null
}

function Get-UnloadCandidates {
    $c = $script:nodesCache
    if ($c.data -and $c.data.candidates) { return @($c.data.candidates) }
    return @()
}

# ---- явное состояние узла: только оно решает судьбу (заявка/автоподъём) ----
function Get-NodeState {
    param([string]$Id, [bool]$Alive, [string]$Desired, $Fact)
    $class = if ($ServerClass.Contains($Id)) { $ServerClass[$Id] } else { 'demand' }
    $val = $null
    if ($Fact -and $null -ne $Fact.Val) { try { $val = [double]$Fact.Val } catch { $val = $null } }

    if ($Alive) {
        # жив, но очки истекли (никто не обращался) и намерения «нужен» нет —
        # это «простаивает / выгружен по требованию», а не «сломан»
        if ($null -ne $val -and $val -le 0.005 -and $Desired -ne 'up' -and $class -in @('agent','demand')) { return 'unloaded' }
        if ($null -ne $val -and $val -le 0.5 -and $class -in @('agent','demand')) { return 'idle' }
        return 'active'
    }
    # не работает:
    if ($Desired -eq 'up') { return 'fault' }                 # нужен прямо сейчас → дефект
    if ($class -eq 'service') { return 'fault' }             # служба должна жить всегда
    if ($class -eq 'core')    { return 'fault' }             # ядро: не работает = дефект
    return 'unloaded'                                        # demand/agent без интента = по требованию
}

function Test-Server {
    param([string]$Server)
    switch ($Server) {
        'local-llm' {
            $proc    = Get-ProcessByCmdline 'llm_mcp_server.py'
            $procN   = @($proc).Count
            $ollamaOk = Test-Port 11434
            $ok = ($procN -gt 0) -and $ollamaOk
            $detail = "процесс llm_mcp_server.py: $procN; ollama:$(if ($ollamaOk) {'ok'} else {'down'})"
            return @($ok, $detail)
        }
        'firecrawl' {
            $proc  = Get-ProcessByCmdline 'firecrawl-mcp'
            $procN = @($proc).Count
            $key = [bool][Environment]::GetEnvironmentVariable('FIRECRAWL_API_KEY','User')
            $ok = ($procN -gt 0)
            $detail = "процесс firecrawl-mcp: $procN; FIRECRAWL_API_KEY(env):$(if ($key) {'set'} else {'missing'})"
            return @($ok, $detail)
        }
        'MCP_DOCKER' {
            $proc  = Get-ProcessByCmdline 'mcp gateway run'
            $procN = @($proc).Count
            $daemon = Test-DockerDaemon
            $ok = ($procN -gt 0) -and $daemon[0]
            $detail = "процесс 'mcp gateway run': $procN; docker daemon:$($daemon[0])"
            return @($ok, $detail)
        }
        'ollama' { return Test-OllamaServer }
        'browsertool' { return Test-Browsertool }
        'invr-stack' { return Test-InvrStack }
        'guardian' { return Test-Guardian }
        'monitor' { return Test-Monitor }
    }
    return @($false, "неизвестный сервер $Server")
}

function Get-OpenTickets {
    $tickets = @()
    Get-ChildItem -LiteralPath $ReqDir -Filter 'chk_*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $t = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if ($t.status -eq 'open') { $tickets += $t.id }
        } catch {}
    }
    return $tickets
}

function Save-Current {
    param($Opencode, $Results, $Tickets)
    $body = [ordered]@{
        watchdogStartedAt = $Script:StartedAt
        lastCheckAt       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        # 0.5.2: heartbeat дублируется в финальной записи — иначе Save-Current
        # в конце цикла стирает отметку, поставленную в начале (guardian считал бы
        # демон подвисшим во время долгого цикла лечения Docker)
        heartbeatAt       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        phase             = 'cycle-complete'
        opencodeDetected  = $Opencode
        checks            = $Results
        openTickets       = @($Tickets)
        policy            = [ordered]@{
            model         = '0.4.0'
            # 'owner-decides': решение о завершении принимает владелец узла;
            # демон публикует кандидатов, но сам ничего не завершает.
            unload         = $(if ($AllowUnload) { 'candidates-only(осознанно, -AllowUnload не включён автопроцесса)' } else { 'owner-decides' })
            coreProtected  = @($CoreProtect)
            autoHeal       = @('MCP_DOCKER','local-llm','firecrawl','ollama')
            onDemand       = @('browsertool')
        }
        unloadCandidates  = @($script:unloadReport)
        monitorNodesFile  = $NodesFile
        monitorNodesFresh = $(if (Test-Path -LiteralPath $NodesFile) { [int]((Get-Date) - (Get-Item -LiteralPath $NodesFile).LastWriteTime).TotalSeconds } else { $null })
    }
    $Script:Results = $body
    $body | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $CurFile -Encoding utf8BOM
}

# 0.5.2: отметка «цикл идёт» в начале каждого прохода. Раньше current.json
# обновлялся ТОЛЬКО в конце цикла, а цикл лечения Docker длится до ~180 с
# (и дольше, если daemon не поднимается). Guardian считал такой демон «подвисшим»
# (current.json старше StaleSec) и поднимал второй демон — их становилось 5,
# и они конкурировали за один файл состояния. Теперь current.json всегда свеж.
function Save-Heartbeat {
    param($Phase = 'checking')
    $file = $CurFile
    $existing = $null
    try { if (Test-Path -LiteralPath $file) { $existing = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } } catch { }
    if (-not $existing) {
        Save-Current (Get-OpencodeAlive $ProcessName) ([ordered]@{}) (Get-OpenTickets)
        return
    }
    $existing | Add-Member -NotePropertyName phase -NotePropertyValue $Phase -Force
    $existing | Add-Member -NotePropertyName heartbeatAt -NotePropertyValue (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Force
    $existing | Add-Member -NotePropertyName lastCheckAt -NotePropertyValue (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Force
    $existing | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file -Encoding utf8BOM
}

# ---- старт ----
$Script:StartedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-Log 'INFO' "ДЕМОН СТАРТУЕТ (версия 0.5.2, pid=$PID, интервал=${IntervalSec}s, контроль процесса: $ProcessName, состояние: $CurFile)"
Initialize-IntentDefaults

# защита от дублей: уже работающий демон (проверяем ДО записи своего pid)
$priorPid = $null
if (Test-Path $PidFile) {
    try { $priorPid = [int]((Get-Content -LiteralPath $PidFile -Raw).Trim()) } catch { $priorPid = $null }
}
Write-Log 'DEBUG' "Защита: $PidFile → priorPid=$priorPid (текущий $PID)"
if ($priorPid -and $priorPid -ne $PID -and -not $Once) {
    $priorProc = Get-Process -Id $priorPid -ErrorAction SilentlyContinue
    if ($priorProc) {
        $priorCmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$priorPid" -ErrorAction SilentlyContinue).CommandLine
        if ($priorCmd -and $priorCmd.IndexOf('mcp-watchdog', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Write-Log 'INFO' "Завершение: уже работает демон (pid=$priorPid, cmd содержит mcp-watchdog); второй экземпляр не нужен."
            exit 0
        }
    }
}
if (-not $Once) { Set-Content -LiteralPath $PidFile -Value $PID -Encoding ascii }

# стартовое условие: opencode должен быть обнаружен, иначе штатное завершение с причиной
if (-not (Get-OpencodeAlive $ProcessName)) {
    Write-Log 'INFO' "Завершение: процесс opencode ('$ProcessName') не обнаружен при запуске → демон не нужен."
    exit 0
}
Write-Log 'INFO' "opencode обнаружен → демон переходит в режим слежения."

# разовый прогон (для тестов)
$Servers = @('local-llm','firecrawl','MCP_DOCKER','ollama','browsertool','invr-stack','guardian','monitor')
if ($Once) {
    foreach ($s in $Servers) {
        $r = Test-Server $s
        $it = Get-Intent $s
        $st = Get-NodeState $s ([bool]$r[0]) $it.Desired (Get-NodesFact $s)
        Write-Log 'CHECK' "$s → $(if ($r[0]) {'OK'} else {'FAIL'}) | состояние=$st | интент=$($it.Desired) | $($r[1])"
    }
    exit 0
}

# ---- основной цикл ----
$okStreak = @{}
# 0.4.0: список «заявки не создаём» больше не нужен — решение принимает СОСТОЯНИЕ:
#   unloaded (выключен по требованию) → заявка не создаётся, автоподъёма нет;
#   fault (реально упал / нужен прямо сейчас) → автоподъём + заявка.
$script:lastDockerTry  = [DateTime]::MinValue
$script:lastOllamaTry  = [DateTime]::MinValue
$script:lastBrowserTry = [DateTime]::MinValue
$script:lastLlmTry     = [DateTime]::MinValue
$script:lastFirecrawlTry = [DateTime]::MinValue
$script:lastMcpTry     = [DateTime]::MinValue
while ($true) {
    if (-not (Get-OpencodeAlive $ProcessName)) {
        Write-Log 'INFO' "Завершение: процесс opencode ('$ProcessName') больше не обнаружен → opencode закрыт, демон останавливается."
        break
    }

    Save-Heartbeat 'start-of-cycle'
    $tick = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $results = [ordered]@{}
    $tickets = Get-OpenTickets

    foreach ($s in $Servers) {
        $r  = Test-Server $s
        $it = Get-Intent $s
        $fact = Get-NodesFact $s
        $state = Get-NodeState $s ([bool]$r[0]) $it.Desired $fact
        $class = if ($ServerClass.Contains($s)) { $ServerClass[$s] } else { 'demand' }
        $valTxt = if ($fact -and $null -ne $fact.Val) { [int]([double]$fact.Val * 100) } else { $null }
        $status = if ($r[0]) { 'ok' } else { 'fail' }
        $results[$s] = [ordered]@{
            status = $status
            state  = $state
            intent = $it.Desired
            owner  = $it.Owner
            class  = $class
            val    = $(if ($null -ne $valTxt) { "$valTxt%" } else { $null })
            detail = $r[1]
            lastCheckAt = $tick
        }

        if ($r[0]) {
            if ($okStreak.ContainsKey($s)) { $okStreak[$s]++ } else { $okStreak[$s] = 1 }
            Write-Log 'CHECK' "$tick ${s}: OK | состояние=$state | интент=$($it.Desired) | очки=$valTxt% | $($r[1])"
            # самовылечивание: 2 успешные проверки подряд → закрыть открытую заявку
            if ($okStreak[$s] -ge 2) {
                $left = @()
                Get-ChildItem -LiteralPath $ReqDir -Filter "chk_*.json" -ErrorAction SilentlyContinue | ForEach-Object {
                    try { $t = Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $t = $null }
                    if ($t -and $t.status -eq 'open' -and $t.server -eq $s) {
                        $t.status      = 'resolved'
                        $t.resolvedAt  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                        $t.resolvedBy  = 'watchdog'
                        $t.resolution  = 'сервер снова в состоянии ok (2 проверки подряд), вмешательство оркестратора не потребовалось'
                        $t | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $_.FullName -Encoding utf8BOM
                        Write-Log 'TICKET' "Заявка $($t.id) закрыта демоном (самовосстановление $s)."
                    }
                }
                $tickets = Get-OpenTickets
            }
        } else {
            $okStreak[$s] = 0
            # 0.4.0: НЕ РАБОТАЕТ, НО НЕ СЛОМАНОСЬ.
            # Если интент не 'up' и класс demand/agent → состояние unloaded:
            # это «инструмент по требованию» — НЕ дефект: заявку не создаём,
            # автоподъём НЕ делаем (кроме явной команды 'down' → завершить).
            if ($state -eq 'unloaded') {
                if ($s -eq 'browsertool' -and $it.Desired -eq 'down') {
                    if ((Get-BrowserDriverProcs) -or (Test-Port $BrowserPort)) {
                        Write-Log 'CHECK' "$tick browsertool: команда 'down' (владелец) — завершаю работающий driver.mjs."
                        $null = Stop-Browsertool
                        $results[$s].detail = 'команда down выполнена (процесс завершён)'
                    }
                } else {
                    Write-Log 'CHECK' "$tick ${s}: состояние=unloaded | класс=$class интент='$($it.Desired)' | «по требованию»: не поднимаю, заявка не создаётся."
                }
                continue
            }
            # дальше — только РЕАЛЬНЫЙ дефект: процесс нужен (интент up) или это служба/ядро
            Write-Log 'WARN' "$tick ${s}: состояние=$state (интент='$($it.Desired)', класс=$class) | FAIL: $($r[1])"
            # автовосстановление инфраструктуры (с троттлингом): пробуем поднять, затем перепроверяем
            $healed = $false
            if ($s -eq 'MCP_DOCKER' -and (Get-Date) -gt $script:lastDockerTry.AddSeconds($ThrottleSec)) {
                $script:lastDockerTry = Get-Date
                if (Start-DockerDesktop) {
                    $re = Test-Server 'MCP_DOCKER'
                    if ($re[0]) {
                        $healed = $true
                        $status = 'ok'
                        $results[$s].status = 'ok'
                        $results[$s].state  = Get-NodeState $s $true $it.Desired (Get-NodesFact $s)
                        $results[$s].detail = $re[1]
                        $results[$s].lastCheckAt = $tick
                        Write-Log 'CHECK' "$tick ${s}: OK (после авто-подъёма Docker Desktop) | $($re[1])"
                    }
                }
            }
            if ($s -eq 'MCP_DOCKER' -and -not $healed -and (Test-DockerDaemon)[0] -and (Get-Date) -gt $script:lastMcpTry.AddSeconds($ThrottleSec)) {
                $script:lastMcpTry = Get-Date
                if (Start-McpDockerGateway) {
                    $re = Test-Server 'MCP_DOCKER'
                    if ($re[0]) {
                        $healed = $true
                        $status = 'ok'
                        $results[$s].status = 'ok'
                        $results[$s].state  = Get-NodeState $s $true $it.Desired (Get-NodesFact $s)
                        $results[$s].detail = $re[1]
                        $results[$s].lastCheckAt = $tick
                        Write-Log 'CHECK' "$tick ${s}: OK (после авто-подъёма gateway) | $($re[1])"
                    }
                }
            }
            if ($s -eq 'local-llm' -and -not $healed -and (Get-Date) -gt $script:lastLlmTry.AddSeconds($ThrottleSec)) {
                $script:lastLlmTry = Get-Date
                if (Start-LocalLlm) {
                    $re = Test-Server 'local-llm'
                    if ($re[0]) {
                        $healed = $true
                        $status = 'ok'
                        $results[$s].status = 'ok'
                        $results[$s].state  = Get-NodeState $s $true $it.Desired (Get-NodesFact $s)
                        $results[$s].detail = $re[1]
                        $results[$s].lastCheckAt = $tick
                        Write-Log 'CHECK' "$tick ${s}: OK (после авто-подъёма local-llm) | $($re[1])"
                    }
                }
            }
            if ($s -eq 'firecrawl' -and -not $healed -and (Get-Date) -gt $script:lastFirecrawlTry.AddSeconds($ThrottleSec)) {
                $script:lastFirecrawlTry = Get-Date
                if (Start-FirecrawlMcp) {
                    $re = Test-Server 'firecrawl'
                    if ($re[0]) {
                        $healed = $true
                        $status = 'ok'
                        $results[$s].status = 'ok'
                        $results[$s].state  = Get-NodeState $s $true $it.Desired (Get-NodesFact $s)
                        $results[$s].detail = $re[1]
                        $results[$s].lastCheckAt = $tick
                        Write-Log 'CHECK' "$tick ${s}: OK (после авто-подъёма firecrawl-mcp) | $($re[1])"
                    }
                }
            }
            if ($s -eq 'ollama' -and -not $healed -and (Get-Date) -gt $script:lastOllamaTry.AddSeconds($ThrottleSec)) {
                $script:lastOllamaTry = Get-Date
                if (Start-OllamaServer) {
                    $re = Test-Server 'ollama'
                    if ($re[0]) {
                        $healed = $true
                        $status = 'ok'
                        $results[$s].status = 'ok'
                        $results[$s].state  = Get-NodeState $s $true $it.Desired (Get-NodesFact $s)
                        $results[$s].detail = $re[1]
                        $results[$s].lastCheckAt = $tick
                        Write-Log 'CHECK' "$tick ${s}: OK (после авто-подъёма ollama) | $($re[1])"
                    }
                }
            }
            # browsertool: сюда попадаем только при интент 'up' (для 'none'/'down' выход был выше)
            if ($s -eq 'browsertool' -and -not $healed) {
                if ((Get-Date) -gt $script:lastBrowserTry.AddSeconds($ThrottleSec)) {
                    $script:lastBrowserTry = Get-Date
                    if (Start-Browsertool) {
                        $re = Test-Server 'browsertool'
                        if ($re[0]) {
                            $healed = $true
                            $status = 'ok'
                            $results[$s].status = 'ok'
                            $results[$s].state  = Get-NodeState $s $true $it.Desired (Get-NodesFact $s)
                            $results[$s].detail = $re[1]
                            $results[$s].lastCheckAt = $tick
                            Write-Log 'CHECK' "$tick ${s}: OK (после авто-подъёма browsertool) | $($re[1])"
                        }
                    }
                } else {
                    Write-Log 'CHECK' "$tick browsertool: интент 'up', но троттлинг ${ThrottleSec}s — жду следующей попытки."
                }
            }
            if ($healed) { $okStreak[$s] = 1; continue }
            # 0.4.0: дошли сюда = реальный дефект (fault). Заявка — только для него.
            $openExisting = Get-ChildItem -LiteralPath $ReqDir -Filter "chk_*.json" -ErrorAction SilentlyContinue |
                ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } |
                Where-Object { $_.status -eq 'open' -and $_.server -eq $s }
            if (-not $openExisting) {
                $id  = "chk_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + "_" + (Get-Random -Minimum 1000 -Maximum 9999)
                $tkt = [ordered]@{
                    id             = $id
                    server         = $s
                    status         = 'open'
                    state          = $state
                    intent         = $it.Desired
                    nodeClass      = $class
                    createdAt      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                    lastObservedAt = $tick
                    diagnostics    = $r[1]
                    resolvedAt     = $null
                    resolvedBy     = $null
                    resolution     = $null
                }
                $tkt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReqDir "$id.json") -Encoding utf8BOM
                $tickets += $id
                Write-Log 'TICKET' "Заявка-сессия проверки создана: $id (узел $s, состояние=$state, интент='$($it.Desired)') → оркестратор должен обработать."
            }
        }
    }

    # ---- публикация кандидатов на выгрузку (решение принимает владелец, не демон) ----
    if (((Get-Date) - $script:lastUnloadLog).TotalSeconds -ge $UnloadLogSec) {
        $script:lastUnloadLog = Get-Date
        $cands = Get-UnloadCandidates
        $coreCands = @($cands | Where-Object { $CoreProtect -contains [string]$_.id })
        $softCands = @($cands | Where-Object { $CoreProtect -notcontains [string]$_.id })
        $script:unloadReport = @($softCands | ForEach-Object {
            [ordered]@{ id = [string]$_.id; class = [string]$_.class; val = $_.val; state = [string]$_.state; owner = [string]$_.owner; pid = $_.pid; reason = $_.reason }
        })
        if ($coreCands.Count -gt 0) {
            Write-Log 'INFO' "ЯДРО в кандидатах на выгрузку (ЗАПРЕЩЕНО, игнорирую): $(($coreCands | ForEach-Object { $_.id }) -join ', ')"
        }
        if ($script:unloadReport.Count -gt 0) {
            Write-Log 'INFO' "Кандидаты на выгрузку (ждут решения владельца, демон не завершает): $(($script:unloadReport | ForEach-Object { "$($_.id)=$($_.val)% [$($_.state)]" }) -join ', ')"
        } else {
            Write-Log 'DEBUG' 'Кандидатов на выгрузку нет.'
        }
    }

    Save-Current $true $results $tickets
    Start-Sleep -Seconds $IntervalSec
}

Write-Log 'INFO' "ДЕМОН ЗАВЕРШЁН (pid=$PID)."
if (Test-Path $PidFile) { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue }