<#
.SYNOPSIS
  Перезапуск opencode Desktop с автоподъёмом демона mcp-watchdog и проверкой MCP.

.DESCRIPTION
  Нужен, когда изменены конфиги opencode (opencode.json / plugin / mcp):
  Desktop не перечитывает конфигурацию на лету, MCP-серверы поднимаются
  только при старте приложения. Скрипт:
    1. находит главный процесс OpenCode (не crashpad/renderer) и завершает его;
    2. запускает приложение заново;
    3. поднимает mcp-watchdog, если демон мёртв;
    4. ждёт, пока в current.json все MCP-серверы станут ok (до -TimeoutSec).

  ВАЖНО: запускать из ОТДЕЛЬНОГО окна PowerShell или двойным кликом по
  opencode-restart.cmd. Текущая сессия opencode при этом оборвётся.

.EXAMPLE
  pwsh -NoProfile -File <корень реестра>\opencode-restart.ps1
  pwsh -NoProfile -File <корень реестра>\opencode-restart.ps1 -TimeoutSec 180
#>
#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$NoLaunch,
    [int]$TimeoutSec = 120,
    [switch]$Json
)
# --- UTF-8: кириллица в выводе pwsh 7 (OEMCP 866 ломает чтение) -----------
$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
} catch { }
# ------------------------------------------------------------------------

# Переносимые корни (машинные пути не зашиты): скрипт лежит в
# registry\<tool>\<version>, каталог инструментов — уровнем выше реестра.
$regRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$toolsRoot = Split-Path $regRoot -Parent
$watchdogRuntimeDir = Join-Path $toolsRoot 'mcp-watchdog'
$watchdogState = Join-Path $watchdogRuntimeDir 'state'
$watchdogPidFile = Join-Path $watchdogState 'watchdog.pid'
$watchdogShim = Join-Path $toolsRoot 'mcp-watchdog.ps1'
$currentJson = Join-Path $watchdogState 'current.json'

function Get-OpencodeMain {
    $procs = Get-CimInstance Win32_Process -Filter "Name='OpenCode.exe'" -ErrorAction SilentlyContinue
    $main = $procs | Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' -and $_.ExecutablePath } | Select-Object -First 1
    if (-not $main) { $main = $procs | Where-Object { $_.ExecutablePath } | Select-Object -First 1 }
    return $main
}

function Get-WatchdogAlive {
    if (-not (Test-Path $watchdogPidFile)) { return $false }
    $pidText = (Get-Content $watchdogPidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not $pidText) { return $false }
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$pidText" -ErrorAction SilentlyContinue
    return ($p -and $p.CommandLine -match 'mcp-watchdog')
}

function Get-McpStatus {
    if (-not (Test-Path $currentJson)) { return $null }
    try { return (Get-Content $currentJson -Raw | ConvertFrom-Json) } catch { return $null }
}

$log = [System.Collections.Generic.List[string]]::new()
function Add-Log { param([string]$m) $log.Add($m); if (-not $Json) { Write-Host $m } }

Add-Log "=== Перезапуск opencode ==="

# 1. найти и закрыть
$main = Get-OpencodeMain
$exe = if ($main) { $main.ExecutablePath } else {
    $cand = "$env:LOCALAPPDATA\Programs\@opencode-aidesktop\OpenCode.exe"
    if (Test-Path $cand) { $cand } else { $null }
}
if ($main) {
    Add-Log ("  закрываю opencode: pid {0}  {1}" -f $main.ProcessId, $exe)
    $children = Get-CimInstance Win32_Process -Filter "Name='OpenCode.exe'" | Where-Object { $_.ParentProcessId -eq $main.ProcessId -or ($_.CommandLine -match 'user-data-dir') }
    foreach ($c in @($children)) { Stop-Process -Id $c.ProcessId -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $main.ProcessId -Force -ErrorAction SilentlyContinue
    $t = 0
    while ($t -lt 20 -and (Get-Process -Id $main.ProcessId -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 500; $t++ }
    Add-Log ("  процесс завершён за {0:N1} с" -f ($t * 0.5))
} else {
    Add-Log "  opencode не запущен (закрывать нечего)"
}

# 2. запустить заново
if (-not $NoLaunch) {
    if (-not $exe) { Add-Log "  [ошибка] не найден OpenCode.exe — проверьте установку"; }
    else {
        Start-Process -FilePath $exe -ArgumentList '--updated' | Out-Null
        Add-Log "  запущен: $exe"
        $t = 0; $up = $false
        while ($t -lt 60) {
            Start-Sleep -Seconds 1; $t++
            if (Get-OpencodeMain) { $up = $true; break }
        }
        if ($up) { Add-Log ("  opencode поднялся за {0} с" -f $t) } else { Add-Log "  [внимание] процесс opencode не появился за 60 с" }
    }
}

# 3. демон mcp-watchdog
Start-Sleep -Seconds 3
if (Get-WatchdogAlive) { Add-Log "  mcp-watchdog: уже живой" }
elseif (Test-Path $watchdogShim) {
    Start-Process pwsh -ArgumentList '-NoProfile', '-File', $watchdogShim, '-RuntimeDir', $watchdogRuntimeDir -WindowStyle Hidden | Out-Null
    Add-Log "  mcp-watchdog: запущен"
} else { Add-Log "  [внимание] нет шима $watchdogShim" }

# 4. дождаться MCP
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$last = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $cur = Get-McpStatus
    if (-not $cur) { continue }
    $line = ($cur.checks.PSObject.Properties | ForEach-Object {
            $st = $_.Value.status
            $mark = if ($st -eq 'ok') { '+' } elseif ($st -eq 'fail') { '-' } else { '?' }
            "$mark$($_.Name)"
        }) -join ' '
    if ($line -ne $last) { Add-Log "  статусы: $line"; $last = $line }
    $bad = @($cur.checks.PSObject.Properties | Where-Object { $_.Value.status -eq 'fail' })
    if ($bad.Count -eq 0) { Add-Log "  все сервисы ok"; break }
}
if ($last) { Add-Log "=== готово ===" }

if ($Json) { $log | ConvertTo-Json }
