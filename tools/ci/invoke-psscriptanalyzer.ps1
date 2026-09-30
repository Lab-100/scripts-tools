<#
.SYNOPSIS
  Статический анализ PowerShell-кода репозитория через PSScriptAnalyzer.

.DESCRIPTION
  Явный список разрешённых правил (IncludeRules) вместо «дефолт минус шум»:
  так видно, что отключено сознательно, и конфигурация не «плывёт» вместе с
  обновлением PSScriptAnalyzer. Набор подобрано так, чтобы текущий код
  репозитория проходил анализ без единой находки.

  Почему строгость именно такая. Версии инструментов в registry\<tool>\<version>\
  неизменяемы: правка существующего инструмента = новая версия в новом каталоге.
  Значит «исправить» код существующих версий под правило анализатора нельзя, и
  правила фиксируются такие, под которые код реестра уже чист. Шумные
  формально-стилевые правила отключены осознанно:

    PSAvoidUsingWriteHost                    форматный вывод в консоль — норма
                                              для инструментов оркестрации;
    PSAvoidUsingPositionalParameters          шимы и скрипты пишутся позиционно;
    PSAvoidUsingEmptyCatchBlock              пустой catch — сознательный
                                              паттерн «опционально/кодировка»;
    PSUseBOMForUnicodeEncodedFile             репозиторий UTF-8 без BOM, pwsh 7;
    PSUseShouldProcessForStateChangingFunctions, PSReviewUnusedParameter,
    PSUseDeclaredVarsMoreThanAssignments, PSUseSingularNouns
                                              стиль, а не дефект;
    PSUseApprovedVerbs                        глаголы Lerp-Color, Init-Actuality,
    PSAvoidAssignmentToAutomaticVariable      Touch-NodeAct, Is-Waking,
                                              Bump-OrWake, Apply-EdgeAct, $Error,
                                              $home — часть неизменяемых версий;
    PSAvoidOverwritingBuiltInCmdlets           ложное срабатывание на собственной
                                              функции Write-Log.

  Включены правила безопасности и корректности (в т.ч. запрет паролей и
  незашифрованной аутентификации в открытом виде, Invoke-Expression, WMI,
  компьютера-хардкод, неверные сравнения с $null и т.п.).

  Отчёт: artifacts\psscriptanalyzer\pssa-report.ndjson и summary.txt.
  Код возврата: 0 — находок нет, 1 — находки есть (при -FailOnFinding).

  pwsh -NoProfile -File tools\ci\invoke-psscriptanalyzer.ps1
#>
param(
    [string]$Root = '',
    [string]$ReportDir = '',
    [switch]$FailOnFinding
)
# UTF-8 console default (no krakozyabry)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ErrorActionPreference = 'Stop'

if (-not $Root)      { $Root = Join-Path $PSScriptRoot '..\..' }
$Root = [IO.Path]::GetFullPath($Root)
if (-not $ReportDir) { $ReportDir = Join-Path $Root 'artifacts\psscriptanalyzer' }

