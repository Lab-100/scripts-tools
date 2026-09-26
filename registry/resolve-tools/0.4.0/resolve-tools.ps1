<#
.SYNOPSIS
  INVR-Tools локер: связывает инструменты реестра с проектами по манифесту
  project.json. Каждый инструмент = каталог версии в реестре; в проекте
  создаётся junction tools\<tool> -> registry\<tool>\<version>.

.DESCRIPTION
  Решает: без дублей инструментов между проектами, версионирование и
  эволюция инструментов, фиксация "форка" инструмента в манифесте проекта.

  Команды:
    init   - создать project.json (если нет) и пустые tools\.inrv\
    status - сверить манифест с реестром и фактическими линками
    link   - резолв диапазонов + создание/починка junction (идемпотентно)
    update - git pull реестра (опц.) + повторный резолв + перелинковка
    purge  - удалить tools\ линки и state (реестр не трогается)

  Каталог junction-ов переопределяется манифестом: "links": { "dir": "tools-links" }.


  pwsh resolve-tools.ps1 link -Project C:\Scripts\Lab100
  pwsh resolve-tools.ps1 status -Project C:\Scripts\devstation-deploy
#>
param(
    [ValidateSet('init','status','link','update','purge','shims')]
    [string]$Action = 'link',
    [string]$Project = (Get-Location),
    [string]$Registry = '',
    [switch]$DryRun,
    [switch]$NoPull,
    [switch]$GenerateShims,
    [string]$ShimRoot = ''
)
# UTF-8 console default (no krakozyabry)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath($Project)

if (-not $Registry) {
    $Registry = $env:INVR_REGISTRY
}
if (-not $Registry) {
    $Registry = Join-Path $PSScriptRoot 'registry'
}
if (-not (Test-Path $Registry)) {
    $parentDir = Split-Path $PSScriptRoot -Parent
    $grandDir  = Split-Path $parentDir -Parent
    if ((Split-Path $grandDir -Leaf) -eq 'registry') { $Registry = $grandDir }
}
$registryRoot = [IO.Path]::GetFullPath($Registry)

$manifestName = 'project.json'
$stateDirName = '.inrv'
# Каталог junction-ов: по умолчанию 'tools', переопределяется манифестом
# ("links": { "dir": "<каталог>" }) — нужно, когда в tools\ уже лежат шимы
# и runtime-каталоги, и junction-и туда ставить нельзя.
$linkRootName = 'tools'
$_mfProbe = Join-Path $projectRoot $manifestName
if (Test-Path $_mfProbe) {
    try {
        $_mfTmp = Get-Content $_mfProbe -Raw | ConvertFrom-Json
        if (($_mfTmp.PSObject.Properties.Name -contains 'links') -and $_mfTmp.links) {
            $_ld = $_mfTmp.links.dir
            if ($_ld) { $linkRootName = "$_ld" }
        }
    } catch { }
}

function Get-Semver { param([string]$v)
    if ($v -notmatch '^(\d+)\.(\d+)\.(\d+)$') { return $null }
    return [pscustomobject]@{
        major = [int]$Matches[1]; minor = [int]$Matches[2]; patch = [int]$Matches[3]
    }
}

function Compare-Semver { param($a, $b)
    if ($a.major -ne $b.major) { return $a.major.CompareTo($b.major) }
    if ($a.minor -ne $b.minor) { return $a.minor.CompareTo($b.minor) }
    return $a.patch.CompareTo($b.patch)
}

# Парсер диапазона: "0.1.0" | "0.1.x" | ">=0.1.0 <0.3.0" | "=0.1.0"
function Test-Range { param([string]$range, [string]$version)
    $ver = Get-Semver $version
    if (-not $ver) { return $false }
    $range = $range.Trim()
    if ($range -eq 'latest') { return $true }   # только для шимов
    $parts = $range -split '\s+'
    foreach ($p in $parts) {
        if (-not $p) { continue }
        if ($p -match '^([<>=]+)\s*(\d+)\.(\d+)(?:\.(\d+))?$') {
            $op = $Matches[1]; $m = [int]$Matches[2]; $n = [int]$Matches[3]
            $pa = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
            $target = Get-Semver "$m.$n.$pa"
            $cmp = Compare-Semver $ver $target
            $ok = switch ($op) {
                '>='  { $cmp -ge 0 }
                '>'   { $cmp -gt 0 }
                '<='  { $cmp -le 0 }
                '<'   { $cmp -lt 0 }
                '='   { $cmp -eq 0 }
                default { $false }
            }
            if (-not $ok) { return $false }
        }
        elseif ($p -match '^(\d+)\.(\d+)(?:\.(\d+))?$') {
            $m = [int]$Matches[1]; $n = [int]$Matches[2]
            $pa = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
            $target = Get-Semver "$m.$n.$pa"
            $cmp = Compare-Semver $ver $target
            if ($cmp -ne 0) { return $false }
        }
        elseif ($p -match '^(\d+)\.(\d+)\.([x*])$') {
            $m = [int]$Matches[1]; $n = [int]$Matches[2]
            if ($ver.major -ne $m -or $ver.minor -ne $n) { return $false }
        }
        else {
            throw "Неизвестный диапазон версии: [$range] (часть [$p])"
        }
    }
    return $true
}

