<#
  install.ps1 — Установщик opencode-improvements (Windows).
  Раскладывает плагины (plugins/*.js) и инструменты (tools/*) из клона
  репозитория в целевую структуру opencode и перегенерирует cmd-шимы
  запуска под реальный путь установки.

  Запуск:  pwsh -NoProfile -File .\install.ps1 [-ToolsDir <путь>] [-PluginsDir <путь>] [-DryRun] [-CheckOnly] [-Force]

  Сценарии:
    -CheckOnly   только проверка среды и источников, ничего не пишет
    -DryRun      печатает, что будет сделано, без записи
    (по умолчанию) выполняет копирование и регенерацию шим
  #>
[CmdletBinding()]
param(
  [string]$ToolsDir   = 'C:\Scripts\tools',
  [string]$PluginsDir = 'C:\Scripts\.opencode\plugins',
  [switch]$DryRun,
  [switch]$CheckOnly,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$srcRoot  = $PSScriptRoot
$srcPlugs = Join-Path $srcRoot 'plugins'
$srcTools = Join-Path $srcRoot 'tools'

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Err($m)  { Write-Host "FAIL: $m" -ForegroundColor Red }

Write-Step "Начинаю установку opencode-improvements"
"  источник плагинов : $srcPlugs"
"  источник инструментов: $srcTools"
"  целевой каталог плагинов: $PluginsDir"
"  целевой каталог инструментов: $ToolsDir"

# ---------- проверка среды ----------
$checks = @()
$checks += [pscustomobject]@{ Name='pwsh 7+';            Ok = $PSVersionTable.PSVersion.Major -ge 7 }
$checks += [pscustomobject]@{ Name='источник plugins/';   Ok = (Test-Path -LiteralPath $srcPlugs) }
$checks += [pscustomobject]@{ Name='источник tools/';     Ok = (Test-Path -LiteralPath $srcTools) }
$checks += [pscustomobject]@{ Name='plugins opener *.js'; Ok = (Get-ChildItem -LiteralPath $srcPlugs -Filter *.js -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0 }

"`nПроверки среды:"
$fail = $false
foreach ($c in $checks) {
  $mark = if ($c.Ok) { 'ok ' } else { '!! ' }
  "  [$mark] $($c.Name)"
  if (-not $c.Ok) { $fail = $true }
}
if ($fail) { Write-Err "Окружение не удовлетворяет требованиям (см. выше)."; exit 1 }
if ($CheckOnly) { "`nCheckOnly: среда в порядке, целевые каталоги:"; "  $PluginsDir"; "  $ToolsDir"; exit 0 }

# список файлов для установки
$pluginFiles = Get-ChildItem -LiteralPath $srcPlugs -Filter *.js
"`nФайлы к установке: плагинов=$($pluginFiles.Count), tools=$((Get-ChildItem -LiteralPath $srcTools -File | Measure-Object).Count)"

# ---------- dry run ----------
if ($DryRun) {
  "`nDryRun: будет создано/обновлено:"
  foreach ($p in $pluginFiles) { "    $PluginsDir\$($p.Name)" }
  Get-ChildItem -LiteralPath $srcTools -File | ForEach-Object { "    $ToolsDir\$($_.Name)" }
  "    $ToolsDir\infra-graph.cmd   (регенерация под путь)"
  "    $ToolsDir\opencode-monitor.cmd (регенерация под путь)"
  "    $ToolsDir\opencode-status.cmd  (регенерация под путь)"
  exit 0
}

# ---------- создание целевых каталогов ----------
foreach ($d in @($ToolsDir, $PluginsDir)) {
  if (-not (Test-Path -LiteralPath $d)) {
    if ($Force) { New-Item -ItemType Directory -Path $d -Force | Out-Null; "создан каталог: $d" }
    else { Write-Err "Целевой каталог не существует: $d. Создайте его или укажите -Force."; exit 1 }
  }
}

# ---------- копирование плагинов ----------
Write-Step "Копирую плагины"
foreach ($p in $pluginFiles) {
  Copy-Item -LiteralPath $p.FullName -Destination (Join-Path $PluginsDir $p.Name) -Force
  "  плагин: $($p.Name)"
}

# ---------- копирование инструментов ----------
Write-Step "Копирую инструменты"
Get-ChildItem -LiteralPath $srcTools -File | Where-Object { $_.Extension -ne '.cmd' } | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $ToolsDir $_.Name) -Force
  "  инструмент: $($_.Name)"
}

# ---------- регенерация cmd-шим под реальный путь ----------
Write-Step "Генерирую cmd-шимы под путь: $ToolsDir"
# одинарные кавычки (cmd-кавычки для PowerShell внутри -Command)
$qt = "'"
$igCmd = @"
@echo off
rem Запуск карты инфраструктуры (двойной клик из Explorer) - консоль свёрнута.
rem -STA обязателен: WinForms-форма живёт в однопоточном апартменте (без него
rem pwsh работает в MTA и окно/трей разрушаются). НЕ использовать -WindowStyle
rem Hidden: он наследуется в саму форму (vis=False) и карта не показывается.
cd /d $ToolsDir
start "" /min pwsh -NoProfile -STA -Command "& { [Console]::Title='infra-graph'; & $qt$ToolsDir\infra-graph.ps1$qt }"
"@
[System.IO.File]::WriteAllText((Join-Path $ToolsDir 'infra-graph.cmd'), $igCmd, (New-Object System.Text.UTF8Encoding $false))

$monCmd = @"
@echo off
rem Запуск монитора оркестратора (двойной клик из Explorer) - консоль скрыта
cd /d $ToolsDir
start "" /min pwsh -NoProfile -WindowStyle Hidden -Command "& { [Console]::Title='opencode-monitor'; & $qt$ToolsDir\opencode-monitor.ps1$qt }"
"@
[System.IO.File]::WriteAllText((Join-Path $ToolsDir 'opencode-monitor.cmd'), $monCmd, (New-Object System.Text.UTF8Encoding $false))

$stCmd = @"
@echo off
rem Текстовой монитор инфраструктуры opencode (консоль, живое обновление)
rem Двойной клик из Explorer: консоль свёрнута, статус обновляется каждые 3 сек.
cd /d $ToolsDir
start "" /min pwsh -NoProfile -Command "& { [Console]::Title='opencode-status'; & $qt$ToolsDir\opencode-status.ps1$qt -Watch 3 }"
"@
[System.IO.File]::WriteAllText((Join-Path $ToolsDir 'opencode-status.cmd'), $stCmd, (New-Object System.Text.UTF8Encoding $false))

"`nРазработка завершена. Проверка:"
"  плагины -> $PluginsDir"
"  инструменты -> $ToolsDir"
""
"Перезапустите opencode, чтобы плагины (.opencode/plugins) подхватились."
"Запуск графиков:"
"  cmd /c start "" /min pwsh -NoProfile -STA -File $ToolsDir\infra-graph.ps1"
"  cmd /c start "" /min pwsh -NoProfile -File $ToolsDir\opencode-monitor.ps1"