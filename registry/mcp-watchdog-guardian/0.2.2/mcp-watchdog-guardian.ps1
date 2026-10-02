# mcp-watchdog-guardian.ps1 — хранитель демона-стража и монитора состояния
# Версия 0.2.2. Надзор за тремя уровнями системы:
#   opencode (сессия) → mcp-watchdog (демон-страж) → infra-graph -Daemon (монитор).
# Монитор считает очки/состояния узлов и пишет nodes.json; хранитель следит, чтобы
# монитор был жив, зеркалит nodes.json в свой каталог состояния и НИЧЕГО не
# выгружает сам: решение о завершении процессов принимает владелец узла
# (см. модель состояний в mcp-watchdog 0.4.0 / infra-graph 0.7.0).
#Requires -Version 7

<#
.SYNOPSIS
  Хранитель демона-стража mcp-watchdog и монитора infra-graph: автозапуск вместе
  с системой, подъём демона и монитора при каждом появлении/перезапуске opencode,
  зеркало состояния узлов.

.DESCRIPTION
  Зачем он нужен:
    - демон mcp-watchdog по условию старта требует живой процесс opencode и сам
      завершается, когда opencode закрыт. Поэтому демон нельзя просто «запустить
      с системой»: без открытого opencode он штатно выйдет.
    - монитор (infra-graph -Daemon) считает очки и состояния всех узлов и пишет
      nodes.json; без него watchdog не знает актуальности, а плагин статуса
      показывает устаревшие данные.
    - хранитель стартует при входе пользователя в Windows (HKCU Run), живёт всю
      сессию и каждые -IntervalSec секунд смотрит:
        1) есть ли процесс opencode;
        2) если есть — жив ли демон (pid-файл + процесс + cmdline + свежесть
           state\current.json);
        3) если есть — жив ли монитор (процесс infra-graph +Daemon ИЛИ свежесть
           nodes.json не старше -MonitorStaleSec);
        4) раз в -MirrorSec секунд зеркалит nodes.json в свой каталог состояния
           и публикует сводку (включая кандидатов на выгрузку) в state\current.json.
      Если демон или монитор мёртв (или подвис) — хранитель поднимает его скрыто
      (Start-Process pwsh -WindowStyle Hidden), с троттлингом -StartThrottleSec.
    - открыт ли opencode или нет, демон и монитор не дублируются: проверка по
      pid-файлу/процессу и защита от дублей есть у самого демона и монитора.

  Логика состояний (хранитель): opencode нет → демон и монитор не нужны (демон
  завершается сам; монитор завершается, если запущен хранителем — чтобы не жечь
  ресурсы без сессии); opencode есть и демон/монитор мёртв → автоподъём; всё живо →
  ничего не делаем.

  ПОЛИТИКА ВЫГРУЗКИ: хранитель НЕ завершает процессы по очкам и НЕ принимает
  решение о выгрузке. Он только публикует unloadCandidates и ждёт решения
  владельца. Автоматически не останавливается ничего, кроме монитора, который
  сам был запущен хранителем, при закрытии opencode (парность сессии, как у демона).

.PARAMETER IntervalSec
  Период опроса состояния (по умолчанию 20 с).

.PARAMETER ProcessName
  Имя процесса opencode (по умолчанию OpenCode).

.PARAMETER StartThrottleSec
  Минимальный интервал между попытками подъёма демона/монитора (защита от частых
  перезапусков, по умолчанию 60 с).

.PARAMETER StaleSec
  Сколько секунд может не обновляться state\current.json демона, прежде чем
  демон будет признан подвисшим (по умолчанию 420 с; 0 — не проверять).
  0.2.2: было 120 с — этого не хватало: демон внутри цикла может надолго
  (до ~3 мин) лечить Docker Desktop (старт 90 с + wsl --shutdown и вторая
  попытка) и в это время не пишет current.json; guardian успевал решить, что
  демон «подвис», и поднять второй экземпляр.

