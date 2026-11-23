<#
.SYNOPSIS
    reap-lib.ps1 — правила безопасной зачистки лишних процессов (часть mcp-watchdog 0.7.0).

.DESCRIPTION
    Библиотека вынесена из демона отдельным файлом ровно по той же причине, что и
    throttle-lib.ps1: здесь лежит ЧИСТАЯ логика, которую можно проверить тестами
    без WMI, без прав администратора и без завершения живых процессов.

    Задача владельца. В системе 8,1 ГБ памяти и постоянно живут сотни процессов:
    консольные обёртки (conhost), интерпретаторы (pwsh/python/node/uv), агенты
    (OpenCode, MultiTool, cline-cli), docker/vmmem, базы и лицензионные службы.
    Лишние из них (сироты, обёртки без хозяина, остатки рантаймов) память занимают,
    но не нужны; нужные — нужны всегда. Значит нужен МЕХАНИЗМ, который:

      * трогает только то, что детерминированно безопасно (сирота = родитель мёртв;
        дубль-обёртка без окна и без живых потомков; uv без живого python-потомка);
      * НИКОГДА не трогает защищённое (ядро oc/watchdog/guardian/monitor, агенты,
        IDE, базы, docker/vmmem, лицензии, системные процессы, ветку потомков
        процессов-узлов, которые нужны прямо сейчас);
      * срабатывает ТОЛЬКО при реальной нехватке памяти и НЕ УСИЛИВАЕТ агрессию,
        когда метрики неполные (безопасный инвариант: не знаешь — не делай);
      * ограничен антидребезгом (не чаще одного прохода в N секунд, не более
        M закрытий за проход и за час).

    Три уровня (класса) кандидатов:

      класс 0 «безопасный» — сироты (родитель мёртв), conhost без владельца-консоли,
        uv без живого python-потомка, дубли-обёртки без окна и без живых потомков.
        Только этот класс разрешён к автоматическому закрытию на первом этапе.
      класс 1 «простой»   — pwsh/node/python со простоем дольше порога (900/600/300 с
        по умолчанию) и без главного окна.
      класс 2             — msedgewebview2-сироты и дубли профилей.

    Классы 1 и 2 публикуются как «предложения владельцу» (suggested) и на этом
    этапе НЕ закрываются даже в режиме enforce.

    Режимы:
      report  — ничего не закрываем, публикуем кандидатов (безопасное включение);
      enforce — закрываем ТОЛЬКО класс 0, только при нехватке памяти, с лимитами.

    Мягкое закрытие (в демоне): CloseMainWindow → Stop-Process → Stop-Process -Force.
    Перед закрытием пишется строка в state\killed.jsonl с полной командной строкой,
    чтобы процесс можно было запустить руками.

    Единственная функция с побочным эффектом — Write-InvrAtomicJson (атомарная
    запись файла состояния). Она оставлена здесь намеренно: её поведение
    (временный файл рядом, Move-Item -Force, UTF-8 без BOM, retry) тоже проверяется
    тестами.

    Возвращаемые массивы: empty-массив из функции в PowerShell разворачивается в
    $null, поэтому ВЫЗЫВАЮЩИЙ код всегда оборачивает результат в @(...).
#>

# ---- встроенные (заводские) значения политики ----
function Get-InvrReapDefaults {
    <#
    .SYNOPSIS
        Заводская политика зачистки: те же значения, что и в config\reap-policy.json.
    .DESCRIPTION
        Чистая функция: возвращает объект с порогами и списками. Нужна, чтобы
        библиотека работала и без файла конфигурации, и чтобы тесты могли
        сравнивать файл с заводскими значениями.
    #>
    [pscustomobject]@{
        # память: начинаем при свободно < 10%, «отбой» при > 15%, ниже 200 МБ агрессию не усиливаем
        minFreePct        = 10.0
        resumeFreePct     = 15.0
        absoluteMinFreeMb = 200.0
        # антидребезг
        minGapSec         = 300
        maxActionsPerPass = 3
        maxActionsPerHour = 10
        # порог «процесс не работал за окно замера», сек CPU
        cpuActiveSec      = 0.5
        # пороги простоя по имени процесса (сек)
        idleSec           = @{
            pwsh    = 900
            python  = 600
            pythonw = 600
            node    = 300
            uv      = 600
            conhost = 1800
        }
        # класс 1 (простой, без окна) — только «на решение владельца» на этом этапе
        class1Names       = @('pwsh','node','python','pythonw','uv')
        # класс 2 — msedgewebview2: сироты и дубли профилей
        class2Names       = @('msedgewebview2')
        # дубли-обёртки: одинаковая командная строка, без окна, без живых потомков → класс 0
        duplicateWrapperNames = @('cmd','conhost','uv','wscript','cscript')
        # белый список имён процессов, которые НИКОГДА не закрываются
        protectedNames    = @(
            # ядро
            'oc','opencode','opencode-cli','watchdog','mcp-watchdog','guardian','mcp-watchdog-guardian',
            'monitor','infra-graph',
            # агенты
            'cline','cline-cli','multitool','mcp-server*','mcp-server-*','*mcp*server*',
            # IDE
            'code','code-insiders','idea','idea64','pycharm','pycharm64','webstorm','webstorm64',
            'devenv','rider','goland','clion','studio64',
            # базы
            'postgres','postgresql','pg_ctl','sqlservr','mysqld','mongod','redis-server',
            # docker/vm
            'docker','docker desktop','com.docker.backend','com.docker.build','docker-proxy',
            'vmmem','vmmemwsl','vmwp','wslservice','wslhost','wsl','dockerd',
            # лицензии
            'lmgrd','lmadmin','hasplmv','hasp','lmutil',
            # системные
            'system','registry','idle','smss','csrss','wininit','services','lsass','winlogon',
            'svchost','dwm','explorer','fontdrvhost','ctfmon','sihost','taskhostw',
            'runtimebroker','searchindexer','spoolsv','audiodg','shellexperiencehost',
            'startmenuexperiencehost','textinputhost','securityhealthservice','msmpeng','msmpengcp',
            'nissrv','taskmgr','sppsvc','winmgmt','wmiprvse','dllhost','backgroundtaskhost',
            'trustedinstaller','tiworker','msiexec','sppsvc','usocoreworker','usoclient',
            # прочее нужное машине
            'explorer'
        )
        # защита по КОМАНДНОЙ СТРОКЕ (процесс и его предки): ядро и агенты
        protectedCmdlinePatterns = @(
            'mcp-watchdog','infra-graph','mcp-watchdog-guardian','opencode','MultiTool',
            'MultiTool.exe','cline-cli','llm_mcp_server','firecrawl-mcp','mcp gateway run'
        )
        # браузеры: MainWindowHandle ≠ 0 и предок-IDE → защищены
        browserNames      = @('msedge','chrome','firefox','iexplore','brave','yandex','opera','msedgewebview2')
        # режим: report (по умолчанию) | enforce
        mode              = 'report'
        enforceClasses    = @(0)
    }
}

