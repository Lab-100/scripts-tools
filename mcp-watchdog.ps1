# INVR-Tools shim (автоген локера): вызывает версию из реестра по latest.txt.
# ДЕЛАТЬ РУКАМИ В ШИМ НЕЛЬЗЯ — изменения в registry\<tool>\<version>\.
$tool  = 'mcp-watchdog'
$entry = 'mcp-watchdog.ps1'
$latest = (Get-Content (Join-Path 'C:\Scripts\tools\registry' "\$tool\latest.txt") -Raw).Trim()
$target = Join-Path 'C:\Scripts\tools\registry' "\$tool\$latest\$entry"
if (-not (Test-Path -LiteralPath $target)) { throw "INVR: нет $tool версии $latest (запусти resolve-tools.ps1 update)" }
& $target @args
exit $LASTEXITCODE
