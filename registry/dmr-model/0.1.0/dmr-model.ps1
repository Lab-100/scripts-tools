<#
.SYNOPSIS
    Установка моделей в локальное хранилище Docker Model Runner (DMR) без CLI `docker model`.

.DESCRIPTION
    Docker Desktop 4.92 / CLI 29.8.0 на этой машине НЕ содержит команды `docker model`
    и плагина docker-model.exe, а HTTP-эндпоинты pull/delete у раннера отсутствуют (404).
    Локальное хранилище — OCI-layout в %USERPROFILE%\.docker\models:
        layout.json                 — {"version":"1.0.0"}
        blobs\sha256\<hex>          — сами файлы (gguf, license, config.json)
        manifests\sha256\<hex>      — манифест OCI (его sha256 = id модели)
        bundles\sha256\<hex>\config.json        — копия config-блоба
        bundles\sha256\<hex>\model\<name>.gguf  — HARDLINK на gguf-блоб
        models.json                 — индекс: id (digest манифеста), tags, files
    Инструмент тянет манифест и блобы напрямую из реестра Docker Hub, проверяет sha256,
    раскладывает по схеме выше и регистрирует тег в models.json.

.PARAMETER Command
    list     — показать установленные модели (по models.json)
    install  — скачать и установить модель из Docker Hub
    verify   — сверить models.json с манифестами и блобами (пропущенные/битые)
    remove   — удалить модель из индекса и удалить её блобы/манифест/bundle

.EXAMPLE
    pwsh -NoProfile -File dmr-model.ps1 list
    pwsh -NoProfile -File dmr-model.ps1 install -Repo ai/qwen2.5 -Tag 3B-Q4_K_M
    pwsh -NoProfile -File dmr-model.ps1 install -Repo ai/gemma3 -Tag 4b-q4_K_M -DryRun
    pwsh -NoProfile -File dmr-model.ps1 verify
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'install', 'verify', 'remove')]
    [string]$Command = 'list',

    [string]$Repo,
    [string]$Tag = 'latest',
    [string]$Id,
    [switch]$DryRun,
    [switch]$Quiet,
    [int]$TimeoutSec = 3600
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Log {
    param([string]$Message, [ValidateSet('info', 'warn', 'err', 'ok')][string]$Level = 'info')
    if ($Quiet -and $Level -eq 'info') { return }
    $map = @{ info = '---'; warn = '!!!'; err = 'XXX'; ok = '+++' }
    $color = @{ info = 'Gray'; warn = 'Yellow'; err = 'Red'; ok = 'Green' }
    Write-Host ("[{0}] {1}" -f $map[$Level], $Message) -ForegroundColor $color[$Level]
}

function Get-StoreRoot {
    $envCandidate = $env:INVR_DMR_STORE
    if ($envCandidate) {
        if (-not (Test-Path -LiteralPath $envCandidate)) {
            throw "INVR_DMR_STORE указывает на несуществующий каталог: $envCandidate"
        }
        return $envCandidate
    }
    $default = Join-Path $env:USERPROFILE '.docker\models'
    if (-not (Test-Path -LiteralPath $default)) {
        throw "Хранилище DMR не найдено: $default (переменная INVR_DMR_STORE не задана)"
    }
    return $default
}

function Get-HexOfDigest {
    param([string]$Digest)
    return ($Digest -replace '^sha256:', '')
}

function Get-Sha256File {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-Index {
    param([string]$Root)
    $path = Join-Path $Root 'models.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ models = @() }
    }
    return (Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json)
}

function Save-Index {
    param([string]$Root, $Index)
    $path = Join-Path $Root 'models.json'
    $tmp = "$path.tmp"
    $json = ($Index | ConvertTo-Json -Depth 8)
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Write-Log "индекс обновлён: $path" -Level ok
}

function Get-RegistryHeaders {
    param([string]$Scope)
    $tokenUrl = 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:' + $Scope + ':pull'
    $token = (Invoke-RestMethod -Uri $tokenUrl -TimeoutSec 30).token
    if (-not $token) { throw 'Docker Hub не вернул токен доступа' }
    return @{ Authorization = 'Bearer ' + $token }
}

function Get-RunnerEndpoint {
    $base = $env:INVR_DMR_ENDPOINT
    if ($base) { return $base.TrimEnd('/') }
    return 'http://127.0.0.1:12434'
}

