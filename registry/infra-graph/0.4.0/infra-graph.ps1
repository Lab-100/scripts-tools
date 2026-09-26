#requires -Version 7.0
<#
  infra-graph.ps1 - карта графов всей инфраструктуры оркестратора
  Окно рисует граф: открытые сессии opencode, провайдеры моделей, MCP-серверы,
  сервисы (ollama/docker/browsertool), пул Lab100, каталог отката, GitHub.
  Индикация на узле: работает/запущен/завис/остановлен + время работы.
  Сворачивается в трей. Запускать В ИНТЕРАКТИВНОЙ СЕССИИ (из opencode окна не видны).
  Режимы:
    без аргументов   - GUI-окно с графом и треем
    -Status          - разовый текстовый статус всех узлов (для проверки)
    -Shot <png>      - отрисовать граф в PNG (offline-рендер, можно звать из opencode)
#>
param(
  [switch]$Status,
  [string]$Shot
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$off = [System.Text.Encoding]::UTF8
$LogPath = Join-Path $env:USERPROFILE '.local\share\opencode\log\opencode.log'
$WdPath  = 'C:\Scripts\tools\mcp-watchdog\state\current.json'
$WdLog   = 'C:\Scripts\Logs\mcp-watchdog.log'

# ---------- сбор статусов ----------
function Get-NodeStatus {
  $wd = $null
  if (Test-Path $WdPath) {
    try { $wd = Get-Content $WdPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $wd = $null }
  }

  # открытые сессии opencode
  $oc = @(Get-Process OpenCode -ErrorAction SilentlyContinue)
  $ocUptime = '—'
  if ($oc.Count -gt 0) {
    $minStart = ($oc | ForEach-Object StartTime | Sort-Object | Select-Object -First 1)
    if ($minStart) { $ocUptime = ((Get-Date) - $minStart).ToString('h\:mm\:ss') }
  }
  $ocStatus = if ($oc.Count -gt 0) { 'green' } else { 'gray' }
  $ocDetail = if ($oc.Count -gt 0) { "сессий: $($oc.Count)" } else { 'не запущен' }

  # модель из хвоста лога
  $model = '?'
  if (Test-Path $LogPath) {
    $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $fs.Seek(-([Math]::Min(300000, $fs.Length)), [System.IO.SeekOrigin]::End) | Out-Null
      $sr = New-Object System.IO.StreamReader($fs, $off)
      $tail = $sr.ReadToEnd()
    } finally { $sr.Dispose(); $fs.Dispose() }
    if ($tail -match 'message="llm runtime selected".*? llm.model=(\S+)') { $model = $Matches[1] }
  }

  # MCP / сервисы из watchdog (status: ok, fail, ...)
  function Get-Wd($name) {
    if ($null -eq $wd) { return $null }
    $p = $wd.checks.$name
    if ($null -eq $p) { return $null }
    [pscustomobject]@{ Status = $p.status.ToString(); Detail = $p.detail.ToString() }
  }

  $nodes = @()
  function New-Node($id, $label, $status, $uptime, $detail) {
    [pscustomobject]@{ Id=$id; Label=$label; Status=$status; Uptime=$uptime; Detail=$detail }
  }

  # 1. оркестратор
  $nodes += New-Node 'oc' "opencode`nоркестратор`nмодель: $model" $ocStatus $ocUptime $ocDetail

  # 2. провайдеры моделей
  $nodes += New-Node 'ollama-prov' "ollama`nпровайдер (hermes3)"                'green'  '—' 'endpoint 11434'
  $nodes += New-Node 'cloud'      "opencode cloud`n(облачная модель)"           'green'  '—' 'big-pickle'
  $nodes += New-Node 'openrouter' "openrouter`n(free-резерв)"                   'gray'   '—' 'ключ: есть'

  # 3. MCP-серверы
  foreach ($mcp in @('local-llm','firecrawl','MCP_DOCKER')) {
    $w = Get-Wd $mcp
    $st = if ($w) { if ($w.Status -eq 'ok') { 'green' } else { 'red' } } else { 'gray' }
    $up = if ($w) { '' } else { '—' }
    $det = if ($w) { $w.Detail } else { 'нет данных (watchdog?)' }
    $nodes += New-Node $mcp "MCP $mcp" $st $up $det
  }

  # 4. сервисы
  $svc = @('ollama','browsertool')
  foreach ($s in $svc) {
    $w = Get-Wd $s
    $st = if ($w) { if ($w.Status -eq 'ok') { 'green' } else { 'red' } } else { 'gray' }
    $det = if ($w) { $w.Detail } else { 'нет данных' }
    $nodes += New-Node $s "сервис: $s" $st '' $det
  }
  $dw = $wd
  $dockerSt = if ($null -ne $dw -and $dw.checks.MCP_DOCKER -and $dw.checks.MCP_DOCKER.detail -match 'docker daemon:(True|False)') { if ($Matches[1] -eq 'True') { 'green' } else { 'yellow' } } else { 'gray' }
  $nodes += New-Node 'docker' "Docker Desktop`n(инфраструктура)" $dockerSt '' 'daemon: см. MCP_DOCKER'

  # 5. демон-страж mcp-watchdog (контролирует MCP-серверы и сервисы)
  $wdProc = @()
  $wdUp = '—'; $wdStatus = 'gray'
  try {
    $wdProc = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction Stop |
      Where-Object { $_.CommandLine -match 'mcp-watchdog' })
    if ($wdProc.Count -gt 0) {
      $wdStatus = 'green'
      $wdSw = Get-Process -Id $wdProc[0].ProcessId -ErrorAction SilentlyContinue
      if ($wdSw -and $wdSw.StartTime) { $wdUp = ((Get-Date) - $wdSw.StartTime).ToString('h\:mm\:ss') }
    }
  } catch { }
  # открытые заявки демона (тикеты проверки серверов)
  $openTk = 0
  $reqDir = Join-Path $PSScriptRoot 'mcp-watchdog\requests'
  if (Test-Path $reqDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $reqDir -Filter 'chk_*.json' -ErrorAction SilentlyContinue)) {
      try {
        $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
        if ($j.status -ne 'resolved') { $openTk++ }
      } catch { }
    }
  }
  $wdDet = if ($wdProc.Count -gt 0) {
    if ($openTk -gt 0) { "заявок: $openTk" } else { 'все сервисы в норме' }
  } else { 'демон не запущен' }
  $nodes += New-Node 'watchdog' "mcp-watchdog`nдемон-страж" $wdStatus $wdUp $wdDet

  # 6. пул Lab100
  $labDet = 'C:\Scripts\Lab100'
  $poolSt = 'yellow'
  $nodes += New-Node 'lab' "Lab100`nпул ИИ-агентов" $poolSt '' $labDet

  # 7. хранилище / git
  $nodes += New-Node 'rollback' "каталог отката`nE:\rollback-catalog" 'green' '' 'приватный репо'
  $nodes += New-Node 'gh' "GitHub`nLab-100/*" 'green' '' 'приватные репо'

  return @{ Nodes = $nodes; Opencode = $oc; Model = $model }
}

