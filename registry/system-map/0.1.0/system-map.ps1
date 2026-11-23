#Requires -Version 7
<#
.SYNOPSIS
  system-map — живая карта системы агентов, демонов, провайдеров и железа.

.DESCRIPTION
  Две роли:
    1) сборщик (по умолчанию): collector.py → JSON снимок в stdout и в state\snapshot.json;
    2) -Serve: локальный веб-сервер (127.0.0.1:<Port>) с графом и метриками железа.

  Источники только читаются: mcp-watchdog\state\current.json, monitor\state\nodes.json,
  guardian state, run-watch state, opencode.db (mode=ro), env/конфиги провайдеров,
  psutil и счётчики GPU. Ничего не меняется вне system-map\state\.

  Пути переносимые: корень инструментов — INVR_TOOLS_ROOT, иначе вычисляется
  от расположения версии в реестре. Машинных путей в коде нет.

.PARAMETER Serve
  Запустить веб-сервер вместо одноразового сбора.

.PARAMETER Port
  Порт локального сервера (по умолчанию 8765).

.PARAMETER Json
  Полный JSON снимка в stdout.

.PARAMETER NoState
  Не писать state\snapshot.json.

.PARAMETER StateDir
  Переопределить каталог состояния.

.PARAMETER Db
  Переопределить путь к opencode.db.

.EXAMPLE
  pwsh -NoProfile -File C:\Scripts\tools\system-map.ps1 -Json

.EXAMPLE
  pwsh -NoProfile -File C:\Scripts\tools\system-map.ps1 -Serve -Port 8765
#>
param(
    [switch]$Serve,
    [switch]$DetachServe,
    [int]$Port = 8765,
    [switch]$Json,
    [switch]$NoState,
    [string]$StateDir = '',
    [string]$Db = '',
    [string]$PythonExe = ''
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$ErrorActionPreference = 'Continue'

$regRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$toolsRoot = Split-Path $regRoot -Parent
if (-not $env:INVR_TOOLS_ROOT) { $env:INVR_TOOLS_ROOT = $toolsRoot }
if (-not $StateDir) {
    $StateDir = Join-Path $toolsRoot 'system-map\state'
}
$py = $PythonExe
if (-not $py) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { $py = $cmd.Source }
}
if (-not $py) { Write-Error 'INVR system-map: не найден python (нужен 3.9+)'; exit 1 }

if ($DetachServe) {
    # Долгоживущий сервис: запуск через run-watch -Detach (потомков не чистим).
    $runner = Join-Path $toolsRoot 'run-watch.ps1'
    $self = Join-Path $toolsRoot 'system-map.ps1'
    $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not (Test-Path -LiteralPath $runner) -or -not $pwshExe) { Write-Error 'INVR system-map: нет run-watch.ps1 или pwsh'; exit 1 }
    & $runner -Target $pwshExe -Arguments @('-NoProfile', '-File', $self, '-Serve', '-Port', "$Port") -Marker "system-map-server-$Port" -Name "system-map-$Port" -Detach
    exit $LASTEXITCODE
}

if ($Serve) {
    # node.exe ищем явно: шим node.ps1 на этой машине битый.
    $node = $null
    if ($env:INVR_NODE_EXE -and (Test-Path -LiteralPath $env:INVR_NODE_EXE)) { $node = $env:INVR_NODE_EXE }
    if (-not $node) {
        $candidates = @(
            (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
        )
        foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { $node = $c; break } }
    }
    if (-not $node) {
        $all = Get-Command node.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -like '*.exe' }
        if ($all) { $node = $all[0].Source }
    }
    if (-not $node) { Write-Error 'INVR system-map: не найден node.exe (нужен 18+)'; exit 1 }

    $server = Join-Path $PSScriptRoot 'server.mjs'
    Write-Host "INVR system-map: http://127.0.0.1:$Port"
    & $node $server --port "$Port" --tools-root "$toolsRoot" --python "$py"
    exit $LASTEXITCODE
}

$collector = Join-Path $PSScriptRoot 'collector.py'
if (-not (Test-Path -LiteralPath $collector)) { Write-Error "INVR system-map: нет $collector"; exit 1 }
$argsPy = @($collector, '--tools-root', $toolsRoot, '--state-dir', $StateDir)
if ($Json)    { $argsPy += '--json' }
if ($NoState) { $argsPy += '--no-state' }
if ($Db)      { $argsPy += @('--db', $Db) }
& $py @argsPy
exit $LASTEXITCODE
