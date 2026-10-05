#Requires -Version 7
<#
.SYNOPSIS
  run-watch — запуск процессов оркестратора с гарантированной очисткой потомков.

.DESCRIPTION
  Проблема: процессы, запущенные оркестратором через Start-Process (Docker Desktop,
  node, python, отдельные pwsh и т.п.), при завершении задачи часто остаются в
  памяти как зомби/сироты и плодят дубли (типовой случай — 9 инстансов
  Docker Desktop при принудительном старте).

  run-watch:
    1) запускает целевую команду (оборачивает .ps1 → pwsh, .cmd/.bat → cmd.exe);
    2) пишет запись в реестре запусков <run-watch>\state\run-watch.json —
       её читает демон-страж mcp-watchdog 0.4.4+ как страховку на случай,
       когда сам run-watch оборван (таймаут сессии, kill) или оркестратор
       запустил процесс напрямую;
    3) ждёт завершения процесса (или таймаута -WaitSec);
    4) после завершения/ошибки очищает САМ процесс (если он ещё жив, например по
       пределу ожидания -WaitSec) и ВСЕХ потомков (рекурсивное дерево от
       основного pid) и любые процессы по -Marker: мягко (Stop-Process),
       при неудаче — насильно (taskkill /T /F);
    5) обновляет запись и завершается сам (в памяти ничего не остаётся).

  Изменения:
    - 0.1.1: корневой процесс тоже завершается после таймаута -WaitSec
      (в 0.1.0 он оставался живым, порт не освобождался). Добавлен tool.json.

  Режимы:
    - по умолчанию foreground: после завершения/ошибки потомки принудительно
      очищаются, запись помечается done;
    - -Detach (background): процесс сознательно фоновый — потомки НЕ чистятся,
      запись помечается background (не трогается стражем «по демонтажу», но
      всё же контролируется по маркеру при зависании).

.PARAMETER Target
  Путь к исполняемому файлу/скрипту (обязательно).
.PARAMETER Arguments
  Аргументы (массив строк).
.PARAMETER Marker
  Уникальная подстрока командной строки потомков (обязательно) — используется
  как второй фильтр очистки и как ключ для стража.
.PARAMETER Name
  Короткое имя задачи для реестра запусков (по умолчанию — имя файла Target).
.PARAMETER WaitSec
  Сколько ожидать завершения процесса, сек (0 = до конца).
.PARAMETER Visible
  Запускать целевую команду с видимым окном (по умолчанию скрыто).
.PARAMETER Detach
  Фоновый режим: запустить и сразу вернуться; потомков не чистить.
.PARAMETER RuntimeDir
  Переопределить каталог реестра запусков (по умолчанию <tools>\run-watch).

.EXAMPLE
  pwsh -NoProfile -File run-watch.ps1 -Target 'C:\Program Files\Docker\Docker\Docker Desktop.exe' -Marker 'DockerDesktop' -Name docker-desktop

.EXAMPLE
  pwsh -NoProfile -File run-watch.ps1 -Target 'C:\Scripts\ollama-server.cmd' -Marker 'ollama' -Detach
#>