function Show-Models {
    param([string]$Root)
    $index = Get-Index -Root $Root
    if (-not $index.models -or @($index.models).Count -eq 0) {
        Write-Log 'модели не установлены' -Level warn
        return
    }
    $rows = foreach ($m in $index.models) {
        $manifestPath = Join-Path $Root "manifests\sha256\$((Get-HexOfDigest $m.id))"
        $gguf = Get-ChildItem -LiteralPath (Join-Path $Root 'blobs\sha256') -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 1MB } | Sort-Object Length -Descending
        [pscustomobject]@{
            Tag       = ($m.tags -join ',')
            Id        = (Get-HexOfDigest $m.id).Substring(0, 12)
            Layers    = @($m.files).Count
            ManifestOk = Test-Path -LiteralPath $manifestPath
            StoreGiB  = [math]::Round((($m.files | ForEach-Object {
                            $hex = Get-HexOfDigest $_
                            $p = Join-Path $Root "blobs\sha256\$hex"
                            if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).Length } else { 0 }
                        } | Measure-Object -Sum).Sum / 1GB), 2)
            MissingBlobs = @($m.files | Where-Object {
                    -not (Test-Path -LiteralPath (Join-Path $Root "blobs\sha256\$((Get-HexOfDigest $_))"))
                }).Count
        }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

function Test-Store {
    param([string]$Root)
    $index = Get-Index -Root $Root
    $problems = @()
    foreach ($m in $index.models) {
        $manifestHex = Get-HexOfDigest $m.id
        $manifestPath = Join-Path $Root "manifests\sha256\$manifestHex"
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            $problems += "манифест отсутствует: $manifestHex ($($m.tags -join ','))"
            continue
        }
        $actual = Get-Sha256File -Path $manifestPath
        if ($actual -ne $manifestHex) {
            $problems += "манифест повреждён (sha256 не сходится): $manifestHex"
        }
        foreach ($f in $m.files) {
            $hex = Get-HexOfDigest $f
            $blob = Join-Path $Root "blobs\sha256\$hex"
            if (-not (Test-Path -LiteralPath $blob)) {
                $problems += "блоб отсутствует: $hex ($($m.tags -join ','))"
                continue
            }
            if ((Get-Item -LiteralPath $blob).Length -lt 1MB) { continue }
            $actualBlob = Get-Sha256File -Path $blob
            if ($actualBlob -ne $hex) {
                $problems += "блоб повреждён (sha256 не сходится): $hex ($($m.tags -join ','))"
            }
        }
        $bundle = Join-Path $Root "bundles\sha256\$manifestHex"
        if (-not (Test-Path -LiteralPath $bundle)) {
            $problems += "bundle отсутствует: $manifestHex ($($m.tags -join ','))"
        }
    }
    if ($problems.Count -eq 0) {
        Write-Log 'хранилище целостно: расхождений нет' -Level ok
        return 0
    }
    foreach ($p in $problems) { Write-Log $p -Level err }
    return 1
}

