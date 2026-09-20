$ErrorActionPreference = 'SilentlyContinue'

function Test-Http($name, $url, $auth, $method, $body) {
    $a = @('-s', '-o', 'NUL', '-w', '%{http_code}', '-X', $method, $url, '--max-time', '15')
    if ($auth) { $a += '-H'; $a += "Authorization: Bearer $auth" }
    if ($body) { $a += '--data'; $a += $body }
    $code = & curl.exe @a 2>$null
    if (-not $code) { $code = 'NO-RESP' }
    return $code
}

$k = @{}
foreach ($n in 'OPENROUTER_API_KEY','OPENAI_API_KEY','ANTHROPIC_API_KEY','GEMINI_API_KEY','GROQ_API_KEY','XAI_API_KEY','MISTRAL_API_KEY') {
    $k[$n] = [Environment]::GetEnvironmentVariable($n, 'User')
}

$rows = @(
    [pscustomobject]@{ Provider='OpenRouter'; HasKey=[bool]$k.OPENROUTER_API_KEY; Code=(Test-Http 'or' 'https://openrouter.ai/api/v1/key' $k.OPENROUTER_API_KEY 'GET' $null) },
    [pscustomobject]@{ Provider='OpenAI';    HasKey=[bool]$k.OPENAI_API_KEY;    Code=(Test-Http 'oa' 'https://api.openai.com/v1/models' $k.OPENAI_API_KEY 'GET' $null) },
    [pscustomobject]@{ Provider='Anthropic'; HasKey=[bool]$k.ANTHROPIC_API_KEY; Code=(Test-Http 'an' 'https://api.anthropic.com/v1/models' $k.ANTHROPIC_API_KEY 'GET' $null) },
    [pscustomobject]@{ Provider='Gemini';    HasKey=[bool]$k.GEMINI_API_KEY;    Code=(Test-Http 'ge' "https://generativelanguage.googleapis.com/v1beta/models?key=$($k.GEMINI_API_KEY)" $null 'GET' $null) },
    [pscustomobject]@{ Provider='Groq';      HasKey=[bool]$k.GROQ_API_KEY;      Code=(Test-Http 'gr' 'https://api.groq.com/openai/v1/models' $k.GROQ_API_KEY 'GET' $null) },
    [pscustomobject]@{ Provider='xAI';       HasKey=[bool]$k.XAI_API_KEY;       Code=(Test-Http 'xa' 'https://api.x.ai/v1/models' $k.XAI_API_KEY 'GET' $null) },
    [pscustomobject]@{ Provider='Mistral';   HasKey=[bool]$k.MISTRAL_API_KEY;   Code=(Test-Http 'mi' 'https://api.mistral.ai/v1/models' $k.MISTRAL_API_KEY 'GET' $null) }
)

$ollama = & curl.exe -s --max-time 8 'http://localhost:11434/api/tags' 2>$null
$ollamaOk = $false
if ($ollama) {
    try { $t = $ollama | ConvertFrom-Json; $ollamaOk = $t.models.Count -gt 0 } catch {}
}

$rows | ForEach-Object {
    $status = if ($_.Code -eq '200') { 'OK    ' } elseif ($_.Code -eq '401') { 'BADKEY' } elseif ($_.Code -eq '403') { 'GEO-   ' } elseif ($_.Code -eq '404') { '404    ' } else { $_.Code }
    '{0,-10} key={1,-3}  HTTP {2,4}  {3}' -f $_.Provider, ($(if($_.HasKey){'yes'}else{'no'})), $_.Code, $status
}

if ($ollamaOk) {
    'Ollama   (loc)  : OK      локальные модели: ' + (($t.models.name) -join ', ')
} else {
    'Ollama   (loc)  : down'
}

Write-Host ''
Write-Host 'Порядок OpenClaw-failover: openrouter/auto -> mistral -> ollama/hermes3:8b -> gemini-3.6 -> anthropic'
Write-Host '403 = гео-блок РФ (нужен VPN), 401 = неверный ключ, 429/5xx = лимит/сбой провайдера.'