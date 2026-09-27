<#
.SYNOPSIS
  Утилита бэкапа/отката изменений для оркестратора opencode.
  Политика: полный доступ к файлам вне проекта, КРОМЕ системных областей
  Windows (C:\Windows и пр.) и файлов служб удалённого управления/реестра.
  Каждое изменение: бэкап оригинала + запись в журнал + restore-скрипт.

.USAGE
  pwsh backup-util.ps1 list
  pwsh backup-util.ps1 backup -Files @('C:\path\file.txt','C:\dir') -Notes 'desc'
  pwsh backup-util.ps1 undo -ChangeId chg_20260913_120000_ab3
#>
param(
    [ValidateSet('backup', 'undo', 'list', 'init')]
    [string]$Action = 'list',
    [string[]]$Files = @(),
    [string]$Notes = '',
    [string]$ChangeId = '',
    [switch]$Force,
    [string]$RollbackRoot = ''
)
# UTF-8 console default (no krakozyabry)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'
# Каталог бэкапов НЕ на системном диске (политика), версионируется в GitHub.
# Приоритет корня: -RollbackRoot > env INVR_ROLLBACK_ROOT > файл рядом со скриптом
# (rollback-root.txt, пишется развёртывателем) > первый несистемный диск.
# Get-PSDrive отдаёт и неготовые приводы (CD/DVD), поэтому тип и готовность тома
# проверяются через DriveInfo; если несистемных дисков нет — каталог в профиле.
function Get-DefaultRoot {
    param([string]$Leaf)
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne 'C' -and $_.Root } | Sort-Object Name)) {
        try {
            $di = [System.IO.DriveInfo]::new($d.Root)
            if ($di.IsReady -and $di.DriveType -eq [System.IO.DriveType]::Fixed) { return (Join-Path $d.Root $Leaf) }
        } catch { }
    }
    return (Join-Path $env:USERPROFILE $Leaf)
}
function Resolve-Root {
    if ($RollbackRoot) { return [IO.Path]::GetFullPath($RollbackRoot) }
    try {
        $envRoot = [Environment]::GetEnvironmentVariable('INVR_ROLLBACK_ROOT')
        if ($envRoot) { return [IO.Path]::GetFullPath($envRoot) }
    } catch {}
    $side = Join-Path $PSScriptRoot 'rollback-root.txt'
    if (Test-Path $side) {
        $v = (Get-Content $side -Raw -ErrorAction SilentlyContinue).Trim()
        if ($v) { return [IO.Path]::GetFullPath($v) }
    }
    $homeSide = Join-Path $env:USERPROFILE '.devstation\rollback-root.txt'
    if (Test-Path $homeSide) {
        $v = (Get-Content $homeSide -Raw -ErrorAction SilentlyContinue).Trim()
        if ($v) { return [IO.Path]::GetFullPath($v) }
    }
    return (Get-DefaultRoot 'rollback-catalog')
}
$root = Resolve-Root
$entryHint = if ($PSCommandPath) { $PSCommandPath } else { 'backup-util.ps1' }
$changesDir = Join-Path $root 'changes'
$manifestPath = Join-Path $root 'manifest.json'
$readmePath = Join-Path $root 'README.md'

# Области, куда оркестратор НЕ имеет права писать/менять (политика пользователя).
$DenyPrefixes = @(
    'C:\Windows\',
    'C:\ProgramData\Microsoft\Windows\',
    'C:\Program Files\Windows Defender\',
    'C:\Program Files (x86)\Windows Defender\'
)
$DenyFilePatterns = @('winrm*', '*RemoteRegistry*', 'RegSvc*', 'Wecsvc*')

function Get-Manifest {
    if (Test-Path $manifestPath) {
        return @(Get-Content $manifestPath -Raw | ConvertFrom-Json)
    }
    return @()
}

function Save-Manifest([Array]$data) {
    $json = $data | ConvertTo-Json -Depth 6
    Set-Content -Path $manifestPath -Value $json -Encoding utf8
}

