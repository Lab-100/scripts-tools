<#
.SYNOPSIS
    Роутер локальных моделей Docker Model Runner: сам выбирает lite/heavy по задаче и памяти.

.DESCRIPTION
    На этой машине Docker Desktop 4.92 / CLI 29.8.0 НЕ содержит команды `docker model`
    (нет ни плагина docker-model.exe, ни HTTP pull/delete), поэтому модели ставятся
    инструментом dmr-model, а выбор модели делает этот роутер.

    Логика выбора:
      1) Классификация задачи по ключевым словам (cfg.Classifier.Keywords) —
         тяжёлые признаки: код, архитектура, отладка, рефакторинг, анализ, дизайн, ADR, тесты.
      2) Проверка свободной памяти: heavy требует >= HeavyMinFreeGB (по умолчанию 7 ГБ),
         иначе принудительно берётся lite. Это снимает ошибку «failed to load model».
      3) При недоступности выбранной модели выполняется каскад: heavy -> lite -> fallback,
         каждый следующий вариант проверяется реальным запросом (проба, ProbeMaxTokens).

    Модели обращаются напрямую к раннеру (OpenAI-совместимый эндпоинт), поэтому ответ
    возвращается без накладных расходов docker agent.

.PARAMETER Ask
    Текст задачи.
.PARAMETER Mode
    auto (по умолчанию) | lite | heavy | fast — принудительный режим.
.PARAMETER Task
    short | normal | deep — влияет на порог памяти для heavy (deep требует больше).
.PARAMETER DryRun
    Только показать решение (модель, причина, каскад), без запроса к модели.
.PARAMETER Json
    Машиночитаемый вывод: модель, ответ, время, скорость, каскад.

.EXAMPLE
    pwsh -NoProfile -File dmr-router.ps1 -Ask 'привет' -Json
    pwsh -NoProfile -File dmr-router.ps1 -Ask 'разбери архитектуру этого модуля и предложи рефакторинг' -Json
    pwsh -NoProfile -File dmr-router.ps1 -Ask 'напиши regex' -Mode lite -DryRun -Json

.EXAMPLE
    $j = pwsh -NoProfile -File dmr-router.ps1 -Ask 'посчитай сумму чисел' -Json | ConvertFrom-Json
    $j.model; $j.text; $j.seconds; $j.tokensPerSecond
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Ask,
    [ValidateSet('auto', 'lite', 'heavy', 'fast')]
    [string]$Mode = 'auto',
    [ValidateSet('short', 'normal', 'deep')]
    [string]$Task = 'normal',
    [switch]$DryRun,
    [switch]$Json,
    [int]$MaxTokens = 512,
    [double]$Temperature = 0.4
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ConfigPath = if ($env:INVR_DMR_ROUTER_CONFIG) { $env:INVR_DMR_ROUTER_CONFIG }
else { Join-Path $PSScriptRoot 'dmr-router-config.json' }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Не найден конфиг роутера: $ConfigPath (задайте INVR_DMR_ROUTER_CONFIG)"
}
$Cfg = Get-Content -Raw -LiteralPath $ConfigPath -Encoding UTF8 | ConvertFrom-Json

function Get-FreeMemoryGB {
    $os = Get-CimInstance Win32_OperatingSystem
    return [math]::Round($os.FreePhysicalMemory / 1MB, 2)
}

function Get-RunnerAvailable {
    param([string]$Endpoint)
    try {
        $null = Invoke-RestMethod -Uri "$Endpoint/models" -TimeoutSec 10
        return $true
    } catch { return $false }
}

function Get-InstalledModels {
    param([string]$Endpoint)
    try {
        $r = Invoke-RestMethod -Uri "$Endpoint/v1/models" -TimeoutSec 15
        return @($r.data | ForEach-Object { $_.id })
    } catch { return @() }
}

function Test-TaskHeavy {
    param([string]$Text)
    $text = $Text.ToLowerInvariant()
    foreach ($kw in $Cfg.Classifier.Keywords) {
        if ($text.Contains([string]$kw)) { return $kw }
    }
    return $null
}

