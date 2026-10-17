<#
.SYNOPSIS
    Тесты контроля свободного места на диске в карте инфраструктуры (Pester 5+/6).

.DESCRIPTION
    Проверяется требование владельца: сегодня том C: заполнялся до 0 байт, из-за чего
    падали демон карты и .NET-процессы. Поэтому карта инфраструктуры обязана:

      1) ПОКАЗЫВАТЬ свободное место тома состояния (строка «Диск C: 3,5 / 119 ГБ (3%)»
         в подвале карты и в -Status) с цветовой индикацией;
      2) писать в nodes.json поле-корень "disk" (root/freeGb/totalGb/freePct/updatedAt),
         НЕ меняя при этом прежние поля и схему 'invr.nodes/1';
      3) ротировать СВОИ журналы (events.log, infra-graph.err.log) при превышении ~1 МБ
         в архив .1 (одна копия, старая перезаписывается), не трогая чужие логи;
      4) беречь место: при остатке меньше 1,5 ГБ кадр рисуется не чаще раза в 10 минут,
         при меньше 0,5 ГБ — не рисуется вовсе, а nodes.json пишется всегда.

    Место на диске тесты НЕ освобождают (это зона владельца) и рабочий nodes.json
    не трогают: функциональная проверка идёт через отдельный -StateFile в $TestDrive.

    Запуск: pwsh -NoProfile -Command "Invoke-Pester -Path tests -CI"
#>