function Get-InvrReapPolicy {
    <#
    .SYNOPSIS
        Политика зачистки: файл конфигурации (если есть) поверх заводских значений.
    .PARAMETER Path
        Путь к JSON-политике. Пусто — только заводские значения.
    .PARAMETER Override
        Хэш-таблица точечных переопределений (например из ключей командной строки):
        mode, minFreePct, resumeFreePct, minGapSec, maxActionsPerPass, maxActionsPerHour.
    .DESCRIPTION
        Файл читается «мягко»: любая ошибка разбора или отсутствие файла не ломают
        демон, а оставляют заводские значения (безопасный инвариант). Незнакомые
        ключи игнорируются, недостающие берутся из заводских.
    #>
    [CmdletBinding()]
    param(
        [string]$Path = '',
        [hashtable]$Override = @{}
    )
    $d = Get-InvrReapDefaults
    $src = 'defaults'

    $raw = $null
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $src = $Path
        } catch { $raw = $null; $src = 'defaults' }
    }
    $p = [ordered]@{
        minFreePct        = $d.minFreePct
        resumeFreePct     = $d.resumeFreePct
        absoluteMinFreeMb = $d.absoluteMinFreeMb
        minGapSec         = $d.minGapSec
        maxActionsPerPass = $d.maxActionsPerPass
        maxActionsPerHour = $d.maxActionsPerHour
        cpuActiveSec      = $d.cpuActiveSec
        idleSec           = @{} + $d.idleSec
        class1Names       = @($d.class1Names)
        class2Names       = @($d.class2Names)
        duplicateWrapperNames = @($d.duplicateWrapperNames)
        protectedNames    = @($d.protectedNames)
        protectedCmdlinePatterns = @($d.protectedCmdlinePatterns)
        browserNames      = @($d.browserNames)
        mode              = $d.mode
        enforceClasses    = @($d.enforceClasses)
        source            = $src
    }

    if ($raw) {
        if ($raw.memory) {
            if ($null -ne $raw.memory.minFreePct)        { $p.minFreePct = [double]$raw.memory.minFreePct }
            if ($null -ne $raw.memory.resumeFreePct)     { $p.resumeFreePct = [double]$raw.memory.resumeFreePct }
            if ($null -ne $raw.memory.absoluteMinFreeMb) { $p.absoluteMinFreeMb = [double]$raw.memory.absoluteMinFreeMb }
            # Совместимость с фактическим файлом config\reap-policy.json (version 1.0.0):
            # в нём те же пороги названы короче — startPct / resumePct / minFreeMb /
            # neverIncreaseAggroBelowMb. Без этих строк файл политики молча игнорировался
            # целиком и работали только заводские значения: порог владельца не применялся.
            if ($null -ne $raw.memory.startPct)     { $p.minFreePct = [double]$raw.memory.startPct }
            if ($null -ne $raw.memory.resumePct)    { $p.resumeFreePct = [double]$raw.memory.resumePct }
            if ($null -ne $raw.memory.minFreeMb)    { $p.absoluteMinFreeMb = [double]$raw.memory.minFreeMb }
            if ($null -ne $raw.memory.neverIncreaseAggroBelowMb) { $p.absoluteMinFreeMb = [double]$raw.memory.neverIncreaseAggroBelowMb }
        }
        if ($raw.antiFlutter) {
            if ($null -ne $raw.antiFlutter.minGapSec)         { $p.minGapSec = [int]$raw.antiFlutter.minGapSec }
            if ($null -ne $raw.antiFlutter.maxActionsPerPass) { $p.maxActionsPerPass = [int]$raw.antiFlutter.maxActionsPerPass }
            if ($null -ne $raw.antiFlutter.maxActionsPerHour) { $p.maxActionsPerHour = [int]$raw.antiFlutter.maxActionsPerHour }
        }
        # второй (фактический) раздел того же файла называется throttle
        if ($raw.throttle) {
            if ($null -ne $raw.throttle.minGapSec)         { $p.minGapSec = [int]$raw.throttle.minGapSec }
            if ($null -ne $raw.throttle.maxActionsPerRun)  { $p.maxActionsPerPass = [int]$raw.throttle.maxActionsPerRun }
            if ($null -ne $raw.throttle.maxActionsPerHour) { $p.maxActionsPerHour = [int]$raw.throttle.maxActionsPerHour }
        }
        if ($null -ne $raw.cpuActiveSec) { $p.cpuActiveSec = [double]$raw.cpuActiveSec }
        if ($raw.idleSec) {
            foreach ($n in @($raw.idleSec.PSObject.Properties.Name)) {
                $p.idleSec[[string]$n] = [int]$raw.idleSec.$n
            }
        }
        if ($raw.classes) {
            if ($raw.classes.class1Names)          { $p.class1Names = @($raw.classes.class1Names | ForEach-Object { [string]$_ }) }
            if ($raw.classes.class2Names)          { $p.class2Names = @($raw.classes.class2Names | ForEach-Object { [string]$_ }) }
            if ($raw.classes.duplicateWrapperNames){ $p.duplicateWrapperNames = @($raw.classes.duplicateWrapperNames | ForEach-Object { [string]$_ }) }
        }
        if ($raw.protected) {
            if ($raw.protected.names)           { $p.protectedNames = @($p.protectedNames) + @($raw.protected.names | ForEach-Object { [string]$_ }) }
            if ($raw.protected.extraNames)      { $p.protectedNames = @($p.protectedNames) + @($raw.protected.extraNames | ForEach-Object { [string]$_ }) }
            if ($raw.protected.cmdlinePatterns) { $p.protectedCmdlinePatterns = @($p.protectedCmdlinePatterns) + @($raw.protected.cmdlinePatterns | ForEach-Object { [string]$_ }) }
            if ($raw.protected.browserNames)    { $p.browserNames = @($p.browserNames) + @($raw.protected.browserNames | ForEach-Object { [string]$_ }) }
        }
        if ($raw.mode) { $p.mode = [string]$raw.mode }
        if ($null -ne $raw.enforceClasses) { $p.enforceClasses = @($raw.enforceClasses | ForEach-Object { [int]$_ }) }
    }

    foreach ($k in @($Override.Keys)) {
        if ($null -eq $Override[$k]) { continue }
        $p[$k] = $Override[$k]
    }
    # защита от мусора: пороги обязаны быть числами в разумных границах
    if ($p.minFreePct -lt 0)    { $p.minFreePct = $d.minFreePct }
    if ($p.resumeFreePct -lt $p.minFreePct) { $p.resumeFreePct = $p.minFreePct }
    if ($p.minGapSec -lt 0)     { $p.minGapSec = $d.minGapSec }
    if ($p.maxActionsPerPass -lt 0) { $p.maxActionsPerPass = $d.maxActionsPerPass }
    return [pscustomobject]$p
}

