#requires -Version 7.0
<#
  opencode-monitor.ps1 - оперативный монитор оркестратора opencode
  Окно с хвостом лога opencode + статусом процессов/модели/агентов.
  Сворачивается в трей (крестик и кнопка). Запускать В ИНТЕРАКТИВНОЙ СЕССИИ,
  а не из opencode (окна из opencode не видны на десктопе).
#   0.5.0: значок в трее окрашивается по состоянию узлов из current.json
#         (зелёный/жёлтый/красный), левый клик/меню — сводка узлов;
#         режим -TrayOnly: только значок, окно скрыто (так поднимает хранитель).
  Режимы:
    без аргументов       - GUI-окно с треем
    -TrayOnly            - только значок в трее, окно сразу скрыто
    -Text [N]            - головной режим: строки лога за последние N сек (по умолчанию 120)
    -Status              - разовый статус: процессы, сессии, модель, агенты
  Требует pwsh (PowerShell 7).
#>
param(
  [switch]$Text,
  [int]$Seconds = 120,
  [switch]$Status,
  [switch]$TrayOnly
)
# --- UTF-8: кириллица в выводе pwsh 7 (OEMCP 866 ломает чтение) ---------
$ErrorActionPreference = 'Continue'
try {
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
  $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $env:PYTHONUTF8 = '1'
  $env:PYTHONIOENCODING = 'utf-8'
} catch { }
# ------------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$LogPath = Join-Path $env:USERPROFILE '.local\share\opencode\log\opencode.log'
# Каталог инструментов (уровнем выше registry\): состояние демона рядом с шимами
$toolsRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$WdPath = Join-Path $toolsRoot 'mcp-watchdog\state\current.json'
$off = [System.Text.Encoding]::UTF8

# ---------- сбор данных ----------
function Get-OcProcesses {
  Get-Process OpenCode -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{
      Id        = $_.Id
      StartTime = $_.StartTime
      Uptime    = if ($_.StartTime) { (Get-Date) - $_.StartTime } else { $null }
    }
  }
}

function Get-OcTail {
  param([int]$Lines = 60)
  if (-not (Test-Path $LogPath)) { return @() }
  $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $fs.Seek(- ([Math]::Min($Lines * 260, $fs.Length)), [System.IO.SeekOrigin]::End) | Out-Null
    $sr = New-Object System.IO.StreamReader($fs, $off)
    $text = $sr.ReadToEnd()
    return ($text -split "`n" | Select-Object -Last $Lines)
  } finally { $sr.Dispose(); $fs.Dispose() }
}

function Invoke-OcStats {
  $procs = Get-OcProcesses
  $lines = Get-OcTail -Lines 400
  $model = $null; $agent = $null; $mode = $null
  $ids = @($procs | ForEach-Object Id)
  $lastModel = $null; $lastAgent = $null
  foreach ($ln in $lines) {
    if ($ln -match 'message=stream .* modelID=(\S+).*? agent=(\S+) mode=(primary|subagent)') {
      $lastModel = $Matches[1]; $lastAgent = $Matches[2]
    }
    elseif ($ln -match 'message="llm runtime selected".* llm.model=(\S+)') { $lastModel = $Matches[1] }
  }
  if ($lastAgent) { $agent = $lastAgent } else { $agent = '?' }
  if ($lastModel) { $model = $lastModel } else { $model = '?' }
  # последняя активность = время последнего run/stream/evaluated
  $lastStamp = $lastSeen = $null
  foreach ($ln in $lines) {
    if ($ln -match 'timestamp=(\d{4}-\d{2}-\d{2}T[\d:.]+Z).* (?:message=loop|message=stream|message=evaluated)') {
      if (-not $lastSeen) {
        $lastSeen = if ($Matches[1] -match '(\d{2}:\d{2}:\d{2})') { $Matches[1] } else { $Matches[1] }
      }
    }
  }
  $wd = Get-Content $WdPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
  $mcpSummary = ''
  if ($wd) {
    $sm = @($wd.checks.PSObject.Properties | ForEach-Object { $_.Name + '=' + $_.Value.status }) -join ' '
    $mcpSummary = $sm
  }
  return [pscustomobject]@{
    Processes = $procs
    Count     = @($procs).Count
    Model     = $model
    Agent     = $agent
    LastSeen  = $lastSeen
    Mcp       = $mcpSummary
  }
}

