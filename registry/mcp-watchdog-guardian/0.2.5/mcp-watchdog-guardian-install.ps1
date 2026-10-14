# mcp-watchdog-guardian-install.ps1 — автозапуск хранителя при входе пользователя
# Ветка HKCU Run. Версия 0.2.5.
#Requires -Version 7

<#
.SYNOPSIS
  Регистрирует (или снимает) автозапуск хранителя mcp-watchdog-guardian в ветке
  HKCU\Software\Microsoft\Windows\CurrentVersion\Run, чтобы после перезагрузки
  ядро (демон-страж mcp-watchdog + монитор infra-graph) вставало само, без
  ручного вмешательства.

.DESCRIPTION
  Хранитель — единственная точка, которую нужно поднимать вместе с системой:
  он ждёт появления процесса opencode и затем сам поднимает демон и монитор.
  Обратный порядок (демон «с системой») не работает: без открытого opencode
  демон штатно завершается.

  Команда автозапуска указывает на ШИМ (<tools-root>\mcp-watchdog-guardian.ps1),
  а не на конкретную версию реестра: смена версии через latest.txt не требует
  перенастройки автозапуска.

  Скрипт идемпотентен: повторный Install не дублирует запись и сообщает
  «уже установлено».

.PARAMETER Action
  Install (по умолчанию) — установить/обновить автозапуск.
  Remove  — снять автозапуск.
  Check   — только проверить запись; код возврата 1, если её нет или она отличается.

.PARAMETER ToolsRoot
  Каталог плоских шимов (tools). По умолчанию берётся из INVR_TOOLS_ROOT, иначе
  вычисляется от расположения скрипта в реестре.

.PARAMETER RuntimeDir
  Каталог состояния хранителя. По умолчанию <tools-root>\mcp-watchdog-guardian.

.PARAMETER ValueName
  Имя значения в HKCU Run (по умолчанию McpWatchdogGuardian).

.EXAMPLE
  pwsh -File mcp-watchdog-guardian-install.ps1
  Установить автозапуск (обычный случай).

.EXAMPLE
  pwsh -File mcp-watchdog-guardian-install.ps1 -Action Check
  Проверить, стоит ли автозапуск.

.EXAMPLE
  pwsh -File mcp-watchdog-guardian-install.ps1 -Action Remove
  Снять автозапуск.
#>

param(
    [ValidateSet('Install', 'Remove', 'Check')]
    [string]$Action = 'Install',
    [string]$ToolsRoot = '',
    [string]$RuntimeDir = '',
    [string]$ValueName = 'McpWatchdogGuardian'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# --- корень инструментов (машинные пути не зашиты) ---
if (-not $ToolsRoot) {
    if ($env:INVR_TOOLS_ROOT -and (Test-Path -LiteralPath $env:INVR_TOOLS_ROOT)) {
        $ToolsRoot = $env:INVR_TOOLS_ROOT
    } else {
        # скрипт лежит в registry\<tool>\<version>; реестр — двумя уровнями выше,
        # корень инструментов — каталогом выше реестра.
        $regRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $ToolsRoot = Split-Path $regRoot -Parent
    }
}
$ToolsRoot = [IO.Path]::GetFullPath($ToolsRoot)
$entry = Join-Path $ToolsRoot 'mcp-watchdog-guardian.ps1'
if (-not $RuntimeDir) { $RuntimeDir = Join-Path $ToolsRoot 'mcp-watchdog-guardian' }
$RuntimeDir = [IO.Path]::GetFullPath($RuntimeDir)

$pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshExe) { $pwshExe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }

$runKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
# Путь к pwsh в кавычках обязателен: в нём пробелы (Program Files).
$command = '"{0}" -NoProfile -WindowStyle Hidden -File "{1}" -RuntimeDir "{2}"' -f $pwshExe, $entry, $RuntimeDir

function Get-RunValue {
    try { (Get-ItemProperty -Path $runKey -Name $ValueName -ErrorAction Stop).$ValueName } catch { $null }
}

Write-Output "Хранитель:      $entry"
Write-Output "Состояние:      $RuntimeDir"
Write-Output "Команда:        $command"
Write-Output ""

$current = Get-RunValue

switch ($Action) {
    'Check' {
        if (-not $current) {
            Write-Output "Автозапуск НЕ установлен (нет значения $ValueName в HKCU Run)."
            exit 1
        }
        if ($current -eq $command) {
            Write-Output "Автозапуск установлен и совпадает с ожидаемым ($ValueName)."
            exit 0
        }
        Write-Output "Автозапуск есть, но команда отличается."
        Write-Output "  сейчас:    $current"
        Write-Output "  ожидается: $command"
        exit 1
    }
    'Install' {
        if (-not (Test-Path -LiteralPath $entry)) {
            throw "Не найден шим хранителя: $entry (сначала resolve-tools.ps1 link/shims)"
        }
        if ($current -eq $command) {
            Write-Output "Автозапуск уже установлен ($ValueName) — изменений не требуется."
            exit 0
        }
        New-Item -Path $runKey -Force | Out-Null
        Set-ItemProperty -Path $runKey -Name $ValueName -Value $command -Type String
        if ($current) { Write-Output "Автозапуск обновлён ($ValueName)." }
        else { Write-Output "Автозапуск установлен ($ValueName)." }
        Write-Output "Теперь хранитель поднимается при входе пользователя в Windows."
        Write-Output "Проверка сейчас (не запуская второй экземпляр): pwsh -File `"$entry`" -Once"
        exit 0
    }
    'Remove' {
        if (-not $current) {
            Write-Output "Автозапуск и так не установлен (значения $ValueName нет)."
            exit 0
        }
        Remove-ItemProperty -Path $runKey -Name $ValueName -Force
        Write-Output "Автозапуск снят ($ValueName)."
        Write-Output "Уже запущенный хранитель продолжает работать до выхода пользователя."
        exit 0
    }
}
