#Requires -Version 7
<#
.SYNOPSIS
  delegation-lint — жёсткая проверка правила делегирования opencode.

.DESCRIPTION
  Обёртка над delegation_lint.py (Python, только стандартная библиотека):
    1) ставит UTF-8 для консоли и для python;
    2) передаёт пороги и аргументы, пробрасывает код возврата
       (0 — нарушений нет, 1 — есть нарушения, 2 — БД недоступна, 3 — сбой);
    3) не пишет состояние и не меняет чужие конфиги.

  Вход (только чтение): opencode.db (session/message/part, режим mode=ro),
  mcp-watchdog\state\current.json (признак живого ollama).

.PARAMETER Sessions
  Сколько последних сессий анализировать (по умолчанию 50).

.PARAMETER BuildShareMax
  Верхняя граница доли вызовов build (по умолчанию 0.6).

.PARAMETER ShareTaskMin
  Нижняя граница доли сессий с вызовом task (по умолчанию 0.1).

.PARAMETER CyclesNoTaskMax
  Верхняя граница доли циклов с ≥CycleMinCalls вызовов без task (по умолчанию 0.25).

.PARAMETER LeadChildrenMin
  Минимальное среднее число субагентов на сессию invr-lead (по умолчанию 1.0).

.PARAMETER PaidShareMax
  Верхняя граница доли платных каналов при живом ollama (по умолчанию 0.3).

.PARAMETER CycleMinCalls
  Сколько вызовов считают цикл длинным (по умолчанию 20).

.PARAMETER Json
  Вывести полный JSON вместо таблицы.

.PARAMETER OutFile
  Записать тот же вывод в файл в кодировке UTF-8.

.PARAMETER DbPath
  Переопределить путь к opencode.db.

.PARAMETER WatchdogPath
  Переопределить путь к current.json демона-стража.

.EXAMPLE
  pwsh -NoProfile -File C:\Scripts\tools\registry\delegation-lint\0.1.0\delegation-lint.ps1

.EXAMPLE
  pwsh -NoProfile -File C:\Scripts\tools\registry\delegation-lint\0.1.0\delegation-lint.ps1 -Sessions 50 -Json
#>
param(
    [int]$Sessions = 50,
    [double]$BuildShareMax = 0.6,
    [double]$ShareTaskMin = 0.1,
    [double]$CyclesNoTaskMax = 0.25,
    [double]$LeadChildrenMin = 1.0,
    [double]$PaidShareMax = 0.3,
    [int]$CycleMinCalls = 20,
    [switch]$Json,
    [string]$OutFile = '',
    [string]$DbPath = '',
    [string]$WatchdogPath = ''
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

$ErrorActionPreference = 'Continue'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
function Fmt([double]$v) { $v.ToString('0.####', $inv) }

$entry = Join-Path $PSScriptRoot 'delegation_lint.py'
if (-not (Test-Path -LiteralPath $entry)) {
    Write-Error "INVR delegation-lint: нет $entry рядом с обёрткой"
    exit 3
}

$pyArgs = @(
    $entry,
    '--sessions', "$Sessions",
    '--build-share-max', (Fmt $BuildShareMax),
    '--share-task-min', (Fmt $ShareTaskMin),
    '--cycles-no-task-max', (Fmt $CyclesNoTaskMax),
    '--lead-children-min', (Fmt $LeadChildrenMin),
    '--paid-share-max', (Fmt $PaidShareMax),
    '--cycle-min-calls', "$CycleMinCalls"
)
if ($Json)         { $pyArgs += '--json' }
if ($OutFile)      { $pyArgs += @('--out', $OutFile) }
if ($DbPath)       { $pyArgs += @('--db', $DbPath) }
if ($WatchdogPath) { $pyArgs += @('--watchdog', $WatchdogPath) }

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-Error 'INVR delegation-lint: не найден python в PATH (нужен Python 3.9+)'
    exit 3
}

& $python.Source @pyArgs
exit $LASTEXITCODE