# ---------- метрики производительности по узлам-агентам ----------
# сопоставление узла с (обычно парой) процессов по имени/командной строке.
# Возврат: id -> @{ Ram=байт; CpuPct=% (делится на ядра); Disk=байт; Where='CPU'|'GPU'}
function Get-ProcsByNode {
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $match = @{
    'oc'          = { $_.Name -eq 'OpenCode.exe' -or $_.Name -eq 'opencode.exe' }
    'ollama-prov' = { $_.Name -match 'ollama' }
    'ollama'      = { $_.Name -match 'ollama' }
    'local-llm'   = { $_.Name -eq 'python.exe' -and $_.CommandLine -match 'llm_mcp_server' }
    'firecrawl'   = { $_.Name -eq 'node.exe' -and $_.CommandLine -match 'firecrawl' }
    'MCP_DOCKER'  = { ($_.Name -eq 'node.exe' -or $_.Name -eq 'bun.exe') -and $_.CommandLine -match 'mcp' }
    'docker'      = { $_.Name -match 'Docker Desktop' -or $_.Name -match 'com.docker.backend' -or $_.Name -match 'vpnkit' -or $_.Name -match 'wsl' }
    'browsertool' = { $_.Name -eq 'node.exe' -and $_.CommandLine -match 'driver.mjs' }
    'watchdog'    = { $_.Name -eq 'pwsh.exe' -and $_.CommandLine -match 'mcp-watchdog' }
    'lab'         = { $_.Name -eq 'python.exe' -and $_.CommandLine -match 'lab100' }
  }
  $out = @{}
  foreach ($k in $match.Keys) {
    $ps = @($all | Where-Object { & $match[$k] })
    if ($ps.Count -eq 0 -and $k -ne 'lab') { continue }
    $ram = ($ps | Measure-Object WorkingSetSize -Sum -ErrorAction SilentlyContinue).Sum
    $cpu = ($ps | Measure-Object -Property KernelModeTime -Sum -ErrorAction SilentlyContinue).Sum +
           ($ps | Measure-Object -Property UserModeTime -Sum -ErrorAction SilentlyContinue).Sum
    $out[$k] = [pscustomobject]@{
      Ram  = if ($ram) { [long]$ram } else { 0 }
      CpuTicks = if ($cpu) { [double]$cpu } else { 0.0 }   # накапливаемое время CPU в тиках
      Where = 'CPU'
    }
  }
  return $out
}
# кэш предыдущего замера CPU и текущих значений (пересчитывается в таймере)
$script:cpuPrev = @{}
$script:perf = @{}
$script:diskSizes = @{}
$script:perfLast = [DateTime]::MinValue

function Get-PerfText($nodeId) {
  # агрегация RAM и диска одного агента (ollama-prov и ollama делят процесс)
  $p = $script:perf
  if (-not $p -or -not $p.ContainsKey($nodeId)) { return '' }
  $m = $p[$nodeId]
  $parts = @()
  if ($m.Ram -gt 0) { $parts += ("ram:{0}" -f (Format-Size $m.Ram)) }
  if ($m.CpuPct -gt 0.5) { $parts += ("cpu:{0}%" -f [int]$m.CpuPct) }
  if ($m.Disk -gt 0) { $parts += ("dsk:{0}" -f (Format-Size $m.Disk)) }
  $parts += $m.Where
  return ($parts -join '  ')
}

function Format-Size([long]$bytes) {
  if ($bytes -ge 1GB)  { return ('{0:f1}G' -f ($bytes/1GB)) }
  if ($bytes -ge 1MB)  { return ('{0:f0}M' -f ($bytes/1MB)) }
  return ('{0}K' -f [int]([Math]::Ceiling($bytes/1KB)))
}

# обновить метрики (вызывается по таймеру, каждые 3 с)
function Update-Perf {
  $now = [DateTime]::UtcNow
  $procs = Get-ProcsByNode
  # раз в 5 минут и при первом запуске пересчитываем размеры на диске (до построения perf)
  if (($now - $script:perfLast).TotalMinutes -gt 5 -or $script:diskSizes.Count -eq 0) {
    $script:diskSizes = @{}
    $script:diskSizes['ollama'] = Get-DirSize 'E:\OllamaModels'
    $dockerVhdx = $null
    foreach ($cand in @((Join-Path $env:LOCALAPPDATA 'Docker\wsl\data\ext4.vhdx'), 'E:\Libraries\DockerDesktopWSL\main\ext4.vhdx', 'D:\Libraries\DockerDesktopWSL\main\ext4.vhdx')) {
      if (Test-Path -LiteralPath $cand) { $dockerVhdx = $cand; break }
    }
    $script:diskSizes['docker'] = if ($dockerVhdx) { Get-DirSize $dockerVhdx } else { 0 }
    $script:diskSizes['lab']    = Get-DirSize 'C:\Scripts\Lab100'
    $script:perfLast = $now
  }
  $cores = [Math]::Max(1, [Environment]::ProcessorCount)
  $pct = @{}
  foreach ($k in $procs.Keys) {
    $m = $procs[$k]
    $prev = $script:cpuPrev[$k]
    $diff = 0.0
    if ($prev) {
      $dt = ($now - $prev.Time).TotalSeconds
      if ($dt -gt 0.1) { $diff = ($m.CpuTicks - $prev.Ticks) / ($dt * 10000000) }  # сек/сек
    }
    $script:cpuPrev[$k] = @{ Time = $now; Ticks = $m.CpuTicks }
    $pct[$k] = [Math]::Min(999, [Math]::Max(0.0, ($diff / $cores) * 100.0))
  }
  $script:perf = @{}
  foreach ($k in $procs.Keys) {
    $script:perf[$k] = [pscustomobject]@{
      Ram    = [long]$procs[$k].Ram
      CpuPct = $pct[$k]
      Disk   = $script:diskSizes[$k]
      Where  = 'CPU'
    }
  }
}