# ---- нормализация имён и защита ----
function Get-InvrProcBaseName {
    <#
    .SYNOPSIS
        Имя процесса без расширения и без пути, в нижнем регистре (ключ группировки).
    #>
    param([string]$Name)
    if (-not $Name) { return '' }
    $leaf = $Name
    try { $leaf = [IO.Path]::GetFileName($Name) } catch { }
    $base = $leaf
    try { $base = [IO.Path]::GetFileNameWithoutExtension($leaf) } catch { }
    if (-not $base) { $base = $leaf }
    return $base.Trim().ToLowerInvariant()
}

function Test-InvrNameMatches {
    <#
    .SYNOPSIS
        Совпадает ли имя процесса с одним из шаблонов (поддерживаются * и ?).
    #>
    param([string]$Name, [string[]]$Patterns = @())
    $n = Get-InvrProcBaseName $Name
    if (-not $n) { return $false }
    foreach ($pat in @($Patterns)) {
        if (-not $pat) { continue }
        $p = ([string]$pat).Trim().ToLowerInvariant()
        if (-not $p) { continue }
        if ($n -eq $p) { return $true }
        if ($p.Contains('*') -or $p.Contains('?')) {
            if ($n -like (Get-InvrProcBaseName $p) -or $n -like $p) { return $true }
        }
    }
    return $false
}