# ---------- headless: -Text / -Status ----------
if ($Text -or $Status) {
  if ($Status) {
    $s = Invoke-OcStats
    "Процессов opencode: $($s.Count)"
    if ($s.Processes) {
      $s.Processes | ForEach-Object { "{0}  старт {1:HH:mm:ss}  uptime {2:mm\:ss}" -f $_.Id, $_.StartTime, $_.Uptime }
    }
    "Модель: $($s.Model)   агент: $($s.Agent)   последняя активность: $($s.LastSeen)"
    "MCP (watchdog): $($s.Mcp)"
    exit 0
  }
  $cut = (Get-Date).AddSeconds(-$Seconds)
  Get-Content $LogPath -Tail 2000 -ErrorAction SilentlyContinue | Where-Object {
    $_ -match 'timestamp=(\d{4}-\d{2}-\d{2}T[\d:.]+Z)'
    $ts = $Matches[1]
    if ($ts -match 'T(\d{2}:\d{2}:\d{2})') { $local = [datetime]::ParseExact($Matches[1], 'HH:mm:ss', $null) } else { $local = $null }
    if ($local -and $local -ge $cut.TimeOfDay) { $true } else { $false }
  } | Select-Object -Last 80
  exit 0
}

# ---------- здоровье узлов по current.json (для цвета значка) ----------
# Читает журнал демона-стража и сводит состояние всех узлов к одному уровню:
#   fail — есть узел в состоянии fault/fail; warn — need-guard, opencode не
#   виден или heartbeat протух (>90 с); иначе ok.
function Get-NodeHealth {
  $level = 'ok'
  $fails = @(); $warns = @()
  $chips = @()
  $j = $null
  try {
    if (Test-Path -LiteralPath $WdPath) { $j = Get-Content -LiteralPath $WdPath -Raw | ConvertFrom-Json }
  } catch { $j = $null }
  if (-not $j) {
    return [pscustomobject]@{ level = 'warn'; tip = 'журнал демона (current.json) не найден'; chips = @('[нет данных демон]'); json = $null }
  }
  # опенкод и свежесть heartbeat
  $op = $true
  if ($j.PSObject.Properties.Name -contains 'opencodeDetected') { $op = [bool]$j.opencodeDetected }
  $hbAge = $null
  if (($j.PSObject.Properties.Name -contains 'heartbeatAt') -and $j.heartbeatAt) {
    try { $hbAge = ((Get-Date) - ([DateTime]$j.heartbeatAt)).TotalSeconds } catch { }
  }
  if (-not $op) { $warns += 'opencode'; $chips += '[нет opencode]' }
  elseif ($null -ne $hbAge -and $hbAge -gt 90) { $warns += 'heartbeat'; $chips += ("[heartbeat {0:N0}s]" -f $hbAge) }
  # узлы
  if (($j.PSObject.Properties.Name -contains 'checks') -and $j.checks) {
    foreach ($p in $j.checks.PSObject.Properties) {
      $v = $p.Value
      $st = ''
      if ($v -is [System.Management.Automation.PSCustomObject]) {
        foreach ($k in @('state', 'status')) {
          if (($v.PSObject.Properties.Name -contains $k) -and $v.$k) { $st = [string]$v.$k; break }
        }
      } elseif ($null -ne $v) { $st = [string]$v }
      $nice = switch ($st) {
        'ok'         { 'ок' }
        'active'     { 'ок' }
        'idle'       { 'простой' }
        'unloaded'   { 'выгружен' }
        'need-guard' { 'нет стража' }
        'fail'       { 'СЛОМАН' }
        'fault'      { 'СЛОМАН' }
        default      { if ($st) { $st } else { '?' } }
      }
      if ($st -in @('fault', 'fail')) { $fails += $p.Name; $level = 'fail' }
      elseif ($st -eq 'need-guard') { $warns += $p.Name; if ($level -ne 'fail') { $level = 'warn' } }
      $chips += "[$nice $($p.Name)]"
    }
  }
  # открытые заявки демона
  $tickets = 0
  if (($j.PSObject.Properties.Name -contains 'openTickets') -and $j.openTickets) {
    try { $tickets = @($j.openTickets).Count } catch { $tickets = 0 }
  }
  if ($tickets -gt 0) { $chips += "[заявок: $tickets]"; if ($level -ne 'fail') { $level = 'warn' } }
  $tip = if ($level -eq 'fail')   { ('СБОЙ: ' + (($fails | Select-Object -First 3) -join ', ')) }
         elseif ($level -eq 'warn') { ('внимание: ' + (($warns | Select-Object -First 3) -join ', ')) }
         else                       { 'все узлы в норме' }
  return [pscustomobject]@{ level = $level; tip = $tip; chips = $chips; json = $j }
}