function Install-Model {
    param([string]$Root, [string]$RepoName, [string]$TagName)

    if (-not $RepoName) { throw 'install требует -Repo (например ai/qwen2.5)' }
    if ($RepoName -notmatch '^[\w.\-]+(/[\w.\-]+)*$') { throw "Недопустимое имя репозитория: $RepoName" }
    if ($TagName -notmatch '^[\w.\-]+$') { throw "Недопустимое имя тега: $TagName" }

    $fullTag = "docker.io/$RepoName`:$TagName"
    $index = Get-Index -Root $Root
    if ($index.models | Where-Object { $_.tags -contains $fullTag }) {
        Write-Log "модель $fullTag уже зарегистрирована" -Level warn
        return 0
    }

    $headers = Get-RegistryHeaders -Scope $RepoName
    $manifestUrl = "https://registry-1.docker.io/v2/$RepoName/manifests/$TagName"
    $accept = 'application/vnd.oci.image.manifest.v1+json, application/vnd.oci.artifact.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
    $manifestTmp = Join-Path $env:TEMP ("dmr-manifest-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    try {
        Write-Log "запрашиваю манифест: $fullTag" -Level info
        $resp = Invoke-WebRequest -Uri $manifestUrl -Headers ($headers + @{ Accept = $accept }) -OutFile $manifestTmp -PassThru -TimeoutSec 60 -UseBasicParsing
        $remoteDigest = $resp.Headers['Docker-Content-Digest']
        $localDigest = 'sha256:' + (Get-Sha256File -Path $manifestTmp)
        if ($remoteDigest -and $remoteDigest -ne $localDigest) {
            Write-Log "ВНИМАНИЕ: digest манифеста отличается: реестр=$remoteDigest локально=$localDigest" -Level warn
        }
        $manifestHex = Get-HexOfDigest $localDigest
        $manifest = Get-Content -Raw -LiteralPath $manifestTmp -Encoding UTF8 | ConvertFrom-Json

        if (-not $manifest.layers -or @($manifest.layers).Count -eq 0) {
            throw 'в манифесте нет слоёв — это не образ модели'
        }

        $annotations = $manifest.annotations
        $weightName = $null
        if ($annotations -and $annotations.'org.cncf.model.filepath') {
            $weightName = $annotations.'org.cncf.model.filepath'
        } elseif ($annotations -and $annotations.'ai.model.repo') {
            $weightName = "$($annotations.'ai.model.repo'.Split('/')[-1]).gguf"
        }
        if (-not $weightName) { $weightName = 'model.gguf' }
        $weightName = ($weightName -replace '[^A-Za-z0-9._-]', '_')
        if ($weightName -notmatch '\.gguf$') { $weightName = "$weightName.gguf" }

        $totalBytes = [int64](($manifest.layers | Measure-Object -Property size -Sum).Sum)
        Write-Log ("слоёв: {0}, вес: {1:N2} ГБ, файл: {2}" -f @($manifest.layers).Count, ($totalBytes / 1GB), $weightName) -Level info

        if ($DryRun) {
            Write-Log 'DRY-RUN: загрузка не выполнялась' -Level warn
            Write-Log ("был бы манифест: {0}" -f $manifestHex)
            return 0
        }

        $blobsDir = Join-Path $Root 'blobs\sha256'
        $manifestsDir = Join-Path $Root 'manifests\sha256'
        $bundleDir = Join-Path $Root "bundles\sha256\$manifestHex"
        foreach ($d in @($blobsDir, $manifestsDir, $bundleDir, (Join-Path $bundleDir 'model'))) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }

        $downloads = @(
            @{ Digest = $manifest.config.digest; Kind = 'config' }
        )
        $idx = 0
        foreach ($layer in $manifest.layers) {
            $idx++
            $downloads += @{ Digest = $layer.digest; Kind = 'layer'; Index = $idx; NameHint = $weightName }
        }

        foreach ($item in $downloads) {
            $hex = Get-HexOfDigest $item.Digest
            $target = Join-Path $blobsDir $hex
            if (Test-Path -LiteralPath $target) {
                Write-Log "блоб уже есть: $hex" -Level info
                continue
            }
            $url = "https://registry-1.docker.io/v2/$RepoName/blobs/$($item.Digest)"
            $tmp = "$target.download"
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Write-Log ("скачиваю {0} ({1:N0} МБ) {2}..." -f $hex.Substring(0, 12), ((Get-Item -LiteralPath $target -ErrorAction SilentlyContinue).Length / 1MB), $(if ($item.Kind -eq 'config') { '(config)' } else { "(слой $($item.Index))" })) -Level info
            Invoke-WebRequest -Uri $url -Headers $headers -OutFile $tmp -TimeoutSec $TimeoutSec -UseBasicParsing
            $sw.Stop()
            $hash = Get-Sha256File -Path $tmp
            if ($hash -ne $hex) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                throw "sha256 не сошёлся для $hex (получено $hash) — загрузка отменена"
            }
            Move-Item -LiteralPath $tmp -Destination $target -Force
            $mb = [math]::Round((Get-Item -LiteralPath $target).Length / 1MB)
            Write-Log ("готово: {0} МБ за {1:N0} с" -f $mb, $sw.Elapsed.TotalSeconds) -Level ok
        }

        $manifestTarget = Join-Path $manifestsDir $manifestHex
        Copy-Item -LiteralPath $manifestTmp -Destination $manifestTarget -Force

        $configTarget = Join-Path $bundleDir 'config.json'
        $configBlobPath = Join-Path $blobsDir (Get-HexOfDigest $manifest.config.digest)
        # В bundle кладётся НЕ весь блоб, а только внутренний объект config:
        #   mediaType docker.ai.model.config.v0.1 -> config.config (напр. 117 Б)
        #   mediaType cncf.model.config.v1         -> блок целиком (напр. 184 Б)
        $configMedia = [string]$manifest.config.mediaType
        $configRaw = Get-Content -Raw -LiteralPath $configBlobPath -Encoding UTF8 | ConvertFrom-Json
        if ($configMedia -like '*docker.ai.model.config*' -and $configRaw.PSObject.Properties.Name -contains 'config') {
            $configJson = $configRaw.config | ConvertTo-Json -Depth 6 -Compress
            [System.IO.File]::WriteAllText($configTarget, $configJson, (New-Object System.Text.UTF8Encoding($false)))
        } else {
            Copy-Item -LiteralPath $configBlobPath -Destination $configTarget -Force
        }