function Get-AvailableVersions { param([string]$toolName)
    $dir = Join-Path $registryRoot $toolName
    if (-not (Test-Path $dir)) { return @() }
    return @(Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Select-Object -ExpandProperty Name)
}

function Get-MaxVersion {
    # явный компаратор: semver-объекты не реализуют IComparable для Sort-Object
    param([string[]]$Versions)
    $max = $null; $maxVer = $null
    foreach ($v in $Versions) {
        $sv = Get-Semver $v
        if (-not $sv) { continue }
        if (-not $maxVer -or (Compare-Semver $sv $maxVer) -gt 0) {
            $max = $v; $maxVer = $sv
        }
    }
    return $max
}

function Resolve-Tool { param([string]$toolName, [string]$range)
    $versions = Get-AvailableVersions $toolName
    $matching = @($versions | Where-Object { Test-Range $range $_ })
    if ($matching.Count -eq 0) {
        throw "Инструмент [$toolName] диапазон [$range]: не найдено версий в реестре [$registryRoot]. Доступно: [$($versions -join ', ')]"
    }
    return Get-MaxVersion $matching
}

function Get-Manifest { param()
    $m = Join-Path $projectRoot $manifestName
    if (-not (Test-Path $m)) {
        if ($Action -eq 'init') { return $null }
        throw "Нет манифеста $manifestName в $projectRoot. Запусти init."
    }
    return (Get-Content $m -Raw | ConvertFrom-Json)
}

function Get-LinkState { param()
    $f = Join-Path $projectRoot "$linkRootName\$stateDirName\state.json"
    if (Test-Path $f) { return (Get-Content $f -Raw | ConvertFrom-Json) }
    return $null
}

function Save-LinkState { param($obj, [string]$tool, [string]$version, [string]$linkType)
    $dir = Join-Path $projectRoot "$linkRootName\$stateDirName"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $f = Join-Path $dir 'state.json'
    $existing = @{}
    if ($obj) { foreach ($p in $obj.PSObject.Properties) { $existing[$p.Name] = $p.Value } }
    if (-not $existing.ContainsKey('_meta')) {
        $existing['_meta'] = @{ schema = 'inrv.state/1'; project = $projectRoot }
    }
    $existing[$tool] = @{
        version   = $version
        linkType  = $linkType
        linkedAt  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        registry  = $registryRoot
    }
    Set-Content -Path $f -Value (($existing | ConvertTo-Json -Depth 5)) -Encoding utf8
}

function Get-ReparseTarget { param([string]$link)
    try {
        $item = Get-Item -LiteralPath $link -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            return $item.Target
        }
    } catch {}
    return $null
}

function New-Junction { param([string]$link, [string]$target)
    New-Item -ItemType Junction -Path $link -Target $target -Force | Out-Null
}

function Remove-Link { param([string]$link)
    # junction удаляется БЕЗ -Recurse, чтобы не зайти внутрь реестра
    if (Test-Path -LiteralPath $link) {
        [System.IO.Directory]::Delete($link, $false)
    }
}

