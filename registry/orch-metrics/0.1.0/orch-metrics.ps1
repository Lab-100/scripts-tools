#Requires -Version 7
<#
.SYNOPSIS
  orch-metrics — метрики распределения работы оркестратора + рекомендации по порогам делегирования.

.DESCRIPTION
  Обёртка над orch_metrics.py (Python, только стандартная библиотека):
    1) ставит UTF-8 для консоли и для python — иначе русская таблица ломается
       о кодовую страницу машины (ACP 1251 / OEMCP 866);
    2) вычисляет каталог состояния переносимо (INVR_TOOLS_ROOT, иначе два
       уровня выше версии реестра) и передаёт его скрипту — машинные пути
       в коде инструмента не зашиты;
    3) пробрасывает аргументы и код возврата (0 — ок, 1 — сбой, 2 — БД недоступна).

  Вход (только чтение): opencode.db (session/message/part),
  mcp-watchdog\state\current.json, run-watch\state\run-watch.json.
  Выход: stdout (таблица либо -Json), orch-metrics\state\orch-metrics.json
  и кольцевой журнал orch-metrics\state\orch-metrics.log (200 строк).

.PARAMETER Sessions
  Сколько последних сессий анализировать (по умолчанию 50).

.PARAMETER Json
  Полный JSON в stdout вместо таблицы.

.PARAMETER NoState
  Не писать файлы состояния.

.PARAMETER Quiet
  Только список рекомендаций.

.PARAMETER StateDir
  Переопределить каталог состояния (по умолчанию <tools>\orch-metrics\state).

.PARAMETER DbPath
  Переопределить путь к opencode.db.

.EXAMPLE
  pwsh -NoProfile -File C:\Scripts\tools\orch-metrics.ps1

.EXAMPLE
  pwsh -NoProfile -File C:\Scripts\tools\orch-metrics.ps1 -Sessions 50 -Json
#>
param(
    [int]$Sessions = 50,
    [switch]$Json,
    [switch]$NoState,
    [switch]$Quiet,
    [string]$StateDir = '',
    [string]$DbPath = ''
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
# Русские подписи в stdout должны уйти в UTF-8 независимо от кодовой страницы машины.
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

$ErrorActionPreference = 'Continue'

$regRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$toolsRoot = Split-Path $regRoot -Parent
if (-not $StateDir) {
    $StateDir = if ($env:INVR_TOOLS_ROOT -and (Test-Path -LiteralPath $env:INVR_TOOLS_ROOT)) {
        Join-Path $env:INVR_TOOLS_ROOT 'orch-metrics\state'
    } else {
        Join-Path $toolsRoot 'orch-metrics\state'
    }
}

$entry = Join-Path $PSScriptRoot 'orch_metrics.py'
if (-not (Test-Path -LiteralPath $entry)) {
    Write-Error "INVR orch-metrics: нет $entry рядом с обёрткой"
    exit 1
}

$pyArgs = @($entry, '--sessions', "$Sessions", '--state-dir', $StateDir)
if ($Json)    { $pyArgs += '--json' }
if ($NoState) { $pyArgs += '--no-state' }
if ($Quiet)   { $pyArgs += '--quiet' }
if ($DbPath)  { $pyArgs += @('--db', $DbPath) }

$python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $python) {
    Write-Error 'INVR orch-metrics: не найден python в PATH (нужен Python 3.9+)'
    exit 1
}

& $python.Source @pyArgs
exit $LASTEXITCODE