function Get-RequiredFreeGB {
    $need = [double]$Cfg.Memory.HeavyMinFreeGB
    if ($Task -eq 'deep') { $need = [double]$Cfg.Memory.HeavyMinFreeGBDeep }
    if ($Task -eq 'short') { $need = [math]::Max($need - 1, 2) }
    if ($Mode -eq 'lite' -or $Mode -eq 'fast') { $need = [double]$Cfg.Memory.LiteMinFreeGB }
    return $need
}

function Invoke-Model {
    param(
        [string]$Model,
        [string]$Text,
        [int]$Tokens,
        [double]$Temp,
        [string]$Endpoint
    )
    $payload = @{
        model       = $Model
        messages    = @(
            @{ role = 'system'; content = [string]$Cfg.SystemPrompt },
            @{ role = 'user'; content = $Text }
        )
        max_tokens  = $Tokens
        temperature = $Temp
    } | ConvertTo-Json -Depth 8

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = Invoke-WebRequest -Uri "$Endpoint$($Cfg.Endpoint.ChatCompletions)" -Method Post `
        -Body $payload -ContentType 'application/json' -TimeoutSec $Cfg.Timeouts.RequestSec `
        -UseBasicParsing -SkipHttpErrorCheck
    $sw.Stop()

    if ($resp.StatusCode -ne 200) {
        $msg = $resp.Content
        if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) }
        throw "HTTP $($resp.StatusCode): $msg"
    }
    $r = $resp.Content | ConvertFrom-Json
    $textOut = $r.choices[0].message.content
    $tok = 0
    if ($r.usage) { $tok = [int]$r.usage.prompt_tokens + [int]$r.usage.completion_tokens }
    $tps = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($tok / $sw.Elapsed.TotalSeconds, 1) } else { 0 }
    return [pscustomobject]@{
        text           = $textOut
        seconds        = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        tokensPerSecond = $tps
        promptTokens   = $(if ($r.usage) { $r.usage.prompt_tokens } else { 0 })
        completionTokens = $(if ($r.usage) { $r.usage.completion_tokens } else { 0 })
    }
}

# ---- 1) доступность раннера ----
$endpoint = ([string]$Cfg.Endpoint.BaseUrl).TrimEnd('/')
if (-not (Get-RunnerAvailable -Endpoint $endpoint)) {
    $msg = "Docker Model Runner недоступен на $endpoint — подними Docker Desktop (нужен порт 12434)"
    if ($Json) { @{ ok = $false; error = $msg; model = $null } | ConvertTo-Json -Depth 4 } else { Write-Host $msg -ForegroundColor Red }
    exit 2
}
$installed = Get-InstalledModels -Endpoint $endpoint
$free = Get-FreeMemoryGB
$need = Get-RequiredFreeGB

# ---- 2) выбор стартовой модели ----
$heavySignal = Test-TaskHeavy -Text $Ask
$reasons = @()

switch ($Mode) {
    'lite' { $order = @('lite') }
    'fast' { $order = @('fast', 'lite') }
    'heavy' { $order = @('heavy', 'lite') }
    default {
        if ($heavySignal) {
            $order = @('heavy', 'lite')
            $reasons += "задача похожа на тяжёлую (маркер: '$heavySignal')"
        } else {
            $order = @('lite', 'heavy')
            $reasons += 'задача короткая/простая — берём lite'
        }
    }
}

if ($free -lt $need) {
    $reasons += "свободно $([math]::Round($free,2)) ГБ < требуемых $([math]::Round($need,2)) ГБ — понижаю до lite"
    $order = @('lite') + @($order | Where-Object { $_ -ne 'lite' })
}

# ---- 3) каскад с проверкой каждой модели ----
$tried = @()
$chosen = $null
$promptForProbe = if ($DryRun) { '' } else { [string]$Cfg.Classifier.ProbePrompt }
$usedMaxTokens = $MaxTokens