function Test-InvrProtectedProcess {
    <#
    .SYNOPSIS
        Защищён ли процесс от автоматического закрытия (белый список + ветка потомков).
    .DESCRIPTION
        ЧИСТАЯ функция: судит по имени, командной строке, pid, pid родителя и карте
        родственных связей из снимка. Защищённым считается процесс, если:

          1) его имя (или имя любого его предка) в белом списке политики:
             ядро, агенты, IDE, базы, docker/vmmem, лицензии, системные;
          2) его командная строка (или родителя) содержит защитный образец
             (mcp-watchdog, infra-graph, opencode, MultiTool, mcp gateway run …) —
             это защищает и обёртки, запущенные от имени ядра;
          3) его pid или pid его родителя входит в список защищённых pid
             (pid узлов из nodes.json при Wanted=true, pid демона, pid предков);
          4) он потомок защищённого процесса (вся ветка потомков);
          5) это браузер (msedge/chrome/…) с главным окном, чей предок — IDE.
    .PARAMETER Process
        Объект процесса (Pid, ParentPid, Name, CommandLine, MainWindowHandle).
    .PARAMETER AllProcesses
        Снимок процессов для обхода предков (например результат Get-InvrProcessSnapshot).
    .PARAMETER ProtectedPids
        Pid, которые защищены напрямую (узлы «нужен», демон, предки).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Process,
        $Policy = $null,
        [AllowEmptyCollection()][int[]]$ProtectedPids = @(),
        [AllowEmptyCollection()][object[]]$AllProcesses = @(),
        [int]$MaxDepth = 12
    )
    if ($null -eq $Process) { return $false }
    if (-not $Policy) { $Policy = Get-InvrReapDefaults }
    $names    = @($Policy.protectedNames)
    $cmdPats  = @($Policy.protectedCmdlinePatterns)
    $browsers = @($Policy.browserNames)
    $idNames  = @('code','code-insiders','idea','idea64','pycharm','pycharm64','webstorm','webstorm64','devenv','rider','goland','clion','studio64')

    $selfPid = 0
    try { $selfPid = [int]$Process.Pid } catch { $selfPid = 0 }

    # карта pid→ppid: сначала из снимка, затем уточняем самим процессом
    $ppid = @{}
    foreach ($p in @($AllProcesses)) {
        if ($null -eq $p) { continue }
        try { $ppid[[int]$p.Pid] = [int]$p.ParentPid } catch { }
    }
    try { if ($selfPid -gt 0) { $ppid[$selfPid] = [int]$Process.ParentPid } } catch { }

    # цепочка: сам процесс и его предки
    $chain = [System.Collections.Generic.List[object]]::new()
    $chain.Add($Process)
    $cur = $selfPid
    $seen = @{}
    for ($i = 0; $i -lt $MaxDepth; $i++) {
        if (-not $ppid.ContainsKey($cur)) { break }
        $parent = [int]$ppid[$cur]
        if ($parent -le 0 -or $seen.ContainsKey($parent)) { break }
        $seen[$parent] = $true
        $pp = @($AllProcesses | Where-Object { $null -ne $_ -and [int]$_.Pid -eq $parent } | Select-Object -First 1)
        if ($pp.Count -gt 0) { $chain.Add($pp[0]) }
        else { $chain.Add([pscustomobject]@{ Pid = $parent; ParentPid = 0; Name = ''; CommandLine = ''; MainWindowHandle = 0 }) }
        $cur = $parent
    }

    # 1) имена в белом списке (сам процесс или предок)
    foreach ($node in $chain) {
        if (Test-InvrNameMatches $([string]$node.Name) $names) { return $true }
    }
    # 5) браузер с окном, чей предок — IDE
    $hasWindow = $false
    try { $hasWindow = ([int64]$Process.MainWindowHandle -ne 0) } catch { }
    if ($hasWindow -and (Test-InvrNameMatches $Process.Name $browsers)) {
        foreach ($anc in @($chain | Select-Object -Skip 1)) {
            if (Test-InvrNameMatches $anc.Name $idNames) { return $true }
        }
    }
    # 3) защищённые pid (сам или родитель/предок)
    $protSet = @{}
    foreach ($id in @($ProtectedPids)) { try { $protSet[[int]$id] = $true } catch { } }
    if ($protSet.Count -gt 0) {
        foreach ($node in $chain) {
            $nodePid = 0
            try { $nodePid = [int]$node.Pid } catch { }
            if ($nodePid -gt 0 -and $protSet.ContainsKey($nodePid)) { return $true }
        }
    }
    # 2) защитные образцы командной строки (сам процесс и предки)
    if (@($cmdPats).Count -gt 0) {
        foreach ($node in $chain) {
            $cmd = ''
            try { $cmd = [string]$node.CommandLine } catch { }
            if (-not $cmd) { continue }
            foreach ($pat in @($cmdPats)) {
                if ($pat -and $cmd.IndexOf([string]$pat, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
            }
        }
    }
    return $false
}

# ---- снимок процессов и группировка ----
function Get-InvrProcessSnapshot {
    <#
    .SYNOPSIS
        Снимок процессов для анализа: pid, родитель, имя, память (МБ), CPU (сек),
        возраст, командная строка, главное окно.
    .DESCRIPTION
        Единственный «дорогой» источник здесь — Get-CimInstance Win32_Process.
        Главное окно берётся из .NET (Get-Process) — в Win32_Process такого поля нет.
        Ошибки WMI не валят демон: при отказе возвращается пустой массив, а решение
        по зачистке при неполных метриках ничего не делает (безопасный инвариант).
    #>
    [CmdletBinding()]
    param([switch]$NoWindowProbe)
    $out = [System.Collections.Generic.List[object]]::new()
    $wins = @{}
    if (-not $NoWindowProbe) {
        try {
            foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
                try { if ($p.MainWindowHandle -ne 0) { $wins[[int]$p.Id] = [int64]$p.MainWindowHandle } } catch { }
            }
        } catch { }
    }
    $procs = @()
    try { $procs = @(Get-CimInstance Win32_Process -ErrorAction Stop) } catch { return @() }
    foreach ($p in $procs) {
        try {
            $pid0 = [int]$p.ProcessId
            $ws   = 0
            try { $ws = [int64]$p.WorkingSetSize } catch { }
            $cpuSec = 0.0
            try {
                $cpuSec = [math]::Round(([double]$p.KernelModeTime + [double]$p.UserModeTime) / 10000000.0, 3)
            } catch { }
            $created = $null
            try { $created = [datetime]$p.CreationDate } catch { $created = $null }
            $win = 0
            if ($wins.ContainsKey($pid0)) { $win = [int64]$wins[$pid0] }
            $out.Add([pscustomobject]@{
                Pid              = $pid0
                ParentPid        = [int]$p.ParentProcessId
                Name             = [string]$p.Name
                Mb               = [math]::Round($ws / 1MB, 1)
                CpuSec           = $cpuSec
                CreatedAt        = $created
                CommandLine      = [string]$p.CommandLine
                MainWindowHandle = $win
            })
        } catch { }
    }
    return @($out)
}