.PARAMETER MonitorStaleSec
  Сколько секунд может не обновляться nodes.json монитора, прежде чем монитор
  будет признан неработающим (по умолчанию 300 с; 0 — не проверять).

.PARAMETER MonitorGraceSec
  Допуск «процесс только что стартовал»: если процесса монитора нет, но nodes.json
  моложе этого времени (по умолчанию 90 с) — монитор считается живым. Нужен, чтобы
  не поднимать второй монитор в момент старта первого.

.PARAMETER MirrorSec
  Как часто зеркалить nodes.json в каталог хранителя (по умолчанию 300 с).

.PARAMETER WaitMaxMin
  Максимум минут ожидания opencode; 0 (по умолчанию) — ждать бесконечно, пока
  жив сам хранитель.

.PARAMETER Once
  Одна итерация опроса (проверка/тест), затем выход.

.PARAMETER RuntimeDir
  Каталог состояния хранителя (по умолчанию каталог скрипта).

.PARAMETER WatchdogRuntimeDir
  Каталог состояния демона mcp-watchdog (по умолчанию <корень инструментов>\mcp-watchdog).

.PARAMETER MonitorDir
  Каталог состояния монитора (по умолчанию <корень инструментов>\monitor); там
  лежит state\nodes.json.

.EXAMPLE
  pwsh -File mcp-watchdog-guardian.ps1 -Once
  Разовая проверка: есть ли opencode, жив ли демон и монитор.

.EXAMPLE
  pwsh -File mcp-watchdog-guardian.ps1
  Демон-хранитель: работает в фоне, поднимает демон и монитор при появлении opencode.
#>

