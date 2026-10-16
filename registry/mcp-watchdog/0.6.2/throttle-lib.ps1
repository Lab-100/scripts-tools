<#
.SYNOPSIS
    throttle-lib.ps1 — троттлинг ресурсов локальных моделей Ollama (часть mcp-watchdog 0.6.0).

.DESCRIPTION
    Библиотека вынесена из демона отдельным файлом намеренно: здесь лежит
    ЧИСТАЯ логика (решение «выгружать или нет»), которую можно проверить тестами
    без запуска демона, без HTTP и без изменения процессов.

    Задача. Требование владельца: пока работает локальная модель, в системе должно
    оставаться НЕ МЕНЬШЕ 10% свободной оперативной памяти, а загрузка
    процессора — не выше 85% (то есть свободно не меньше 15% процессорного
    времени).

    Два эшелона:
      * МЯГКИЙ (каждый цикл, безопасный и постоянный): процесс runner'а Ollama
        (llama-server) переводится в BelowNormal, чтобы он не перебивал интерфейс
        системы даже в простое. Ollama создаёт новый runner при каждой загрузке
        модели, поэтому понижение повторяется каждый цикл.
      * ЖЁСТКИЙ (только при нарушении порогов): из памяти выгружаются модели,
        перечисленные в GET /api/ps. Выгрузка ПОЛНОСТЬЮ ОБРАТИМА — модель снова
        поднимется по первому же запросу, поэтому никаких данных не теряется.

    Почему только по /api/ps: POST /api/generate с keep_alive=0 для модели,
    которая НЕ загружена, сначала АЛЛОЦИРУЕТ её в памяти (планировщик уходит в
    load), выполняет пустую генерацию и только потом выгружает. То есть выгрузка
    «вслепую» стоила бы нам как раз той памяти, которую экономим.

    Замеры сделаны дешёвыми, потому что цикл демона крутится постоянно:
      * память — GlobalMemoryStatusEx (ullAvailPhys, то же самое, что «Доступно»
        в Диспетчере задач), десятки микросекунд;
      * процессор — System.Diagnostics.PerformanceCounter
        ('Processor','% Processor Time','_Total'), тоже без WMI.
    Тяжёлый WMI (Win32_PerfFormattedData_PerfOS_Processor, ~300-700 мс) оставлен
    только запасным путём на случай, если счётчики недоступны.

    Гистерезис и минимальный интервал (-ThrottleMinGapSec) защищают от раскачки
    «загрузили-выгрузили-загрузили»: каждая перезагрузка модели на этой машине
    стоит десятки секунд процессорного времени.

    Модуль НЕ трогает узлы-сервисы инфраструктуры: только модели, реально
    лежащие в памяти Ollama. Решение о завершении процессов сервисов остаётся
    за владельцем (политика owner-decides демона).
#>

# ---- состояние проб (создаётся один раз на процесс) ----
$script:InvrMemProbeReady = $false
$script:InvrCpuCounter     = $null
$script:InvrCpuPrimed      = $false
$script:InvrCpuLast        = [double]::NaN

function Initialize-InvrThrottleProbe {
    <#
    .SYNOPSIS
        Готовит счётчики памяти и процессора (идемпотентно, безопасно при отказе).
    #>
    if (-not $script:InvrMemProbeReady) {
        $src = @'
using System;
using System.Runtime.InteropServices;
public static class InvrMemProbe {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public class MEMORYSTATUSEX {
        public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        public uint dwMemoryLoad;
        public ulong ullTotalPhys; public ulong ullAvailPhys;
        public ulong ullTotalPageFile; public ulong ullAvailPageFile;
        public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);
    public static double[] Snapshot() {
        var m = new MEMORYSTATUSEX();
        if (!GlobalMemoryStatusEx(m)) return new double[] { -1, 0, 0 };
        double total = m.ullTotalPhys / 1073741824.0;
        double avail = m.ullAvailPhys / 1073741824.0;
        return new double[] { (total > 0 ? 100.0 * m.ullAvailPhys / m.ullTotalPhys : -1), total, avail };
    }
}
'@
        try { Add-Type -TypeDefinition $src -ErrorAction Stop; $script:InvrMemProbeReady = $true } catch { $script:InvrMemProbeReady = $false }
    }
    if (-not $script:InvrCpuCounter) {
        try {
            $script:InvrCpuCounter = [System.Diagnostics.PerformanceCounter]::new('Processor', '% Processor Time', '_Total')
            $null = $script:InvrCpuCounter.NextValue()   # прогрев: первый отсчёт всегда 0
            $script:InvrCpuPrimed = $false
        } catch { $script:InvrCpuCounter = $null }
    }
}

