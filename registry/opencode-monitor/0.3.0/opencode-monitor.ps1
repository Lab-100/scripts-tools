#requires -Version 7.0
<#
  opencode-monitor.ps1 - оперативный монитор оркестратора opencode
  Окно с хвостом лога opencode + статусом процессов/модели/агентов.
  Сворачивается в трей (крестик и кнопка). Запускать В ИНТЕРАКТИВНОЙ СЕССИИ,
  а не из opencode (окна из opencode не видны на десктопе).
  Режимы:
    без аргументов       - GUI-окно с треем
    -Text [N]            - головной режим: строки лога за последние N сек (по умолчанию 120)
    -Status              - разовый статус: процессы, сессии, модель, агенты
  Требует pwsh (PowerShell 7).
#>
param(
  [switch]$Text,
  [int]$Seconds = 120,
  [switch]$Status
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$LogPath = Join-Path $env:USERPROFILE '.local\share\opencode\log\opencode.log'
$off = [System.Text.Encoding]::UTF8

# Каталог инструментов (уровнем выше registry\): состояние демона рядом с шимами
$toolsRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$WdPath = Join-Path $toolsRoot 'mcp-watchdog\state\current.json'

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

  # трей
  $iconBmp = New-Object System.Drawing.Bitmap 16,16
  $g = [System.Drawing.Graphics]::FromImage($iconBmp)
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.FillEllipse([System.Drawing.Brushes]::DodgerBlue, 1, 1, 14, 14)
  $h = $iconBmp.GetHicon()
  $icon = [System.Drawing.Icon]::FromHandle($h)
  $g.Dispose()

  $tray = New-Object System.Windows.Forms.NotifyIcon
  $tray.Icon = $icon
  $tray.Text = 'opencode monitor'
  $tray.Visible = $true

  $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
  $miShow  = New-Object System.Windows.Forms.ToolStripMenuItem('Показать окно')
  $miExit  = New-Object System.Windows.Forms.ToolStripMenuItem('Выход')
  $trayMenu.Items.Add($miShow) | Out-Null
  $trayMenu.Items.Add($miExit) | Out-Null
  $tray.ContextMenuStrip = $trayMenu

  $miShow.Add_Click({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
  $miExit.Add_Click({ $tray.Visible = $false; $form.Close() })
  $tray.Add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
  $btnMin.Add_Click({ $form.Hide() })
  $btnRefresh.Add_Click({ Update-Monitor })

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
    $statusStrip.Text = "процессов: {0}   модель: {1}   агент: {2}   активность: {3}" -f $s.Count, $s.Model, $s.Agent, $s.LastSeen

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