# Значок-кружок 16x16 нужного цвета (зелёный/жёлтый/красный).
function New-TrayIcon {
  param([ValidateSet('ok', 'warn', 'fail')][string]$Level = 'ok')
  $color = switch ($Level) {
    'ok'   { [System.Drawing.Color]::FromArgb(98, 200, 120) }
    'warn' { [System.Drawing.Color]::FromArgb(240, 190, 80) }
    'fail' { [System.Drawing.Color]::FromArgb(240, 80, 85) }
  }
  $bmp = New-Object System.Drawing.Bitmap 16, 16
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.SmoothingMode = 'AntiAlias'
  $g.FillEllipse((New-Object System.Drawing.SolidBrush($color)), 1, 1, 14, 14)
  $g.DrawEllipse((New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(20, 22, 28), 1.2)), 1, 1, 14, 14)
  $h = $bmp.GetHicon()
  $ico = [System.Drawing.Icon]::FromHandle($h)
  $g.Dispose(); $bmp.Dispose()
  return $ico
}

# ---------- GUI ----------
# Необработанные ошибки в обработчиках WinForms всплывают как JIT-диалог —
# перехватываем на уровне потока и пишем в лог рядом со скриптом.
$ErrLog = Join-Path $PSScriptRoot 'opencode-monitor.err.log'
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
  param($s, $e)
  try { "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] $($e.Exception)" | Add-Content -LiteralPath $ErrLog -Encoding utf8 } catch {}
})
$err = $null
try {
  # 0.5.0: защита от второго экземпляра — значок в трее должен быть один.
  $mutex = New-Object System.Threading.Mutex($false, 'Local\INVR_opencode_monitor_tray')
  $isFirst = $false
  try { $isFirst = $mutex.WaitOne(0, $false) } catch { $isFirst = $true }
  if (-not $isFirst) {
    "opencode monitor уже запущен — второй экземпляр не нужен (значок в трее один)." | Add-Content -LiteralPath $ErrLog -Encoding utf8
    exit 0
  }

  # цветовая схема под тёмную консоль
  $bg   = [System.Drawing.Color]::FromArgb(24, 26, 33)
  $fg   = [System.Drawing.Color]::FromArgb(220, 224, 232)
  $acc  = [System.Drawing.Color]::FromArgb(86, 156, 214)
  $dim  = [System.Drawing.Color]::FromArgb(130, 138, 150)
  $ok   = [System.Drawing.Color]::FromArgb(98, 200, 120)
  $warn = [System.Drawing.Color]::FromArgb(240, 190, 80)

  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'opencode monitor'
  $form.StartPosition = 'Manual'
  $form.Location = [System.Drawing.Point]::new(40, [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height - 540)
  $form.Size = [System.Drawing.Size]::new(920, 430)
  $form.BackColor = $bg
  $form.ForeColor = $fg
  $form.FormBorderStyle = 'Sizable'
  $form.MinimumSize = [System.Drawing.Size]::new(700, 300)

  # верхняя строка статуса
  $statusStrip = New-Object System.Windows.Forms.Label
  $statusStrip.Location = [System.Drawing.Point]::new(8, 6)
  $statusStrip.Size = [System.Drawing.Size]::new(910 - 320, 20)
  $statusStrip.Text = 'инициализация...'
  $statusStrip.BackColor = $bg
  $statusStrip.ForeColor = $acc
  $statusStrip.Font = [System.Drawing.Font]::new('Consolas', 9.5)
  $form.Controls.Add($statusStrip)

  # кнопки
  $btnMin = New-Object System.Windows.Forms.Button
  $btnMin.Text = '  В трей  '
  $btnMin.Location = [System.Drawing.Point]::new(730, 5)
  $btnMin.Size = [System.Drawing.Size]::new(85, 24)
  $btnMin.BackColor = [System.Drawing.Color]::FromArgb(40, 44, 54)
  $btnMin.ForeColor = $fg
  $btnMin.FlatStyle = 'Flat'
  $form.Controls.Add($btnMin)

  $btnRefresh = New-Object System.Windows.Forms.Button
  $btnRefresh.Text = ' Обновить '
  $btnRefresh.Location = [System.Drawing.Point]::new(820, 5)
  $btnRefresh.Size = [System.Drawing.Size]::new(85, 24)
  $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(40, 44, 54)
  $btnRefresh.ForeColor = $fg
  $btnRefresh.FlatStyle = 'Flat'
  $form.Controls.Add($btnRefresh)

  # лог
  $txt = New-Object System.Windows.Forms.RichTextBox
  $txt.Location = [System.Drawing.Point]::new(8, 34)
  $txt.Size = [System.Drawing.Size]::new(910 - 16, 390)
  $txt.Anchor = 'Top, Bottom, Left, Right'
  $txt.ReadOnly = $true
  $txt.BackColor = $bg
  $txt.ForeColor = $fg
  $txt.Font = [System.Drawing.Font]::new('Consolas', 8.5)
  $txt.BorderStyle = 'None'
  $txt.HideSelection = $true
  $txt.GetType().GetProperty('DoubleBuffered',[System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($txt,$true)
  $form.Controls.Add($txt)

  # трей: значок-кружок, окрашенный по состоянию узлов (0.5.0)
  $script:curLevel = $null
  $script:icon     = New-TrayIcon -Level 'ok'
  $script:trayTip  = 'opencode monitor'

  $tray = New-Object System.Windows.Forms.NotifyIcon
  $tray.Icon = $script:icon
  $tray.Text = 'opencode monitor'
  $tray.Visible = $true

  $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
  $miSummary  = New-Object System.Windows.Forms.ToolStripMenuItem('Сводка узлов')
  $miShow     = New-Object System.Windows.Forms.ToolStripMenuItem('Показать окно')
  $miExit     = New-Object System.Windows.Forms.ToolStripMenuItem('Выход')
  $trayMenu.Items.Add($miSummary) | Out-Null
  $trayMenu.Items.Add($miShow) | Out-Null
  $trayMenu.Items.Add($miExit) | Out-Null
  $tray.ContextMenuStrip = $trayMenu

  $miShow.Add_Click({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
  $miExit.Add_Click({ $tray.Visible = $false; $form.Close() })
  $tray.Add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
  $btnMin.Add_Click({ $form.Hide() })
  $btnRefresh.Add_Click({ Update-Monitor })

  # Сводка узлов всплывающей подсказкой (левый клик по значку или меню)
  function Show-Summary {
    $h = Get-NodeHealth
    $text = ($h.chips -join '  ')
    if ($text.Length -gt 240) { $text = $text.Substring(0, 240) + '…' }
    try { $tray.ShowBalloonTip(4000, 'Узлы: ' + $h.tip, $text, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
  }

  # Обновление цвета значка и подсказки; вызывается из Update-Monitor
  function Update-Tray {
    param($s)
    if (-not $s) { $s = Invoke-OcStats }
    $h = Get-NodeHealth
    if ($h.level -ne $script:curLevel) {
      $new = New-TrayIcon -Level $h.level
      $old = $script:icon
      $script:icon = $new
      $script:curLevel = $h.level
      try { $tray.Icon = $new } catch { }
      if ($old) {
        try { [void][System.Runtime.InteropServices.Marshal]::DestroyIcon($old.Handle) } catch { }
        try { $old.Dispose() } catch { }
      }
    }
    $tip = 'opencode monitor | ' + $h.tip
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + '...' }
    $script:trayTip = $tip
    try { $tray.Text = $tip } catch { }
    $statusStrip.Text = ("opencode monitor | {0} | процессов: {1}   модель: {2}   агент: {3}   активность: {4}" -f $h.tip, $s.Count, $s.Model, $s.Agent, $s.LastSeen)
  }

  $tray.Add_MouseClick({
    param($snd, $ev)
    if ($ev.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Summary }
  })

  # цвет строк лога и раскраска по типу объекта/события
  function Get-LineColor($ln) {
    if    ($ln -match 'level=ERROR')    { return [System.Drawing.Color]::FromArgb(240, 80, 85) }     # ошибки - красный
    if    ($ln -match 'message=stream') { return [System.Drawing.Color]::FromArgb(100, 210, 140) }    # ответы ИИ - зелёный
    if    ($ln -match 'message=evaluated permission=(\w+)') {
      $cmd = $Matches[1]
      if ($cmd -in @('allow','approve','yes')) { return [System.Drawing.Color]::FromArgb(110, 190, 250) }   # разрешённые приказы - голубой
      if ($cmd -in @('deny','reject','no'))    { return [System.Drawing.Color]::FromArgb(250, 160, 70) }     # запреты - оранжевый
      return [System.Drawing.Color]::FromArgb(180, 160, 240)                                                   # прочие команды - фиолетовый
    }
    if    ($ln -match '"llm runtime selected"') { return [System.Drawing.Color]::FromArgb(215, 160, 255) }   # выбор модели - сиреневый
    if    ($ln -match 'message=(?!level)' -or $ln -match 'lifecycle' -or $ln -match 'connection') {
      return [System.Drawing.Color]::FromArgb(130, 138, 150)                                                   # служебные - серый
    }
    return [System.Drawing.Color]::FromArgb(220, 224, 232)                                                    # обычные - светлый
  }

  function Format-Line($ln) {
    if ($ln -match 'level=ERROR')  { return ('[ошибка] ' + $ln) }
    if ($ln -match 'message=stream') {
      $m = 'модель:?'; if ($ln -match 'modelID=(\S+)') { $m = $Matches[1] }
      $a = ''; if ($ln -match 'agent=(\S+)') { $a = ' агент=' + $Matches[1] }
      return '→ модель=' + $m + $a
    }
    if ($ln -match 'message=evaluated permission=(\w+)') {
      $t = $Matches[1]
      if ($ln -match 'pattern=(.+)$') { return ('· ' + $t + ': ' + $Matches[1].Trim()) }
      return ('· ' + $t)
    }
    if ($ln -match 'message="llm runtime selected".*r untime') { return '· runtime: ' + $ln }
    $short = $ln
    if ($short.Length -gt 190) { $short = $short.Substring(0, 190) }
    return $short
  }

  $firstRun = $true
  $script:lastLen = 0

  function Update-Monitor {
    $s = Invoke-OcStats
    $procTxt = if ($s.Count -gt 0) { ($s.Processes | ForEach-Object { 'PID ' + $_.Id + ' (' + $_.StartTime.ToString('HH:mm:ss') + ', up ' + $_.Uptime.ToString('mm\:ss') + ')' }) -join '  ' } else { 'нет процессов' }
    Update-Tray $s

    $lines = Get-OcTail -Lines 200
    if ($lines.Count -gt 0) {
      # построчная раскраска: разные объекты и события - разным цветом
      $txt.SuspendLayout()
      $txt.Text = ''
      foreach ($l in $lines) {
        $txt.SelectionColor = Get-LineColor $l
        $txt.AppendText((Format-Line $l) + "`n")
      }
      $txt.SelectionColor = $txt.ForeColor
      $txt.SelectionStart = $txt.TextLength
      $txt.ScrollToCaret()
      $txt.ResumeLayout($true)
    }
  }

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 3000
  $timer.Add_Tick({ Update-Monitor })
  $timer.Start()
  Update-Monitor

  # 0.5.0: режим «только значок» — окно скрыто сразу (так поднимает хранитель,
  # чтобы окно не выскакивало каждый раз при запуске opencode).
  if ($TrayOnly) {
    $form.ShowInTaskbar = $false
    $form.Hide()
  }

  $form.Add_FormClosing({
    param($s, $e)
    if ($e.CloseReason -eq 'UserClosing') {
      $e.Cancel = $true
      $form.Hide()
    }
  })

  [System.Windows.Forms.Application]::Run($form)
  $tray.Visible = $false
}
catch {
  $err = $_
  [System.Windows.Forms.MessageBox]::Show('Ошибка: ' + $err.Exception.Message, 'opencode monitor')
  exit 1
}
