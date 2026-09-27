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

#Requires -Version 7

param(
    [int]$IntervalSec = 30,
    [string]$ProcessName = 'OpenCode',
    [int]$ThrottleSec = 180,
    [switch]$Once,
    [string]$RuntimeDir = '',
    [string]$BrowserDriverPath = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$BaseDir   = if ($RuntimeDir) { $RuntimeDir } else { $PSScriptRoot }
$StateDir  = Join-Path $BaseDir 'state'
$ReqDir    = Join-Path $BaseDir 'requests'
$LogDir    = 'C:\Scripts\Logs'
$LogFile   = Join-Path $LogDir 'mcp-watchdog.log'

$DockerExe       = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
$OllamaServerCmd = 'C:\Scripts\ollama-server.cmd'
$BrowserPort     = 8123
$NodeExe         = 'C:\Program Files\nodejs\node.exe'
$toolsRoot    = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$driverLocal  = Join-Path $BaseDir 'browsertool\driver.mjs'
$driverShared = Join-Path $toolsRoot 'browsertool\driver.mjs'
$BrowserDriver   = if ($BrowserDriverPath) { $BrowserDriverPath }
                   elseif (Test-Path -LiteralPath $driverLocal) { $driverLocal }
                   elseif (Test-Path -LiteralPath $driverShared) { $driverShared }
                   else { $driverLocal }

$PidFile   = Join-Path $StateDir 'watchdog.pid'
$CurFile   = Join-Path $StateDir 'current.json'
$MyStamp   = Get-Date -Format 'yyyyMMdd_HHmmss'

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

function Get-ProcessByCmdline {
    param([string]$Needle)
    try {
        Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
    } catch { return $null }
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

function Test-InvrStack {
    $files = @(
        'C:\Scripts\.opencode\agent\invr-lead.md',
        'C:\Scripts\.opencode\agent\invr-analyst.md',
        'C:\Scripts\.opencode\agent\invr-architect.md',
        'C:\Scripts\.opencode\agent\invr-coder.md',
        'C:\Scripts\.opencode\agent\invr-reviewer.md',
        'C:\Scripts\.opencode\agent\invr-qa.md',
        'C:\Scripts\.opencode\agent\invr-devops.md',
        'C:\Scripts\.opencode\agent\invr-docs.md',
        'C:\Scripts\.opencode\command\invr.md',
        'C:\Scripts\.opencode\command\providers.md'
    )
    $missing = @($files | Where-Object { -not (Test-Path $_) })
    $detail = "агенты/команды INVR: есть $($files.Count - $missing.Count) из $($files.Count); отсутствуют: $(if ($missing) { $missing -join '; ' } else { 'нет' })"
    return @(($missing.Count -eq 0), $detail)
}

function Start-DockerDesktop {
    if (-not (Test-Path $DockerExe)) { Write-Log 'WARN' "Auto-heal: Docker Desktop не найден ($DockerExe)"; return $false }
    Write-Log 'INFO' 'Auto-heal: запуск Docker Desktop…'
    Start-Process -FilePath $DockerExe | Out-Null
    for ($i = 0; $i -lt 18; $i++) {
        Start-Sleep 5
        $daemon = $false
        try { $null = (& docker info 2>$null); $daemon = ($LASTEXITCODE -eq 0) } catch { $daemon = $false }
        if ($daemon) { Write-Log 'INFO' 'Auto-heal: Docker daemon поднялся.'; return $true }
    }
    Write-Log 'WARN' 'Auto-heal: Docker daemon не поднялся за ~90с.'
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
    $py  = 'C:\Scripts\hermes-project\.venv-mcp\Scripts\python.exe'
    $srv = 'C:\Scripts\hermes-project\scripts\llm_mcp_server.py'
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
    $idx = 'C:\Program Files\nodejs\node_modules\firecrawl-mcp\dist\index.js'
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
        opencodeDetected  = $Opencode
        checks            = $Results
        openTickets       = @($Tickets)
    }
    $Script:Results = $body
    $body | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $CurFile -Encoding utf8BOM
}

# ---- старт ----
$Script:StartedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-Log 'INFO' "ДЕМОН СТАРТУЕТ (pid=$PID, интервал=${IntervalSec}s, контроль процесса: $ProcessName, состояние: $CurFile)"

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
$Servers = 'local-llm','firecrawl','MCP_DOCKER','ollama','browsertool','invr-stack'
if ($Once) {
    foreach ($s in $Servers) {
        $r = Test-Server $s
        Write-Log 'CHECK' "$s → $(if ($r[0]) {'OK'} else {'FAIL'}) | $($r[1])"
    }
    exit 0
}

# ---- основной цикл ----
$okStreak = @{}
$NoTicket = @('browsertool')   # инструменты «по требованию» — проверяем, но заявки не создаём
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

    $tick = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $results = [ordered]@{}
    $tickets = Get-OpenTickets

    foreach ($s in $Servers) {
        $r = Test-Server $s
        $status = if ($r[0]) { 'ok' } else { 'fail' }
        $results[$s] = [ordered]@{ status = $status; detail = $r[1]; lastCheckAt = $tick }

        if ($r[0]) {
            if ($okStreak.ContainsKey($s)) { $okStreak[$s]++ } else { $okStreak[$s] = 1 }
            Write-Log 'CHECK' "$tick ${s}: OK | $($r[1])"
            # самовылечивание: 2 успешные проверки подряд → закрыть открытую заявку
            if (($s -notin $NoTicket) -and ($okStreak[$s] -ge 2)) {
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
            # автовосстановление инфраструктуры (с троттлингом): пробуем поднять, затем перепроверяем
            $healed = $false
            if ($s -eq 'MCP_DOCKER' -and (Get-Date) -gt $script:lastDockerTry.AddSeconds($ThrottleSec)) {
                $script:lastDockerTry = Get-Date
                if (Start-DockerDesktop) {
                    $re = Test-Server 'MCP_DOCKER'
                    if ($re[0]) {
                        $healed = $true
                        $status = 'ok'
                        $results[$s] = [ordered]@{ status = $status; detail = $re[1]; lastCheckAt = $tick }
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
                        $results[$s] = [ordered]@{ status = $status; detail = $re[1]; lastCheckAt = $tick }
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
                        $results[$s] = [ordered]@{ status = $status; detail = $re[1]; lastCheckAt = $tick }
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
                        $results[$s] = [ordered]@{ status = $status; detail = $re[1]; lastCheckAt = $tick }
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
                        $results[$s] = [ordered]@{ status = $status; detail = $re[1]; lastCheckAt = $tick }
                        Write-Log 'CHECK' "$tick ${s}: OK (после авто-подъёма ollama) | $($re[1])"
                    }
                }
            }
            if ($s -eq 'browsertool' -and -not $healed) {
                $intend = Get-BrowsertoolIntend
                if ($intend -eq 'down') {
                    # явная команда «больше не нужен» → завершаем работающий и не поднимаем
                    $script:lastBrowserTry = [DateTime]::MinValue
                    if ((Get-BrowserDriverProcs) -or (Test-Port $BrowserPort)) {
                        Write-Log 'CHECK' "$tick browsertool: команда 'down' — завершаю работающий driver.mjs."
                        $null = Stop-Browsertool
                    }
                }
                elseif ($intend -eq 'up' -and (Get-Date) -gt $script:lastBrowserTry.AddSeconds($ThrottleSec)) {
                    $script:lastBrowserTry = Get-Date
                    if (Start-Browsertool) {
                        $re = Test-Server 'browsertool'
                        if ($re[0]) {
                            $healed = $true
                            $status = 'ok'
                            $results[$s] = [ordered]@{ status = $status; detail = $re[1]; lastCheckAt = $tick }
                            Write-Log 'CHECK' "$tick ${s}: OK (после авто-подъёма browsertool) | $($re[1])"
                        }
                    }
                }
                else {
                    Write-Log 'CHECK' "$tick browsertool: инструмент «по требованию» (интент '$intend') — не поднимаю."
                }
            }
            if ($healed) { $okStreak[$s] = 1; continue }
            Write-Log 'WARN' "$tick ${s}: FAIL | $($r[1])"
            # новая заявка — только если нет открытой по этому серверу
            if ($s -in $NoTicket) {
                Write-Log 'CHECK' "$tick ${s}: ожидаемое отсутствие (инструмент по требованию) — заявка не создаётся."
            } else {
            $openExisting = Get-ChildItem -LiteralPath $ReqDir -Filter "chk_*.json" -ErrorAction SilentlyContinue |
                ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } |
                Where-Object { $_.status -eq 'open' -and $_.server -eq $s }
            if (-not $openExisting) {
                $id  = "chk_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + "_" + (Get-Random -Minimum 1000 -Maximum 9999)
                $tkt = [ordered]@{
                    id             = $id
                    server         = $s
                    status         = 'open'
                    createdAt      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                    lastObservedAt = $tick
                    diagnostics    = $r[1]
                    resolvedAt     = $null
                    resolvedBy     = $null
                    resolution     = $null
                }
                $tkt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReqDir "$id.json") -Encoding utf8BOM
                $tickets += $id
                Write-Log 'TICKET' "Заявка-сессия проверки создана: $id (сервер $s) → оркестратор должен обработать."
            }
            }
        }
    }

    Save-Current $true $results $tickets
    Start-Sleep -Seconds $IntervalSec
}

Write-Log 'INFO' "ДЕМОН ЗАВЕРШЁН (pid=$PID)."
if (Test-Path $PidFile) { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue }