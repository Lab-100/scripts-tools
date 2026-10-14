<#
.SYNOPSIS
  Тесты целостности реестра инструментов INVR (Pester 5+/6).

.DESCRIPTION
  Реестр живёт по правилам: версия = каталог registry\<tool>\<version>,
  активная версия указана в registry\<tool>\latest.txt, состав версии описан
  в tool.json, а плоские шимы в корне проекта продолжают версии.

  Тесты проверяют именно ПРАВИЛА, а не поведение инструментов:

    1) индекс registry\_registry.json согласован с каталогами и latest.txt;
    2) у каждого инструмента есть непустой latest.txt на существующую
       версию с semver-именем;
    3) в каждой версии валиден tool.json (schema/name/version/entry) и
       существует файл entry;
    4) каждый плоский шим в корне ведёт к реально существующей версии;
    5) в публикуемом реестре нет машинных рабочих каталогов и pid-файлов.

  Запуск: pwsh -NoProfile -Command "Invoke-Pester -Path tests -CI"
  Требуется Pester >= 5.5.0.

  Устройство (важно для Pester 5+):
    * списки для -ForEach собираются в фазе ОБНАРУЖЕНИЯ (BeforeDiscovery),
      потому что к моменту -ForEach блоки BeforeAll ещё не выполнялись;
    * общие величины для фазы прогона считаются заново в BeforeAll;
    * $PSScriptRoot доступен и в BeforeDiscovery, и в BeforeAll.
#>

BeforeDiscovery {
    $repoRoot     = Split-Path -Parent $PSScriptRoot
    $registryRoot = Join-Path $repoRoot 'registry'

    $toolDirs = @(
        Get-ChildItem -LiteralPath $registryRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object {
                $latestFile = Join-Path $_.FullName 'latest.txt'
                $latest = if (Test-Path -LiteralPath $latestFile) {
                    ((Get-Content -LiteralPath $latestFile -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
                }
                else { $null }

                [ordered]@{
                    Name       = $_.Name
                    Dir        = $_.FullName
                    LatestFile = $latestFile
                    Latest     = $latest
                    Versions   = @(Get-ChildItem -LiteralPath $_.FullName -Directory | ForEach-Object { $_.Name })
                }
            }
    )

    $shims = @(
        Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $text = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
                if ($text -match "(?m)^\s*\`$tool\s*=\s*'([^']+)'") {
                    $toolName  = $Matches[1]
                    $entryName = if ($text -match "(?m)^\s*\`$entry\s*=\s*'([^']+)'") { $Matches[1] } else { '' }
                    [ordered]@{ Shim = $_.Name; Tool = $toolName; Entry = $entryName }
                }
            }
    )
}

Describe 'Реестр: индекс _registry.json' {
    BeforeAll {
        $registryRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'registry'
        $index = Get-Content -LiteralPath (Join-Path $registryRoot '_registry.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $semver = '^\d+\.\d+\.\d+$'
    }

    It 'схема индекса — invr.registry/1' {
        $index.schema | Should -Be 'invr.registry/1'
    }

    It 'в индексе есть записи об инструментах' {
        @($index.tools).Count | Should -BeGreaterThan 0
    }

    It 'все каталоги реестра описаны в индексе' {
        $known  = @($index.tools | ForEach-Object { $_.name })
        $dirs   = @(Get-ChildItem -LiteralPath $registryRoot -Directory | ForEach-Object { $_.Name })
        $absent = @($dirs | Where-Object { $_ -notin $known })
        $absent | Should -BeNullOrEmpty -Because ("нет в _registry.json: " + ($absent -join ', '))
    }

    It 'latest в индексе совпадает с latest.txt инструмента <Name>' -ForEach $toolDirs {
        $entry = @($index.tools | Where-Object { $_.name -eq $Name })
        $entry.Count | Should -Be 1 -Because "инструмент $Name должен быть описан ровно один раз"
        $entry[0].latest | Should -Be $Latest
    }
}

Describe 'Реестр: версии инструментов' {
    BeforeAll {
        $registryRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'registry'
        $semver = '^\d+\.\d+\.\d+$'
    }

    It 'у инструмента <Name> есть непустой latest.txt с semver' -ForEach $toolDirs {
        Test-Path -LiteralPath $LatestFile | Should -BeTrue -Because "нет файла $LatestFile"
        $Latest | Should -Match $semver
    }

    It 'latest.txt инструмента <Name> указывает на существующую версию' -ForEach $toolDirs {
        $versionDir = Join-Path $Dir $Latest
        Test-Path -LiteralPath $versionDir -PathType Container | Should -BeTrue -Because "нет каталога $versionDir"
    }

    It 'имена версий инструмента <Name> — semver' -ForEach $toolDirs {
        $bad = @($Versions | Where-Object { $_ -notmatch $semver })
        $bad | Should -BeNullOrEmpty -Because ("не semver: " + ($bad -join ', '))
    }

    It 'tool.json версии <Name> <Latest> валиден и entry существует' -ForEach $toolDirs {
        $versionDir = Join-Path $Dir $Latest
        $toolJson   = Join-Path $versionDir 'tool.json'
        Test-Path -LiteralPath $toolJson | Should -BeTrue -Because "нет $toolJson"

        $meta = Get-Content -LiteralPath $toolJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $meta.schema  | Should -Be 'invr.tool/1'
        $meta.name    | Should -Be $Name
        $meta.version | Should -Be $Latest
        $meta.entry   | Should -Not -BeNullOrEmpty

        $entryPath = Join-Path $versionDir $meta.entry
        Test-Path -LiteralPath $entryPath | Should -BeTrue -Because "нет файла entry: $entryPath"
    }
}

Describe 'Шимы корня проекта' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $registryRoot = Join-Path $repoRoot 'registry'
        $shimFiles = @(
            Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -File |
                ForEach-Object {
                    $text = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
                    if ($text -match "(?m)^\s*\`$tool\s*=\s*'([^']+)'") {
                        [ordered]@{ Shim = $_.Name; Tool = $Matches[1] }
                    }
                }
        )
    }

    It 'в корне есть шимы (автоген локера)' {
        $shimFiles.Count | Should -BeGreaterThan 0
    }

    It 'шим <Shim> ведёт к существующему инструменту <Tool>' -ForEach $shims {
        $toolLatestFile = Join-Path $registryRoot (Join-Path $Tool 'latest.txt')
        Test-Path -LiteralPath $toolLatestFile | Should -BeTrue -Because "шим ссылается на неизвестный инструмент: $Tool"

        $version = ((Get-Content -LiteralPath $toolLatestFile -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
        $version | Should -Match '^\d+\.\d+\.\d+$'

        $Entry | Should -Not -BeNullOrEmpty -Because 'в шиме не найден $entry'
        $target = Join-Path $registryRoot (Join-Path $Tool (Join-Path $version $Entry))
        Test-Path -LiteralPath $target | Should -BeTrue -Because "нет файла entry: $target"
    }
}

Describe 'Публикуемая чистота реестра' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $registryRoot = Join-Path $repoRoot 'registry'
    }

    It 'в реестре нет машинных рабочих каталогов (state/logs/requests)' {
        $leaks = @(
            Get-ChildItem -LiteralPath $registryRoot -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @('state', 'logs', 'requests') } |
                ForEach-Object { $_.FullName.Replace($repoRoot, '.') }
        )
        $leaks | Should -BeNullOrEmpty -Because ("попали рабочие каталоги: " + ($leaks -join ', '))
    }

    It 'в реестре нет pid-файлов' {
        $pids = @(
            Get-ChildItem -LiteralPath $registryRoot -Filter '*.pid' -File -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName.Replace($repoRoot, '.') }
        )
        $pids | Should -BeNullOrEmpty -Because ("попали pid-файлы: " + ($pids -join ', '))
    }
}
