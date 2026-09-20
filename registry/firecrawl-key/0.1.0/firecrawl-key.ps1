param(
    [ValidateSet('Init', 'Poll')][string]$Mode = 'Init',
    [int]$TimeoutSec = 600
)
$ErrorActionPreference = 'Stop'

$stateDir = 'C:\Scripts\tools\.firecrawl-auth'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$stateFile = Join-Path $stateDir 'session.json'

function B64Url([byte[]]$bytes) {
    ([Convert]::ToBase64String($bytes) -replace '\+', '-' -replace '/', '_').TrimEnd('=')
}

if ($Mode -eq 'Init') {
    $verBytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Fill($verBytes)
    $verifier = B64Url $verBytes
    if ($verifier.Length -gt 43) { $verifier = $verifier.Substring(0, 43) }
    $chBytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes($verifier))
    $challenge = B64Url $chBytes
    $sidBytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Fill($sidBytes)
    $sid = ($sidBytes | ForEach-Object { $_.ToString('x2') }) -join ''

    $url = "https://www.firecrawl.dev/cli-auth?code_challenge=$challenge&source=coding-agent#session_id=$sid"
    @{ session_id = $sid; code_verifier = $verifier; url = $url; created = (Get-Date -Format o) } |
        ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8
    Write-Host 'Открой ссылку в браузере и НАЖМИ Authorize (ключ подхватится через Poll):' -ForegroundColor Yellow
    Write-Host $url -ForegroundColor Cyan
    Write-Host "Состояние: $stateFile"
    exit 0
}

if (-not (Test-Path $stateFile)) { Write-Host 'Нет состояния. Сначала: pwsh firecrawl-key.ps1 -Mode Init' -ForegroundColor Red; exit 1 }
$s = Get-Content $stateFile -Raw | ConvertFrom-Json
$sw = [Diagnostics.Stopwatch]::StartNew()
$done = $false
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec -and -not $done) {
    Start-Sleep -Seconds 3
    try {
        $r = Invoke-RestMethod -Method Post -Uri 'https://www.firecrawl.dev/api/auth/cli/status' `
            -ContentType 'application/json' `
            -Body (@{ session_id = $s.session_id; code_verifier = $s.code_verifier } | ConvertTo-Json -Compress)
        if ($r.status -eq 'complete') {
            [Environment]::SetEnvironmentVariable('FIRECRAWL_API_KEY', $r.apiKey, 'User')
            $env:FIRECRAWL_API_KEY = $r.apiKey
            Remove-Item -Path $stateDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "API key СОХРАНЁН в User env: $($r.apiKey.Substring(0, 12))..." -ForegroundColor Green
            $done = $true
        }
    } catch { }
}
if (-not $done) { Write-Host "Ещё не авторизовано за $TimeoutSec c. Повтори Poll: pwsh firecrawl-key.ps1 -Mode Poll" -ForegroundColor Yellow; exit 1 }
& firecrawl --status 2>&1 | Select-Object -First 6