function Get-InvrMemorySnapshot {
    <#
    .SYNOPSIS
        Свободная физическая память в процентах (и в ГБ). Source показывает,
        каким способом получено значение — для диагностики в журнале.
    #>
    Initialize-InvrThrottleProbe
    if ($script:InvrMemProbeReady) {
        try {
            $s = [InvrMemProbe]::Snapshot()
            return [pscustomobject]@{
                FreePct = [math]::Round([double]$s[0], 2)
                TotalGB = [math]::Round([double]$s[1], 2)
                FreeGB  = [math]::Round([double]$s[2], 2)
                Source  = 'GlobalMemoryStatusEx'
            }
        } catch { }
    }
    # запасной путь: WMI (медленно, поэтому только если основной не работает)
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $total = [double]$os.TotalVisibleMemorySize
        $free  = [double]$os.FreePhysicalMemory
        if ($total -le 0) { throw 'нулевой объём памяти' }
        return [pscustomobject]@{
            FreePct = [math]::Round(100 * $free / $total, 2)
            TotalGB = [math]::Round($total * 1KB / 1GB, 2)
            FreeGB  = [math]::Round($free * 1KB / 1GB, 2)
            Source  = 'Win32_OperatingSystem'
        }
    } catch {
        return [pscustomobject]@{ FreePct = -1; TotalGB = 0; FreeGB = 0; Source = 'unavailable' }
    }
}

function Get-InvrCpuLoadPct {
    <#
    .SYNOPSIS
        Загрузка процессора в процентах по всем логическим процессорам.
        Первый вызов после запуска возвращает последнее известное значение
        (обычно -1), потому что счётчик требует прогрева.
    #>
    Initialize-InvrThrottleProbe
    if ($script:InvrCpuCounter) {
        try {
            $v = [double]$script:InvrCpuCounter.NextValue()
            if (-not $script:InvrCpuPrimed) {
                $script:InvrCpuPrimed = $true
                if (-not [double]::IsNaN($script:InvrCpuLast)) { return [math]::Round($script:InvrCpuLast, 1) }
                return -1
            }
            $script:InvrCpuLast = $v
            return [math]::Round($v, 1)
        } catch { }
    }
    # запасной путь: WMI (дорогой, поэтому только когда счётчик недоступен)
    try {
        $perf = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        return [math]::Round([double]$perf.PercentProcessorTime, 1)
    } catch { return -1 }
}

function Get-InvrOllamaLoadedModels {
    <#
    .SYNOPSIS
        Список моделей, РЕАЛЬНО лежащих в памяти Ollama (GET /api/ps).
        Пустой массив — выгружать нечего.
    #>
    param(
        [string]$OllamaHost = 'http://127.0.0.1:11434',
        [int]$TimeoutSec = 5
    )
    try {
        $resp = Invoke-RestMethod -Uri "$OllamaHost/api/ps" -TimeoutSec $TimeoutSec -ErrorAction Stop
        $models = @($resp.models | ForEach-Object { [string]$_.name } | Where-Object { $_ })
        return ,$models
    } catch {
        Write-Verbose "ollama /api/ps недоступен: $($_.Exception.Message)"
        return ,@()
    }
}

