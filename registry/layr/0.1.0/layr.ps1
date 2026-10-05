#Requires -Version 7
<#
.SYNOPSIS
  Обёртка layr для реестра INVR-Tools: вызывает node-клиент layr из каталога проекта.

.DESCRIPTION
  Каталог проекта ищется переносимо: LAYR_HOME → каталог layr рядом (вверх по
  дереву до 6 уровней) → C:\Scripts\layr. Путь к node тоже не зашит намертво:
  LAYR_NODE → %ProgramFiles%\nodejs\node.exe.

.ENVIRONMENT
  LAYR_HOME   каталог проекта layr (с собранным dist\cli.js)
  LAYR_NODE   путь к node.exe (на этой машине node в PATH — битый шим)
#>

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Resolve-LayrHome {
    if ($env:LAYR_HOME -and (Test-Path -LiteralPath (Join-Path $env:LAYR_HOME 'dist\cli.js'))) {
        return $env:LAYR_HOME
    }
    $dir = $PSScriptRoot
    for ($i = 0; $i -lt 6 -and $dir; $i++) {
        $candidate = Join-Path $dir 'layr'
        if (Test-Path -LiteralPath (Join-Path $candidate 'dist\cli.js')) { return $candidate }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $fallback = 'C:\Scripts\layr'
    if (Test-Path -LiteralPath (Join-Path $fallback 'dist\cli.js')) { return $fallback }
    throw 'layr: каталог проекта не найден (нужен dist\cli.js). Задайте LAYR_HOME или выполните npm run build.'
}

$layrHome = Resolve-LayrHome
$cli = Join-Path $layrHome 'dist\cli.js'

$nodeExe = $env:LAYR_NODE
if (-not $nodeExe -or -not (Test-Path -LiteralPath $nodeExe)) {
    $nodeExe = Join-Path $env:ProgramFiles 'nodejs\node.exe'
}
if (-not (Test-Path -LiteralPath $nodeExe)) {
    throw 'layr: не найден node.exe. Задайте LAYR_NODE полным путём.'
}

& $nodeExe $cli @args
exit $LASTEXITCODE