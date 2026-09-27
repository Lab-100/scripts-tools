#Requires -Version 7

<#
.SYNOPSIS
  Хранитель демона-стража mcp-watchdog: автозапуск вместе с системой и подъём
  демона при каждом появлении/перезапуске opencode.

.DESCRIPTION
  Зачем он нужен:
    - демон mcp-watchdog по условию старта требует живой процесс opencode и сам
      завершается, когда opencode закрыт. Поэтому демон нельзя просто «запустить
      с системой»: без открытого opencode он штатно выйдет.
    - хранитель стартует при входе пользователя в Windows (HKCU Run), живёт всю
      сессию и каждые -IntervalSec секунд смотрит:
        1) есть ли процесс opencode;
        2) если есть — жив ли демон (pid-файл + процесс + cmdline + свежесть
           state\current.json).
      Если демон мёртв (или подвис) — хранитель поднимает его скрыто
      (Start-Process pwsh -WindowStyle Hidden), с троттлингом -StartThrottleSec.
    - открыт ли opencode или нет, демон не дублируется: проверка по pid-файлу и
      защита от дублей есть и у самого демона.

  Логика состояний (демон): opencode нет → демон не нужен; opencode есть и демон
  мёртв → автоподъём; opencode есть и демон жив → ничего не делаем.

.PARAMETER IntervalSec
  Период опроса состояния (по умолчанию 20 с).

.PARAMETER ProcessName
  Имя процесса opencode (по умолчанию OpenCode).

.PARAMETER StartThrottleSec
  Минимальный интервал между попытками подъёма демона (защита от частых
  перезапусков, по умолчанию 60 с).

.PARAMETER StaleSec
  Сколько секунд может не обновляться state\current.json демона, прежде чем
  демон будет признан подвисшим (по умолчанию 120 с; 0 — не проверять).

.PARAMETER WaitMaxMin
  Максимум минут ожидания opencode; 0 (по умолчанию) — ждать бесконечно, пока
  жив сам хранитель.

.PARAMETER Once
  Одна итерация опроса (проверка/тест), затем выход.

.PARAMETER RuntimeDir
  Каталог состояния хранителя (по умолчанию каталог скрипта).

.PARAMETER WatchdogRuntimeDir
  Каталог состояния демона mcp-watchdog (по умолчанию C:\Scripts\tools\mcp-watchdog).

.EXAMPLE
  pwsh -File mcp-watchdog-guardian.ps1 -Once
  Разовая проверка: есть ли opencode и жив ли демон.

.EXAMPLE
  pwsh -File mcp-watchdog-guardian.ps1
  Демон-хранитель: работает в фоне, поднимает демон при появлении opencode.
#>

param(
    [int]$IntervalSec = 20,
    [string]$ProcessName = 'OpenCode',
    [int]$StartThrottleSec = 60,
    [int]$StaleSec = 120,
    [int]$WaitMaxMin = 0,
    [switch]$Once,
    [string]$RuntimeDir = '',
    [string]$WatchdogRuntimeDir = 'C:\Scripts\tools\mcp-watchdog',
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$BaseDir  = if ($RuntimeDir) { $RuntimeDir } else { $PSScriptRoot }
$StateDir = Join-Path $BaseDir 'state'
if (-not $LogFile) { $LogFile = Join-Path 'C:\Scripts\Logs' 'mcp-watchdog-guardian.log' }
$LogDir = Split-Path $LogFile -Parent
foreach ($d in @($StateDir, $LogDir)) { if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

$GuardianPidFile = Join-Path $StateDir 'guardian.pid'
$WdStateDir      = Join-Path $WatchdogRuntimeDir 'state'
$WdPidFile       = Join-Path $WdStateDir 'watchdog.pid'
$WdCurFile       = Join-Path $WdStateDir 'current.json'
$WdShim          = 'C:\Scripts\tools\mcp-watchdog.ps1'
$WdRegistryRoot  = 'C:\Scripts\tools\registry\mcp-watchdog'

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

# ---- защита от дублей хранителя ----
$startedAt = Get-Date
Write-Log 'INFO' "ХРАНИТЕЛЬ СТАРТУЕТ (pid=$PID, интервал=${IntervalSec}s, троттлинг=${StartThrottleSec}s, opencode='$ProcessName', каталог демона: $WatchdogRuntimeDir)"
$prior = $null
if (Test-Path -LiteralPath $GuardianPidFile) {
    try { $prior = [int]((Get-Content -LiteralPath $GuardianPidFile -Raw).Trim()) } catch { $prior = $null }
}
if ($prior -and $prior -ne $PID -and (Test-ProcAlive -Id $prior -Needle 'mcp-watchdog-guardian')) {
    Write-Log 'INFO' "Завершение: уже работает хранитель (pid=$prior) — второй экземпляр не нужен."
    exit 0
}
Set-Content -LiteralPath $GuardianPidFile -Value $PID -Encoding ascii

$lastStart = [DateTime]::MinValue
$lastState  = ''

while ($true) {
    $oc = Get-OpencodeAlive $ProcessName
    if ($oc) {
        $wd = Test-WatchdogAlive
        if ($wd.alive) {
            if ($lastState -ne 'ok') { Write-Log 'INFO' "opencode работает, демон-страж на месте ($($wd.reason))" }
            $lastState = 'ok'
        } else {
            $need = (((Get-Date) - $lastStart).TotalSeconds -ge $StartThrottleSec)
            if ($need) {
                Write-Log 'WARN' "opencode работает, но демон-страж мёртв ($($wd.reason)) → автоподъём"
                $script:lastStart = Get-Date
                if (Start-Watchdog) { $lastState = 'started' } else { $lastState = 'fail' }
            } else {
                if ($lastState -ne 'wait') {
                    $left = [int]($StartThrottleSec - ((Get-Date) - $lastStart).TotalSeconds)
                    Write-Log 'INFO' "автоподъём отложен по троттлингу (осталось ${left}s): $($wd.reason)"
                }
                $lastState = 'wait'
            }
        }
    } else {
        if ($lastState -ne 'idle') { Write-Log 'INFO' "opencode не запущен → демон-страж не нужен, жду появления процесса '$ProcessName'" }
        $lastState = 'idle'
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