param(
    [int]$IntervalSec = 20,
    [string]$ProcessName = 'OpenCode',
    [int]$StartThrottleSec = 60,
    [int]$StaleSec = 420,
    [int]$MonitorStaleSec = 300,
    [int]$MonitorGraceSec = 90,
    [int]$MirrorSec = 300,
    [int]$WaitMaxMin = 0,
    [switch]$Once,
    [string]$RuntimeDir = '',
    [string]$WatchdogRuntimeDir = '',
    [string]$MonitorDir = '',
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Переносимые корни (машинные пути не зашиты): скрипт лежит в
# registry\<tool>\<version>, каталог инструментов — уровнем выше реестра.
$regRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$toolsRoot = Split-Path $regRoot -Parent
if (-not $WatchdogRuntimeDir) { $WatchdogRuntimeDir = Join-Path $toolsRoot 'mcp-watchdog' }
if (-not $MonitorDir)        { $MonitorDir        = Join-Path $toolsRoot 'monitor' }

$BaseDir  = if ($RuntimeDir) { $RuntimeDir } else { $PSScriptRoot }
$StateDir = Join-Path $BaseDir 'state'
# Журнал: env INVR_LOG_DIR (процесс, затем User) > <корень инструментов>\Logs
$logDirEnv = if ($env:INVR_LOG_DIR) { $env:INVR_LOG_DIR } else { [Environment]::GetEnvironmentVariable('INVR_LOG_DIR', 'User') }
if (-not $LogFile) {
    $logDir = if ($logDirEnv) { $logDirEnv } else { Join-Path $toolsRoot 'Logs' }
    $LogFile = Join-Path $logDir 'mcp-watchdog-guardian.log'
}
$LogDir = Split-Path $LogFile -Parent
foreach ($d in @($StateDir, $LogDir)) { if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

$GuardianPidFile = Join-Path $StateDir 'guardian.pid'
$WdStateDir      = Join-Path $WatchdogRuntimeDir 'state'
$WdPidFile       = Join-Path $WdStateDir 'watchdog.pid'
$WdCurFile       = Join-Path $WdStateDir 'current.json'
$WdShim          = Join-Path $toolsRoot 'mcp-watchdog.ps1'
$WdRegistryRoot  = Join-Path $regRoot 'mcp-watchdog'
# --- монитор состояния (infra-graph -Daemon) ---
$MonNodesFile    = Join-Path $MonitorDir 'state\nodes.json'
$MonShim         = Join-Path $toolsRoot 'infra-graph.ps1'
$MonRegistryRoot = Join-Path $regRoot 'infra-graph'
$MonNeedle       = 'infra-graph'

function Write-Log {
    param([string]$Level, [string]$Msg)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg"
    Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8BOM
    Write-Output $line
}

trap {
    Write-Log 'FATAL' "необработанная ошибка: $($_.Exception.Message) | $($_.InvocationInfo.PositionMessage)"
    exit 1
}

function Get-ProcCmdline {
    param([int]$Id)
    try { (Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction Stop).CommandLine }
    catch { $null }
}

function Test-ProcAlive {
    param([int]$Id, [string]$Needle)
    if (-not $Id) { return $false }
    $p = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if ($Needle) {
        $cmd = Get-ProcCmdline -Id $Id
        if (-not $cmd -or $cmd.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

function Get-OpencodeAlive {
    param([string]$Name)
    [bool](Get-Process -Name $Name -ErrorAction SilentlyContinue)
}

function Get-WatchdogPid {
    if (-not (Test-Path -LiteralPath $WdPidFile)) { return $null }
    try { [int]((Get-Content -LiteralPath $WdPidFile -Raw).Trim()) } catch { $null }
}

function Test-WatchdogAlive {
    $pid0 = Get-WatchdogPid
    if (-not $pid0) { return [pscustomobject]@{ alive = $false; pid = $null; reason = 'нет pid-файла демона' } }
    if (-not (Test-ProcAlive -Id $pid0 -Needle 'mcp-watchdog')) {
        return [pscustomobject]@{ alive = $false; pid = $pid0; reason = "процесс pid=$pid0 не жив или это не демон" }
    }
    if ($StaleSec -gt 0 -and (Test-Path -LiteralPath $WdCurFile)) {
        try {
            $cur = Get-Content -LiteralPath $WdCurFile -Raw | ConvertFrom-Json
            $last = [datetime]::ParseExact([string]$cur.lastCheckAt, 'yyyy-MM-dd HH:mm:ss', $null)
            $age = ((Get-Date) - $last).TotalSeconds
            if ($age -gt $StaleSec) {
                return [pscustomobject]@{ alive = $false; pid = $pid0; reason = "демон pid=$pid0 есть, но current.json устарел (${age}s > ${StaleSec}s) — подвис" }
            }
        } catch { }
    }
    return [pscustomobject]@{ alive = $true; pid = $pid0; reason = "демон жив (pid=$pid0)" }
}

function Resolve-WatchdogEntry {
    if (Test-Path -LiteralPath $WdShim) { return $WdShim }
    $latestFile = Join-Path $WdRegistryRoot 'latest.txt'
    if (Test-Path -LiteralPath $latestFile) {
        $ver = (Get-Content -LiteralPath $latestFile -Raw).Trim()
        $entry = Join-Path $WdRegistryRoot "$ver\mcp-watchdog.ps1"
        if (Test-Path -LiteralPath $entry) { return $entry }
    }
    return $null
}

function Start-Watchdog {
    $entry = Resolve-WatchdogEntry
    if (-not $entry) { Write-Log 'WARN' "не найден запуск демона (шим $WdShim и реестр $WdRegistryRoot) — пропуск подъёма"; return $false }
    try {
        Start-Process pwsh -WindowStyle Hidden -ArgumentList '-NoProfile', '-File', $entry, '-RuntimeDir', $WatchdogRuntimeDir | Out-Null
        Write-Log 'INFO' "демон-страж mcp-watchdog поднят (точка входа: $entry, состояние: $WatchdogRuntimeDir)"
        return $true
    } catch {
        Write-Log 'ERROR' "не удалось поднять демон-страж: $($_.Exception.Message)"
        return $false
    }
}

function Get-ProcsByNeedle {
    param([string]$Needle)
    $out = @()
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if (-not $p.CommandLine) { continue }
        # 0.2.1: одноразовые проверки из консоли (pwsh -Command «... infra-graph ...»)
        # НЕ считаем сервисами — иначе демоны «видели» бы самих себя проверяющих.
        if ($p.CommandLine -match '\s-(Command|command|c)\s') { continue }
        if ($p.ProcessId -eq $PID) { continue }
        if ($p.CommandLine.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $out += $p }
    }
    return @($out)
}

# ---- монитор состояния (infra-graph -Daemon) ----
function Test-MonitorAlive {
    $procs = @(Get-ProcsByNeedle $MonNeedle | Where-Object { $_.ProcessId -ne $PID })
    $age = $null
    if (Test-Path -LiteralPath $MonNodesFile) {
        try { $age = [int]((Get-Date) - (Get-Item -LiteralPath $MonNodesFile).LastWriteTime).TotalSeconds } catch { }
    }
    $ageTxt = if ($null -ne $age) { "nodes.json обновлён ${age}s назад" } else { 'nodes.json нет' }
    # жив = идёт процесс ИЛИ файл свежий.
    # 0.2.1: без процесса допуск на «только что стартовал» = -MonitorGraceSec (90 с),
    # а не -MonitorStaleSec (300 с): раньше после падения монитора система молчала 5 минут,
    # потому что оставшийся свежий nodes.json маскировал отсутствие процесса.
    $fresh = $null -ne $age -and ($MonitorGraceSec -le 0 -or $age -lt $MonitorGraceSec)
    $ok = ($procs.Count -gt 0) -or $fresh
    return [pscustomobject]@{
        alive   = $ok
        pids    = @($procs | ForEach-Object { $_.ProcessId })
        ageSec  = $age
        reason  = "процесс(ов) infra-graph: $($procs.Count); $ageTxt"
    }
}

function Resolve-MonitorEntry {
    if (Test-Path -LiteralPath $MonShim) { return $MonShim }
    $latestFile = Join-Path $MonRegistryRoot 'latest.txt'
    if (Test-Path -LiteralPath $latestFile) {
        $ver = (Get-Content -LiteralPath $latestFile -Raw).Trim()
        foreach ($cand in @((Join-Path $MonRegistryRoot "$ver\infra-graph.ps1"), (Join-Path $MonRegistryRoot "$ver\infra-graph.cmd"))) {
            if (Test-Path -LiteralPath $cand) { return $cand }
        }
    }
    return $null
}

function Start-Monitor {
    $entry = Resolve-MonitorEntry
    if (-not $entry) { Write-Log 'WARN' "не найден запуск монитора (шим $MonShim и реестр $MonRegistryRoot) — пропуск подъёма"; return $false }
    try {
        if ($entry.EndsWith('.ps1')) {
            Start-Process pwsh -WindowStyle Hidden -ArgumentList '-NoProfile', '-File', $entry, '-Daemon' | Out-Null
        } else {
            Start-Process cmd.exe -WindowStyle Hidden -ArgumentList '/c', $entry, '-Daemon' | Out-Null
        }
        Write-Log 'INFO' "монитор состояния поднят (точка входа: $entry -Daemon)"
        return $true
    } catch {
        Write-Log 'ERROR' "не удалось поднять монитор: $($_.Exception.Message)"
        return $false
    }
}

# завершение монитора при закрытии opencode — только если его запустил хранитель
function Stop-MonitorIfStartedByUs {
    param([string]$FlagFile)
    if (-not (Test-Path -LiteralPath $FlagFile)) { return $false }
    $procs = @(Get-ProcsByNeedle $MonNeedle | Where-Object { $_.ProcessId -ne $PID })
    if ($procs.Count -eq 0) { Remove-Item -LiteralPath $FlagFile -Force -ErrorAction SilentlyContinue; return $false }
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-Log 'INFO' "opencode закрыт → монитор (pid=$($p.ProcessId), запущен хранителем) завершён: без сессии считать очки незачем."
        } catch { Write-Log 'WARN' "не удалось завершить монитор pid=$($p.ProcessId): $($_.Exception.Message)" }
    }
    Remove-Item -LiteralPath $FlagFile -Force -ErrorAction SilentlyContinue
    return $true
}

function Save-Atomic {
    param([string]$Path, [string]$Content)
    $tmp = "$Path.tmp"
    Set-Content -LiteralPath $tmp -Value $Content -Encoding utf8BOM
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ---- зеркало nodes.json + сводка (низкая нагрузка: раз в -MirrorSec) ----
function Write-Mirror {
    param($MonitorInfo, $WdInfo, [bool]$OcAlive)
    if (-not (Test-Path -LiteralPath $MonNodesFile)) { return }
    $nodes = $null
    try { $nodes = Get-Content -LiteralPath $MonNodesFile -Raw | ConvertFrom-Json } catch { return }
    # 1) зеркало состояния (атомарно, чтобы читатель никогда не увидел полузапись)
    try { Save-Atomic -Path (Join-Path $StateDir 'nodes.mirror.json') -Content (Get-Content -LiteralPath $MonNodesFile -Raw) } catch { }
    # 2) компактная сводка для плагина статуса и для оркестратора
    $summary = [ordered]@{}
    if ($nodes.nodes) {
        foreach ($p in $nodes.nodes.PSObject.Properties) {
            $n = $p.Value
            $summary[$p.Name] = [ordered]@{
                state = [string]$n.state; class = [string]$n.class
                val   = $n.val; owner = [string]$n.owner; intent = [string]$n.intent
            }
        }
    }
    $cands = @()
    if ($nodes.candidates) { $cands = @($nodes.candidates | ForEach-Object { [ordered]@{ id = [string]$_.id; class = [string]$_.class; val = $_.val; state = [string]$_.state; owner = [string]$_.owner } }) }
    $body = [ordered]@{
        guardianStartedAt = $Script:StartedAt
        lastMirrorAt      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        opencodeDetected  = $OcAlive
        monitor           = [ordered]@{ alive = $MonitorInfo.alive; pids = $MonitorInfo.pids; nodesAgeSec = $MonitorInfo.ageSec; source = $MonNodesFile }
        watchdog          = [ordered]@{ alive = $WdInfo.alive; pid = $WdInfo.pid; reason = $WdInfo.reason }
        policy            = [ordered]@{
            unload         = 'owner-decides'      # решение о завершении — за владельцем узла
            coreProtected  = @('oc','watchdog','guardian','monitor')
            guardianDoes   = 'надзор за демоном и монитором + зеркало; НЕ выгружает по очкам'
            monitorStopWith= 'opencode-закрыт (если монитор запущен хранителем)'
        }
        nodes             = $summary
        unloadCandidates  = $cands
    }
    try { Save-Atomic -Path (Join-Path $StateDir 'current.json') -Content ($body | ConvertTo-Json -Depth 6) } catch { }
    if ($cands.Count -gt 0) {
        Write-Log 'INFO' "зеркало: кандидаты на выгрузку (ждут решения владельца, ничего не завершаю): $(($cands | ForEach-Object { "$($_.id)=$($_.val)% [$($_.state)]" }) -join ', ')"
    }
}

# ---- защита от дублей хранителя ----
$Script:StartedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$startedAt = Get-Date
Write-Log 'INFO' "ХРАНИТЕЛЬ СТАРТУЕТ (pid=$PID, версия 0.2.2, интервал=${IntervalSec}s, троттлинг=${StartThrottleSec}s, opencode='$ProcessName', демон: $WatchdogRuntimeDir, монитор: $MonitorDir)"
$prior = $null
if (Test-Path -LiteralPath $GuardianPidFile) {
    try { $prior = [int]((Get-Content -LiteralPath $GuardianPidFile -Raw).Trim()) } catch { $prior = $null }
}
if ($prior -and $prior -ne $PID -and (Test-ProcAlive -Id $prior -Needle 'mcp-watchdog-guardian')) {
    Write-Log 'INFO' "Завершение: уже работает хранитель (pid=$prior) — второй экземпляр не нужен."
    exit 0
}
Set-Content -LiteralPath $GuardianPidFile -Value $PID -Encoding ascii

$MonStartedByUsFlag = Join-Path $StateDir 'monitor.started-by-guardian.flag'
$lastStart = [DateTime]::MinValue
$lastState  = ''
$lastMirror = [DateTime]::MinValue

while ($true) {
    $oc = Get-OpencodeAlive $ProcessName
    $wd = Test-WatchdogAlive
    $mon = Test-MonitorAlive
    if ($oc) {
        if (-not $wd.alive) {
            $need = (((Get-Date) - $lastStart).TotalSeconds -ge $StartThrottleSec)
            if ($need) {
                Write-Log 'WARN' "opencode работает, но демон-страж мёртв ($($wd.reason)) → автоподъём"
                $script:lastStart = Get-Date
                if (Start-Watchdog) { $lastState = 'watchdog-started' } else { $lastState = 'watchdog-fail' }
            } else {
                if ($lastState -ne 'wd-wait') {
                    $left = [int]($StartThrottleSec - ((Get-Date) - $lastStart).TotalSeconds)
                    Write-Log 'INFO' "автоподъём демона отложен по троттлингу (осталось ${left}s): $($wd.reason)"
                }
                $lastState = 'wd-wait'
            }
        }
        # --- монитор состояния ---
        if (-not $mon.alive) {
            $needM = (((Get-Date) - $lastStart).TotalSeconds -ge $StartThrottleSec)
            if ($needM) {
                Write-Log 'WARN' "opencode работает, но монитор не работает ($($mon.reason)) → автоподъём"
                $script:lastStart = Get-Date
                if (Start-Monitor) { $lastState = 'monitor-started'; Set-Content -LiteralPath $MonStartedByUsFlag -Value $PID -Encoding ascii } else { $lastState = 'monitor-fail' }
            } else {
                if ($lastState -ne 'mon-wait') {
                    $left = [int]($StartThrottleSec - ((Get-Date) - $lastStart).TotalSeconds)
                    Write-Log 'INFO' "автоподъём монитора отложен по троттлингу (осталось ${left}s): $($mon.reason)"
                }
                $lastState = 'mon-wait'
            }
        } else {
            if ($lastState -ne 'ok') {
                Write-Log 'INFO' "opencode работает; демон: $($wd.reason); монитор: $($mon.reason)"
            }
            $lastState = 'ok'
        }
        # --- зеркало nodes.json (низкая нагрузка) ---
        if ($MirrorSec -le 0 -or ((Get-Date) - $lastMirror).TotalSeconds -ge $MirrorSec) {
            $lastMirror = Get-Date
            try { Write-Mirror -MonitorInfo $mon -WdInfo $wd -OcAlive $true } catch { Write-Log 'WARN' "зеркало не записано: $($_.Exception.Message)" }
        }
    } else {
        if ($lastState -ne 'idle') { Write-Log 'INFO' "opencode не запущен → демон-страж и монитор не нужны, жду появления процесса '$ProcessName'" }
        $lastState = 'idle'
        $null = Stop-MonitorIfStartedByUs -FlagFile $MonStartedByUsFlag
    }

    if ($Once) { break }

    if ($WaitMaxMin -gt 0) {
        if (((Get-Date) - $startedAt).TotalMinutes -ge $WaitMaxMin) {
            Write-Log 'INFO' "Завершение: превышено ожидание opencode ${WaitMaxMin} мин."
            break
        }
    }

    Start-Sleep -Seconds $IntervalSec
}

Write-Log 'INFO' "ХРАНИТЕЛЬ ЗАВЕРШЕН (pid=$PID)"
exit 0