function Get-DirSize([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return 0 }
  try {
    if ((Get-Item -LiteralPath $path -Force).PSIsContainer) {
      return (Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    }
    return (Get-Item -LiteralPath $path -Force).Length
  } catch { return 0 }
}

# ---------- сцена + трансформ: центрирование графа в окне, масштаб ----------
$script:SceneW = 1040.0; $script:SceneH = 780.0   # виртуальная сцена (все координаты узлов)
$script:PosFrac = $null   # id -> @{ Xf; Yf } (доли сцены; ресайз решает трансформ)
$script:animT  = 0.0      # фаза анимации (змейки/пульс) по рёбрам
$script:edgeLast = @{}    # ребро "from|to" -> @{ Dir=1|-1; Last=[DateTime] } (последний реальный трафик)
$script:snakes = @()      # активные змейки-импульсы (по одной на запрос/ответ):
                          # @{ E='from|to'; Dir=1|-1; Start=[DateTime] }
$script:edgeCursor = $null  # последний обработанный timestamp лога (дедуп событий)
$script:wdCursor   = $null  # то же для лога демона-стража (встречный трафик в граф)
$script:PosFile = Join-Path $PSScriptRoot 'infra-graph.positions.json'   # запоминание ручной раскладки

# шрифты и измерительная графика (рамки узлов считаются по тексту)
$script:fTitle = [System.Drawing.Font]::new('Segoe UI Semibold', 10.5)
$script:fSub   = [System.Drawing.Font]::new('Segoe UI', 8.2)
$script:fUp    = [System.Drawing.Font]::new('Consolas', 8)
$script:mBmp = [System.Drawing.Bitmap]::new(8, 8)
$script:mG   = [System.Drawing.Graphics]::FromImage($script:mBmp)

function Get-Transform([double]$W, [double]$H) {
  # единый масштаб + центрирование виртуальной сцены в реальном окне
  $scale = [Math]::Min($W / $script:SceneW, $H / $script:SceneH)
  $scale = [Math]::Min($scale, 1.5)
  return @{ Scale = $scale; Ox = ($W - $script:SceneW*$scale)/2; Oy = ($H - $script:SceneH*$scale)/2 }
}
function SceneToScreen($t, [double]$x, [double]$y) {
  [System.Drawing.PointF]::new($t.Ox + $x*$t.Scale, $t.Oy + $y*$t.Scale)
}
function ScreenToScene($t, [double]$x, [double]$y) {
  [System.Drawing.PointF]::new(($x - $t.Ox)/$t.Scale, ($y - $t.Oy)/$t.Scale)
}

# размер узла под его надписи (текст не выходит за рамку)
function Get-NodeSize($n) {
  $lines = $n.Label -split "`n"
  # единый вертикальный шаг строки — по высоте заголовочного шрифта (запас для подстрок)
  $step = [Math]::Ceiling($script:fTitle.Height)
  $w = 0.0
  for ($i=0; $i -lt $lines.Count; $i++) {
    $f = if ($i -eq 0) { $script:fTitle } else { $script:fSub }
    $sz = $script:mG.MeasureString($lines[$i], $f)
    if ($sz.Width -gt $w) { $w = $sz.Width }
  }
  $w = [int]($w + 34)   # маркер 8 + отступ 26
  $h = [int]($lines.Count * $step + 14)   # строки + вертикальные поля
  if ($n.Uptime -and $n.Uptime -ne '—') { $h += 16 }
  return @{ W = [Math]::Max($w, 150); H = [Math]::Max($h, 50) }
}

# автораскладка БЕЗ перекрытий: узлы выстраиваются по слоям (сверху вниз),
# внутри слоя — по центру сцены с реальными размерами и зазором; ширина слоя
# заранее суммируется, чтобы ни один узел не наехал на соседа.
function Get-DefaultPositions([array]$nodeObjs) {
  $layerIds = @(
    @('oc','watchdog'),
    @('ollama-prov','cloud','openrouter'),
    @('local-llm','firecrawl','MCP_DOCKER'),
    @('ollama','browsertool','docker'),
    @('lab','rollback','gh')
  )
  $m = @{}; if ($nodeObjs) { foreach ($n in $nodeObjs) { $m[$n.Id] = $n } }
  $pos = @{}
  $y = 24.0
  $gapH = 46.0; $gapV = 46.0
  foreach ($layer in $layerIds) {
    $row = @()
    foreach ($id in $layer) { if ($m.ContainsKey($id)) { $row += $m[$id] } }
    if ($row.Count -eq 0) { continue }
    $totalW = 0.0; $maxH = 0.0
    foreach ($n in $row) {
      $sz = Get-NodeSize $n
      $totalW += $sz.W
      if ($sz.H -gt $maxH) { $maxH = $sz.H }
    }
    $totalW += $gapH * ($row.Count - 1)
    $x = ($script:SceneW - $totalW) / 2
    foreach ($n in $row) {
      $sz = Get-NodeSize $n
      $pos[$n.Id] = [System.Drawing.Point]::new([int]$x, [int]$y)
      $x += $sz.W + $gapH
    }
    $y += $maxH + $gapV
  }
  # узлы, не попавшие ни в один слой — последовательно под последний ряд,
  # перенос по ширине сцены
  $cx = 40.0; $cy = $y
  $tailH = 56.0
  foreach ($id in $m.Keys) {
    if ($pos.ContainsKey($id)) { continue }
    $sz = Get-NodeSize $m[$id]
    $pos[$id] = [System.Drawing.Point]::new([int]$cx, [int]$cy)
    $cx += $sz.W + $gapH
    if ($cx + $sz.W -gt ($script:SceneW - 40)) { $cx = 40.0; $cy += $tailH + $gapV }
  }
  return $pos
}

function Save-Positions {
  try {
    $obj = @{}
    foreach ($k in $script:PosFrac.Keys) {
      $f = $script:PosFrac[$k]
      $obj[$k] = [pscustomobject]@{ Xf = [Math]::Round($f.Xf, 4); Yf = [Math]::Round($f.Yf, 4) }
    }
    $obj | ConvertTo-Json | Set-Content -LiteralPath $script:PosFile -Encoding utf8
  } catch { }
}

function Initialize-PosFrac([array]$nodeObjs) {
  $saved = $null
  if (Test-Path $script:PosFile) {
    try { $saved = Get-Content -LiteralPath $script:PosFile -Raw | ConvertFrom-Json } catch { $saved = $null }
  }
  if ($saved) {
    # позиции из файла: Xf/Yf — доли сцены (ресайз-безопасны, как и autolayout)
    $script:PosFrac = @{}
    foreach ($prop in $saved.PSObject.Properties) {
      $v = $prop.Value
      if ($null -eq $v) { continue }
      $xf = [double]$v.Xf; $yf = [double]$v.Yf
      if ($xf -is [double] -or $xf -is [int] -or $xf -is [long]) {
        $script:PosFrac[$prop.Name] = @{ Xf = $xf; Yf = $yf }
      }
    }
    # узлы, которых нет в файле (новые) — добавить автораскладкой
    $def = Get-DefaultPositions $nodeObjs
    foreach ($id in $def.Keys) {
      if (-not $script:PosFrac.ContainsKey($id)) {
        $p = $def[$id]
        $script:PosFrac[$id] = @{ Xf = $p.X / $script:SceneW; Yf = $p.Y / $script:SceneH }
      }
    }
    return
  }
  $def = Get-DefaultPositions $nodeObjs
  $script:PosFrac = @{}
  foreach ($k in $def.Keys) {
    $p = $def[$k]
    $script:PosFrac[$k] = @{ Xf = $p.X / $script:SceneW; Yf = $p.Y / $script:SceneH }
  }
}

# позиции узлов в координатах СЦЕНЫ (не зависят от размера окна —
# центрирование/масштаб на окно делает трансформ по Render-Time)
function Resolve-PositionsScene([array]$nodeObjs = $null) {
  if ($null -eq $script:PosFrac) {
    if ($null -eq $nodeObjs -and $script:st) { $nodeObjs = $script:st.Nodes }
    Initialize-PosFrac $nodeObjs
  }
  $out = @{}
  foreach ($k in $script:PosFrac.Keys) {
    $f = $script:PosFrac[$k]
    $out[$k] = [System.Drawing.PointF]::new($f.Xf * $script:SceneW, $f.Yf * $script:SceneH)
  }
  return $out
}

# ---------- активность рёбер по логу ----------
# Каждое ребро "from|to" получает последний РЕАЛЬНЫЙ вектор трафика:
#   Dir =  1  запрос от источника к приёмнику (поток "вниз" по ребру)
#   Dir = -1  ответ от приёмника к источнику (поток "обратно")
#   Last = время последнего события. Древние события -> стрелка гаснет, серая.
function Update-EdgeActivity {
  if (-not (Test-Path $LogPath)) { return }
  try {
    $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $fs.Seek(-([Math]::Min(400000, $fs.Length)), [System.IO.SeekOrigin]::End) | Out-Null
      $sr = New-Object System.IO.StreamReader($fs, $off)
      $tail = $sr.ReadToEnd()
    } finally { $sr.Dispose(); $fs.Dispose() }
  } catch { return }

  # одна змейка на ОДНО реальное событие (запрос/ответ); дедуп — по курсору,
  # т.к. хвост лога перечитывается каждый тик
  $foundTs = $null

  foreach ($line in ($tail -split "`r?`n")) {
    if (-not $line.StartsWith('timestamp=')) { continue }
    $mTs = [regex]::Match($line, '^timestamp=(\S+)')
    if (-not $mTs.Success) { continue }
    $ts = $null
    try {
      $ts = [datetime]::Parse($mTs.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime()
    } catch { continue }
    if ($ts -lt ((Get-Date).AddMinutes(-5))) { continue }
    if ($script:edgeCursor -and $ts -le $script:edgeCursor) { continue }
    if (-not $foundTs -or $ts -gt $foundTs) { $foundTs = $ts }

    function Reg($p) { $mm = [regex]::Match($line, $p); if ($mm.Success) { $mm.Groups[1].Value } else { $null } }

    # --- ответ модели (stream): поток идёт обратно в opencode ---
    $provId = Reg 'providerID=(\S+)'
    if ($provId) {
      $node = switch ($provId) { 'opencode' { 'cloud' } 'openrouter' { 'openrouter' } 'ollama' { 'ollama-prov' } default { $null } }
      if ($node) {
        $key = "oc|$node"
        $script:edgeLast[$key] = @{ Dir = -1; Last = $ts }
        $script:snakes += @{ E = $key; Dir = -1; Start = $ts }
        if ($node -eq 'ollama-prov') {
          $script:edgeLast['ollama-prov|ollama'] = @{ Dir = -1; Last = $ts }
          $script:snakes += @{ E = 'ollama-prov|ollama'; Dir = -1; Start = $ts }
        }
      }
    }
    # --- выбор LLM-рантайма перед запросом: поток вниз (запрос) ---
    $prov = Reg 'llm\.provider=(\S+)'
    if ($prov) {
      $node = switch ($prov) { 'opencode' { 'cloud' } 'openrouter' { 'openrouter' } 'ollama' { 'ollama-prov' } default { $null } }
      if ($node) {
        $key = "oc|$node"
        $script:edgeLast[$key] = @{ Dir = 1; Last = $ts }
        $script:snakes += @{ E = $key; Dir = 1; Start = $ts }
        if ($node -eq 'ollama-prov') {
          $script:edgeLast['ollama-prov|ollama'] = @{ Dir = 1; Last = $ts }
          $script:snakes += @{ E = 'ollama-prov|ollama'; Dir = 1; Start = $ts }
        }
      }
    }
    # --- вызов инструмента (permission): запрос вниз ---
    $tool = Reg 'message=evaluated permission=(firecrawl_\w+|MCP_DOCKER_\w+|local-llm_\w+)'
    if ($tool) {
      if ($tool -like 'firecrawl_*') {
        $script:edgeLast['oc|firecrawl'] = @{ Dir = 1; Last = $ts }
        $script:snakes += @{ E = 'oc|firecrawl'; Dir = 1; Start = $ts }
      } elseif ($tool -like 'MCP_DOCKER_*') {
        $script:edgeLast['oc|MCP_DOCKER'] = @{ Dir = 1; Last = $ts }
        $script:snakes += @{ E = 'oc|MCP_DOCKER'; Dir = 1; Start = $ts }
        $script:edgeLast['MCP_DOCKER|docker'] = @{ Dir = 1; Last = $ts }
        $script:snakes += @{ E = 'MCP_DOCKER|docker'; Dir = 1; Start = $ts }
      } elseif ($tool -like 'local-llm_*') {
        $script:edgeLast['oc|local-llm'] = @{ Dir = 1; Last = $ts }
        $script:snakes += @{ E = 'oc|local-llm'; Dir = 1; Start = $ts }
        $script:edgeLast['local-llm|ollama'] = @{ Dir = 1; Last = $ts }
        $script:snakes += @{ E = 'local-llm|ollama'; Dir = 1; Start = $ts }
      }
    }
    # --- MCP-сервер отработал (server log): ответ обратно ---
    $srv = Reg 'message="MCP server log" server=(\S+)'
    if ($srv) {
      $node = switch ($srv) { 'firecrawl' { 'firecrawl' } 'MCP_DOCKER' { 'MCP_DOCKER' } 'local-llm' { 'local-llm' } default { $null } }
      if ($node) {
        $key = "oc|$node"
        $script:edgeLast[$key] = @{ Dir = -1; Last = $ts }
        $script:snakes += @{ E = $key; Dir = -1; Start = $ts }
        if ($node -eq 'MCP_DOCKER') {
          $script:edgeLast['MCP_DOCKER|docker'] = @{ Dir = -1; Last = $ts }
          $script:snakes += @{ E = 'MCP_DOCKER|docker'; Dir = -1; Start = $ts }
        }
        if ($node -eq 'local-llm') {
          $script:edgeLast['local-llm|ollama'] = @{ Dir = -1; Last = $ts }
          $script:snakes += @{ E = 'local-llm|ollama'; Dir = -1; Start = $ts }
        }
      }
    }
  }

  # продвинули курсор: события старше него повторно змейку не создадут
  if ($foundTs) {
    if (-not $script:edgeCursor -or $foundTs -gt $script:edgeCursor) { $script:edgeCursor = $foundTs }
  } elseif (-not $script:edgeCursor) {
    $script:edgeCursor = (Get-Date)
  }

  # --- встречный трафик "объект -> демон-страж" по логу самого демона ---
  # каждая строка CHECK/WARN по конкретному серверу = сервер передал демону свой статус,
  # поэтому змейка летит ОТ сервера К демону (reverse ctl-ребра "watchdog|server").
  if (Test-Path $WdLog) {
    try {
      $wfs = [System.IO.File]::Open($WdLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      try {
        $wfs.Seek(-([Math]::Min(200000, $wfs.Length)), [System.IO.SeekOrigin]::End) | Out-Null
        $wsr = New-Object System.IO.StreamReader($wfs, $off)
        $wtail = $wsr.ReadToEnd()
      } finally { $wsr.Dispose(); $wfs.Dispose() }
    } catch { $wtail = '' }

    $wdFoundTs = $null
    # соответствие имени сервера в логе демона -> id узла графа
    $wdNodes = @{ 'local-llm'='local-llm'; 'firecrawl'='firecrawl'; 'MCP_DOCKER'='MCP_DOCKER';
                  'ollama'='ollama'; 'browsertool'='browsertool'; 'docker'='docker'; 'lab'='lab' }
    foreach ($wline in ($wtail -split "`r?`n")) {
      if ($wline -notmatch '\[(CHECK|WARN|ERROR)\]') { continue }
      $wTm = [regex]::Match($wline, '\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]')
      if (-not $wTm.Success) { continue }
      $wts = $null
      try { $wts = [datetime]::ParseExact($wTm.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null) } catch { continue }
      if ($wts -lt ((Get-Date).AddMinutes(-5))) { continue }
      if ($script:wdCursor -and $wts -le $script:wdCursor) { continue }
      if (-not $wdFoundTs -or $wts -gt $wdFoundTs) { $wdFoundTs = $wts }

      $wSrv = [regex]::Match($wline, '\] (local-llm|firecrawl|MCP_DOCKER|ollama|browsertool|docker|lab)\s*:')
      if (-not $wSrv.Success) { continue }
      $node = $wdNodes[$wSrv.Groups[1].Value]
      if (-not $node) { continue }
      # объект сообщил демону: поток от объекта к демону (Dir=-1 на "watchdog|объект")
      $key = "watchdog|$node"
      $script:edgeLast[$key] = @{ Dir = -1; Last = $wts }
      $script:snakes += @{ E = $key; Dir = -1; Start = $wts }
    }
    if ($wdFoundTs) {
      if (-not $script:wdCursor -or $wdFoundTs -gt $script:wdCursor) { $script:wdCursor = $wdFoundTs }
    } elseif (-not $script:wdCursor) {
      $script:wdCursor = (Get-Date)
    }
  }

  # выкидываем отжившие змейки (старше 5 с) — пул не растёт
  $cut = (Get-Date).AddSeconds(-5)
  $script:snakes = @($script:snakes | Where-Object { $_.Start -ge $cut })
  if ($script:snakes.Count -gt 250) { $script:snakes = @($script:snakes | Select-Object -Last 250) }
}

# плавное смешение цвета (яркое -> серое) по свежести 0..1
function Lerp-Color($cA, $cB, $t) {
  $t = [Math]::Max(0.0, [Math]::Min(1.0, $t))
  [System.Drawing.Color]::FromArgb(
    [int]($cA.A + ($cB.A - $cA.A)*$t),
    [int]($cA.R + ($cB.R - $cA.R)*$t),
    [int]($cA.G + ($cB.G - $cA.G)*$t),
    [int]($cA.B + ($cB.B - $cA.B)*$t))
}

# ---------- текстовый статус ----------
if ($Status) {
  Update-Perf
  $st = Get-NodeStatus
  "Граф инфраструктуры (модель: $($st.Model)):"
  $st.Nodes | ForEach-Object {
    $mark = switch ($_.Status) { 'green' { 'OK  ' } 'yellow' { 'UP  ' } 'red' { 'FAIL' } 'gray' { 'STOP' } default { ' ?  ' } }
    $perfTxt = Get-PerfText $_.Id
    $line = "{0,-28} {1} uptime={2,-10} {3}" -f $_.Label.Split("`n")[0], $mark, $_.Uptime, $_.Detail
    if ($perfTxt) { $line += "  |  $perfTxt" }
    $line
  }
  exit 0
}

# ---------- GDI+ рендер ----------
function Invoke-DrawGraph($g, $nodes, [bool]$pulse) {
  $W = $g.VisibleClipBounds.Width
  $H = $g.VisibleClipBounds.Height
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'AntiAliasGridFit'

  # карта статусов -> цвет
  $col = @{
    green  = [System.Drawing.Color]::FromArgb(0, 200, 90)
    yellow = [System.Drawing.Color]::FromArgb(235, 185, 40)
    red    = [System.Drawing.Color]::FromArgb(235, 60, 60)
    gray   = [System.Drawing.Color]::FromArgb(90, 96, 106)
  }

  # трансформ: масштаб + центрирование виртуальной сцены в реальном окне
  $t   = Get-Transform $W $H
  $g.TranslateTransform($t.Ox, $t.Oy)
  $g.ScaleTransform($t.Scale, $t.Scale)
  $pos = Resolve-PositionsScene $nodes

  # связи (from -> to)
  # watchdog (демон-страж) контролирует: MCP-серверы, сервисы, docker, пул
  $edges = @(
    @('oc','ollama-prov'), @('oc','cloud'), @('oc','openrouter'),
    @('oc','local-llm'), @('oc','firecrawl'), @('oc','MCP_DOCKER'),
    @('ollama-prov','ollama'), @('local-llm','ollama'),
    @('firecrawl','ollama'), @('MCP_DOCKER','docker'),
    @('oc','browsertool'), @('oc','lab'), @('lab','rollback'), @('lab','gh'),
    # демон-страж -> кого контролирует
    @('watchdog','oc','ctl'), @('watchdog','local-llm','ctl'), @('watchdog','firecrawl','ctl'),
    @('watchdog','MCP_DOCKER','ctl'), @('watchdog','ollama','ctl'), @('watchdog','browsertool','ctl'),
    @('watchdog','docker','ctl'), @('watchdog','lab','ctl'),
    # пул ИИ -> какие модели/пулы использует в каскаде
    @('lab','ollama-prov'), @('lab','cloud')
  )

  $nodeMap = @{}; foreach ($n in $nodes) { $nodeMap[$n.Id] = $n }

  # координаты центров узлов в сцене
  $cen = @{}
  foreach ($n in $nodes) {
    if (-not $pos.ContainsKey($n.Id)) { continue }
    $sz = Get-NodeSize $n
    $p  = $pos[$n.Id]
    $cen[$n.Id] = @{ X = $p.X + $sz.W/2; Y = $p.Y + $sz.H/2; W = $sz.W; H = $sz.H }
  }

  # рисуем связи
  # РАБОЧАЯ связь = оба узла живые (не red/не gray) -> направленная анимация
  # (змейка летит строго по вектору запроса: от источника к приёмнику).
  # Нерабочая связь -> сухая пунктирная линия, БЕЗ анимации.
  $iEdge = 0
  foreach ($e in $edges) {
    if (-not $cen.ContainsKey($e[0]) -or -not $cen.ContainsKey($e[1])) { $iEdge++; continue }
    $cA = $cen[$e[0]]; $cB = $cen[$e[1]]
    $nA = $nodeMap[$e[0]]; $nB = $nodeMap[$e[1]]
    $aliveA = ($null -ne $nA) -and ($nA.Status -notin @('red','gray'))
    $aliveB = ($null -ne $nB) -and ($nB.Status -notin @('red','gray'))
    $x1 = $cA.X; $y1 = $cA.Y + $cA.H/2          # низ источника
    $x2 = $cB.X; $y2 = $cB.Y - $cB.H/2          # верх приёмника

    # контрольные рёбра демона-стража: пунктирная лиловая линия (не трафик)
    if ($e.Count -gt 2 -and $e[2] -eq 'ctl') {
      $ctlOn  = [System.Drawing.Color]::FromArgb(168, 120, 235)
      $ctlOff = [System.Drawing.Color]::FromArgb(78, 64, 110)
      $ctlFade = 0.0; if ($nA.Status -eq 'gray') { $ctlFade = 1.0 }
      $ctlC = Lerp-Color $ctlOn $ctlOff $ctlFade
      $penCtl = [System.Drawing.Pen]::new($ctlC, 1.4)
      $penCtl.DashStyle = 'Dot'
      $g.DrawLine($penCtl, $x1, $y1, $x2, $y2)
      # маленький кубик-маркер "контроль" в середине ребра
      $mx = ($x1+$x2)/2; $my = ($y1+$y2)/2
      $cb = [System.Drawing.SolidBrush]::new($ctlC)
      $g.FillRectangle($cb, ($mx-2), ($my-2), 4, 4)
      $cb.Dispose()
      $penCtl.Dispose()
      $iEdge++
      continue
    }

    if (-not ($aliveA -and $aliveB)) {
      # нерабочая связь: пунктир, без свечения/змейки/стрелки
      $penDead = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(60, 70, 85), 1.2)
      $penDead.DashStyle = 'Dash'
      $g.DrawLine($penDead, $x1, $y1, $x2, $y2)
      $penDead.Dispose()
      $iEdge++
      continue
    }

    # --- РАБОЧАЯ связь: свечение + базовая линия ---
    # активность ребра по логу (реальные запросы/ответы)
    $actKey = "$($e[0])|$($e[1])"
    $act = $script:edgeLast[$actKey]
    $fresh = 0.0
    if ($act) {
      $ageSec = ((Get-Date) - $act.Last).TotalSeconds
      $fresh  = [Math]::Max(0.0, 1.0 - $ageSec/5.0)   # свежий вектор -> 1, гаснет за 5 с
    }
    $dirFlip = if ($act -and $fresh -gt 0.1) { if ($act.Dir -eq -1) { -1 } else { 1 } } else { 1 }
    # при "ответе" поток идёт в обратную сторону (от приёмника к источнику)
    $sX = $x1; $sY = $y1; $tX = $x2; $tY = $y2
    if ($dirFlip -eq -1) { $sX = $x2; $sY = $y2; $tX = $x1; $tY = $y1 }

    $colBright = [System.Drawing.Color]::FromArgb(90, 190, 235)
    $colDim    = [System.Drawing.Color]::FromArgb(82, 88, 98)
    $colArwOn  = [System.Drawing.Color]::FromArgb(205, 225, 245)
    $colArwOff = [System.Drawing.Color]::FromArgb(66, 72, 82)

    # свечение под линией - гасится с потерей свежести
    $glowC = Lerp-Color ([System.Drawing.Color]::FromArgb(45, 90, 130)) ([System.Drawing.Color]::FromArgb(24, 27, 33)) (1 - $fresh)
    $penGlow = [System.Drawing.Pen]::new($glowC, 8)
    $g.DrawLine($penGlow, $x1, $y1, $x2, $y2)
    $edgeC = Lerp-Color ([System.Drawing.Color]::FromArgb(120, 150, 200)) ([System.Drawing.Color]::FromArgb(62, 68, 78)) (1 - $fresh)
    $penEdge = [System.Drawing.Pen]::new($edgeC, 1.6)
    $g.DrawLine($penEdge, $x1, $y1, $x2, $y2)
    $penEdge.Dispose(); $penGlow.Dispose()
    # змейки-импульсы: по одной на КАЖДОЕ событие (запрос/ответ).
    # события, которые ещё не "проползли" 5 сек, визуально идут по ребру
    # строго по вектору события; ответ (Dir=-1) ползёт от ответчика к источнику.
    $len = [Math]::Sqrt(($x2-$x1)*($x2-$x1) + ($y2-$y1)*($y2-$y1))
    if ($len -lt 0.1) { $iEdge++; continue }
    $ix  = ($x2-$x1)/$len; $iy = ($y2-$y1)/$len   # единичный вектор по ребру (сверху вниз)
    $now = Get-Date
    $snakeOn  = [System.Drawing.Color]::FromArgb(80, 220, 255)
    $snakeOff = [System.Drawing.Color]::FromArgb(96, 102, 112)
    foreach ($sn in $script:snakes) {
      if ($sn.E -ne $actKey) { continue }
      $age = ($now - $sn.Start).TotalSeconds
      if ($age -gt 5.0) { continue }              # отжившая — уже вычищена, но на всякий случай
      $prog = [Math]::Min(1.0, $age / 1.2)        # сама змейка пробегает ребро ~1.2 с
      $snAl = 1.0 - $age / 5.0                    # свечение события гаснет за 5 с
      # источник/приёмник по направлению события
      $gX = $x1; $gY = $y1; $gT = 1.0
      if ($sn.Dir -eq -1) { $gX = $x2; $gY = $y2; $gT = -1.0 }
      # хвост змейки из 10 точек позади головы, с поперечной "волной"
      for ($s=0; $s -lt 10; $s++) {
        $d = $prog - $s*0.028
        if ($d -lt 0) { $d += 1 }
        $px = $gX + $ix*$gT*$len*$d
        $py = $gY + $iy*$gT*$len*$d
        $wave = [Math]::Sin($s*1.1 - $script:animT*7.0) * 5
        $px += -$iy*$gT*$wave; $py += $ix*$gT*$wave
        $aa = (230 * [Math]::Max(0.0, (1 - $s/12)))
        $snC = Lerp-Color $snakeOn $snakeOff (1 - $snAl)
        $snA = [System.Drawing.Color]::FromArgb([int]($aa * $snAl), $snC.R, $snC.G, $snC.B)
        $rc = 1.6 + (2.4 * (1 - $s/12))
        $ib = [System.Drawing.SolidBrush]::new($snA)
        $g.FillEllipse($ib, ($px-$rc), ($py-$rc), ($rc*2), ($rc*2))
        $ib.Dispose()
      }
    }
    # стрелка направления на конце реального потока (гаснет до серой при простое)
    $ang = [Math]::Atan2($tY - $sY, $tX - $sX)
    $arr = 9
    $arrC = Lerp-Color $colArwOn $colArwOff (1 - $fresh)
    $arrowBrush = [System.Drawing.SolidBrush]::new($arrC)
    $g.FillPolygon($arrowBrush, [System.Drawing.Point[]]@(
      [System.Drawing.Point]::new([int]($tX), [int]($tY)),
      [System.Drawing.Point]::new([int]($tX - $arr*[Math]::Cos($ang - 0.4)), [int]($tY - $arr*[Math]::Sin($ang - 0.4))),
      [System.Drawing.Point]::new([int]($tX - $arr*[Math]::Cos($ang + 0.4)), [int]($tY - $arr*[Math]::Sin($ang + 0.4)))
    ))
    $arrowBrush.Dispose()
    $iEdge++
  }

  # скруглённый прямоугольник (для тени, фона и рамки узла)
function Get-RoundedRectPath($x, $y, $w, $h, $r) {
  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $d = $r * 2
  $path.AddArc($x, $y, $d, $d, 180, 90)
  $path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  return $path
}

# рисуем узлы (размеры по надписям)
  $brushFg   = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(230, 234, 240))
  $brushDim  = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(150, 158, 170))
  $brushBg   = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(28, 32, 40))
  $fMeta     = [System.Drawing.Font]::new('Segoe UI', $script:fTitle.Size)
  $metaBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(120, 200, 170))

  foreach ($n in $nodes) {
    $p = $pos[$n.Id]
    if (-not $p) { continue }
    $sz = Get-NodeSize $n
    $c = $col[$n.Status]; if (-not $c) { $c = $col['gray'] }
    if ($n.Status -eq 'red' -and -not $pulse) { $c = [System.Drawing.Color]::FromArgb(120, 32, 32) }

    # метрики агента тем же размером, что заголовок узла, обычным шрифтом, НАД прямоугольником
    $perfTxt = Get-PerfText $n.Id
    if ($perfTxt) {
      $psz = $script:mG.MeasureString($perfTxt, $fMeta)
      $g.DrawString($perfTxt, $fMeta, $metaBrush, ($p.X + ($sz.W - $psz.Width)/2), [Math]::Max(0.0, ($p.Y - $psz.Height - 3)))
    }

    # тень (скруглённая, со смещением)
    $rr = 12.0
    $shadowPath = Get-RoundedRectPath ($p.X+3) ($p.Y+3) $sz.W $sz.H $rr
    $shadowBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(10,12,16))
    $g.FillPath($shadowBrush, $shadowPath)
    $shadowBrush.Dispose(); $shadowPath.Dispose()
    # фон узла (скруглённый)
    $bgPath = Get-RoundedRectPath $p.X $p.Y $sz.W $sz.H $rr
    $g.FillPath($brushBg, $bgPath)
    # рамка по статусу (при мигании "завис" - пульсирующая ширина), скруглённая
    $wb = if ($n.Status -eq 'red' -and $pulse) { 3.2 } else { 2.0 }
    $penN = [System.Drawing.Pen]::new($c, $wb)
    $g.DrawPath($penN, $bgPath)
    $penN.Dispose(); $bgPath.Dispose()
    # маркер-точка статуса
    $g.FillEllipse([System.Drawing.SolidBrush]::new($c), $p.X + 8, $p.Y + 10, 10, 10)
    # текст (рамка узла точно оборачивает надписи)
    $lines = $n.Label -split "`n"
    $tx = $p.X + 26
    $ty = $p.Y + 8
    $g.DrawString($lines[0], $script:fTitle, $brushFg, $tx, $ty)
    if ($lines.Count -gt 1) { $g.DrawString($lines[1], $script:fSub, $brushDim, $tx, $ty + [Math]::Ceiling($script:fTitle.Height)) }
    if ($lines.Count -gt 2) { $g.DrawString($lines[2], $script:fSub, $brushDim, $tx, $ty + 2*[Math]::Ceiling($script:fTitle.Height)) }
    # uptime (внизу рамки, по центру ширины)
    if ($n.Uptime -and $n.Uptime -ne '—') {
      $upBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(120, 200, 150))
      $upTxt = 'up ' + $n.Uptime
      $upSz  = $script:mG.MeasureString($upTxt, $script:fUp)
      $g.DrawString($upTxt, $script:fUp, $upBrush, ($p.X + ($sz.W - $upSz.Width)/2), ($p.Y + $sz.H - 18))
      $upBrush.Dispose()
    }
  }
  $brushFg.Dispose(); $brushDim.Dispose(); $brushBg.Dispose(); $fMeta.Dispose(); $metaBrush.Dispose()

  # вернуть трансформ (легенда поверх рисуется в реальных координатах)
  $g.ResetTransform()
}

