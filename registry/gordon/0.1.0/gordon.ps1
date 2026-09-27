param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [string]$AgentFile = "$env:USERPROFILE\.agents\gordon.yaml",
    [switch]$ShowAll
)
$ErrorActionPreference = 'Continue'

# Ротация облачных провайдеров (кредиты бесплатных объёмов) + фолбэк на локальный Model Runner.
# Порядок берётся из gordon-providers.json рядом с шимами. Добавляется использование, когда появится ключ.
$seed = @(
    @{ name = 'groq';        env = 'GROQ_API_KEY';        model = 'groq/llama-3.3-70b-versatile';  url = 'https://console.groq.com' },
    @{ name = 'google';      env = 'GOOGLE_API_KEY';      model = 'google/gemini-2.5-flash';       url = 'https://aistudio.google.com/apikey' },
    @{ name = 'openai';      env = 'OPENAI_API_KEY';      model = 'openai/gpt-5-mini';             url = 'https://platform.openai.com/api-keys' },
    @{ name = 'anthropic';   env = 'ANTHROPIC_API_KEY';   model = 'anthropic/claude-sonnet-5';      url = 'https://console.anthropic.com/settings/keys' },
    @{ name = 'mistral';     env = 'MISTRAL_API_KEY';     model = 'mistral/' ;                      url = 'https://console.mistral.ai' },
    @{ name = 'cerebras';    env = 'CEREBRAS_API_KEY';    model = 'cerebras/' ;                     url = 'https://cloud.cerebras.ai' },
    @{ name = 'openrouter';  env = 'OPENROUTER_API_KEY';  model = 'openrouter/' ;                   url = 'https://openrouter.ai/settings/keys' }
)

# Каталог конфигурации рядом с шимами: уровнем выше registry\
$toolsRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$cfg = Join-Path $toolsRoot 'gordon-providers.json'
if (Test-Path $cfg) { $providers = Get-Content $cfg -Raw | ConvertFrom-Json } else { $providers = $seed; $providers | ConvertTo-Json -Depth 4 | Set-Content $cfg -Encoding utf8; Write-Host "Создан список провайдеров: $cfg" }

$who = ''
foreach ($pr in $providers) {
    if (-not [Environment]::GetEnvironmentVariable($pr.env)) { continue }
    Write-Host "  попытка: $($pr.name) ($($pr.model))" -ForegroundColor DarkCyan
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