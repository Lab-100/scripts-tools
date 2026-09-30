<#
.SYNOPSIS
  Проверка синтаксиса всех PowerShell-файлов репозитория системным парсером.

.DESCRIPTION
  Минимальная проверка успешности CI. Pester-тестов в репозитории нет, поэтому
  вместо них проверяется разбираемость всех *.ps1/*.psm1/*.psd1 (включая каталог
  registry\ и автогенерируемые шимы в корне) парсером PowerShell. Значения
  исходных строк в отчёт не попадают: только путь, номер строки и описание
  ошибки от парсера.

  Отчёт: artifacts\syntax\syntax-report.ndjson и artifacts\syntax\summary.txt.
  Код возврата: 0 — ошибок нет, 1 — есть ошибки (или файлы не найдены),
  2 — не удалось записать отчёт.

  pwsh -NoProfile -File tools\ci\invoke-syntax-check.ps1
#>
param(
    [string]$Root = '',
    [string]$ReportDir = ''
)
# UTF-8 console default (no krakozyabry)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ErrorActionPreference = 'Stop'

if (-not $Root)      { $Root = Join-Path $PSScriptRoot '..\..' }
$Root = [IO.Path]::GetFullPath($Root)
if (-not $ReportDir) { $ReportDir = Join-Path $Root 'artifacts\syntax' }

# Рабочие и служебные каталоги: их содержимое не проверяем.
$skipDirs = @('.git', 'node_modules', 'artifacts', '__pycache__', '.venv', 'venv', 'dist')

$files = Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' -ErrorAction SilentlyContinue |
    Where-Object {
        $full = $_.FullName
        -not ($skipDirs | Where-Object { $full -like "*\$_\*" })
    } |
    Sort-Object FullName

if (-not $files -or @($files).Count -eq 0) {
    Write-Host "ОШИБКА: PowerShell-файлы не найдены в $Root" -ForegroundColor Red
    exit 1
}

$findings = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    if ($errs) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
        foreach ($e in $errs) {
            $findings.Add([pscustomobject]@{
                File    = $rel
                Line    = [int]$e.Extent.StartLineNumber
                Message = $e.Message
            })
        }
    }
}

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$ndjsonPath = Join-Path $ReportDir 'syntax-report.ndjson'
$summaryPath = Join-Path $ReportDir 'summary.txt'
$utf8NoBom = [Text.UTF8Encoding]::new($false)

# Значение исходной строки намеренно не выводится и в отчёт не пишется.
$reportLines = @()
if ($findings.Count -gt 0) {
    $reportLines = foreach ($x in $findings) {
        ('{{"file":"{0}","line":{1},"message":"{2}"}}' -f $x.File, $x.Line, ($x.Message -replace '"', '\"'))
    }
}
try {
    [IO.File]::WriteAllLines($ndjsonPath, [string[]]@($reportLines), $utf8NoBom)
    $summary = @(
        "Проверено файлов: $(@($files).Count)"
        "Ошибок синтаксиса: $($findings.Count)"
    )
    [IO.File]::WriteAllLines($summaryPath, [string[]]$summary, $utf8NoBom)
} catch {
    Write-Host "ОШИБКА: не удалось записать отчёт в $ReportDir : $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

Write-Host "Проверено файлов: $(@($files).Count)"
Write-Host "Ошибок синтаксиса: $($findings.Count)"
foreach ($x in $findings) {
    Write-Host ("{0}:{1} [Синтаксис] {2}" -f $x.File, $x.Line, $x.Message) -ForegroundColor Yellow
}

if ($findings.Count -gt 0) { exit 1 }
exit 0
