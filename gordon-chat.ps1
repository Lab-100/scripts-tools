[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$tool = 'gordon-chat'
$registry = 'C:\Scripts\tools\registry'
$latestFile = Join-Path $registry "$tool\latest.txt"
$version = (Get-Content -LiteralPath $latestFile -Raw).Trim()
$entry = Join-Path $registry "$tool\$version\$tool.ps1"
& $entry @args
exit $LASTEXITCODE