function Get-InvrProcessGroups {
    <#
    .SYNOPSIS
        Группы процессов по имени: память, возраст, сироты, дубли по командной строке,
        дельта CPU за окно замера, признак главного окна.
    .DESCRIPTION
        ЧИСТАЯ функция: работает по готовым снимкам (до/после), а замер WMI делает
        Get-InvrProcessSnapshot. Поэтому правило проверяется тестами на выдуманных
        процессах — без запуска и без завершения чего-либо.

        Дельта CPU берётся как CpuSec(после) − CpuSec(до) по pid. Если «до» не передан
        (или pid в «до» нет), дельта неизвестна: CpuDeltaSec = -1.
    .PARAMETER Snapshot
        Снимок «после» (то, что видно сейчас).
    .PARAMETER PrevSnapshot
        Снимок «до» (сделанный за 2-3 с до). Пусто — дельта неизвестна.
    .PARAMETER AlivePids
        Явный список живых pid (по умолчанию — из снимка «после»).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Snapshot,
        [AllowEmptyCollection()][object[]]$PrevSnapshot = @(),
        [AllowEmptyCollection()][int[]]$AlivePids = @()
    )
    $procs = @($Snapshot | Where-Object { $_ -and ($null -ne $_.Pid) })
    if ($AlivePids.Count -gt 0) { $alive = @($AlivePids | ForEach-Object { [int]$_ }) }
    else { $alive = @($Snapshot | ForEach-Object { [int]$_.Pid }) }
    $aliveSet = @{}
    foreach ($a in $alive) { $aliveSet[[int]$a] = $true }

    $prevCpu = @{}
    foreach ($p in @($PrevSnapshot)) {
        if ($null -eq $p) { continue }
        try { $prevCpu[[int]$p.Pid] = [double]$p.CpuSec } catch { }
    }

    $now = Get-Date
    # Накопители групп. Раньше они подразумевались «уже существующими» ($script:...),
    # но нигде не создавались: первый же вызов падал на вызове метода у $null.
    # Теперь набор пересоздаётся на каждый вызов — функция остаётся чистой и
    # пригодной к повторным вызовам из одного процесса (демон зовёт её каждый цикл).
    $script:InvrGroupsTmp   = @{}
    $script:InvrGroupsOrder = [System.Collections.Generic.List[string]]::new()
    $byName = [ordered]@{}
    foreach ($p in @($Snapshot)) {
        if ($null -eq $p) { continue }
        $name = Get-InvrProcBaseName $p.Name
        if (-not $name) { continue }
        $pid0 = 0; $ppid0 = 0
        try { $pid0 = [int]$Pid } catch { }
        try { $pid0 = [int]$p.Pid } catch { }
        try { $ppid0 = [int]$p.ParentPid } catch { }
        $age = -1
        try {
            if ($p.CreatedAt) { $age = [int]((Get-Date) - ([datetime]$p.CreatedAt)).TotalSeconds }
        } catch { $age = -1 }
        $delta = -1.0
        try {
            if ($PrevSnapshot.Count -gt 0) {
                foreach ($q in @($PrevSnapshot)) {
                    if ($null -ne $q -and [int]$q.Pid -eq $pid0) {
                        $delta = [math]::Round(([double]$p.CpuSec - [double]$q.CpuSec), 3)
                        break
                    }
                }
            }
        } catch { $delta = -1.0 }
        $orphan = ($ppid0 -gt 0 -and -not $aliveSet.ContainsKey($ppid0))
        $win = 0
        try { $win = [int64]$p.MainWindowHandle } catch { }
        $item = [pscustomobject]@{
            Pid              = $pid0
            ParentPid        = $ppid0
            Name             = $name
            RawName          = [string]$p.Name
            Mb               = [double]$p.Mb
            AgeSec           = $age
            CpuDeltaSec      = $delta
            CpuKnown         = ($delta -ge 0)
            CommandLine      = [string]$p.CommandLine
            MainWindowHandle = $win
            HasWindow        = ($win -ne 0)
            IsOrphan         = $orphan
        }
        if (-not $script:InvrGroupsTmp.ContainsKey($name)) { $script:InvrGroupsTmp[$name] = [System.Collections.Generic.List[object]]::new() }
        $script:InvrGroupsTmp[$name].Add($item)
        if (-not $script:InvrGroupsOrder.Contains($name)) { $script:InvrGroupsOrder.Add($name) }
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($name in @($script:InvrGroupsOrder)) {
        $list = @($script:InvrGroupsTmp[$name])
        if ($list.Count -eq 0) { continue }
        $totalMb = 0.0; $maxAge = -1; $orphans = 0; $anyWindow = $false
        $cpuSum = 0.0; $cpuKnown = 0
        foreach ($it in $list) {
            $totalMb += [double]$it.Mb
            if ($it.AgeSec -gt $maxAge) { $maxAge = $it.AgeSec }
            if ($it.IsOrphan) { $orphans++ }
            if ($it.HasWindow) { $anyWindow = $true }
            if ($it.CpuKnown) { $cpuSum += [double]$it.CpuDeltaSec; $cpuKnown++ }
        }
        # дубли по одинаковой командной строке (пустые строки не считаем дублями)
        $byCmd = @{}
        foreach ($it in $list) {
            $c = ([string]$it.CommandLine).Trim()
            if (-not $c) { continue }
            if (-not $byCmd.ContainsKey($c)) { $byCmd[$c] = [System.Collections.Generic.List[object]]::new() }
            $byCmd[$c].Add($it)
        }
        $dups = [System.Collections.Generic.List[object]]::new()
        foreach ($c in @($byCmd.Keys)) {
            if ($byCmd[$c].Count -gt 1) {
                $dups.Add([pscustomobject]@{
                    CommandLine = $c
                    Count       = $byCmd[$c].Count
                    Pids        = @($byCmd[$c] | ForEach-Object { $_.Pid })
                })
            }
        }
        $groups.Add([pscustomobject]@{
            Name         = $name
            Count        = $list.Count
            TotalMb      = [math]::Round($totalMb, 1)
            AvgMb        = [math]::Round($totalMb / $list.Count, 1)
            MaxAgeSec    = $maxAge
            OrphanCount  = $orphans
            CpuDeltaSec  = $(if ($cpuKnown -gt 0) { [math]::Round($cpuSum, 3) } else { -1.0 })
            CpuDeltaKnown = ($cpuKnown -gt 0)
            HasWindow    = $anyWindow
            Duplicates   = @($dups)
            CommandLines = @(@($list | Where-Object { $_.CommandLine } | ForEach-Object { ([string]$_.CommandLine).Trim() } | Select-Object -Unique) | Select-Object -First 5)
            Processes    = @($list)
        })
    }
    return @($groups)
}

function Get-InvrIdleThreshold {
    <#
    .SYNOPSIS
        Порог простоя (сек) для имени процесса: idleSec.<имя> или заводское значение.
    #>
    param([string]$Name, $Policy = $null)
    if (-not $Policy) { $Policy = Get-InvrReapDefaults }
    $n = Get-InvrProcBaseName $Name
    $map = $Policy.idleSec
    if ($map -and $null -ne $map[$n]) { return [int]$map[$n] }
    if ($n -like 'pwsh*' -or $n -like 'powershell*') { return 900 }
    if ($n -like 'python*') { return 600 }
    if ($n -like 'node*')   { return 300 }
    if ($n -like 'uv*')     { return 600 }
    return 900
}

# ---- решение: что закрывать, что предложить, что запрещено ----
function Get-InvrReapDecision {
    <#
    .SYNOPSIS
        ЧИСТОЕ решение о зачистке: breached/не breached, ступень, безопасные кандидаты
        и «на решение владельца».
    .DESCRIPTION
        Никаких побочных эффектов: только группы, числа и политика. Поэтому правило
        проверяется тестами без WMI и без завершения процессов.

        Безопасные инварианты:
          * метрика памяти недоступна (-1) или группы не собрались → решение 'none';
          * свободной памяти больше порога → 'none' (ничего не делаем);
          * режим report → только 'report' (кандидаты публикуются, ничего не закрываем);
          * при свободной памяти ниже absoluteMinFreeMb (200 МБ по умолчанию) агрессия
            НЕ усиливается: остаются только детерминированные правила класса 0;
          * антидребезг: чаще minGapSec и больше maxActionsPerPass/maxActionsPerHour
            закрытий не бывает;
          * классы 1 и 2 в enforce на этом этапе только публикуются (action='suggest').
    .PARAMETER Groups
        Группы из Get-InvrProcessGroups.
    .PARAMETER FreeMemPct
        Свободная физическая память, % (-1 — неизвестна).
    .PARAMETER FreeMemMb
        Свободная физическая память, МБ (-1 — неизвестна).
    .PARAMETER Mode
        report | enforce. Пусто — режим берётся из политики.
    .PARAMETER LastActionAt
        Момент последнего закрытия (антидребезг). MinValue — закрытий не было.
    .PARAMETER ActionsLastHour
        Сколько процессов закрыто за последний час (лимит из политики).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups,
        [double]$FreeMemPct = -1,
        [double]$FreeMemMb = -1,
        [double]$TotalMemMb = -1,
        [int]$ProcCount = -1,
        $Policy = $null,
        [ValidateSet('report','enforce','')]
        [string]$Mode = '',
        [datetime]$LastActionAt = [datetime]::MinValue,
        [int]$ActionsLastHour = 0,
        [AllowEmptyCollection()][int[]]$ProtectedPids = @(),
        [AllowEmptyCollection()][object[]]$AllProcesses = @(),
        [datetime]$Now = (Get-Date)
    )
    if (-not $Policy) { $Policy = Get-InvrReapDefaults }
    $p = $Policy
    $mode = if ($Mode) { $Mode } else { [string]$p.mode }
    if ($mode -notin @('report','enforce')) { $mode = 'report' }

    $out = [ordered]@{
        mode              = $mode
        decision          = 'none'
        breached          = $false
        tier              = 0
        reason            = ''
        minFreePct        = $p.minFreePct
        resumeFreePct     = $p.resumeFreePct
        absoluteMinFreeMb = $p.absoluteMinFreeMb
        minGapSec         = $p.minGapSec
        maxActionsPerPass = $p.maxActionsPerPass
        maxActionsPerHour = $p.maxActionsPerHour
        enforceClasses    = @($p.enforceClasses)
        hardFloor         = $false
        actionsLastHour   = $ActionsLastHour
        lastActionAt      = $(if ($LastActionAt -eq [datetime]::MinValue) { $null } else { $LastActionAt.ToString('yyyy-MM-dd HH:mm:ss') })
        freeMemPct        = $FreeMemPct
        freeMemMb         = $FreeMemMb
        totalMemMb        = $TotalMemMb
        procCount         = $ProcCount
        groupCount        = @($Groups).Count
        orphanCount       = 0
        metricsOk         = $true
        safe              = @()
        suggested         = @()
        protectedSkipped  = 0
        at                = $Now.ToString('yyyy-MM-dd HH:mm:ss')
    }

    # 1) безопасный инвариант: без метрики памяти ничего не делаем
    if ($FreeMemPct -lt 0) {
        $out.metricsOk = $false
        $out.decision  = 'none'
        $out.reason    = 'метрика свободной памяти недоступна — бездействие (безопасный инвариант)'
        return [pscustomobject]$out
    }
    if (@($Groups).Count -eq 0) {
        $out.metricsOk = $false
        $out.decision  = 'none'
        $out.reason    = 'не удалось собрать группы процессов — бездействие (безопасный инвариант)'
        return [pscustomobject]$out
    }

    foreach ($g in @($Groups)) { if ($g.OrphanCount) { $out.orphanCount += [int]$g.OrphanCount } }

    # 2) порог памяти
    $breached = ($FreeMemPct -lt [double]$p.minFreePct)
    $out.breached = $breached
    $out.hardFloor = ($FreeMemMb -ge 0 -and $FreeMemMb -lt [double]$p.absoluteMinFreeMb)
    if (-not $breached) {
        $out.decision = 'none'
        $out.tier     = 0
        $out.reason   = "свободная память $FreeMemPct% — порог $($p.minFreePct)% не пробит, зачистка не нужна"
        return [pscustomobject]$out
    }

    # 3) классификация кандидатов
    $safe = [System.Collections.Generic.List[object]]::new()
    $sugg = [System.Collections.Generic.List[object]]::new()
    $class1 = @($p.class1Names | ForEach-Object { (Get-InvrProcBaseName $_) })
    $class2 = @($p.class2Names | ForEach-Object { (Get-InvrProcBaseName $_) })
    $dups   = @($p.duplicateWrapperNames | ForEach-Object { (Get-InvrProcBaseName $_) })

    # карта «pid → есть ли живые потомки» (нужна для дублей-обёрток и uv)
    $childOf = @{}
    foreach ($g in @($Groups)) {
        foreach ($it in @($g.Processes)) {
            $pp = [int]$it.ParentPid
            if ($pp -le 0) { continue }
            if (-not $childOf.ContainsKey($pp)) { $childOf[$pp] = [System.Collections.Generic.List[object]]::new() }
            $childOf[$pp].Add($it)
        }
    }

    foreach ($g in @($Groups)) {
        foreach ($it in @($g.Processes)) {
            if (Test-InvrProtectedProcess -Process $it -Policy $p -ProtectedPids $ProtectedPids -AllProcesses $AllProcesses) {
                $out.protectedSkipped++
                continue
            }
            $nm      = [string]$it.Name
            $age     = [int]$it.AgeSec
            $hasKids = $childOf.ContainsKey([int]$it.Pid) -and $childOf[[int]$it.Pid].Count -gt 0
            $rule    = $null
            $reason  = $null
            $cls     = $null

            # --- класс 0: детерминированно безопасные ---
            # СТРАХОВКА (0.7.0): «сирота» сама по себе НЕ повод закрывать. Сиротой
            # может оказаться и нужный процесс (например, запущенный из закрытой
            # консоли). Поэтому класс 0 для сирот разрешён ТОЛЬКО безопасному набору
            # обёрток без окна: conhost / uv / uvx (и дубли-обёртки по списку политики).
            # Прочие сироты публикуются как предложение владельцу (класс 1).
            $safeOrphanNames = @('conhost','uv','uvx')
            if ($it.IsOrphan -and -not $it.HasWindow -and ($safeOrphanNames -contains $nm)) {
                $rule = 'orphan'; $cls = 0
                $reason = "сирота класса 0 ($nm): родительский процесс (pid $($it.ParentPid)) мёртв, окна нет"
            } elseif ($it.IsOrphan -and -not $it.HasWindow -and ($dups -contains $nm)) {
                $rule = 'dup-wrapper'; $cls = 0
                $reason = "сирота-обёртка ($nm): родитель мёртв, окна и живых потомков нет"
            } elseif ($it.IsOrphan) {
                $cls = 1; $rule = 'orphan-other'
                $reason = "сирота ($nm): родитель (pid $($it.ParentPid)) мёртв, но имя вне безопасного набора класса 0 — только на решение владельца"
            } elseif ($nm -eq 'conhost' -and -not $it.HasWindow -and -not $hasKids) {
                if ($it.IsOrphan -or ($it.CpuKnown -and $it.CpuDeltaSec -lt [double]$p.cpuActiveSec -and $age -ge (Get-InvrIdleThreshold $nm $p))) {
                    $rule = 'conhost-idle'; $cls = 0
                    $reason = "conhost без владельца-консоли: окна нет, живых потомков нет, простоя ${age} с"
                }
            } elseif ($nm -like 'uv*' -and -not $it.HasWindow) {
                $pyKid = $false
                if ($hasKids) {
                    foreach ($k in @($childOf[[int]$it.Pid])) { if ([string]$k.Name -like 'python*') { $pyKid = $true; break } }
                }
                if (-not $pyKid) {
                    $rule = 'uv-nochild'; $cls = 0
                    $reason = 'uv без живого python-потомка (обёртка осталась без работы)'
                }
            } elseif ($dups -contains $nm -and -not $it.HasWindow -and -not $hasKids) {
                $isDup = $false
                foreach ($d in @($g.Duplicates)) { if (@($d.Pids) -contains [int]$it.Pid) { $isDup = $true; break } }
                if ($isDup) {
                    $rule = 'dup-wrapper'; $cls = 0
                    $reason = "дубль-обёртка без окна и без живых потомков (та же командная строка, всего $($g.Count) шт.)"
                }
            }

            # --- класс 1: интерпретаторы со простоем и без окна ---
            if (-not $rule -and ($class1 -contains $nm) -and -not $it.HasWindow) {
                $thr = Get-InvrIdleThreshold $nm $p
                if ($it.CpuKnown -and $it.CpuDeltaSec -lt [double]$p.cpuActiveSec -and $age -ge $thr) {
                    $cls = 1; $rule = 'idle'
                    $reason = "$nm без окна, простой ${age} с (порог ${thr} с): за окно замера CPU почти не тратил"
                } elseif (-not $it.CpuKnown) {
                    $cls = 1; $rule = 'idle-unknown'
                    $reason = "$nm без окна, простой не измерен (дельта CPU недоступна) — только на решение владельца"
                }
            }

            # --- класс 2: msedgewebview2 ---
            if (-not $rule -and ($class2 -contains $nm)) {
                if ($it.IsOrphan) {
                    $cls = 2; $rule = 'webview-orphan'
                    $reason = 'msedgewebview2-сирота (родитель мёртв)'
                } else {
                    foreach ($d in @($g.Duplicates)) {
                        if (@($d.Pids) -contains [int]$it.Pid) { $cls = 2; $rule = 'webview-dup'; $reason = "дубль профиля msedgewebview2 (одинаковая командная строка, всего $($d.Count) шт.)"; break }
                    }
                }
            }

            if (-not $rule) { continue }

            $cand = [pscustomobject]@{
                name    = $nm
                pid     = [int]$it.Pid
                mb      = [double]$it.Mb
                idleSec = $age
                class   = $cls
                rule    = $rule
                reason  = $reason
                action  = 'suggest'
                cmd     = [string]$it.CommandLine
            }
            if ($cls -eq 0) { $safe.Add($cand) } else { $sugg.Add($cand) }
        }
    }

    # ниже абсолютного минимума памяти агрессию не усиливаем: «мягкие» правила класса 0
    # (conhost-простой) откладываем, остаются только детерминированные (сирота, дубль, uv)
    if ($out.hardFloor) {
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $safe) {
            if ($c.rule -eq 'conhost-idle') {
                $c.reason = "$($c.reason) — отложено: свободной памяти меньше $([int]$p.absoluteMinFreeMb) МБ, агрессию не усиливаем"
                $sugg.Add($c)
            } else { $kept.Add($c) }
        }
        $safe = $kept
    }

    $out.safe      = @($safe)
    $out.suggested = @($sugg)

    # 4) ступень: 0 — если есть безопасные кандидаты, иначе 1 (простой), иначе 2
    $tier = 2
    if (@($safe).Count -gt 0) { $tier = 0 }
    elseif (@($sugg | Where-Object { $_.class -eq 1 }).Count -gt 0) { $tier = 1 }
    $out.tier = $tier
    if (@($safe).Count -eq 0 -and @($sugg).Count -eq 0) {
        $out.decision = 'none'
        $out.reason   = "память $FreeMemPct% ниже порога $($p.minFreePct)%, но безопасных кандидатов нет — ничего не закрываем"
        return [pscustomobject]$out
    }

    # 5) режим и лимиты
    if ($mode -ne 'enforce') {
        $out.decision = 'report'
        foreach ($c in $out.safe)  { $c.action = 'suggest' }
        foreach ($c in $out.suggested) { $c.action = 'suggest' }
        $out.reason = "режим report: память $FreeMemPct% ниже порога $($p.minFreePct)%, кандидатов $((@($out.safe).Count + @($out.suggested).Count)) — закрытие не выполняется"
        return [pscustomobject]$out
    }
    if (@($p.enforceClasses) -notcontains 0) {
        $out.decision = 'report'
        $out.reason   = 'enforce включён, но безопасный класс 0 не разрешён политикой (enforceClasses) — только публикую'
        return [pscustomobject]$out
    }
    if ($ActionsLastHour -ge [int]$p.maxActionsPerHour) {
        $out.decision = 'skip-limits'
        $out.reason   = "память $FreeMemPct% ниже порога, но за час уже закрыто $ActionsLastHour из $($p.maxActionsPerHour) — лимит исчерпан"
        return [pscustomobject]$out
    }
    if ($LastActionAt -ne [datetime]::MinValue) {
        $since = ($Now - $LastActionAt).TotalSeconds
        if ($since -lt [int]$p.minGapSec) {
            $out.decision = 'skip-gap'
            $out.reason   = "нарушение есть, но прошло $([int]$since) с из $($p.minGapSec) с с прошлого прохода — антидребезг"
            return [pscustomobject]$out
        }
    }
    if (@($safe).Count -eq 0) {
        $out.decision = 'report'
        $out.reason   = "память $FreeMemPct% ниже порога, но безопасных кандидатов нет — публикую только предложения владельцу"
        return [pscustomobject]$out
    }

    # берём не более maxActionsPerPass: сначала самые тяжёлые, затем самые старые
    $ordered = @($safe | Sort-Object -Property @{Expression={ [double]$_.mb }; Descending=$true}, @{Expression={ [int]$_.idleSec }; Descending=$true})
    $limit = [int]$p.maxActionsPerPass
    $chosen = @()
    $extra  = @()
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        if ($i -lt $limit) { $ordered[$i].action = 'close'; $chosen += $ordered[$i] }
        else { $ordered[$i].action = 'suggest'; $extra += $ordered[$i] }
    }
    $out.decision  = 'enforce'
    $out.safe      = @($chosen)
    $out.suggested = @($out.suggested) + @($extra)
    $out.reason    = "память $FreeMemPct% ниже порога $($p.minFreePct)%: закрываю безопасный класс 0 — $(($chosen | ForEach-Object { "$($_.name)#$($_.pid) ($($_.mb) МБ)" }) -join ', ')"
    return [pscustomobject]$out
}

