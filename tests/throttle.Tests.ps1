<#
.SYNOPSIS
    Тесты троттлинга ресурсов локальных моделей (Pester 5+/6).

.DESCRIPTION
    Проверяется ЧИСТОЕ правило выгрузки из throttle-lib.ps1 активной версии
    mcp-watchdog (версия берётся из registry\mcp-watchdog\latest.txt, поэтому
    тест идёт за актуальной версией реестра).

    Что здесь проверяется — ровно то требование владельца: пока работает
    локальная модель, свободной памяти должно оставаться не меньше 10%, а
    загрузка процессора — не выше 85%. Плюс три страховки, без которых это
    требование вредно: гистерезис (порог возврата к норме), минимальный
    интервал между выгрузками (антидребезг) и режим report (только наблюдение).

    Ни Ollama, ни HTTP, ни процессы в тестах не трогаются: решение
    вычисляется из чисел.

    Запуск: pwsh -NoProfile -Command "Invoke-Pester -Path tests -CI"
#>

BeforeDiscovery {
    $repoRoot    = Split-Path -Parent $PSScriptRoot
    $registryRoot = Join-Path $repoRoot 'registry'
    $toolDir     = Join-Path $registryRoot 'mcp-watchdog'
    $latestFile  = Join-Path $toolDir 'latest.txt'
    $latest      = ((Get-Content -LiteralPath $latestFile -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
    $versionDir  = Join-Path $toolDir $latest
    $libFile     = Join-Path $versionDir 'throttle-lib.ps1'
    $daemonFile  = Join-Path $versionDir 'mcp-watchdog.ps1'
}

Describe 'Троттлинг: библиотека активной версии на месте' {
    BeforeAll {
        $repoRoot    = Split-Path -Parent $PSScriptRoot
        $registryRoot = Join-Path $repoRoot 'registry'
        $toolDir     = Join-Path $registryRoot 'mcp-watchdog'
        $latest      = ((Get-Content -LiteralPath (Join-Path $toolDir 'latest.txt') -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
        $versionDir  = Join-Path $toolDir $latest
    }

    It 'в активной версии mcp-watchdog <Latest> есть throttle-lib.ps1' {
        Test-Path -LiteralPath (Join-Path $versionDir 'throttle-lib.ps1') | Should -BeTrue
    }

    It 'демон активной версии подключает throttle-lib.ps1' {
        $text = Get-Content -LiteralPath (Join-Path $versionDir 'mcp-watchdog.ps1') -Raw -Encoding UTF8
        $text | Should -Match 'throttle-lib\.ps1'
        $text | Should -Match 'Invoke-ResourceThrottle'
    }

    It 'пороги владельца стоят по умолчанию: память 10%, процессор 85%' {
        $text = Get-Content -LiteralPath (Join-Path $versionDir 'mcp-watchdog.ps1') -Raw -Encoding UTF8
        $text | Should -Match '\$ThrottleMinFreeMemPct\s*=\s*10\b'
        $text | Should -Match '\$ThrottleMaxCpuPct\s*=\s*85\b'
    }
}

Describe 'Троттлинг: правило выгрузки моделей' {
    BeforeAll {
        $repoRoot    = Split-Path -Parent $PSScriptRoot
        $registryRoot = Join-Path $repoRoot 'registry'
        $toolDir     = Join-Path $registryRoot 'mcp-watchdog'
        $latest      = ((Get-Content -LiteralPath (Join-Path $toolDir 'latest.txt') -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
        . (Join-Path $toolDir (Join-Path $latest 'throttle-lib.ps1'))
        $models = @('qwen2.5:3b')
        $t0     = [datetime]'2026-10-16T12:00:00'
    }

    It 'метрики в норме — ничего не выгружаем' {
        $d = Get-InvrThrottleDecision -FreeMemPct 42 -CpuPct 30 -LoadedModels $models -Now $t0
        $d.action | Should -Be 'none'
        $d.breach  | Should -BeNullOrEmpty
    }

    It 'ровно 10% свободной памяти — ещё норма (порог включительно)' {
        $d = Get-InvrThrottleDecision -FreeMemPct 10 -CpuPct 30 -LoadedModels $models -Now $t0
        $d.action | Should -Be 'none'
    }

    It 'ровно 85% процессора — ещё норма (порог включительно)' {
        $d = Get-InvrThrottleDecision -FreeMemPct 40 -CpuPct 85 -LoadedModels $models -Now $t0
        $d.action | Should -Be 'none'
    }

    It 'свободной памяти меньше 10% — выгружаем модель' {
        $d = Get-InvrThrottleDecision -FreeMemPct 4.1 -CpuPct 30 -LoadedModels $models -Now $t0
        $d.action | Should -Be 'unload'
        $d.breach  | Should -Not -BeNullOrEmpty
        $d.models  | Should -Contain 'qwen2.5:3b'
    }

    It 'процессор выше 85% — выгружаем модель' {
        $d = Get-InvrThrottleDecision -FreeMemPct 40 -CpuPct 99 -LoadedModels $models -Now $t0
        $d.action | Should -Be 'unload'
    }

    It 'обе метрики в норме, но ни одна модель не загружена — выгружать нечего' {
        $d = Get-InvrThrottleDecision -FreeMemPct 4 -CpuPct 99 -LoadedModels @() -Now $t0
        $d.action | Should -Be 'none'
        $d.reason | Should -Match 'не загружена'
    }

    It 'недоступная метрика (-1) не считается нарушением' {
        $d = Get-InvrThrottleDecision -FreeMemPct -1 -CpuPct -1 -LoadedModels $models -Now $t0
        $d.action  | Should -Be 'none'
        $d.breach  | Should -BeNullOrEmpty
    }

    It 'режим report только сообщает, но не выгружает' {
        $d = Get-InvrThrottleDecision -FreeMemPct 4 -CpuPct 99 -LoadedModels $models -Mode report -Now $t0
        $d.action | Should -Be 'report'
        $d.reason | Should -Match 'report'
    }
}

Describe 'Троттлинг: защита от раскачки' {
    BeforeAll {
        $repoRoot    = Split-Path -Parent $PSScriptRoot
        $registryRoot = Join-Path $repoRoot 'registry'
        $toolDir     = Join-Path $registryRoot 'mcp-watchdog'
        $latest      = ((Get-Content -LiteralPath (Join-Path $toolDir 'latest.txt') -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
        . (Join-Path $toolDir (Join-Path $latest 'throttle-lib.ps1'))
        $models = @('qwen2.5:3b')
        $t0     = [datetime]'2026-10-16T12:00:00'
    }

    It 'выгрузка недавно была — ждём минимальный интервал' {
        $d = Get-InvrThrottleDecision -FreeMemPct 4 -CpuPct 30 -LoadedModels $models `
            -MinGapSec 120 -LastActionAt $t0.AddSeconds(-30) -Now $t0
        $d.action | Should -Be 'skip-gap'
        $d.reason | Should -Match 'антидребезг'
    }

    It 'интервал прошёл — снова выгружаем' {
        $d = Get-InvrThrottleDecision -FreeMemPct 4 -CpuPct 30 -LoadedModels $models `
            -MinGapSec 120 -LastActionAt $t0.AddSeconds(-300) -Now $t0
        $d.action | Should -Be 'unload'
    }

    It 'первой выгрузки ещё не было — антидребезг не мешает' {
        $d = Get-InvrThrottleDecision -FreeMemPct 4 -CpuPct 30 -LoadedModels $models `
            -MinGapSec 120 -LastActionAt ([datetime]::MinValue) -Now $t0
        $d.action | Should -Be 'unload'
    }

    It 'после восстановления (память выше порога возврата) нарушение считается снятым' {
        $recovered = Get-InvrThrottleDecision -FreeMemPct 22 -CpuPct 40 -LoadedModels $models -Now $t0
        $recovered.recovered | Should -BeTrue

        $notYet = Get-InvrThrottleDecision -FreeMemPct 12 -CpuPct 40 -LoadedModels $models -Now $t0
        $notYet.recovered | Should -BeFalse
    }

    It 'пороги владельца соблюдаются и при явном нарушении обоих порогов' {
        $d = Get-InvrThrottleDecision -FreeMemPct 3 -CpuPct 97 -LoadedModels $models -Now $t0
        $d.action    | Should -Be 'unload'
        $d.breach.Count | Should -Be 2
    }
}