function Install-Shim { param([string]$tool, [string]$version)
    $regToolDir = Join-Path $registryRoot "$tool\$version"
    $regBase = $registryRoot
    $linkParent = Join-Path $projectRoot $linkRootName
    $ps1files = Get-ChildItem -LiteralPath $regToolDir -File -Filter '*.ps1' -ErrorAction SilentlyContinue
    if (-not $ps1files) { return }
    foreach ($f in $ps1files) {
        $shimName = $f.Name
        $shimPath = Join-Path $linkParent $shimName
        if (Test-Path -LiteralPath $shimPath) {
            $head = Get-Content -LiteralPath $shimPath -TotalCount 1 -ErrorAction SilentlyContinue
            if ($head -match 'INVR-Tools shim') { continue }
            Write-Host "  ! пропущен шим ${shimName}: на месте обычный файл (переноси как инструмент в реестр)" -ForegroundColor Yellow
            continue
        }
        $content = @"
# INVR-Tools shim (автоген локера): вызывает версию из реестра по latest.txt.
# ДЕЛАТЬ РУКАМИ В ШИМ НЕЛЬЗЯ — изменения в registry\<tool>\<version>\.
`$tool  = '$tool'
`$entry = '$shimName'
`$latest = (Get-Content (Join-Path '$regBase' "\`$tool\latest.txt") -Raw).Trim()
`$target = Join-Path '$regBase' "\`$tool\`$latest\`$entry"
if (-not (Test-Path -LiteralPath `$target)) { throw "INVR: нет `$tool версии `$latest (запусти resolve-tools.ps1 update)" }
& `$target @args
exit `$LASTEXITCODE
"@
        Set-Content -LiteralPath $shimPath -Value $content -Encoding utf8
        Write-Host "  shim: $shimName -> registry\$tool\<latest>" -ForegroundColor Cyan
    }
}

function Install-Link { param([string]$tool, [string]$version)
    $regToolDir = Join-Path $registryRoot "$tool\$version"
    if (-not (Test-Path -LiteralPath $regToolDir)) { throw "Нет каталога реестра: $regToolDir" }
    $link = Join-Path $projectRoot "$linkRootName\$tool"
    $linkParent = Join-Path $projectRoot $linkRootName
    New-Item -ItemType Directory -Force -Path $linkParent | Out-Null

    $current = Get-ReparseTarget $link
    if ($current) {
        if ($current -eq $regToolDir) {
            Write-Host "  ok: $tool -> $version (уже)" -ForegroundColor Gray
            return
        }
        Remove-Link $link
    }
    elseif (Test-Path -LiteralPath $link) {
        # обычная папка/файл на месте линка — не трогаем, помечаем
        throw "На месте линка [$link] обычный файл/папка — удали вручную или run purge."
    }

    Write-Host "  link: $tool -> $version  ($regToolDir)" -ForegroundColor Green
    if ($DryRun) { return }

    try {
        New-Junction $link $regToolDir
        Save-LinkState (Get-LinkState) $tool $version 'junction'
    } catch {
        # junction не удался (не-NTFS/SMB) — fallback: копия-кеш
        $cacheDir = Join-Path $projectRoot "$linkRootName\$stateDirName\cache\$tool\$version"
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        Copy-Item -Path (Join-Path $regToolDir '*') -Destination $cacheDir -Recurse -Force
        Copy-Item -Path (Join-Path $regToolDir 'tool.json') -Destination $cacheDir -Force -ErrorAction SilentlyContinue
        New-Junction $link $cacheDir | Out-Null
        Save-LinkState (Get-LinkState) $tool $version 'copy'
        Write-Host "  ! junction недоступен, fallback copy: $cacheDir" -ForegroundColor Yellow
    }
}

switch ($Action) {
    'init' {
        New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot $linkRootName) | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot "$linkRootName\$stateDirName") | Out-Null
        $m = Join-Path $projectRoot $manifestName
        if (-not (Test-Path $m)) {
            $manifestSample = @{
                schema = 'inrv.project/1'
                name   = (Split-Path $projectRoot -Leaf)
                tools  = @{}
                links  = @{ dir = $linkRootName }
            } | ConvertTo-Json -Depth 4
            Set-Content -Path $m -Value $manifestSample -Encoding utf8
            Write-Host "Создан манифест: $m — заполни tools: { имя: диапазон }"
        } else {
            Write-Host "Манифест уже есть: $m"
        }
        Write-Host "Проект: $projectRoot | Реестр: $registryRoot"
    }

    'status' {
        $manifest = Get-Manifest
        if ($manifest.mode -eq 'dist') {
            Write-Host "Проект-дистрибутор (mode='dist') — линки не создаются, СКИП." -ForegroundColor Yellow
            exit 0
        }
        if (-not $manifest.tools) { Write-Host 'Манифест пуст (tools: {}).'; exit 0 }
        $state = Get-LinkState
        $allOk = $true
        foreach ($prop in $manifest.tools.PSObject.Properties) {
            $tool = $prop.Name; $range = $prop.Value
            $needOk = $false
            try {
                $v = Resolve-Tool $tool $range
                $needOk = $true
            } catch {
                Write-Host "  FAIL: $tool [$range] — $($_.Exception.Message)" -ForegroundColor Red
                $allOk = $false
                continue
            }
            $link = Join-Path $projectRoot "$linkRootName\$tool"
            $target = Get-ReparseTarget $link
            $expect = Join-Path $registryRoot "$tool\$v"
            if ($target -eq $expect) {
                Write-Host "  ok:    $tool -> $v" -ForegroundColor Green
            } elseif ($target) {
                Write-Host "  MISMATCH: $tool линк на $target, ожидается $expect" -ForegroundColor Yellow
                $allOk = $false
            } elseif (-not (Test-Path $link)) {
                Write-Host "  missing: $tool (линк не создан)" -ForegroundColor Yellow
                $allOk = $false
            } else {
                Write-Host "  broken: $tool (не reparse point)" -ForegroundColor Yellow
                $allOk = $false
            }
        }
        Write-Host ""
        if ($allOk) { Write-Host "СТАТУС: всё в порядке" -ForegroundColor Green; exit 0 }
        else { Write-Host "СТАТУС: есть проблемы — запусти link" -ForegroundColor Red; exit 1 }
    }

    'link' {
        $manifest = Get-Manifest
        if ($manifest.mode -eq 'dist') {
            Write-Host "Проект-дистрибутор (mode='dist') — линки не создаются, СКИП. Копии держи актуальными вручную/синхронизацией." -ForegroundColor Yellow
            exit 0
        }
        if (-not $manifest.tools) { 'Манифест пуст (tools: {}).' ; exit 0 }
        if (-not (Test-Path $registryRoot)) { throw "Реестр не найден: $registryRoot" }
        foreach ($prop in $manifest.tools.PSObject.Properties) {
            $tool = $prop.Name; $range = $prop.Value
            $v = Resolve-Tool $tool $range
            Install-Link $tool $v
            if ($GenerateShims) { Install-Shim $tool $v }
        }
        if ($DryRun) { Write-Host "DRY-RUN: реальных изменений не внесено" -ForegroundColor Yellow }
    }

    'update' {
        if (-not $NoPull) {
            if (Test-Path (Join-Path $registryRoot '.git')) {
                Write-Host "git pull реестра..." -ForegroundColor Cyan
                Push-Location $registryRoot
                try { & git pull --ff-only 2>&1 | Out-String | Write-Host } finally { Pop-Location }
            }
        }
        & $PSCommandPath link -Project $projectRoot -Registry $registryRoot
    }

    'shims' {
        if (-not (Test-Path $registryRoot)) { throw "Реестр не найден: $registryRoot" }
        $shimParent = if ($ShimRoot) { [IO.Path]::GetFullPath($ShimRoot) } else { Split-Path $registryRoot -Parent }
        if (-not (Test-Path $shimParent)) { throw "Каталог для шимов не найден: $shimParent" }
        $linkParent = $shimParent
        $count = 0
        foreach ($toolDir in (Get-ChildItem -LiteralPath $registryRoot -Directory | Sort-Object Name)) {
            $latestFile = Join-Path $toolDir.FullName 'latest.txt'
            if (-not (Test-Path -LiteralPath $latestFile)) { continue }
            $v = (Get-Content -LiteralPath $latestFile -Raw).Trim()
            if (-not (Test-Path (Join-Path $toolDir.FullName $v))) { continue }
            Install-Shim $toolDir.Name $v
            $count++
        }
        Write-Host ""
        Write-Host "Шимы: обработано инструментов $count, каталог $shimParent" -ForegroundColor Cyan
    }

    'purge' {
        $toolsDir = Join-Path $projectRoot $linkRootName
        if (-not (Test-Path $toolsDir)) { 'tools\ уже нет.'; exit 0 }
        Get-ChildItem $toolsDir -Directory | ForEach-Object {
            $t = Get-ReparseTarget $_.FullName
            if ($t) {
                Remove-Link $_.FullName
                Write-Host "  удалён линк: $($_.Name)"
            } elseif ($_.Name -eq $stateDirName) {
                # .inrv — удаляем только сам каталог state (файлы)
            } else {
                Write-Host "  оставлено (не линк): $($_.Name)"
            }
        }
        # удалить автоген-шимы (только с нашей меткой)
        Get-ChildItem $toolsDir -File -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object {
            $first = Get-Content -LiteralPath $_.FullName -TotalCount 1 -ErrorAction SilentlyContinue
            if ($first -match 'INVR-Tools shim') {
                Remove-Item -LiteralPath $_.FullName -Force
                Write-Host "  удалён шим: $($_.Name)"
            }
        }
        $stateDir = Join-Path $toolsDir $stateDirName
        if (Test-Path $stateDir) {
            Remove-Item -LiteralPath $stateDir -Recurse -Force
            Write-Host "  удалён state: $stateDir"
        }
        if (Test-Path $toolsDir) {
            $left = Get-ChildItem $toolsDir -Force
            if (-not $left) { Remove-Item -LiteralPath $toolsDir -Force; Write-Host "  tools\ пуст — удалён" }
        }
    }
}

Write-Host ""
Write-Host "Реестр: $registryRoot | Проект: $projectRoot"