# ---- утилита записи (единственная функция с побочным эффектом) ----
function Write-InvrAtomicJson {
    <#
    .SYNOPSIS
        Атомарная запись JSON: временный файл рядом → Move-Item -Force, UTF-8 без BOM.
    .DESCRIPTION
        Прямая запись Set-Content затирает файл и делает его видимым читателю пустым
        (именно так state\current.json оказался нулевого размера: демон писал сводку,
        а guardian уже читал файл). Атомарная замена исключает это: читатель видит
        либо старую версию, либо новую целиком.

        Если файл кем-то открыт так, что замена невозможна (или антивирус/индексатор
        держит временный файл), делается до 3 попыток с паузой 200 мс. Возвращается
        $true при успехе и $false, если все попытки исчерпаны (демон продолжит работу).
    .PARAMETER Path
        Куда писать (каталог должен существовать).
    .PARAMETER Data
        Значение (хэш-таблица/объект), сериализуется в JSON с глубиной Depth.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Data,
        [int]$Depth = 8,
        [int]$Attempts = 3,
        [int]$DelayMs = 200
    )
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch { return $false }
    }
    $tmp = Join-Path $dir ('.' + (Split-Path -Path $Path -Leaf) + '.tmp')
    $json = $null
    try { $json = $Data | ConvertTo-Json -Depth $Depth } catch { return $false }
    $enc = New-Object System.Text.UTF8Encoding($false)   # UTF-8 без BOM
    $i = 0
    while ($i -lt [math]::Max(1, $Attempts)) {
        $i++
        try {
            [System.IO.File]::WriteAllText($tmp, $json, $enc)
            Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
            return $true
        } catch {
            try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
            if ($i -lt $Attempts) { Start-Sleep -Milliseconds $DelayMs }
        }
    }
    return $false
}
