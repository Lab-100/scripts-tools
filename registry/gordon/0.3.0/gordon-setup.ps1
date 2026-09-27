# UTF-8 console default (no krakozyabry)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'

Write-Host '=== Gordon setup (автонастройка Docker Agent) ===' -ForegroundColor Cyan

$plugins = @('docker-agent.exe', 'docker-model.exe', 'docker-ai.exe')
$src = 'C:\Program Files\Docker\Docker\resources\cli-plugins'
$dst = "$env:USERPROFILE\.docker\cli-plugins"
foreach ($p in $plugins) {
    $l = Join-Path $dst $p
    if (-not (Test-Path $l)) { New-Item -ItemType SymbolicLink -Path $l -Target (Join-Path $src $p) | Out-Null; Write-Host "  linked $p" }
}
Write-Host "  plugins: ok"

Write-Host '--- Docker Model Runner status ---'
docker model status 2>&1

$have = docker model list 2>&1 | Out-String
if ($have -match '\bqwen3\b') {
    Write-Host '  qwen3 уже локально: ok'
}
else {
    Write-Host '  Потяну ai/qwen3 (~5 ГБ, рекомендуемая Docker для CPU). Это может занять время...'
    docker model pull ai/qwen3
    if ($LASTEXITCODE -ne 0) { Write-Host '  pull не удался — оставлена модель smollm2' -ForegroundColor Yellow }
}

$dir = "$env:USERPROFILE\.agents"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$yaml = @'
models:
  local:
    provider: dmr
    model: ai/qwen3
    max_tokens: 4096
    provider_opts:
      context_size: 8192
      runtime_flags: ["--threads", "4"]
      keep_alive: "30m"
agents:
  root:
    model: local
    description: Gordon (Docker Agent) - локальный бесплатный ИИ
    instruction: |
      Ты - полезный ассистент. Отвечай кратко и по делу.
    toolsets: []
'@
Set-Content -Path (Join-Path $dir 'gordon.yaml') -Value $yaml -Encoding utf8
Write-Host "  агент-конфиг: $dir\gordon.yaml"

Write-Host '--- docker agent doctor ---'
docker agent doctor (Join-Path $dir 'gordon.yaml') 2>&1 | Select-Object -Last 20

Write-Host '=== Готово. Использование: ===' -ForegroundColor Green
$gordonShim = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'gordon.ps1'
Write-Host "  ротатор:   pwsh $gordonShim -Prompt `"задача`""
Write-Host '  напрямую:  docker agent run $HOME\.agents\gordon.yaml --exec "задача"'