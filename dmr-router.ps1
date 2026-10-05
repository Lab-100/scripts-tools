#!/usr/bin/env pwsh
# ШИМ (обёртка-переходник) — вручную не правится.
# Канон: C:\Scripts\tools\registry\dmr-router\<последняя версия>\dmr-router.ps1
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$latest = (Get-Content -Raw -LiteralPath (Join-Path $root 'registry\dmr-router\latest.txt')).Trim()
$entry = Join-Path $root "registry\dmr-router\$latest\dmr-router.ps1"
if (-not (Test-Path -LiteralPath $entry)) { throw "Не найден исполняемый файл инструмента: $entry" }
& $entry @args
exit $LASTEXITCODE