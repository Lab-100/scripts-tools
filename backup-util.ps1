# INVR-Tools shim (автоген): вызывает версию из реестра по latest.txt.
# ДЕЛАТЬ РУКАМИ В ШИМ НЕЛЬЗЯ — изменения в registry\<tool>\<version>\.
$tool  = 'backup-util'
$entry = 'backup-util.ps1'
$latest = (Get-Content (Join-Path $PSScriptRoot "registry\$tool\latest.txt") -Raw).Trim()
$target = Join-Path $PSScriptRoot "registry\$tool\$latest\$entry"
if (-not (Test-Path -LiteralPath $target)) { throw "INVR: нет $tool версии $latest (запусти resolve-tools.ps1 update)" }
& $target @args
exit $LASTEXITCODE