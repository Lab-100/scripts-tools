param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [string]$AgentFile = "$env:USERPROFILE\.agents\gordon.yaml",
    [string]$ProvidersJson = '',
    [int]$GordonTimeoutSec = 300,
    [switch]$ShowAll
)
# UTF-8 console default (no krakozyabry)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Continue'

# Каталог инструментов (каталог с шимами): уровнем выше registry\
$toolsRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent

# Ротация облачных провайдеров (кредиты бесплатных объёмов) + фолбэк на локальный Model Runner.
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
foreach ($pr in $providers) {
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
    Write-Host '  фолбэк: локальный Model Runner (free)' -ForegroundColor DarkCyan
    & docker agent run $AgentFile --model local --exec $Prompt 2>&1 | Write-Output
    $who = 'local-model-runner'
}

Write-Host "`n--- отвечал: $who ---" -ForegroundColor Green