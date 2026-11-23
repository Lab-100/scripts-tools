#Requires -Version 7
<#
Проверка исправления EXDEV в janitor 0.1.2: перенос в карантин на другом диске
и обратное восстановление. Тест создаёт только собственные временные файлы.

RU: проверка переноса между дисками; EN: cross-volume transfer check.
#>

Describe 'janitor: перенос между томами (EXDEV)' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $registryDir = Join-Path $repoRoot 'registry\janitor'
        $version = (Get-Content -LiteralPath (Join-Path $registryDir 'latest.txt') -Raw).Trim()
        $toolDir = Join-Path $registryDir $version
        $script:janitorPath = Join-Path $toolDir 'janitor.mjs'

        $nodeExe = 'C:\Program Files\nodejs\node.exe'
        if (-not (Test-Path -LiteralPath $nodeExe)) {
            $cmd = Get-Command 'node' -ErrorAction SilentlyContinue
            if ($cmd) { $nodeExe = $cmd.Source } else { $nodeExe = 'node' }
        }
        $script:nodeExe = $nodeExe
        $script:InvokeJanitor = {
            param([string[]]$JanitorArgs)
            $raw = & $script:nodeExe $script:janitorPath @JanitorArgs 2>&1 | Out-String
            $line = $raw -split "`r?`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1
            if (-not $line) { throw "janitor не вернул JSON: $raw" }
            return ($line | ConvertFrom-Json)
        }

        $script:skipReason = $null
        $systemDrive = ($env:SystemDrive -replace ':', '').ToUpperInvariant()
        $other = Get-PSDrive -PSProvider FileSystem |
            Where-Object { $_.Name.ToUpperInvariant() -ne $systemDrive -and $_.Free -gt 10MB } |
            Select-Object -First 1
        if (-not $other) {
            $script:skipReason = 'нет второго диска с свободным местом'
        }

        $marker = 'janitor-cvtest-' + [guid]::NewGuid().ToString('N')
        $script:srcDir = Join-Path ([System.IO.Path]::GetTempPath()) $marker
        $script:hostDir = if ($other) { Join-Path ($other.Name + ':\') ('janitor-tests\' + $marker) } else { $null }
        $script:runDir = if ($script:hostDir) { Join-Path $script:hostDir 'janitor' } else { $null }
        $script:probePath = Join-Path $script:srcDir 'probe.cvprobe'

        if ($script:runDir) {
            New-Item -ItemType Directory -Path $script:srcDir -Force | Out-Null
            New-Item -ItemType Directory -Path $script:runDir -Force | Out-Null
            Copy-Item -Path (Join-Path $toolDir '*') -Destination $script:runDir -Recurse -Force
            # janitor читает config.json из своего каталога — запускаем копию на E:.
            $script:janitorPath = Join-Path $script:runDir 'janitor.mjs'
            Set-Content -LiteralPath $script:probePath -Value ('x' * 4096) -Encoding ascii
            $script:WriteConfig = {
                param([bool]$CrossVolume)
                @{
                    schema          = 'janitor.config/1'
                    dryRun          = $false
                    crossVolumeCopy = $CrossVolume
                    refs            = @{ etw = $false }
                    roots           = @($script:srcDir)
                    protect         = @()
                    windowDays      = 30
                    decay           = 0.9
                    theta           = 10
                    quarantineDays  = 30
                    minAgeMinutes   = 0
                    intervalMin     = 60
                    autoStart       = $false
                } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:runDir 'config.json') -Encoding utf8
                @{
                    schema = 'janitor.rules/1'
                    rules  = @(@{ id = 'cv-probe'; glob = '**/*.cvprobe'; kind = 'temp'; minAgeMin = 0 })
                } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:runDir 'rules.json') -Encoding utf8
            }
            & $script:WriteConfig -CrossVolume $true
        }
    }

    AfterAll {
        if ($script:srcDir -and (Test-Path -LiteralPath $script:srcDir)) {
            Remove-Item -LiteralPath $script:srcDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:hostDir -and (Test-Path -LiteralPath $script:hostDir)) {
            Remove-Item -LiteralPath $script:hostDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'переносит файл на другой диск и возвращает его командой restore' {
        if ($script:skipReason) { Set-ItResult -Skipped -Because $script:skipReason; return }

        $originalSize = (Get-Item -LiteralPath $script:probePath).Length
        $scan = & $script:InvokeJanitor @('scan', '--json')
        $scan.ok | Should -BeTrue
        $scan.data.summary.cand | Should -Be 1

        $clean = & $script:InvokeJanitor @('clean', '--yes', '--json')
        $clean.ok | Should -BeTrue
        $clean.data.moved | Should -Be 1
        $clean.data.crossVolumeMoved | Should -Be 1
        $clean.data.movedFiles[0].transport | Should -Be 'copy-delete'
        Test-Path -LiteralPath $script:probePath | Should -BeFalse

        $quarantined = $clean.data.movedFiles[0].dst -replace '/', '\'
        Test-Path -LiteralPath $quarantined | Should -BeTrue
        (Get-Item -LiteralPath $quarantined).Length | Should -Be $originalSize

        $restored = & $script:InvokeJanitor @('restore', $clean.data.movedFiles[0].id, '--yes', '--json')
        $restored.ok | Should -BeTrue
        $restored.data.restored | Should -BeTrue
        $restored.data.transport | Should -Be 'copy-delete'
        Test-Path -LiteralPath $script:probePath | Should -BeTrue
        (Get-Item -LiteralPath $script:probePath).Length | Should -Be $originalSize
    }

    It 'при crossVolumeCopy=false пропускает файл с ошибкой EXDEV' {
        if ($script:skipReason) { Set-ItResult -Skipped -Because $script:skipReason; return }
        if (Test-Path -LiteralPath $script:probePath) {
            Remove-Item -LiteralPath $script:probePath -Force
        }
        Set-Content -LiteralPath $script:probePath -Value ('y' * 2048) -Encoding ascii
        & $script:WriteConfig -CrossVolume $false

        $clean = & $script:InvokeJanitor @('clean', '--yes', '--json')
        $clean.ok | Should -BeTrue
        $clean.data.moved | Should -Be 0
        $clean.data.skipped | Should -Be 1
        Test-Path -LiteralPath $script:probePath | Should -BeTrue

        $log = Get-Content -LiteralPath (Join-Path $script:runDir 'actions.jsonl') -Raw -Encoding utf8
        $log | Should -Match 'EXDEV'
    }
}
