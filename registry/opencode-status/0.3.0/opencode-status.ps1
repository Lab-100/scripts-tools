#requires -Version 7.0
<#
  opencode-status.ps1 - текстовой монитор инфраструктуры opencode.
  Консольная версия графа: те же узлы/статусы, что и в infra-graph.ps1,
  без GUI - удобно в терминале и для автоматизации.

  Режимы:
    без аргументов / -Once   разовый текстовой статус
    -Watch [N]               живое обновление каждые N секунд (по умолчанию 3)
    -Json                    машинный вывод (один объект JSON)
    -NoColor                 без ANSI-цветов (plain)
  Требует pwsh (PowerShell 7) - не Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
  [switch]$Once,
  [switch]$Json,
  [int]$Watch = 3,
  [switch]$NoColor
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference  = 'SilentlyContinue'

$LogPath = Join-Path $env:USERPROFILE '.local\share\opencode\log\opencode.log'
$WdPath  = 'C:\Scripts\tools\mcp-watchdog\state\current.json'

# ---------- сбор статусов ----------
function Get-Status {
  $wd = $null
  if (Test-Path $WdPath) {
    try { $wd = Get-Content $WdPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $wd = $null }
  }

  # opencode: процессы и uptime
  $oc = @(Get-Process OpenCode -ErrorAction SilentlyContinue)
  $ocUptime = '—'
  if ($oc.Count -gt 0) {
    $ms = ($oc | ForEach-Object StartTime | Sort-Object | Select-Object -First 1)
    if ($ms) { $ocUptime = ((Get-Date) - $ms).ToString('h\:mm\:ss') }
  }

  # модель из хвоста лога
  $model = '?'
  if (Test-Path $LogPath) {
    $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $fs.Seek(-([Math]::Min(300000, $fs.Length)), [System.IO.SeekOrigin]::End) | Out-Null
      $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
      $tail = $sr.ReadToEnd()
    } finally { $sr.Dispose(); $fs.Dispose() }
    if ($tail -match 'message="llm runtime selected".*? llm.model=(\S+)') { $model = $Matches[1] }
  }

  function Get-Wd($name) {
    if ($null -eq $wd) { return $null }
    $p = $wd.checks.$name
    if ($null -eq $p) { return $null }
    [pscustomobject]@{ Status = $p.status.ToString(); Detail = $p.detail.ToString() }
  }

  # группы узлов: Группа, Узел, Статус, Uptime, Деталь
  $rows = @()
  $ocStatus = if ($oc.Count -gt 0) { 'ok' } else { 'stop' }
  $rows += [pscustomobject]@{ Group='оркестратор'; Id='opencode';   Label="opencode (модель: $model)"; Status=$ocStatus; Uptime=$ocUptime; Detail=if ($oc.Count -gt 0) { "сессий: $($oc.Count)" } else { 'не запущен' } }

  $rows += [pscustomobject]@{ Group='провайдеры'; Id='ollama-prov'; Label='ollama-провайдер (hermes3)';  Status='ok';   Uptime='—'; Detail='endpoint 11434' }
  $rows += [pscustomobject]@{ Group='провайдеры'; Id='cloud';       Label='opencode cloud (облачная)';    Status='ok';   Uptime='—'; Detail=$model }
  $rows += [pscustomobject]@{ Group='провайдеры'; Id='openrouter';  Label='openrouter (free-резерв)';      Status='stop'; Uptime='—'; Detail='ключ: есть' }

  foreach ($mcp in @('local-llm','firecrawl','MCP_DOCKER')) {
    $w = Get-Wd $mcp
    $st = if ($w) { if ($w.Status -eq 'ok') { 'ok' } else { 'fail' } } else { 'stop' }
    $det = if ($w) { $w.Detail } else { 'нет данных (watchdog?)' }
    $rows += [pscustomobject]@{ Group='MCP'; Id=$mcp; Label="MCP $mcp"; Status=$st; Uptime=''; Detail=$det }
  }

  foreach ($s in @('ollama','browsertool')) {
    $w = Get-Wd $s
    $st = if ($w) { if ($w.Status -eq 'ok') { 'ok' } else { 'fail' } } else { 'stop' }
    $det = if ($w) { $w.Detail } else { 'нет данных' }
    $rows += [pscustomobject]@{ Group='сервисы'; Id=$s; Label="сервис: $s"; Status=$st; Uptime=''; Detail=$det }
  }
  $dockerSt = 'stop'
  if ($null -ne $wd -and $wd.checks.MCP_DOCKER -and $wd.checks.MCP_DOCKER.detail -match 'docker daemon:(True|False)') {
    $dockerSt = if ($Matches[1] -eq 'True') { 'ok' } else { 'warn' }
  }
  $rows += [pscustomobject]@{ Group='инфраструктура'; Id='docker';  Label='Docker Desktop';       Status=$dockerSt; Uptime=''; Detail='daemon: см. MCP_DOCKER' }
  $rows += [pscustomobject]@{ Group='инфраструктура'; Id='lab';     Label='Lab100 (пул ИИ)';       Status='ok';      Uptime=''; Detail='C:\Scripts\Lab100' }
  $rows += [pscustomobject]@{ Group='инфраструктура'; Id='rollback';Label='каталог отката';        Status='ok';      Uptime=''; Detail='E:\rollback-catalog' }
  $rows += [pscustomobject]@{ Group='инфраструктура'; Id='gh';      Label='GitHub (Lab-100/*)';    Status='ok';      Uptime=''; Detail='приватные репо' }

  return [pscustomobject]@{
    Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Model     = $model
    Sessions  = $oc.Count
    Rows      = $rows
  }
}

# ---------- вывод ----------
$script:cMapColor = @{ green='32'; red='31'; yellow='33'; gray='90'; blue='34' }

function Out-Text($s, [bool]$color) {
  "=== opencode-status | $($s.Timestamp) | модель: $($s.Model) | сессий: $($s.Sessions) ==="
  $cMap = @{ 'ok'='green'; 'fail'='red'; 'warn'='yellow'; 'stop'='gray' }
  $curGroup = $null
  foreach ($r in $s.Rows) {
    if ($r.Group -ne $curGroup) {
      $curGroup = $r.Group
      ""
      "[ $curGroup ]"
    }
    $mark = switch ($r.Status) {
      'ok'   { 'OK'   }
      'warn' { 'UP'   }
      'fail' { 'FAIL' }
      'stop' { 'STOP' }
      default { '?'    }
    }
    $body = "{0,-34}  uptime={1,-10} {2}" -f $r.Label, $r.Uptime, $r.Detail
    if ($color) {
      $c = $cMap[$r.Status]; if (-not $c) { $c = 'gray' }
      $mark = "`e[$($script:cMapColor[$c]);1m$($mark.PadRight(4))`e[0m"
    } else { $mark = $mark.PadRight(4) }
    "$mark $body"
  }
}

function Out-Json($s) {
  $s | ConvertTo-Json -Depth 4
}

if ($Json) {
  Out-Json (Get-Status)
  exit 0
}

if ($Once -or $Watch -le 0) {
  Out-Text (Get-Status) (-not $NoColor)
  exit 0
}

# живой режим: очистка экрана между обновлениями
while ($true) {
  Clear-Host
  Out-Text (Get-Status) (-not $NoColor)
  Start-Sleep -Seconds $Watch
}