# ---------- offline render: -Shot ----------
if ($Shot) {
  Update-Perf
  Update-EdgeActivity
  $st = Get-NodeStatus
  $bmp = [System.Drawing.Bitmap]::new(1000, 620)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::FromArgb(18, 20, 26))
  Invoke-DrawGraph $g $st.Nodes $false
  $g.Dispose()
  $bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Output "saved: $Shot"
  exit 0
}

# ---------- GUI ----------
# Необработанные ошибки в обработчиках WinForms всплывают как JIT-диалог —
# перехватываем на уровне потока и пишем в лог рядом со скриптом.
$ErrLog = Join-Path $PSScriptRoot 'infra-graph.err.log'
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
  param($s, $e)
  try { "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] $($e.Exception)" | Add-Content -LiteralPath $ErrLog -Encoding utf8 } catch {}
})
$st = Get-NodeStatus
$script:st = $st

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Карта инфраструктуры | оркестратор'
$form.StartPosition = 'Manual'
$form.Size = [System.Drawing.Size]::new(1040, 680)
$form.MinimumSize = [System.Drawing.Size]::new(760, 520)
$form.Location = [System.Drawing.Point]::new(30, 30)
$form.FormBorderStyle = 'Sizable'
$form.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 26)

# панель графа - рисуем сами (DoubleBuffered против мерцания)
$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = 'Fill'
$panel.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 26)
$panel.GetType().GetProperty('DoubleBuffered',[System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($panel,$true)
$form.Controls.Add($panel)

# перетаскивание узлов мышью (координаты СЦЕНЫ -> переживает ресайз,
# захват в точке клика без скачков)
$script:dragNode = $null
$script:dragOffset = [System.Drawing.PointF]::new(0, 0)
function Get-NodeAt([System.Drawing.Point]$pt) {
  $t   = Get-Transform $panel.Width $panel.Height
  $spt = ScreenToScene $t $pt.X $pt.Y
  $pos = Resolve-PositionsScene
  foreach ($n in $script:st.Nodes) {
    $pk = $pos[$n.Id]
    if (-not $pk) { continue }
    $sz = Get-NodeSize $n
    if ($spt.X -ge $pk.X -and $spt.X -le ($pk.X + $sz.W) -and $spt.Y -ge $pk.Y -and $spt.Y -le ($pk.Y + $sz.H)) {
      return $n.Id
    }
  }
  return $null
}
$panel.Add_MouseDown({
  param($s,$e)
  if ($e.Button -eq 'Left') {
    $script:dragNode = Get-NodeAt $e.Location
    if ($script:dragNode) {
      # смещение точки клика относительно левого верхнего угла узла (в сцене) —
      # чтобы узел не "прыгал", а двигался ровно под курсором
      $t   = Get-Transform $panel.Width $panel.Height
      $spt = ScreenToScene $t $e.X $e.Y
      $pk  = (Resolve-PositionsScene)[$script:dragNode]
      $script:dragOffset = [System.Drawing.PointF]::new($spt.X - $pk.X, $spt.Y - $pk.Y)
    }
    $panel.Cursor = 'SizeAll'
  }
})
$panel.Add_MouseMove({
  param($s,$e)
  if ($script:dragNode) {
    $f = $script:PosFrac[$script:dragNode]
    if ($f) {
      $t   = Get-Transform $panel.Width $panel.Height
      $spt = ScreenToScene $t $e.X $e.Y
      $nx  = [Math]::Max(0.0, [Math]::Min(1.0, ($spt.X - $script:dragOffset.X) / $script:SceneW))
      $ny  = [Math]::Max(0.0, [Math]::Min(1.0, ($spt.Y - $script:dragOffset.Y) / $script:SceneH))
      $f.Xf = [Math]::Round($nx, 4)
      $f.Yf = [Math]::Round($ny, 4)
      $panel.Invalidate()
    }
  } elseif ($null -eq $script:dragNode) {
    $panel.Cursor = if (Get-NodeAt $e.Location) { 'Hand' } else { 'Default' }
  }
})
$panel.Add_MouseUp({
  param($s,$e)
  if ($script:dragNode) { Save-Positions }   # узел реально тянули — запомнить раскладку
  $script:dragNode = $null
  $script:dragOffset = [System.Drawing.PointF]::new(0, 0)
  $panel.Cursor = 'Default'
})
$panel.Add_Resize({ $panel.Invalidate() })

# иконка трея
$iconBmp = New-Object System.Drawing.Bitmap 16,16
$ig = [System.Drawing.Graphics]::FromImage($iconBmp)
$ig.Clear([System.Drawing.Color]::Transparent)
$ig.FillEllipse([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(0,200,90)), 1, 1, 14, 14)
$trayIcon = [System.Drawing.Icon]::FromHandle($iconBmp.GetHicon())
$ig.Dispose()

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $trayIcon
$tray.Text = 'Карта инфраструктуры'
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = New-Object System.Windows.Forms.ToolStripMenuItem('Показать')
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem('Выход')
$menu.Items.Add($miShow) | Out-Null
$menu.Items.Add($miExit) | Out-Null
$tray.ContextMenuStrip = $menu
$miShow.Add_Click({ $form.Show(); $form.Activate() })
$miExit.Add_Click({ $tray.Visible = $false; $form.Close() })
$tray.Add_DoubleClick({ $form.Show(); $form.Activate() })

# пульсация "завис" (красный) - мигает рамкой
[bool]$script:pulse = $false

$panel.Add_Paint({
  param($s, $e)
  $g = $e.Graphics
  $g.SmoothingMode = 'AntiAlias'
  if ($script:st) {
    Invoke-DrawGraph $g $script:st.Nodes $script:pulse
  }
  # легенда поверх
  $legFont = [System.Drawing.Font]::new('Segoe UI', 8.5)
  $items = @('работает','запущен','завис / ошибка','остановлен')
  $cols  = @([System.Drawing.Color]::FromArgb(0,200,90), [System.Drawing.Color]::FromArgb(235,185,40), [System.Drawing.Color]::FromArgb(235,60,60), [System.Drawing.Color]::FromArgb(90,96,106))
  $x = 14; $y = $panel.Height - 26
  for ($i=0; $i -lt $items.Count; $i++) {
    $g.FillEllipse([System.Drawing.SolidBrush]::new($cols[$i]), $x, $y-6, 10, 10)
    $legBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(190,196,206))
    $g.DrawString($items[$i], $legFont, $legBrush, ($x + 16), ($y - 11))
    $legBrush.Dispose()
    $x += 30 + ($items[$i].Length * 7.4)
  }
  $legFont.Dispose()
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
  $prev = @{}; if ($script:st) { foreach ($n in $script:st.Nodes) { $prev[$n.Id] = $n.Status } }
  Update-Perf
  Update-EdgeActivity
  $script:st    = Get-NodeStatus
  $script:pulse = (-not $script:pulse)
  $changed = $false
  if ($script:st) {
    foreach ($n in $script:st.Nodes) {
      if ($prev[$n.Id] -ne $n.Status) { $changed = $true; break }
      if ($n.Status -eq 'red') { $changed = $true; break }
    }
  }
  if ($changed -or -not $prev.Count) { $panel.Invalidate() }
})
$timer.Start()

# анимация направленных связей ("змейки" бегут по рёбрам) и пульсация красных
$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 60
$animTimer.Add_Tick({
  $script:animT = ($script:animT + 0.02) % 1000
  $panel.Invalidate()
})
$animTimer.Start()

$form.Add_FormClosing({
  param($s, $e)
  if ($e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; $form.Hide() }
})

[System.Windows.Forms.Application]::Run($form)
$tray.Visible = $false