param(
    [Parameter(Mandatory)] [string]$Target,
    [string[]]$Arguments = @(),
    [Parameter(Mandatory)] [string]$Marker,
    [string]$Name = '',
    [int]$WaitSec = 0,
    [switch]$Visible,
    [switch]$Detach,
    [string]$RuntimeDir = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ---- переносимые корни (машинные пути не зашиты) ----
$regRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$toolsRoot = Split-Path $regRoot -Parent
if (-not $RuntimeDir) {
    $RuntimeDir = if ($env.INVR_TOOLS_ROOT -and (Test-Path -LiteralPath $env.INVR_TOOLS_ROOT)) {
        Join-Path $env.INVR_TOOLS_ROOT 'run-watch'
    } else {
        Join-Path $toolsRoot 'run-watch'
    }
}
$StateDir   = Join-Path $RuntimeDir 'state'
$RunFile    = Join-Path $StateDir 'run-watch.json'
$logDirEnv  = if ($env:INVR_LOG_DIR) { $env:INVR_LOG_DIR } else { [Environment]::GetEnvironmentVariable('INVR_LOG_DIR', 'User') }
$LogDir     = if ($logDirEnv) { $logDirEnv } else { Join-Path $toolsRoot 'Logs' }
$LogFile    = Join-Path $LogDir 'run-watch.log'
foreach ($d in @($StateDir, $LogDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
if (-not $Name) { $Name = Split-Path $Target -Leaf }

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

function Save-Record {
    param([hashtable]$Record)
    $Record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $RunFile -Encoding utf8BOM
}

# ---- 1) проверка цели ----
if (-not (Test-Path -LiteralPath $Target)) {
    Write-Log 'ERROR' "цель не найдена: $Target → запись failed, выход 1"
    $rec = [ordered]@{
        task = $Name; marker = $Marker; pid = $null; ppid = $PID
        mode = $(if ($Detach) {'background'} else {'foreground'})
        status = 'failed'; startedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        finishedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); exitCode = 1
        killed = @(); target = $Target; reason = "Target не найден"
    }
    Save-Record $rec
    exit 1
}

# ---- 2) обёртка интерпретатора ----
$launch = $Target
$args2  = @($Arguments)
$ext = [IO.Path]::GetExtension($Target).ToLowerInvariant()
if ($ext -eq '.ps1')    { $launch = (Get-Command pwsh).Source; $args2 = @('-NoProfile','-File',$Target) + $Arguments }
elseif ($ext -eq '.cmd' -or $ext -eq '.bat') { $launch = $env:ComSpec; $args2 = @('/c', $Target) + $Arguments }

$style = if ($Visible) { 'Normal' } else { 'Hidden' }
$proc = $null
try {
    $proc = Start-Process -FilePath $launch -ArgumentList $args2 -WorkingDirectory $PWD -PassThru -WindowStyle $style
} catch {
    Write-Log 'ERROR' "запуск не удался: $($_.Exception.Message) → запись failed, выход 1"
    $rec = [ordered]@{
        task = $Name; marker = $Marker; pid = $null; ppid = $PID
        mode = $(if ($Detach) {'background'} else {'foreground'})
        status = 'failed'; startedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        finishedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); exitCode = 1
        killed = @(); target = $Target; reason = $_.Exception.Message
    }
    Save-Record $rec
    exit 1
}

$started = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$rec = [ordered]@{
    task = $Name; marker = $Marker; pid = $proc.Id; ppid = $PID
    mode = $(if ($Detach) {'background'} else {'foreground'})
    status = 'running'; startedAt = $started; finishedAt = $null
    exitCode = $null; killed = @(); target = $Target; cmd = $launch
}
Save-Record $rec
Write-Log 'INFO' "запущено: $Name (pid=$($proc.Id), маркер='$Marker', режим=$($rec.mode))"

# ---- 3) фоновый режим: вернуться и не чистить ----
if ($Detach) {
    Write-Log 'INFO' "фоновый запуск $Name завершён (pid=$($proc.Id)) — за процессом следит страж/владелец."
    exit 0
}

# ---- 4) ожидание завершения (или таймаута) ----
$deadline = if ($WaitSec -gt 0) { (Get-Date).AddSeconds($WaitSec) } else { $null }
$exitCode = $null
while ((Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
    if ($deadline -and (Get-Date) -gt $deadline) { break }
    Start-Sleep -Milliseconds 800
}
$proc.Refresh()
if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
    Write-Log 'INFO' "превышен предел ожидания (${WaitSec}s) — процесс $Name ещё жив, приступаю к очистке процесса и потомков."
    $exitCode = $null
} else {
    $exitCode = $proc.ExitCode
    Write-Log 'INFO' "процесс $Name завершился (код выхода: $exitCode)."
}

# ---- 5) очистка потомков: дерево от pid + по маркеру ----
function Get-Descendants {
    param([int]$RootPid)
    try { $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) } catch { return @() }
    $map = @{}
    foreach ($x in $all) { if ($x.ProcessId) { $map[[int]$x.ProcessId] = [int]$x.ParentProcessId } }
    $out  = [System.Collections.Generic.List[int]]::new()
    $stck = [System.Collections.Generic.Stack[int]]::new()
    $stck.Push($RootPid)
    while ($stck.Count -gt 0) {
        $cur = $stck.Pop()
        foreach ($kv in $map.GetEnumerator()) {
            if ($kv.Value -eq $cur) { $out.Add($kv.Key); $stck.Push($kv.Key) }
        }
    }
    return @($out)
}

$ids = @(Get-Descendants $proc.Id)
if ($Marker) {
    $ids += @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and
        $_.ProcessId -ne $proc.Id -and
        $_.ProcessId -ne $PID -and
        $_.CommandLine.IndexOf($Marker, [StringComparison]::OrdinalIgnoreCase) -ge 0
    } | ForEach-Object { [int]$_.ProcessId })
}
# 0.1.1: корневой процесс тоже под очистку — иначе при таймауте -WaitSec он остаётся жив
if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) { $ids = @($proc.Id) + $ids }
$ids = @($ids | Sort-Object -Unique)

$killed = @()
foreach ($id in $ids) {
    if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { continue }
    Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    $killed += $id
}
Start-Sleep 3
# насильное завершение для упорных (taskkill /T /F по дереву)
foreach ($id in $ids) {
    if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { continue }
    & taskkill.exe /PID $id /T /F 2>&1 | Out-Null
    $killed += $id
}
$killed = @($killed | Sort-Object -Unique)

if ($killed.Count -gt 0) {
    Write-Log 'INFO' "очищено процессов (включая потомков): $($killed -join ', ')"
} else {
    Write-Log 'DEBUG' 'процессов на очистку не обнаружено.'
}

# ---- 6) фиксация результата ----
$rec.finishedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$rec.exitCode   = $exitCode
$rec.status     = 'done'
$rec.killed     = $killed
Save-Record $rec
Write-Log 'INFO' "run-watch завершён: $Name статус=done, очищено процессов=$($killed.Count)."
exit 0