function Assert-Allowed([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    foreach ($p in $DenyPrefixes) {
        if ($full.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Запрещённая область изменения: $full (политика: системные файлы Windows)"
        }
    }
    $fn = [IO.Path]::GetFileName($full)
    foreach ($pat in $DenyFilePatterns) {
        if ($fn -like $pat) {
            throw "Запрещённый файл службы: $full (политика: службы управления/реестра)"
        }
    }
}

function New-ChangeId {
    return "chg_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + "_" + ('{0:x3}' -f (Get-Random -Maximum 4095))
}

function New-UndoScript([string]$changeId, [string]$changeDir, [string[]]$paths) {
    $restore = Join-Path $changeDir 'restore.ps1'
    $lines = @(
        '# Автовосстановление изменений. Запуск: pwsh restore.ps1'
        "param(`[switch`]`$Force)", ''
        "`$ErrorActionPreference = 'Stop'"
        "`$root = '$root'"
        "`$changeId = '$changeId'"
        "`$originals = Join-Path `$root 'changes' `$changeId 'originals'"
        ''
        'Write-Host "Восстановление изменения ${changeId}:" -ForegroundColor Yellow'
    )
    $i = 0
    foreach ($p in $paths) {
        $i++
        $full = [IO.Path]::GetFullPath($p)
        $lines += @(
            "`$backup = Join-Path `$originals ('orig_' + '$i')"
            "`$target = '$full'"
            "if (-not (Test-Path `$target)) { Write-Warning 'Нет файла (пропускаем): ' + `$target; exit }"
            "if (-not `$Force) {"
            "    `$ans = Read-Host '    Откатить [$i] `$target? [y/N]'"
            "    if (`$ans -notin @('y','Y','yes','д','Д','да')) { Write-Host '    пропущено'; exit }"
            "}"
            "Copy-Item -LiteralPath `$backup -Destination `$target -Recurse -Force"
            "Write-Host '    OK: ' + `$target"
            ''
        )
    }
    $lines += 'Write-Host "Готово: $changeId восстановлен." -ForegroundColor Green'
    Set-Content -Path $restore -Value ($lines -join "`n") -Encoding utf8
    return $restore
}

switch ($Action) {
    'init' {
        New-Item -ItemType Directory -Force -Path $changesDir | Out-Null
        if (-not (Test-Path $manifestPath)) { Save-Manifest @() }
        if (-not (Test-Path $readmePath)) {
            $readme = @(
                '# Каталог отката изменений (rollback-catalog)',
                '',
                "Хранится вне системного диска ($root), версионируется приватным GitHub-репо.",
                '',
                '## Структура',
                '- `manifest.json` — журнал изменений (ChangeId, время, файлы, описание).',
                '- `changes/<ChangeId>/` — одно изменение:',
                '  - `desc.md` — описание (можно дополнять),',
                '  - `originals/` — копии оригиналов до изменения,',
                '  - `restore.ps1` — скрипт отката этого изменения.',
                '',
                '## Правила каталога',
                '- Создание новых файлов и дополнение desc.md — разрешено без спроса.',
                '- Редактирование/удаление/откат существующих изменений — только после',
                '  пошагового подтверждения пользователя.',
                "- Откат: ``pwsh $entryHint undo -ChangeId <id>``"
            )
            Set-Content -Path $readmePath -Value ($readme -join "`n") -Encoding utf8
        }
        Write-Host "Rollback root: $root" -ForegroundColor Green
    }
    'list' {
        if (-not (Test-Path $manifestPath)) { Write-Host 'Журнал пуст.'; break }
        $data = Get-Manifest
        Write-Host ("{0,-30} {1,-20} {2,-6} {3}" -f 'ChangeId', 'Когда', 'Файлов', 'Описание')
        Write-Host ('-' * 100)
        foreach ($e in $data) {
            Write-Host ("{0,-30} {1,-20} {2,-6} {3}" -f $e.changeId, $e.timestamp, $e.fileCount, $e.notes)
        }
    }
    'backup' {
        $id = New-ChangeId
        $changeDir = Join-Path $changesDir $id
        $orig = Join-Path $changeDir 'originals'
        New-Item -ItemType Directory -Force -Path $orig | Out-Null
        $paths = $Files
        if ($paths.Count -eq 0) { throw 'Укажи -Files (что бэкапим).' }
        $i = 0
        foreach ($p in $paths) {
            $i++
            if (-not (Test-Path -LiteralPath $p)) { throw "Путь не найден: $p" }
            Assert-Allowed $p
            $dest = Join-Path $orig ("orig_" + $i)
            Copy-Item -LiteralPath $p -Destination $dest -Recurse -Force
        }
        $restore = New-UndoScript $id $changeDir $paths
        $manifest = @(Get-Manifest)
        $manifest += [pscustomobject]@{
            changeId   = $id
            timestamp  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            op         = 'backup'
            fileCount  = $paths.Count
            files      = $paths
            notes      = $Notes
            backupDir  = $changeDir
            restore    = $restore
        }
        Save-Manifest $manifest
        # Файл описания изменения (разрешено дополнять; остальные операции — по разрешению)
        $descLines = @(
            "# Изменение $id",
            '',
            "- **Когда:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            "- **Что/зачем:** $Notes",
            "- **Файлов:** $($paths.Count)",
            '- **Файлы:**',
            ($paths | ForEach-Object { "  - $_" }),
            "- **Бэкап оригинала:** $orig",
            "- **Скрипт отката:** $restore",
            '',
            "> Правила каталога ``$root``: создание новых файлов и дополнение",
            '> этого desc.md — разрешены. Редактирование/удаление/откат существующих изменений',
            '> — только после подтверждения пользователем.'
        )
        Set-Content -Path (Join-Path $changeDir 'desc.md') -Value ($descLines -join "`n") -Encoding utf8
        Write-Host "ChangeId: $id" -ForegroundColor Green
        Write-Host "Backup:   $changeDir"
        Write-Host "Скрипт восстановления: $restore"
        Write-Host "(его всегда можно запустить: pwsh `"$restore`")"
    }
    'undo' {
        if (-not $ChangeId) { throw 'Укажи -ChangeId.' }
        $manifest = @(Get-Manifest)
        $e = $manifest | Where-Object { $_.changeId -eq $ChangeId } | Select-Object -First 1
        if (-not $e) { throw "Изменение $ChangeId не найдено." }
        if (-not (Test-Path $e.restore)) { throw "Скрипт отката отсутствует: $($e.restore)" }
        Write-Host "Откат изменения $ChangeId ($($e.notes)). Файлы:" -ForegroundColor Yellow
        $e.files | ForEach-Object { Write-Host "  - $_" }
        if (-not $Force) {
            $ans = Read-Host 'Подтверждаешь откат ВСЕХ файлов этого изменения? [y/N]'
            if ($ans -notin @('y', 'Y', 'yes', 'д', 'Д', 'да')) { Write-Host 'Отменено.'; break }
        }
        & $e.restore -Force
    }
}