foreach ($role in $order) {
    $modelCfg = $Cfg.Models.$role
    if (-not $modelCfg) { $reasons += "роль '$role' не описана в конфиге"; continue }
    $tag = [string]$modelCfg.tag

    $isInstalled = $false
    foreach ($i in $installed) {
        if ($i -like "*$($modelCfg.repo):*" -or $i -eq $tag) { $isInstalled = $true }
    }
    if (-not $isInstalled) {
        $reasons += "$tag не установлен (установи: dmr-model install -Repo $($modelCfg.repo) -Tag $($modelCfg.tag))"
        continue
    }

    $needGB = [double]$modelCfg.minFreeGB
    if ($free -lt $needGB) {
        $reasons += "${tag}: свободно $([math]::Round($free,2)) ГБ < нужно $($needGB) ГБ — пропускаю"
        continue
    }

    $tried += $tag
    if ($DryRun) {
        $chosen = [pscustomobject]@{ role = $role; model = $tag; minFreeGB = $needGB }
        break
    }

    try {
        $probeTokens = [int]$Cfg.Classifier.ProbeMaxTokens
        $probe = Invoke-Model -Model $modelCfg.apiName -Text $promptForProbe -Tokens $probeTokens -Temp 0.2 -Endpoint $endpoint
        if (-not $probe.text -or $probe.text.Trim().Length -eq 0) { throw 'пустой ответ пробы' }
        $reasons += "$tag проба успешна ($($probe.tokensPerSecond) ток/с)"
        $answer = Invoke-Model -Model $modelCfg.apiName -Text $Ask -Tokens $usedMaxTokens -Temp $Temperature -Endpoint $endpoint
        $chosen = [pscustomobject]@{
            role        = $role
            model       = $tag
            apiName     = [string]$modelCfg.apiName
            minFreeGB   = $needGB
            seconds     = $answer.seconds
            tokensPerSecond = $answer.tokensPerSecond
            text        = $answer.text
            promptTokens = $answer.promptTokens
            completionTokens = $answer.completionTokens
            fallbackUsed = ($role -ne $order[0])
        }
        break
    } catch {
        $detail = $_.Exception.Message
        if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) }
        $reasons += "$tag не сработала: $detail"
    }
}

# ---- 4) вывод ----
if ($Json) {
    $out = [ordered]@{
        ok            = [bool]$chosen
        model         = $(if ($chosen) { $chosen.model } else { $null })
        role          = $(if ($chosen) { $chosen.role } else { $null })
        text          = $(if ($chosen) { $chosen.text } else { $null })
        seconds       = $(if ($chosen) { $chosen.seconds } else { $null })
        tokensPerSecond = $(if ($chosen) { $chosen.tokensPerSecond } else { $null })
        fallbackUsed  = $(if ($chosen) { $chosen.fallbackUsed } else { $null })
        freeGB        = $free
        requiredGB    = $need
        mode          = $Mode
        task          = $Task
        dryRun        = [bool]$DryRun
        cascadeTried  = $tried
        reasons       = $reasons
        runnerModels  = $installed
    }
    ($out | ConvertTo-Json -Depth 6) | Write-Output
} else {
    Write-Host "свободно памяти: $free ГБ (для роли требовалось $need ГБ)" -ForegroundColor DarkGray
    $color = if ($chosen) { 'Green' } else { 'Red' }
    Write-Host "решение: $(if ($chosen) { $chosen.model } else { 'НЕТ ПОДХОДЯЩЕЙ МОДЕЛИ' })" -ForegroundColor $color
    foreach ($r in $reasons) { Write-Host "  - $r" -ForegroundColor DarkGray }
    if ($chosen -and -not $DryRun) {
        Write-Host ""
        Write-Host $chosen.text
        Write-Host ""
        Write-Host "[$($chosen.seconds) с | ~$($chosen.tokensPerSecond) ток/с]" -ForegroundColor DarkGray
    }
}

if (-not $chosen) { exit 3 }
exit 0