param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [string]$AgentFile = "$env:USERPROFILE\.agents\gordon.yaml",
    [string]$ProvidersJson = '',
    [int]$GordonTimeoutSec = 300,
    [switch]$ShowAll,
    [switch]$Local
)
# UTF-8 console default (no krakozyabry)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Continue'

# Каталог инструментов (каталог с шимами): уровнем выше registry\
$toolsRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent

# Ротация облачных провайдеров (кредиты бесплатных объёмов) + двухуровневый фолбэк:
# 1) dmr-router (сам выбирает fast/lite по задаче и памяти, держит каскад с fallback),
# 2) docker agent --model local (smollm2). Режим -Local идёт сразу в локальный роутер.
# Порядок конфига: -ProvidersJson > env GORDON_PROVIDERS_JSON > рядом со скриптом >
# USERPROFILE\.devstation > каталог инструментов.
$seed = @(
    @{ name = 'groq';        env = 'GROQ_API_KEY';         model = 'groq/llama-3.3-70b-versatile';  url = 'https://console.groq.com' },
    @{ name = 'google';      env = 'GEMINI_API_KEY';       model = 'google/gemini-2.5-flash';       url = 'https://aistudio.google.com/apikey' },
    @{ name = 'openai';      env = 'OPENAI_API_KEY';       model = 'openai/gpt-5-mini';             url = 'https://platform.openai.com/api-keys' },
    @{ name = 'anthropic';   env = 'ANTHROPIC_API_KEY';    model = 'anthropic/claude-sonnet-5';      url = 'https://console.anthropic.com/settings/keys' },
    @{ name = 'mistral';     env = 'MISTRAL_API_KEY';      model = 'mistral/mistral-small-latest';  url = 'https://console.mistral.ai' },
    @{ name = 'cerebras';    env = 'CEREBRAS_API_KEY';     model = 'cerebras/' ;                     url = 'https://cloud.cerebras.ai' },
    @{ name = 'openrouter';  env = 'OPENROUTER_API_KEY';   model = 'openrouter/x-ai/grok-4.7';       url = 'https://openrouter.ai/settings/keys' },
    @{ name = 'xai';         env = 'XAI_API_KEY';          model = 'xai/grok-4.7';                  url = 'https://console.x.ai' },
    @{ name = 'docker-cloud'; env = 'ANTHROPIC_API_KEY';   model = 'anthropic/claude-haiku-4-5';    url = 'https://docs.docker.com/ai/' },
    @{ name = 'gordon-desktop'; env = ''; mode = 'npipe';  model = 'anthropic/claude-haiku-4-5';    url = 'https://docs.docker.com/ai/gordon/usage-limits/' }
)

function Resolve-ProvidersJson {
    if ($ProvidersJson) { return [IO.Path]::GetFullPath($ProvidersJson) }
    try { $e = [Environment]::GetEnvironmentVariable('GORDON_PROVIDERS_JSON'); if ($e) { return $e } } catch {}
    $side = Join-Path $PSScriptRoot 'gordon-providers.json'
    if (Test-Path $side) { return $side }
    $home = Join-Path $env:USERPROFILE '.devstation\gordon-providers.json'
    if (Test-Path $home) { return $home }
    $legacy = Join-Path $toolsRoot 'gordon-providers.json'
    if (Test-Path $legacy) { return $legacy }
    return ''
}
$cfg = Resolve-ProvidersJson
if (-not $cfg) { $cfg = Join-Path $env:USERPROFILE '.devstation\gordon-providers.json' }
if (Test-Path $cfg) { $providers = Get-Content $cfg -Raw | ConvertFrom-Json } else { $providers = $seed; New-Item -ItemType Directory -Force -Path (Split-Path $cfg -Parent) | Out-Null; $providers | ConvertTo-Json -Depth 4 | Set-Content $cfg -Encoding utf8; Write-Host "Создан список провайдеров: $cfg" }

# Шим gordon-chat (динамический latest) для канала Gordon Desktop через npipe docker-agent.
$gordonChatShim = Join-Path $toolsRoot 'gordon-chat.ps1'

$who = ''
if ($Local) { Write-Host '  режим -Local: облачные провайдеры пропущены' -ForegroundColor DarkGray }
foreach ($pr in $providers) {
    if ($Local) { break }
    $isNpipe = ($pr.mode -eq 'npipe')
    if ($isNpipe) {
        $agentExe = Get-CimInstance Win32_Process -Filter "Name='docker-agent.exe'" -ErrorAction SilentlyContinue
        if (-not $agentExe) { Write-Host "  $($pr.name): docker-agent.exe не запущен (Docker Desktop) — пропуск" -ForegroundColor DarkGray; continue }
    }
    elseif (-not [Environment]::GetEnvironmentVariable($pr.env)) { continue }
    Write-Host "  попытка: $($pr.name) ($($pr.model))" -ForegroundColor DarkCyan
    if ($isNpipe) {
        $outJ = & $gordonChatShim -Ask $Prompt -Model $pr.model -TimeoutSec $GordonTimeoutSec -Json 2>&1
        $jraw = $outJ -join "`n"
        $j = $null
        try { $j = $jraw | ConvertFrom-Json } catch {}
        if ($j -and $j.status -eq 'ok' -and $j.text) {
            $who = $pr.name
            $j.text | Write-Output
            break
        }
        elseif ($ShowAll) { $jraw | Write-Output }
        continue
    }
    $out = & docker agent run $AgentFile --model $pr.model --exec $Prompt 2>&1
    $errRe = $out -join "`n"
    if ($LASTEXITCODE -eq 0 -and $errRe -notmatch 'rate\s*limit|quota|429|credit|exhaust|insufficient|недост|лимит') {
        $who = $pr.name
        $out | Write-Output
        break
    }
    elseif ($ShowAll) { $out | Write-Output }
}

if (-not $who) {
    # Уровень 1: локальный роутер dmr-router — сам выбирает fast/lite по задаче и памяти,
    # держит каскад heavy -> lite -> fallback и отдаёт готовый ответ (без docker agent).
    $routerShim = Join-Path $toolsRoot 'dmr-router.ps1'
    Write-Host '  фолбэк: локальный роутер dmr-router (free)' -ForegroundColor DarkCyan
    if (Test-Path -LiteralPath $routerShim) {
        $rjRaw = & $routerShim -Ask $Prompt -Json 2>&1 | Out-String
        $r = $null
        try { $r = $rjRaw | ConvertFrom-Json } catch {}
        if ($r -and $r.ok -and $r.text) {
            $who = "dmr-router:$($r.role)/$($r.model)"
            $r.text | Write-Output
        }
        elseif ($r) {
            Write-Host "  роутер не смог выбрать модель: $($r.reasons -join '; ')" -ForegroundColor Yellow
        }
        else {
            Write-Host '  роутер вернул нечитаемый ответ' -ForegroundColor Yellow
        }
    }
}

if (-not $who) {
    # Уровень 2 (последний): docker agent c моделью local (smollm2) напрямую.
    Write-Host '  фолбэк: docker agent --model local (free)' -ForegroundColor DarkCyan
    & docker agent run $AgentFile --model local --exec $Prompt 2>&1 | Write-Output
    $who = 'local-model-runner'
}

Write-Host "`n--- отвечал: $who ---" -ForegroundColor Green