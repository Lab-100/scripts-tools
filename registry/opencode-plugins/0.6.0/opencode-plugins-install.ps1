<#
  opencode-plugins-install.ps1 — установка плагинов opencode из реестра INVR.

  Копирует plugins\*.js в каталог плагинов opencode и генерирует переносимые
  cmd-шимы мониторов инфраструктуры (infra-graph, opencode-status, opencode-monitor).
  Сами инструменты в реестре не копируются: их плоские шимы создаёт
  resolve-tools.ps1 (действие shims).

  Запуск:  pwsh -NoProfile -File .\opencode-plugins-install.ps1 [-PluginsDir <путь>] [-ShimsDir <путь>] [-DryRun] [-CheckOnly] [-Force]

  Параметры:
    -PluginsDir  каталог плагинов opencode (по умолчанию <рабочее пространство>\.opencode\plugins,
                иначе %USERPROFILE%\.opencode\plugins)
    -ShimsDir    каталог для cmd-шимов (по умолчанию корень реестра: <tools>)
    -CheckOnly   только проверка среды, ничего не пишет
    -DryRun      печатает, что будет сделано
  #>
[CmdletBinding()]
param(
  [string]$PluginsDir = '',
  [string]$ShimsDir   = '',
  [switch]$DryRun,
  [switch]$CheckOnly,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Каталог плагинов opencode: .opencode рабочего пространства, иначе профиля
# пользователя (машинный путь не зашит).
if (-not $PluginsDir) {
  $regRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  $wsRoot  = Split-Path (Split-Path $regRoot -Parent) -Parent
  $PluginsDir = foreach ($c in @((Join-Path $wsRoot '.opencode\plugins'), (Join-Path $env:USERPROFILE '.opencode\plugins'))) {
    if (Test-Path -LiteralPath $c) { $c; break }
  }
  if (-not $PluginsDir) { $PluginsDir = Join-Path $wsRoot '.opencode\plugins' }
}

$srcPlugs = Join-Path $PSScriptRoot 'plugins'
if (-not $ShimsDir) {
    $ShimsDir = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
}

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Err($m)  { Write-Host "FAIL: $m" -ForegroundColor Red }

Write-Step "Установка opencode-plugins"
"  источник плагинов  : $srcPlugs"
"  целевой каталог    : $PluginsDir"
"  каталог cmd-шимов  : $ShimsDir"

$checks = @(
    [pscustomobject]@{ Name='pwsh 7+';            Ok = ($PSVersionTable.PSVersion.Major -ge 7) },
    [pscustomobject]@{ Name='источник plugins\';  Ok = (Test-Path -LiteralPath $srcPlugs) },
    [pscustomobject]@{ Name='плагины *.js';       Ok = ((Get-ChildItem -LiteralPath $srcPlugs -Filter *.js -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) }
)
"`nПроверки среды:"
$fail = $false
foreach ($c in $checks) {
    "  [$(if ($c.Ok) { 'ok ' } else { '!! ' })] $($c.Name)"
    if (-not $c.Ok) { $fail = $true }
}
if ($fail) { Write-Err 'Окружение не удовлетворяет требованиям (см. выше).'; exit 1 }
if ($CheckOnly) { "`nCheckOnly: среда в порядке"; exit 0 }

$pluginFiles = Get-ChildItem -LiteralPath $srcPlugs -Filter *.js
"`nПлагинов к установке: $($pluginFiles.Count)"

if ($DryRun) {
    "`nDryRun: будет создано/обновлено:"
    foreach ($p in $pluginFiles) { "    $PluginsDir\$($p.Name)" }
    "    $ShimsDir\infra-graph.cmd"
    "    $ShimsDir\opencode-monitor.cmd"
    "    $ShimsDir\opencode-status.cmd"
    "    $ShimsDir\opencode-restart.cmd"
    exit 0
}

foreach ($d in @($PluginsDir, $ShimsDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        if ($Force) { New-Item -ItemType Directory -Path $d -Force | Out-Null; "создан каталог: $d" }
        else { Write-Err "Каталог не существует: $d. Создайте его или укажите -Force."; exit 1 }
    }
}

Write-Step 'Копирую плагины'
foreach ($p in $pluginFiles) {
    Copy-Item -LiteralPath $p.FullName -Destination (Join-Path $PluginsDir $p.Name) -Force
    "  плагин: $($p.Name)"
}

Write-Step 'Генерирую cmd-шимы мониторов (переносимые, %~dp0)'
$igCmd = @'
@echo off
rem Карта инфраструктуры оркестратора (двойной клик из Explorer) - консоль свёрнута.
rem -STA обязателен: WinForms-форма живёт в STA-апартменте, без него окно/трей разрушаются.
set "TOOLS=%~dp0"
cd /d "%TOOLS%"
start "" /min pwsh -NoProfile -STA -Command "& { [Console]::Title='infra-graph'; & (Join-Path $env:TOOLS 'infra-graph.ps1') }"
'@
$monCmd = @'
@echo off
rem Оперативный монитор оркестратора (двойной клик из Explorer) - консоль скрыта.
set "TOOLS=%~dp0"
cd /d "%TOOLS%"
start "" /min pwsh -NoProfile -WindowStyle Hidden -Command "& { [Console]::Title='opencode-monitor'; & (Join-Path $env:TOOLS 'opencode-monitor.ps1') }"
'@
$stCmd = @'
@echo off
rem Текстовой монитор инфраструктуры opencode (консоль, живое обновление).
set "TOOLS=%~dp0"
cd /d "%TOOLS%"
start "" /min pwsh -NoProfile -Command "& { [Console]::Title='opencode-status'; & (Join-Path $env:TOOLS 'opencode-status.ps1') -Watch 3 }"
'@
$rsCmd = @'
@echo off
rem Перезапуск opencode (двойной клик из Explorer): поднимает демон-страж
rem и ждёт готовности MCP. Запускать из ОТДЕЛЬНОГО окна: текущая сессия
rem opencode при перезапуске обрывается.
set "TOOLS=%~dp0"
cd /d "%TOOLS%"
start "" pwsh -NoProfile -NoLogo -Command "& (Join-Path $env:TOOLS 'opencode-restart.ps1')"
'@
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $ShimsDir 'infra-graph.cmd'), $igCmd, $utf8)
[System.IO.File]::WriteAllText((Join-Path $ShimsDir 'opencode-monitor.cmd'), $monCmd, $utf8)
[System.IO.File]::WriteAllText((Join-Path $ShimsDir 'opencode-status.cmd'), $stCmd, $utf8)
if (Test-Path (Join-Path $ShimsDir 'opencode-restart.ps1')) {
    [System.IO.File]::WriteAllText((Join-Path $ShimsDir 'opencode-restart.cmd'), $rsCmd, $utf8)
    "  opencode-restart.cmd (перезапуск opencode)"
}
"  infra-graph.cmd, opencode-monitor.cmd, opencode-status.cmd"

"`nГотово. Перезапустите opencode, чтобы плагины подхватились."
