<#
.SYNOPSIS
    Тесты безопасной зачистки лишних процессов (mcp-watchdog 0.7.0, Pester 5+/6).

.DESCRIPTION
    Проверяется ЧИСТОЕ правило зачистки из reap-lib.ps1 активной версии
    mcp-watchdog (версия берётся из registry\mcp-watchdog\latest.txt) и
    интеграция библиотеки в демон.

    Требование владельца: лишние процессы память занимают, но не нужны;
    нужные нужны всегда. Поэтому механизм обязан:
      * в режиме report НИЧЕГО не закрывать — только публиковать кандидатов;
      * закрывать только детерминированно безопасный класс 0 (сироты-обёртки
        conhost/uv/uvx без окна и дубли-обёртки), не более 3 за проход;
      * уважать антидребезг и часовой лимит;
      * никогда не трогать защищённое (ядро, агенты, IDE, базы, docker);
      * без метрики памяти или без снимка процессов — бездействовать.

    Ни один живой процесс в тестах не трогается: снимки процессов выдуманные,
    решение вычисляется из чисел и структур.

    Запуск: pwsh -NoProfile -Command "Invoke-Pester -Path tests -CI"
#>

BeforeDiscovery {
    $repoRoot     = Split-Path -Parent $PSScriptRoot
    $registryRoot = Join-Path $repoRoot 'registry'
    $toolDir      = Join-Path $registryRoot 'mcp-watchdog'
    $latest       = ((Get-Content -LiteralPath (Join-Path $toolDir 'latest.txt') -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
    $versionDir   = Join-Path $toolDir $latest
}

Describe 'Зачистка: библиотека и политика активной версии' {
    BeforeAll {
        $repoRoot     = Split-Path -Parent $PSScriptRoot
        $toolDir      = Join-Path (Join-Path $repoRoot 'registry') 'mcp-watchdog'
        $latest       = ((Get-Content -LiteralPath (Join-Path $toolDir 'latest.txt') -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
        $versionDir   = Join-Path $toolDir $latest
        . (Join-Path $versionDir 'reap-lib.ps1')
    }

    It 'в активной версии mcp-watchdog <Latest> есть reap-lib.ps1' {
        Test-Path -LiteralPath (Join-Path $versionDir 'reap-lib.ps1') | Should -BeTrue
    }

    It 'демон подключает reap-lib.ps1 и вызывает проход зачистки' {
        $text = Get-Content -LiteralPath (Join-Path $versionDir 'mcp-watchdog.ps1') -Raw -Encoding UTF8
        $text | Should -Match 'reap-lib\.ps1'
        $text | Should -Match 'function Invoke-ReapPass'
        $text | Should -Match '\$script:reapLastPass\s*=\s*Invoke-ReapPass'   # вызов в основном цикле
    }

    It 'пороги владельца стоят по умолчанию: память 10%, отбой 15%, антидребезг 300 с' {
        $d = Get-InvrReapDefaults
        $d.minFreePct        | Should -Be 10.0
        $d.resumeFreePct     | Should -Be 15.0
        $d.minGapSec         | Should -Be 300
        $d.maxActionsPerPass | Should -Be 3
    }

    It 'режим по умолчанию — report (ничего не закрывается без решения владельца)' {
        (Get-InvrReapDefaults).mode | Should -Be 'report'
        (Get-InvrReapPolicy).mode   | Should -Be 'report'
    }

    It 'файл config\reap-policy.json версии <Latest> реально читается (ключи startPct/throttle)' {
        # Файл политики называет пороги короче (memory.startPct, throttle.maxActionsPerRun).
        # Пока библиотека знала только длинные имена, файл молча игнорировался целиком.
        $file = Join-Path $versionDir 'config\reap-policy.json'
        Test-Path -LiteralPath $file | Should -BeTrue
        $p = Get-InvrReapPolicy -Path $file
        $p.source      | Should -Match 'reap-policy\.json'
        $p.minFreePct  | Should -Be 10.0
        $p.minGapSec   | Should -Be 300
        $p.maxActionsPerPass | Should -Be 3
    }

    It 'параметры командной строки главнее файла политики' {
        $file = Join-Path $versionDir 'config\reap-policy.json'
        $p = Get-InvrReapPolicy -Path $file -Override @{ minGapSec = 45; mode = 'enforce' }
        $p.minGapSec | Should -Be 45
        $p.mode      | Should -Be 'enforce'
    }
}

Describe 'Зачистка: правило решения' {
    BeforeAll {
        $repoRoot   = Split-Path -Parent $PSScriptRoot
        $toolDir    = Join-Path (Join-Path $repoRoot 'registry') 'mcp-watchdog'
        $latest     = ((Get-Content -LiteralPath (Join-Path $toolDir 'latest.txt') -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
        . (Join-Path $toolDir (Join-Path $latest 'reap-lib.ps1'))
        $script:now = [datetime]'2026-10-23T00:00:00'
        $script:pol = Get-InvrReapPolicy

        # выдуманный снимок: пять conhost-сирот (родитель 999 отсутствует = мёртв)
        $snap = @(); $prev = @()
        foreach ($i in 1..5) {
            $snap += [pscustomobject]@{ Pid = (100 + $i); ParentPid = 999; Name = 'conhost.exe'; Mb = (10.0 + $i); CpuSec = 2.0; CreatedAt = $script:now.AddHours(-3); CommandLine = 'conhost.exe 0x4'; MainWindowHandle = 0 }
            $prev += [pscustomobject]@{ Pid = (100 + $i); ParentPid = 999; Name = 'conhost.exe'; Mb = (10.0 + $i); CpuSec = 1.9; CreatedAt = $script:now.AddHours(-3); CommandLine = 'conhost.exe 0x4'; MainWindowHandle = 0 }
        }
        $script:groups = @(Get-InvrProcessGroups -Snapshot $snap -PrevSnapshot $prev)
    }

    It 'сироты conhost без окна собраны в группы с признаком сироты' {
        @($script:groups).Count | Should -BeGreaterThan 0
        @($script:groups)[0].OrphanCount | Should -Be 5
    }

    It 'память в норме — решение none (ничего не делаем)' {
        $d = Get-InvrReapDecision -Groups $script:groups -FreeMemPct 40 -FreeMemMb 3000 -TotalMemMb 8100 -ProcCount 5 -Policy $script:pol -Mode enforce -Now $script:now
        $d.decision | Should -Be 'none'
        $d.breached | Should -BeFalse
    }

    It 'без метрики памяти — бездействие (безопасный инвариант)' {
        $d = Get-InvrReapDecision -Groups $script:groups -FreeMemPct -1 -FreeMemMb -1 -ProcCount 5 -Policy $script:pol -Mode enforce -Now $script:now
        $d.decision | Should -Be 'none'
        $d.metricsOk | Should -BeFalse
    }

    It 'без групп процессов — бездействие (снимок не собрался)' {
        $d = Get-InvrReapDecision -Groups @() -FreeMemPct 3 -FreeMemMb 200 -ProcCount -1 -Policy $script:pol -Mode enforce -Now $script:now
        $d.decision | Should -Be 'none'
        $d.metricsOk | Should -BeFalse
    }

    It 'режим report публикует кандидатов, но НИ ОДНОГО не помечает к закрытию' {
        $d = Get-InvrReapDecision -Groups $script:groups -FreeMemPct 4 -FreeMemMb 300 -TotalMemMb 8100 -ProcCount 5 -Policy $script:pol -Mode report -Now $script:now
        $d.decision | Should -Be 'report'
        $d.reason   | Should -Match 'report'
        @($d.safe).Count | Should -Be 5
        @($d.safe | Where-Object { $_.action -eq 'close' }).Count | Should -Be 0
    }

    It 'enforce закрывает только класс 0 и не более 3 за проход' {
        $d = Get-InvrReapDecision -Groups $script:groups -FreeMemPct 4 -FreeMemMb 300 -TotalMemMb 8100 -ProcCount 5 -Policy $script:pol -Mode enforce -Now $script:now
        $d.decision | Should -Be 'enforce'
        $close = @($d.safe | Where-Object { $_.action -eq 'close' })
        $close.Count | Should -BeLessOrEqual 3
        $close.Count | Should -Be 3
        @($close | Where-Object { $_.class -ne 0 }).Count | Should -Be 0
        @($close | Where-Object { $_.rule -notin @('orphan','uv-nochild','dup-wrapper','conhost-idle') }).Count | Should -Be 0
    }

    It 'антидребезг: после недавнего закрытия проход пропускается' {
        $d = Get-InvrReapDecision -Groups $script:groups -FreeMemPct 4 -FreeMemMb 300 -ProcCount 5 -Policy $script:pol -Mode enforce -LastActionAt $script:now.AddSeconds(-30) -Now $script:now
        $d.decision | Should -Be 'skip-gap'
        $d.reason   | Should -Match 'антидребезг'
    }

    It 'антидребезг: интервал прошёл — закрытие снова разрешено' {
        $d = Get-InvrReapDecision -Groups $script:groups -FreeMemPct 4 -FreeMemMb 300 -ProcCount 5 -Policy $script:pol -Mode enforce -LastActionAt $script:now.AddSeconds(-400) -Now $script:now
        $d.decision | Should -Be 'enforce'
    }

    It 'часовой лимит: лимит исчерпан — проход пропускается' {
        $d = Get-InvrReapDecision -Groups $script:groups -FreeMemPct 4 -FreeMemMb 300 -ProcCount 5 -Policy $script:pol -Mode enforce -ActionsLastHour 10 -Now $script:now
        $d.decision | Should -Be 'skip-limits'
    }

    It 'защищённое не закрывается: ядро, агент, docker' {
        $snap = @(
            [pscustomobject]@{ Pid = 501; ParentPid = 999; Name = 'opencode.exe'; Mb = 500.0; CpuSec = 5.0; CreatedAt = $script:now.AddHours(-5); CommandLine = 'opencode.exe serve'; MainWindowHandle = 0 },
            [pscustomobject]@{ Pid = 502; ParentPid = 999; Name = 'docker.exe'; Mb = 200.0; CpuSec = 5.0; CreatedAt = $script:now.AddHours(-5); CommandLine = 'docker.exe ps'; MainWindowHandle = 0 },
            [pscustomobject]@{ Pid = 503; ParentPid = 999; Name = 'pwsh.exe'; Mb = 90.0; CpuSec = 5.0; CreatedAt = $script:now.AddHours(-5); CommandLine = 'pwsh.exe -File mcp-watchdog.ps1'; MainWindowHandle = 0 }
        )
        $prev = @($snap | ForEach-Object { [pscustomobject]@{ Pid = $_.Pid; ParentPid = $_.ParentPid; Name = $_.Name; Mb = $_.Mb; CpuSec = 4.0; CreatedAt = $_.CreatedAt; CommandLine = $_.CommandLine; MainWindowHandle = 0 } })
        $g = @(Get-InvrProcessGroups -Snapshot $snap -PrevSnapshot $prev)
        $d = Get-InvrReapDecision -Groups $g -FreeMemPct 4 -FreeMemMb 300 -ProcCount 3 -Policy $script:pol -Mode enforce -Now $script:now
        @($d.safe | Where-Object { $_.action -eq 'close' }).Count | Should -Be 0
        $d.protectedSkipped | Should -Be 3
    }

    It 'PID самой программы защищён (свой процесс закрывать нельзя)' {
        Test-InvrProtectedProcess -Process ([pscustomobject]@{ Pid = 777; ParentPid = 999; Name = 'conhost.exe'; CommandLine = 'conhost.exe 0x4'; MainWindowHandle = 0 }) `
            -Policy $script:pol -ProtectedPids @(777) -AllProcesses @() | Should -BeTrue
    }
}

Describe 'Зачистка: интеграция с демоном (0.7.0)' {
    BeforeAll {
        $repoRoot   = Split-Path -Parent $PSScriptRoot
        $toolDir    = Join-Path (Join-Path $repoRoot 'registry') 'mcp-watchdog'
        $latest     = ((Get-Content -LiteralPath (Join-Path $toolDir 'latest.txt') -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
        $versionDir = Join-Path $toolDir $latest
        $script:daemon = Get-Content -LiteralPath (Join-Path $versionDir 'mcp-watchdog.ps1') -Raw -Encoding UTF8
    }

    It 'параметры зачистки присутствуют, режим по умолчанию report' {
        $script:daemon | Should -Match '\[ValidateSet\(''enforce'',''report''\)\]'
        $script:daemon | Should -Match '\$ReapMode\s*=\s*''report'''
        $script:daemon | Should -Match '\$ReapMinGapSec\s*=\s*300'
        $script:daemon | Should -Match '\$ReapOnce'
        $script:daemon | Should -Match '\$ReapPolicyPath'
    }

    It 'разовый проход: -ReapOnce не берёт блокировку демона и не пишет pid-файл' {
        $script:daemon | Should -Match 'if \(-not \$Once -and -not \$ReapOnce -and -not \(Enter-DaemonLock\)\)'
        $script:daemon | Should -Match 'if \(-not \$Once -and -not \$ReapOnce\) \{ Set-Content -LiteralPath \$PidFile'
    }

    It 'сводка current.json: schemaVersion 0.7.0 и разделы memory/reap' {
        $script:daemon | Should -Match "schemaVersion\s*=\s*'0\.7\.0'"
        $script:daemon | Should -Match 'memory\s*=\s*\$script:memoryReport'
        $script:daemon | Should -Match 'reap\s*=\s*\$script:reapReport'
        $script:daemon | Should -Match "model\s*=\s*'0\.7\.0'"
        $script:daemon | Should -Not -Match "model\s*=\s*'0\.6\.5'"
    }

    It 'раздел memory публикует freeMb/totalMb/freePct/procCount/orphanCount/topGroups' {
        foreach ($key in 'freeMb','totalMb','freePct','procCount','orphanCount','topGroups') {
            $script:daemon | Should -Match "\b$key\b" -Because "раздел memory должен содержать $key"
        }
    }

    It 'раздел reap публикует mode/decision/breached/reason/killed/lastActionAt/пороги' {
        foreach ($key in 'mode','decision','breached','reason','suggested','killed','lastActionAt','minFreePct','resumeFreePct') {
            $script:daemon | Should -Match "\b$key\b" -Because "раздел reap должен содержать $key"
        }
    }

    It 'журнал закрытий: state\killed.jsonl, только дописывание, запись ДО закрытия' {
        $script:daemon | Should -Match 'killed\.jsonl'
        $script:daemon | Should -Match 'AppendAllText'
        # запись журнала вызывается внутри Close-InvrReapCandidate раньше Stop-Process
        $body = [regex]::Match($script:daemon, 'function Close-InvrReapCandidate \{[\s\S]*?\n\}').Value
        $body | Should -Not -BeNullOrEmpty
        # докстроки и комментарии убираем: в них тоже упоминается Stop-Process
        $body = [regex]::Replace($body, '(?s)<#.*?#>', '')
        $code = (@($body -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $iRecord = $code.IndexOf('Write-ReapKillRecord')
        $iStop   = $code.IndexOf('Stop-Process')
        $iRecord | Should -BeGreaterOrEqual 0
        $iStop   | Should -BeGreaterThan $iRecord
    }

    It 'мягкое закрытие: CloseMainWindow → Stop-Process → Stop-Process -Force' {
        $body = [regex]::Match($script:daemon, 'function Close-InvrReapCandidate \{[\s\S]*?\n\}').Value
        $iWin   = $body.IndexOf('CloseMainWindow')
        $iSoft  = $body.IndexOf('Stop-Process -Id $procId -ErrorAction Stop')
        $iForce = $body.IndexOf('Stop-Process -Id $procId -Force')
        $iWin   | Should -BeGreaterOrEqual 0
        $iSoft  | Should -BeGreaterThan $iWin
        $iForce | Should -BeGreaterThan $iSoft
    }

    It 'демон ограничивает проход тремя закрытиями и перепроверяет защиту' {
        $body = [regex]::Match($script:daemon, 'function Invoke-ReapPass \{[\s\S]*?\n\}').Value
        $body | Should -Match '\$limit\s*=\s*3'
        $body | Should -Match 'Test-InvrProtectedProcess'
        $body | Should -Match 'killed\.Count -ge \$limit'
    }

    It 'антидребезг и часовой лимит считаются по журналу закрытий (переживают перезапуск)' {
        $script:daemon | Should -Match 'function Get-ReapActionHistory'
        $body = [regex]::Match($script:daemon, 'function Get-ReapActionHistory \{[\s\S]*?\n\}').Value
        $body | Should -Match 'AddHours\(-1\)'
        $body | Should -Match 'actionsLastHour'
    }
}