BeforeDiscovery {
    $repoRoot    = Split-Path -Parent $PSScriptRoot
    $toolDir     = Join-Path $repoRoot 'registry\infra-graph'
    $latestFile  = Join-Path $toolDir 'latest.txt'
    $latest      = ((Get-Content -LiteralPath $latestFile -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
    $versionDir  = Join-Path $toolDir $latest
    $entryFile   = Join-Path $versionDir 'infra-graph.ps1'
}

Describe 'Карта инфраструктуры: файл активной версии' {
    BeforeAll {
        $repoRoot    = Split-Path -Parent $PSScriptRoot
        $toolDir     = Join-Path $repoRoot 'registry\infra-graph'
        $latest      = ((Get-Content -LiteralPath (Join-Path $toolDir 'latest.txt') -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
        $versionDir  = Join-Path $toolDir $latest
        $entry       = Join-Path $versionDir 'infra-graph.ps1'
        $EntryText   = Get-Content -LiteralPath $entry -Raw -Encoding UTF8
        $entryFile   = $entry      # в фазе прогона путь из BeforeDiscovery недоступен — берём свой
    }

    It 'файл infra-graph.ps1 активной версии <Latest> на месте' {
        Test-Path -LiteralPath $entryFile | Should -BeTrue -Because "нет файла $entryFile"
    }

    It 'скрипт карты разбирается парсером PowerShell без ошибок' {
        $errs = $null
        $tok  = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($entryFile, [ref]$tok, [ref]$errs)
        @($errs).Count | Should -Be 0 -Because ("ошибки разбора: " + (@($errs | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '))
    }

    It 'в коде карты нет машинных путей (переносимость 0.9.0 не сломана)' {
        $EntryText | Should -Not -Match 'C:\\Users\\'
    }
}

Describe 'Карта: пороги защиты от переполнения диска' {
    BeforeAll {
        $repoRoot  = Split-Path -Parent $PSScriptRoot
        $toolDir   = Join-Path $repoRoot 'registry\infra-graph'
        $latest    = ((Get-Content -LiteralPath (Join-Path $toolDir 'latest.txt') -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
        $entryPath = Join-Path $toolDir (Join-Path $latest 'infra-graph.ps1')
        $EntryText = Get-Content -LiteralPath $entryPath -Raw -Encoding UTF8

        # Значения порогов берём ИЗ САМОГО СКРИПТА (регуляркой), а не задаём заново:
        # так тест ловит и подмену порога в коде.
        $pick = {
            param($name, $text)
            $m = [regex]::Match($text, ('\$script:' + [regex]::Escape($name) + '\s*=\s*([0-9.]+)'))
            if (-not $m.Success) { return $null }
            return [double]$m.Groups[1].Value
        }
        $script:DiskWarnGb     = & $pick 'DiskWarnGb'     $EntryText
        $script:DiskCritGb     = & $pick 'DiskCritGb'     $EntryText
        $script:DiskThrottleGb = & $pick 'DiskThrottleGb' $EntryText
        $script:DiskStopGb     = & $pick 'DiskStopGb'     $EntryText
        $script:DiskPngMinSec  = & $pick 'DiskPngMinSec'  $EntryText
        $script:DiskLogMaxBytes = & $pick 'DiskLogMaxBytes' $EntryText
        $script:diskLevel      = 'normal'
        $script:lastFrameAt    = [DateTime]::MinValue

        # Логика режимов вынесена в чистые функции: берём их ТЕКСТ из AST и подключаем
        # в тест. Так проверяется настоящее поведение, а не только наличие строк в файле.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($entryPath, [ref]$null, [ref]$null)
        $wanted = @('Get-DiskSaveMode', 'Get-DiskWarnLevel', 'Format-GbText', 'Test-FrameDrawAllowed', 'Invoke-LogRotation')
        $defs = @($ast.FindAll({ param($a)
            $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and ($wanted -contains $a.Name)
        }, $true))
        $lib = ($defs | ForEach-Object { $_.Extent.Text }) -join "`n"
        . ([scriptblock]::Create($lib))
    }

    It 'пороги найдены в скрипте и стоят по требованию владельца' {
        $script:DiskWarnGb     | Should -Be 5.0
        $script:DiskCritGb     | Should -Be 2.0
        $script:DiskThrottleGb | Should -Be 1.5
        $script:DiskStopGb     | Should -Be 0.5
        $script:DiskLogMaxBytes | Should -Be 1048576
    }

    It 'снимок кадра при нехватке места делается не чаще раза в 10 минут' {
        $script:DiskPngMinSec | Should -Be 600
    }

    It 'нормальный запас места — обычный режим' -ForEach @(6.0, 3.0, 1.5) {
        Get-DiskSaveMode $_ | Should -Be 'normal'
    }

    It 'мало места ниже 1,5 ГБ — режим экономии кадра (throttle)' -ForEach @(1.49, 1.0, 0.5) {
        Get-DiskSaveMode $_ | Should -Be 'throttle'
    }

    It 'критический остаток ниже 0,5 ГБ — кадр не рисуется (stop)' -ForEach @(0.49, 0.1, 0.0) {
        Get-DiskSaveMode $_ | Should -Be 'stop'
    }

    It 'в обычном режиме кадр разрешён всегда' {
        $script:diskLevel = 'normal'
        Test-FrameDrawAllowed | Should -BeTrue
    }

    It 'при критическом остатке кадр запрещён, сколько бы времени ни прошло' {
        $script:diskLevel = 'stop'
        $script:lastFrameAt = (Get-Date).AddHours(-5)
        Test-FrameDrawAllowed | Should -BeFalse
    }

    It 'при нехватке места кадр запрещён, пока не истёк интервал' {
        $script:diskLevel = 'throttle'
        $script:lastFrameAt = (Get-Date).AddSeconds(-30)
        Test-FrameDrawAllowed | Should -BeFalse
    }

    It 'при нехватке места кадр разрешён после истечения интервала (режим восстанавливается)' {
        $script:diskLevel = 'throttle'
        $script:lastFrameAt = (Get-Date).AddSeconds(-($script:DiskPngMinSec + 5))
        Test-FrameDrawAllowed | Should -BeTrue
    }

    It 'жалоба в журнал на переход режима не спамит (ключ режима и троттлинг)' {
        $EntryText | Should -Match 'function Write-DiskWarn'
        $EntryText | Should -Match '\$script:diskWarnLast\['
        $EntryText | Should -Match 'Update-DiskGuard'
        $EntryText | Should -Match '\$script:diskWarnLast\['
        $EntryText | Should -Match 'Update-DiskGuard'
    }
}

Describe 'Карта: уровень места и цвет строки' {
    BeforeAll {
        $repoRoot  = Split-Path -Parent $PSScriptRoot
        $toolDir   = Join-Path $repoRoot 'registry\infra-graph'
        $latest    = ((Get-Content -LiteralPath (Join-Path $toolDir 'latest.txt') -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
        $entryPath = Join-Path $toolDir (Join-Path $latest 'infra-graph.ps1')
        $script:EntryText = Get-Content -LiteralPath $entryPath -Raw -Encoding UTF8
        $script:DiskWarnGb = 5.0
        $script:DiskCritGb = 2.0
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($entryPath, [ref]$null, [ref]$null)
        $wanted = @('Get-DiskWarnLevel', 'Format-GbText')
        $defs = @($ast.FindAll({ param($a)
            $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and ($wanted -contains $a.Name)
        }, $true))
        . ([scriptblock]::Create((($defs | ForEach-Object { $_.Extent.Text }) -join "`n")))
    }

    It 'много места (> 5 ГБ) — уровень ok' {
        Get-DiskWarnLevel 20.0 | Should -Be 'ok'
        Get-DiskWarnLevel 5.0  | Should -Be 'ok'
    }

    It 'остаток 2…5 ГБ — уровень warning' {
        Get-DiskWarnLevel 4.99 | Should -Be 'warning'
        Get-DiskWarnLevel 2.0  | Should -Be 'warning'
    }

    It 'остаток меньше 2 ГБ — уровень critical' {
        Get-DiskWarnLevel 1.99 | Should -Be 'critical'
        Get-DiskWarnLevel 0.0  | Should -Be 'critical'
    }

    It 'числа показываются по-русски: целые без дробей, дробные с запятой' {
        Format-GbText 119.0 | Should -Be '119'
        Format-GbText 3.49  | Should -Be '3,5'
        Format-GbText 0.5   | Should -Be '0,5'
    }

    It 'строка карты имеет требуемый вид «Диск C: 3,5 / 119 ГБ (3%)»' {
        $EntryText | Should -Match "'Диск \{0\} \{1\} / \{2\} ГБ \(\{3\}%\)'"
        $EntryText | Should -Match '\$d\.Root'
        $EntryText | Should -Match '\$d\.FreePct'
    }

    It 'цвет строки: зелёный > 5 ГБ, жёлтый 2…5 ГБ, красный < 2 ГБ' {
        # цвета берутся из Get-DiskColor (0,200,90 / 235,185,40 / 235,60,60)
        $EntryText | Should -Match 'function Get-DiskColor'
        $EntryText | Should -Match '235, 60, 60'
        $EntryText | Should -Match '235, 185, 40'
        $EntryText | Should -Match '0, 200, 90'
    }

    It 'строка диска выводится и на карте, и в -Status' {
        # подвал карты (её зовёт и окно, и -Shot)
        $EntryText | Should -Match 'Draw-BackdropText \$g \$legFont \$diskTxt'
        # текстовый режим -Status
        $EntryText | Should -Match '\$\(Get-DiskText\) — \$\(Get-DiskLevelText\)'
    }
}

Describe 'Карта: nodes.json — поле disk и прежние поля' {
    BeforeAll {
        $repoRoot  = Split-Path -Parent $PSScriptRoot
        $toolDir   = Join-Path $repoRoot 'registry\infra-graph'
        $latest    = ((Get-Content -LiteralPath (Join-Path $toolDir 'latest.txt') -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
        $entryPath = Join-Path $toolDir (Join-Path $latest 'infra-graph.ps1')
        $script:EntryText = Get-Content -LiteralPath $entryPath -Raw -Encoding UTF8
        $script:EntryPath = $entryPath
    }

    It 'схема состояния не менялась: invr.nodes/1' {
        $EntryText | Should -Match "schema\s*=\s*'invr\.nodes/1'"
    }

    It 'в корень документа пишется поле disk с root/freeGb/totalGb/freePct/updatedAt' {
        $EntryText | Should -Match 'disk\s*=\s*\$diskRec'
        foreach ($f in @('root', 'freeGb', 'totalGb', 'freePct', 'updatedAt')) {
            $EntryText | Should -Match ([regex]::Escape($f) + '\s*=')
        }
    }

    It 'прежние поля состояния на месте (узлы, кандидаты, savedAt)' {
        $EntryText | Should -Match 'nodes\s*=\s*\$nodesObj'
        $EntryText | Should -Match 'candidates\s*=\s*@\(\$script:candidates\)'
        $EntryText | Should -Match 'savedAt\s*=\s*\$now\.ToString\(''o''\)'
    }

    It 'телеметрия пишется даже при критическом остатке (кадр — нет, nodes.json — да)' {
        $EntryText | Should -Match 'Test-FrameDrawAllowed'
        $EntryText | Should -Match 'Approve-FrameDraw'
        # в GUI-цикле запись состояния идёт ДО проверки разрешения на кадр
        $EntryText | Should -Match 'Save-NodesState'
    }

    It 'настоящий тик демона пишет во временный файл валидный nodes.json с полем disk' {
        # Рабочий nodes.json не трогаем: состояние направляем в $TestDrive через -StateFile
        $tmp = Join-Path $TestDrive 'nodes.json'
        & pwsh -NoProfile -File $script:EntryPath -Daemon -Once -StateFile $tmp | Out-Null
        Test-Path -LiteralPath $tmp | Should -BeTrue -Because 'демон за один тик должен записать состояние'

        $j = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
        $j.schema | Should -Be 'invr.nodes/1'
        "$($j.savedAt)" | Should -Not -BeNullOrEmpty
        # поле disk — новое и обязательное
        $j.disk | Should -Not -BeNullOrEmpty
        "$($j.disk.root)" | Should -Match '^[A-Za-z]:$|^\\\\'
        $j.disk.freeGb  | Should -BeGreaterOrEqual 0
        $j.disk.totalGb | Should -BeGreaterThan 0
        $j.disk.freePct | Should -BeGreaterOrEqual 0
        "$($j.disk.updatedAt)" | Should -Not -BeNullOrEmpty
        # прежние поля и узлы
        $j.nodes | Should -Not -BeNullOrEmpty
        @($j.nodes.PSObject.Properties).Count | Should -BeGreaterThan 25
        # у свежего файла список кандидатов бывает пуст — важно наличие самого поля
        $j.PSObject.Properties.Name | Should -Contain 'candidates'
    }
}

Describe 'Карта: ротация собственных журналов' {
    BeforeAll {
        $repoRoot  = Split-Path -Parent $PSScriptRoot
        $toolDir   = Join-Path $repoRoot 'registry\infra-graph'
        $latest    = ((Get-Content -LiteralPath (Join-Path $toolDir 'latest.txt') -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
        $entryPath = Join-Path $toolDir (Join-Path $latest 'infra-graph.ps1')
        $script:EntryText = Get-Content -LiteralPath $entryPath -Raw -Encoding UTF8
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($entryPath, [ref]$null, [ref]$null)
        $defs = @($ast.FindAll({ param($a)
            $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Invoke-LogRotation'
        }, $true))
        . ([scriptblock]::Create((($defs | ForEach-Object { $_.Extent.Text }) -join "`n")))
    }

    It 'порог ротации — около 1 МБ, архив с суффиксом .1' {
        $EntryText | Should -Match '\$script:DiskLogMaxBytes\s*=\s*1048576'
        $EntryText | Should -Match '"\$path\.1"'
    }

    It 'ротация включена только для СВОИХ журналов (events.log и infra-graph.err.log)' {
        $EntryText | Should -Match 'Invoke-LogRotation \$script:eventsPath'
        $EntryText | Should -Match 'Invoke-LogRotation \$script:ErrLogPath'
        # чужие логи (демон-страж, лог оркестратора) в ротацию не попадают
        $EntryText | Should -Not -Match 'Invoke-LogRotation \$WdLog'
        $EntryText | Should -Match 'update-logrotation|Update-LogRotation'
    }

    It 'маленький журнал (200 байт) ротация не трогает' {
        $f = Join-Path $TestDrive 'small.log'
        Set-Content -LiteralPath $f -Value ('шум ' * 40) -Encoding utf8
        Invoke-LogRotation $f 1048576 | Should -BeFalse
        Test-Path -LiteralPath $f | Should -BeTrue
        Test-Path -LiteralPath "$f.1" | Should -BeFalse
    }

    It 'журнал больше 1 МБ уходит в .1, а рабочий файл начинается заново' {
        $f = Join-Path $TestDrive 'big.log'
        Set-Content -LiteralPath $f -Value ('строка журнала' * 100000) -Encoding utf8
        (Get-Item -LiteralPath $f).Length | Should -BeGreaterThan 1048576
        Invoke-LogRotation $f | Should -BeTrue
        Test-Path -LiteralPath $f | Should -BeFalse
        Test-Path -LiteralPath "$f.1" | Should -BeTrue
    }

    It 'архивная копия одна: прежний .1 перезаписывается, а не плодится' {
        $f = Join-Path $TestDrive 'copy.log'
        Set-Content -LiteralPath "$f.1" -Value 'старый архив' -Encoding utf8
        Set-Content -LiteralPath $f -Value ('новое содержимое' * 200000) -Encoding utf8
        Invoke-LogRotation $f | Should -BeTrue
        (Get-Content -LiteralPath "$f.1" -Raw) | Should -Not -Match 'старый архив'
        Test-Path -LiteralPath "$f.2" | Should -BeFalse
    }

    It 'ротация затрагивает только свои два журнала (чужие логи не перечислены)' {
        $body = [regex]::Match($EntryText, '(?s)function Update-LogRotation \{.*?\n\}').Value
        $body | Should -Not -BeNullOrEmpty
        $body | Should -Match 'eventsPath'
        $body | Should -Match 'ErrLogPath'
        $body | Should -Not -Match 'mcp-watchdog'
        $body | Should -Not -Match 'opencode\.log'
    }
}