function Unload-InvrOllamaModel {
    <#
    .SYNOPSIS
        Выгружает ОДНУ загруженную модель: POST /api/generate с keep_alive=0.
        Вызывать только для моделей из Get-InvrOllamaLoadedModels.
    #>
    param(
        [Parameter(Mandatory)][string]$Model,
        [string]$OllamaHost = 'http://127.0.0.1:11434',
        [int]$TimeoutSec = 30
    )
    $body = @{ model = $Model; keep_alive = 0 } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Method Post -Uri "$OllamaHost/api/generate" `
            -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Verbose "выгрузка $Model не удалась: $($_.Exception.Message)"
        return $false
    }
}

function Set-InvrRunnerPriorityLow {
    <#
    .SYNOPSIS
        Мягкий эшелон: опускает приоритет процессов runner'а Ollama до BelowNormal.
        Возвращает количество изменённых процессов.
    #>
    param([string[]]$ProcessName = @('llama-server'))
    $changed = 0
    foreach ($name in $ProcessName) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try {
                if ($p.PriorityClass -ne [System.Diagnostics.ProcessPriorityClass]::BelowNormal) {
                    Set-ProcessPriorityClass -InputObject $p -PriorityClass BelowNormal -ErrorAction Stop
                    $changed++
                }
            } catch { }
        }
    }
    return $changed
}

function Get-InvrThrottleDecision {
    <#
    .SYNOPSIS
        ЧИСТОЕ РЕШЕНИЕ троттлинга по метрикам: что делать сейчас (или ничего).

    .DESCRIPTION
        Никаких побочных эффектов: только входные числа и текст решения.
        Поэтому правило выгрузки проверяется тестами без Ollama и без прав.

        Пороги владельца по умолчанию: свободная память не меньше 10%,
        загрузка процессора не выше 85%.

    .PARAMETER FreeMemPct
        Свободная физическая память в процентах; -1 — метрика недоступна (порог не проверяем).
    .PARAMETER CpuPct
        Загрузка процессора в процентах; -1 — метрика недоступна.
    .PARAMETER LoadedModels
        Модели, реально лежащие в памяти Ollama.
    .PARAMETER MinFreeMemPct
        Ниже этого процента свободной памяти считаем нарушением (по умолчанию 10).
    .PARAMETER MaxCpuPct
        Выше этой загрузки процессора считаем нарушением (по умолчанию 85).
    .PARAMETER ResumeFreeMemPct
        Порог возврата к норме (гистерезис): пока свободная память ниже его,
        нарушение считается не восстановленным (по умолчанию 15).
    .PARAMETER ResumeCpuPct
        Порог возврата к норме по процессору (по умолчанию 70).
    .PARAMETER MinGapSec
        Минимальный интервал между выгрузками, сек (антидребезг).
    .PARAMETER LastActionAt
        Момент последней выгрузки; MinValue — выгрузок ещё не было.
    .PARAMETER Mode
        'enforce' — выгружать при нарушении; 'report' — только сообщать.
    .PARAMETER Now
        Текущее время (для тестов передаётся явно).
    #>
    [CmdletBinding()]
    param(
        [double]$FreeMemPct = -1,
        [double]$CpuPct = -1,
        [string[]]$LoadedModels = @(),
        [double]$MinFreeMemPct = 10,
        [double]$MaxCpuPct = 85,
        [double]$ResumeFreeMemPct = 15,
        [double]$ResumeCpuPct = 70,
        [int]$MinGapSec = 120,
        [datetime]$LastActionAt = [datetime]::MinValue,
        [ValidateSet('enforce','report')]
        [string]$Mode = 'enforce',
        [datetime]$Now = [datetime]::Now
    )

    $breach = @()
    if ($FreeMemPct -ge 0 -and $FreeMemPct -lt $MinFreeMemPct) { $breach += "память ${FreeMemPct}% < ${MinFreeMemPct}%" }
    if ($CpuPct -ge 0 -and $CpuPct -gt $MaxCpuPct)              { $breach += "процессор ${CpuPct}% > ${MaxCpuPct}%" }

    $recovered = ($FreeMemPct -lt 0 -or $FreeMemPct -ge $ResumeFreeMemPct) -and
                 ($CpuPct -lt 0 -or $CpuPct -le $ResumeCpuPct)

    $result = [ordered]@{
        action      = 'none'
        reason      = ''
        breach      = @($breach)
        recovered   = $recovered
        models      = @($LoadedModels)
        mode        = $Mode
        checkedAt   = $Now.ToString('yyyy-MM-dd HH:mm:ss')
    }

    if ($breach.Count -eq 0) {
        $result.reason = 'пороги в норме'
        return [pscustomobject]$result
    }
    if (@($LoadedModels).Count -eq 0) {
        $result.reason = 'нарушение есть, но ни одна модель не загружена — выгружать нечего'
        return [pscustomobject]$result
    }
    if ($Mode -eq 'report') {
        $result.action = 'report'
        $result.reason = "режим report: нарушение ($($breach -join '; ')) — выгрузка не выполняется"
        return [pscustomobject]$result
    }
    if ($LastActionAt -ne [datetime]::MinValue) {
        $since = ($Now - $LastActionAt).TotalSeconds
        if ($since -lt $MinGapSec) {
            $result.action = 'skip-gap'
            $result.reason = "нарушение ($($breach -join '; ')), но с прошлой выгрузки прошло $([int]$since) с из $MinGapSec — ждём (антидребезг)"
            return [pscustomobject]$result
        }
    }
    $result.action = 'unload'
    $result.reason = "выгружаю модели: $($breach -join '; ')"
    return [pscustomobject]$result
}