# INVR-Tools shim (автоген локера): вызывает версию из реестра по latest.txt.
# ДЕЛАТЬ РУКАМИ В ШИМ НЕЛЬЗЯ — изменения в registry\<tool>\<version>\.
# Шим переносимый: реестр ищется от расположения самого шима, поэтому
# одинаково работает в клоне реестра, в плоском каталоге инструментов и в
# раскладке дистрибутора (шим в <tool-dir>, реестр в <tool-dir>\tools\registry).
# INVR_TOOLS_ROOT = каталог шима; инструменты берут отсюда свои рабочие данные
# (monitor\state, mcp-watchdog-guardian\state и т.п.) вместо зашитых путей.
$tool  = 'run-watch'
$entry = 'run-watch.ps1'
if (-not $env:INVR_TOOLS_ROOT) { $env:INVR_TOOLS_ROOT = $PSScriptRoot }
$regRoot = if ($env:INVR_REGISTRY -and (Test-Path -LiteralPath $env:INVR_REGISTRY)) { $env:INVR_REGISTRY }
           elseif (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'registry')) { Join-Path $PSScriptRoot 'registry' }
           elseif (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'tools\registry')) { Join-Path $PSScriptRoot 'tools\registry' }
           else { Join-Path $PSScriptRoot 'registry' }
$latest = (Get-Content (Join-Path $regRoot "\$tool\latest.txt") -Raw).Trim()
$target = Join-Path $regRoot "\$tool\$latest\$entry"
if (-not (Test-Path -LiteralPath $target)) { throw "INVR: нет $tool версии $latest (запусти resolve-tools.ps1 update)" }
& $target @args
exit $LASTEXITCODE