# Разрешённые правила. Проверено на PSScriptAnalyzer 1.25.0: 0 находок.
$allowedRules = [string[]]@(
    'PSAvoidGlobalAliases'
    'PSAvoidGlobalFunctions'
    'PSAvoidGlobalVars'
    'PSAvoidDefaultValueForMandatoryParameter'
    'PSAvoidDefaultValueSwitchParameter'
    'PSAvoidInvokingEmptyMembers'
    'PSAvoidMultipleTypeAttributes'
    'PSAvoidNullOrEmptyHelpMessageAttribute'
    'PSAvoidReservedWordsAsFunctionNames'
    'PSAvoidShouldContinueWithoutForce'
    'PSAvoidTrailingWhitespace'
    'PSAvoidUsingAllowUnencryptedAuthentication'
    'PSAvoidUsingBrokenHashAlgorithms'
    'PSAvoidUsingCmdletAliases'
    'PSAvoidUsingComputerNameHardcoded'
    'PSAvoidUsingConvertToSecureStringWithPlainText'
    'PSAvoidUsingInvokeExpression'
    'PSAvoidUsingPlainTextForPassword'
    'PSAvoidUsingUsernameAndPasswordParams'
    'PSAvoidUsingWMICmdlet'
    'PSMisleadingBacktick'
    'PSMissingModuleManifestField'
    'PSPossibleIncorrectComparisonWithNull'
    'PSPossibleIncorrectUsageOfAssignmentOperator'
    'PSPossibleIncorrectUsageOfRedirectionOperator'
    'PSProvideCommentHelp'
    'PSReservedCmdletChar'
    'PSReservedParams'
    'PSShouldProcess'
    'PSUseCmdletCorrectly'
    'PSUseConsistentWhitespace'
    'PSUseLiteralInitializerForHashtable'
    'PSUseOutputTypeCorrectly'
    'PSUseProcessBlockForPipelineCommand'
    'PSUsePSCredentialType'
    'PSUseSingleValueFromPipelineParameter'
    'PSUseSupportsShouldProcess'
    'PSUseToExportFieldsInManifest'
    'PSUseUTF8EncodingForHelpFile'
    'PSUseUsingScopeModifierInNewRunspaces'
)

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Host 'ОШИБКА: модуль PSScriptAnalyzer не найден. Установить: Install-Module PSScriptAnalyzer -Scope CurrentUser' -ForegroundColor Red
    exit 2
}

$settings = @{
    IncludeRules = $allowedRules
    Severity    = @('Error', 'Warning')
}

# Рабочие и служебные каталоги: их содержимое не анализируем.
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

# Анализируем пофайлово: так список файлов под наш контролем (исключения выше)
# и результат однозначно привязан к проверенным файлам.
$findings = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $res = Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings
    if ($res) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
        foreach ($r in $res) {
            $findings.Add([pscustomobject]@{
                File     = $rel
                Line     = [int]$r.Line
                Rule     = $r.RuleName
                Severity = [string]$r.Severity
                Message  = $r.Message
            })
        }
    }
}

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$ndjsonPath = Join-Path $ReportDir 'pssa-report.ndjson'
$summaryPath = Join-Path $ReportDir 'summary.txt'
$utf8NoBom = [Text.UTF8Encoding]::new($false)

$reportLines = @()
if ($findings.Count -gt 0) {
    $reportLines = foreach ($x in $findings) {
        ('{{"file":"{0}","line":{1},"rule":"{2}","severity":"{3}","message":"{4}"}}' -f
            $x.File, $x.Line, $x.Rule, $x.Severity, ($x.Message -replace '"', '\"'))
    }
}
try {
    [IO.File]::WriteAllLines($ndjsonPath, [string[]]@($reportLines), $utf8NoBom)
} catch {
    Write-Host "ОШИБКА: не удалось записать отчёт $ndjsonPath : $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add("Проверено файлов: $(@($files).Count)")
$summary.Add("Правил включено: $($allowedRules.Count)")
$summary.Add("Найдено: $($findings.Count)")
foreach ($g in ($findings | Group-Object -Property Rule | Sort-Object Count -Descending)) {
    $summary.Add(("  {0} = {1}" -f $g.Name, $g.Count))
}
[IO.File]::WriteAllLines($summaryPath, [string[]]$summary.ToArray(), $utf8NoBom)

Write-Host "Проверено файлов: $(@($files).Count)"
Write-Host "Правил включено: $($allowedRules.Count)"
Write-Host "Найдено: $($findings.Count)"
foreach ($x in $findings) {
    # Содержимое исходной строки не выводится: только место и диагностика.
    Write-Host ("{0}:{1} [{2}] {3}" -f $x.File, $x.Line, $x.Rule, $x.Message) -ForegroundColor Yellow
}

if ($findings.Count -gt 0 -and $FailOnFinding.IsPresent) { exit 1 }
exit 0