$weightLayer = $manifest.layers | Sort-Object size -Descending | Select-Object -First 1
$weightBlob = Join-Path $blobsDir (Get-HexOfDigest $weightLayer.digest)
$weightTarget = Join-Path $bundleDir "model\$weightName"
# Если нужная жёсткая ссылка уже существует и указывает на нужный блоб — не трогаем:
# раннер DMR держит GGUF открытым, пока модель загружена в память, и Remove-Item падает
# с "Access denied". Лишние старые ссылки того же блоба безвредны.
$linkOk = $false
if (Test-Path -LiteralPath $weightTarget) {
    $existing = Get-Item -LiteralPath $weightTarget -Force
    $sameLength = ($existing.Length -eq (Get-Item -LiteralPath $weightBlob).Length)
    if ($existing.LinkType -eq 'HardLink' -and $sameLength) {
        $linkOk = $true
        Write-Log "жёсткая ссылка уже на месте, не пересоздаю: $weightName" -Level info
    } else {
        try {
            Remove-Item -LiteralPath $weightTarget -Force -ErrorAction Stop
        } catch {
            throw "не могу заменить $weightTarget (файл занят раннером): $($_.Exception.Message). Выгрузите модель (перезапустите Docker Desktop) и повторите."
        }
    }
}
if (-not $linkOk) {
    cmd /c mklink /H `"$weightTarget`" `"$weightBlob`" | Out-Null
    if (-not (Test-Path -LiteralPath $weightTarget)) {
        Copy-Item -LiteralPath $weightBlob -Destination $weightTarget -Force
        Write-Log 'жёсткая ссылка не создалась — сделана копия' -Level warn
    } else {
        Write-Log "жёсткая ссылка создана: $weightName" -Level ok
    }
}

        $files = @($manifest.layers | ForEach-Object { $_.digest }) + @($manifest.config.digest)
        $entry = [pscustomobject]@{
            id    = "sha256:$manifestHex"
            tags  = @($fullTag)
            files = $files
        }
        $index.models = @($index.models) + @($entry)
        Save-Index -Root $Root -Index $index

        Write-Log "модель установлена: $fullTag (id $manifestHex)" -Level ok
        try {
            $endpoint = Get-RunnerEndpoint
            $listed = Invoke-RestMethod -Uri "$endpoint/models" -TimeoutSec 20
            $names = @($listed.models | ForEach-Object { $_.id })
            Write-Log ("раннер видит моделей: {0}; наша в списке: {1}" -f $names.Count, ($names -contains $fullTag)) -Level info
            if ($names -notcontains $fullTag) {
                Write-Log 'раннер не подхватил модель без перезапуска — нужен перезапуск Docker Desktop' -Level warn
            }
        } catch {
            Write-Log "не удалось опросить раннер ($($_.Exception.Message))" -Level warn
        }
        return 0
    } finally {
        Remove-Item -LiteralPath $manifestTmp -Force -ErrorAction SilentlyContinue
    }
}

function Remove-Model {
    param([string]$Root, [string]$ModelId)
    $index = Get-Index -Root $Root
    $target = $index.models | Where-Object {
        $_.id -eq $ModelId -or $_.tags -contains $ModelId -or ((Get-HexOfDigest $_.id).StartsWith($ModelId))
    } | Select-Object -First 1
    if (-not $target) { throw "модель не найдена в индексе: $ModelId" }
    $hex = Get-HexOfDigest $target.id
    Write-Log "удаляю $($target.tags -join ',') (id $hex)" -Level warn
    if ($DryRun) { return 0 }

    foreach ($f in $target.files) {
        $p = Join-Path $Root "blobs\sha256\$((Get-HexOfDigest $f))"
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    foreach ($p in @(
            (Join-Path $Root "manifests\sha256\$hex"),
            (Join-Path $Root "bundles\sha256\$hex"))) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
    }
    $index.models = @($index.models | Where-Object { $_ -ne $target })
    Save-Index -Root $Root -Index $index
    Write-Log 'модель удалена' -Level ok
    return 0
}

$store = Get-StoreRoot
Write-Log "хранилище: $store"

switch ($Command) {
    'list' { Show-Models -Root $store }
    'verify' { exit (Test-Store -Root $store) }
    'install' { exit (Install-Model -Root $store -RepoName $Repo -TagName $Tag) }
    'remove' { exit (Remove-Model -Root $store -ModelId $(if ($Id) { $Id } else { $Repo })) }
}
exit 0