#Requires -Version 7
<#
  Локальный Vulkan-раннер для роли heavy: llama-server.exe из Docker Model Runner.
  Отключение оверлейного слоя NVIDIA и контрольных точек обходит краш 0xC0000005
  на Windows; GGML_VK_VISIBLE_DEVICES=0 выбирает Intel HD Graphics 630 (GTX 1050
  с 4 ГБ VRAM падает при загрузке ggml-vulkan.dll).
#>
[CmdletBinding()]
param(
    [string]$Model = $env:INVR_DMR_HEAVY_MODEL,
    [int]$Port = 12435,
    [int]$Gpu = 0,
    [int]$WaitSec = 240
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if (-not $Model) { $Model = 'E:\models\Qwen3-4B-Q4_K_M.gguf' }
if (-not (Test-Path -LiteralPath $Model)) { throw "Нет модели: $Model (задайте INVR_DMR_HEAVY_MODEL)" }

$exe = Join-Path $env:USERPROFILE '.docker\bin\inference\llama-server.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "Нет llama-server.exe: $exe" }

try {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) { Write-Host "порт $Port уже занят (pid $($conn[0].OwningProcess)) — раннер не перезапущен"; exit 0 }
} catch {}

$env:DISABLE_LAYER_NV_OPTIMUS_1 = '1'
$env:GGML_VK_VISIBLE_DEVICES = [string]$Gpu
$env:GGML_VK_DISABLE_COOPMAT = '1'
$env:LLAMA_ARG_CTX_CHECKPOINTS = '0'

$p = Start-Process -FilePath $exe -ArgumentList @(
    '-m', $Model,
    '-ngl', '999',
    '--port', [string]$Port,
    '--host', '127.0.0.1',
    '-c', '8192',
    '--ctx-checkpoints', '0'
) -PassThru -WindowStyle Hidden

$ready = $false
for ($i = 0; $i -lt [math]::Ceiling($WaitSec / 4); $i++) {
    Start-Sleep -Seconds 4
    if ($p.HasExited) { throw "llama-server упал, код $($p.ExitCode)" }
    try {
        $h = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3
        if ($h.status -eq 'ok') { $ready = $true; break }
    } catch {}
}
if (-not $ready) { throw "раннер на порту $Port не стал готов за ${WaitSec} с (pid $($p.Id))" }
Write-Host "Vulkan-раннер готов: pid=$($p.Id), port=$Port, gpu=$Gpu, model=$Model"
