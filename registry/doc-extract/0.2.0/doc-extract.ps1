param(
    [string]$InputPath,
    [string]$OutFile,
    [string]$ReportOut,
    [ValidateSet('auto', 'analyze', 'process', 'judge')][string]$Mode = 'auto',
    [int]$MaxProviders = 3,
    [switch]$Judge,
    [switch]$NoJudge,
    [switch]$NoOllama,
    [string]$Providers,
    [string]$ItemsJson,
    [int]$TimeoutSec = 180
)
# UTF-8 console default (no krakozyabry)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:USERPROFILE '.docorchestra'
$reportDir = Join-Path $stateRoot 'reports'

function Get-EnvStrict {
    param([string]$Name)
    $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($v)) { $v = [Environment]::GetEnvironmentVariable($Name, 'User') }
    if ([string]::IsNullOrWhiteSpace($v)) { $v = [Environment]::GetEnvironmentVariable($Name, 'Machine') }
    return $v
}

function Add-ToObject {
    param($Obj, [string]$Prop, $Value)
    $Obj.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new($Prop, $Value))
}

function Get-InputInfo {
    param([string]$Path)
    $isUrl = $Path -match '^https?://'
    $info = [pscustomobject]@{ input = $Path; is_url = $isUrl; ext = ''; bytes = 0; est_pages = 1; est_tokens = 0 }
    if (-not $isUrl) {
        $full = [System.IO.Path]::GetFullPath($Path)
        if (-not (Test-Path -LiteralPath $full)) { throw "File not found: $full" }
        $info.ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
        $info.bytes = (Get-Item -LiteralPath $full).Length
        $info.input = $full
    }
    $info.est_pages = [math]::Max(1, [int]($info.bytes / 3000))
    $info.est_tokens = [math]::Max(1, [int]($info.bytes / 3.2))
    return $info
}

$providerDefs = @(
    @{ name = 'firecrawl'; kind = 'file'; exts = @('.pdf', '.html', '.htm', '.docx', '.doc', '.odt', '.rtf', '.xlsx', '.xls'); keyvars = @(); free_note = 'Free по кредитам (сейчас 1394)'; method = 'Invoke-FirecrawlParse' },
    @{ name = 'xparse'; kind = 'both'; exts = @('.pdf', '.html', '.rtf', '.docx', '.xlsx', '.png', '.jpg', '.jpeg', '.bmp', '.tiff', '.webp'); keyvars = @(); free_note = '1000 стр/день keyless (xparse-cli --api free)'; method = 'Invoke-XParse' },
    @{ name = 'gemini'; kind = 'both'; exts = @('.pdf', '.png', '.jpg', '.jpeg', '.webp', '.tiff', '.bmp'); keyvars = @('GEMINI_API_KEY'); free_note = 'Free tier (включается конфигом, недоступен в некоторых регионах)'; method = 'Invoke-Gemini'; model = 'gemini-2.0-flash' },
    @{ name = 'ocrspace'; kind = 'image'; exts = @('.pdf', '.png', '.jpg', '.jpeg', '.tiff', '.gif', '.bmp'); keyvars = @('OCRSPACE_API_KEY'); free_note = '25k/мес, 500/день/IP, 1МБ, 3 стр'; method = 'Invoke-OcrSpace' },
    @{ name = 'mistral'; kind = 'both'; exts = @('.pdf', '.png', '.jpg', '.jpeg'); keyvars = @('MISTRAL_API_KEY'); free_note = 'Free mode, лимит в аккаунте'; method = 'Invoke-Mistral' },
    @{ name = 'textin'; kind = 'both'; exts = @('.pdf', '.png', '.jpg', '.jpeg'); keyvars = @('TEXTIN_APP_ID', 'TEXTIN_APP_SECRET'); free_note = 'Free-пробник, квота не раскрыта'; method = 'Invoke-TextIn' },
    @{ name = 'azure'; kind = 'both'; exts = @('.pdf', '.png', '.jpg', '.jpeg', '.tiff', '.bmp'); keyvars = @('AZURE_DI_ENDPOINT', 'AZURE_DI_KEY'); free_note = 'F0: 2 стр/запрос, 1 RPS'; method = 'Invoke-AzureDI' }
)

function Get-ConfigFile { return Join-Path $PSScriptRoot 'doc-extract-config.json' }
function Get-DisabledProviders {
    $cfgPath = Get-ConfigFile
    if (-not (Test-Path -LiteralPath $cfgPath)) { return @{} }
    try {
        $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
        $disabled = @{}
        $provSec = $cfg.providers
        if ($provSec) {
            foreach ($prop in $provSec.PSObject.Properties) {
                if ($prop.Value.enabled -eq $false) { $disabled[$prop.Name] = $prop.Value.note }
            }
        }
        return $disabled
    } catch { return @{} }
}

function Get-AvailableProviders {
    param([string]$Ext, [string]$Include)
    $any = @()
    if ($Include) {
        foreach ($seg in ($Include -split ',')) {
            $name = $seg.Trim().ToLowerInvariant()
            if ($name) { $any += $name }
        }
    }
    $avail = @()
    $availNames = @()
    $disabled = Get-DisabledProviders
    foreach ($p in $providerDefs) {
        if ($disabled.ContainsKey($p.name)) { continue }
        if ($any.Count -gt 0 -and $p.name -notin $any) { continue }
        if ($p.name -eq 'firecrawl' -and -not (Get-Command firecrawl -ErrorAction SilentlyContinue)) { continue }
        if ($p.name -eq 'xparse' -and -not (Get-Command xparse-cli -ErrorAction SilentlyContinue)) { continue }
        if ($p.name -ne 'firecrawl' -and $p.name -ne 'xparse') {
            $missing = @()
            foreach ($kv in $p.keyvars) { if (-not (Get-EnvStrict $kv)) { $missing += $kv } }
            if ($missing.Count -gt 0) { continue }
        }
        if ($Ext -and $p.exts -and $Ext -notin $p.exts) { continue }
        $avail += $p
        $availNames += $p.name
    }
    return $avail
}

function Get-Result {
    param([string]$Provider, [bool]$Ok, [string]$Text, [string]$Error)
    $r = [pscustomobject]@{ provider = $Provider; ok = $Ok; text = $Text; error = $Error; tokens = 0; table_lines = 0; chars = 0; time_ms = 0 }
    if ($Ok -and $Text) {
        $r.chars = $Text.Length
        $r.tokens = [math]::Max(1, [int]($Text.Length / 3.2))
        $r.table_lines = ([regex]::Matches($Text, '(?im)^\s*\|')).Count + ([regex]::Matches($Text, '(?i)<table')).Count
    }
    return $r
}

function Invoke-FirecrawlParse {
    param([string]$Path)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fcparse_{0}.json" -f ([guid]::NewGuid().ToString('N')))
    if ($Path -match '^https?://') {
        & firecrawl scrape $Path --format markdown --json -o $tmp 2>&1 | Out-Null
    } else {
        & firecrawl parse $Path --format markdown --json -o $tmp 2>&1 | Out-Null
    }
    if (-not (Test-Path $tmp)) { return Get-Result 'firecrawl' $false '' 'no output from firecrawl' }
    $j = Get-Content -Raw $tmp | ConvertFrom-Json
    $md = $null
    try { $md = $j.markdown; if (-not $md) { $md = $j.data.markdown } } catch { }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if ($md) {
        $r = Get-Result 'firecrawl' $true $md ''
        $r.text = $md
        return $r
    }
    return Get-Result 'firecrawl' $false '' 'firecrawl returned no markdown'
}

function Invoke-XParse {
    param([string]$Path)
    if (-not (Get-Command xparse-cli -ErrorAction SilentlyContinue)) { return Get-Result 'xparse' $false '' 'xparse-cli not installed' }
    try {
        $out = & xparse-cli parse $Path --api free 2>&1
        $txt = @($out) -join "`n"
        $txt = ($txt -replace '^\s*\[.*?\]\s*$', '').Trim()
        if (-not $txt) { return Get-Result 'xparse' $false '' 'empty result' }
        return Get-Result 'xparse' $true $txt $null
    } catch {
        return Get-Result 'xparse' $false '' ($_.Exception.Message)
    }
}

function Invoke-Gemini {
    param([string]$Path)
    $key = Get-EnvStrict 'GEMINI_API_KEY'
    if (-not $key) { return Get-Result 'gemini' $false '' 'no key' }
    $pw = $providerDefs | Where-Object { $_.name -eq 'gemini' } | Select-Object -First 1
    $model = if (Get-EnvStrict 'GEMINI_MODEL') { Get-EnvStrict 'GEMINI_MODEL' } else { $pw.model }
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
    $mime = switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.pdf' { 'application/pdf' } '.png' { 'image/png' } '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' } '.webp' { 'image/webp' } '.tiff' { 'image/tiff' } '.bmp' { 'image/bmp' }
        default { 'application/octet-stream' }
    }
    $body = @{
        contents = @(@{ parts = @(@{ text = 'Извлеки весь текст и таблицы из документа в Markdown. Сохраняй таблицы как markdown-таблицы.' }, @{ inline_data = @{ mime_type = $mime; data = $b64 } }) })
        generationConfig = @{ responseMimeType = 'text/plain'; temperature = 0.1 }
    } | ConvertTo-Json -Depth 10
    $uri = "https://generativelanguage.googleapis.com/v1beta/models/$model`:generateContent?key=$key"
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
        $txt = $resp.candidates[0].content.parts[0].text
        return Get-Result 'gemini' $true $txt $null
    } catch {
        return Get-Result 'gemini' $false '' ($_.Exception.Message)
    }
}

function Invoke-OcrSpace {
    param([string]$Path)
    $key = Get-EnvStrict 'OCRSPACE_API_KEY'
    if (-not $key) { return Get-Result 'ocrspace' $false '' 'no key' }
    $form = @{ apikey = $key; language = 'rus'; isTable = 'true'; OCREngine = '3'; scale = 'true'; file = Get-Item $Path }
    try {
        $resp = Invoke-RestMethod -Method Post -Uri 'https://api.ocr.space/parse/image' -Form $form -TimeoutSec $TimeoutSec
        if ($resp.ParsedResults) {
            $txt = (($resp.ParsedResults | ForEach-Object { $_.ParsedText }) -join "`n").Trim()
            return Get-Result 'ocrspace' $true $txt $null
        }
        return Get-Result 'ocrspace' $false '' ($resp.ErrorMessage)
    } catch {
        return Get-Result 'ocrspace' $false '' ($_.Exception.Message)
    }
}

function Invoke-Mistral {
    param([string]$Path)
    $key = Get-EnvStrict 'MISTRAL_API_KEY'
    if (-not $key) { return Get-Result 'mistral' $false '' 'no key' }
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
    $url = if ($Path -match '\.(png|jpe?g|webp)$') { "data:image/png;base64,$b64" } else { "data:application/pdf;base64,$b64" }
    $body = @{ model = 'mistral-ocr-latest'; document = @{ type = 'document_url'; document_url = $url } } | ConvertTo-Json -Depth 6
    try {
        $h = @{ Authorization = "Bearer $key" }
        $resp = Invoke-RestMethod -Method Post -Uri 'https://api.mistral.ai/v1/ocr' -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
        $txt = (($resp.pages | ForEach-Object { $_.markdown }) -join "`n`n").Trim()
        return Get-Result 'mistral' $true $txt $null
    } catch {
        return Get-Result 'mistral' $false '' ($_.Exception.Message)
    }
}

function Invoke-TextIn {
    param([string]$Path)
    $appId = Get-EnvStrict 'TEXTIN_APP_ID'
    $secret = Get-EnvStrict 'TEXTIN_APP_SECRET'
    if (-not ($appId -and $secret)) { return Get-Result 'textin' $false '' 'no keys' }
    try {
        $h = @{ 'x-ti-app-id' = $appId; 'x-ti-secret-code' = $secret }
        $resp = Invoke-RestMethod -Method Post -Uri 'https://api.textin.com/v1/recognition' -Headers $h -Form @{ file = Get-Item $Path } -TimeoutSec $TimeoutSec
        $txt = $resp.Result
        return Get-Result 'textin' $true $txt $null
    } catch {
        return Get-Result 'textin' $false '' ($_.Exception.Message)
    }
}

function Invoke-AzureDI {
    param([string]$Path)
    $endpoint = Get-EnvStrict 'AZURE_DI_ENDPOINT'
    $key = Get-EnvStrict 'AZURE_DI_KEY'
    if (-not ($endpoint -and $key)) { return Get-Result 'azure' $false '' 'no keys' }
    $api = '2023-07-31'
    $analyze = "$endpoint`/formrecognizer/documentModels/prebuilt-read:analyze?api-version=$api"
    try {
        $h = @{ 'Ocp-Apim-Subscription-Key' = $key }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $pre = Invoke-WebRequest -Method Post -Uri $analyze -Headers $h -ContentType 'application/octet-stream' -Body $bytes -TimeoutSec $TimeoutSec
        $loc = $pre.Headers['Operation-Location']
        if (-not $loc) { return Get-Result 'azure' $false '' 'no operation location' }
        $loc = $loc.ToString()
        $txt = ''
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 2
            $res = Invoke-RestMethod -Method Get -Uri $loc -Headers $h -TimeoutSec $TimeoutSec
            if ($res.status -eq 'succeeded') {
                $txt = $res.analyzeResult.content
                break
            }
            if ($res.status -eq 'failed') { return Get-Result 'azure' $false '' 'analyze failed' }
        }
        return Get-Result 'azure' $true $txt $null
    } catch {
        return Get-Result 'azure' $false '' ($_.Exception.Message)
    }
}

function Get-NormalizedWords {
    param([string]$Text)
    $t = $Text.ToLowerInvariant() -replace '[^a-zа-яё0-9\s]', ' '
    $words = [regex]::Matches($t, '[a-zа-яё0-9]{3,}') | ForEach-Object { $_.Value }
    $set = @{}
    foreach ($w in $words) { $null = $set.Set_Item($w, $true) }
    return $set
}

function Get-Jaccard {
    param($A, $B)
    if (-not $A -or -not $B) { return 0 }
    $inter = 0
    foreach ($k in $A.Keys) { if ($B.ContainsKey($k)) { $inter++ } }
    $union = ($A.Count + $B.Count - $inter)
    if ($union -le 0) { return 0 }
    return [double]$inter / [double]$union
}

function Test-Ollama {
    try { Invoke-RestMethod -Method Get -Uri 'http://localhost:11434/api/tags' -TimeoutSec 3 | Out-Null; return $true } catch { return $false }
}

function Invoke-OllamaJudge {
    param([array]$Items)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Ты независимый судья-сравнильщик результатов OCR/извлечения текста и таблиц из документа. Сравни извлечения от разных провайдеров и выбери самое правдоподобное, полное и логичное.')
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $frag = ($Items[$i].text -replace '[\r\n]+', ' ')
        if ($frag.Length -gt 2500) { $frag = $frag.Substring(0, 2500) }
        $lines.Add("")
        $lines.Add("ИЗВЛЕЧЕНИЕ $($i + 1) (провайдер: $($Items[$i].provider), символов: $($Items[$i].chars), строк-таблиц: $($Items[$i].table_lines)):")
        $lines.Add("---ФРАГМЕНТ НАЧАЛО---")
        $lines.Add($frag)
        $lines.Add("---ФРАГМЕНТ КОНЕЦ---")
    }
    $lines.Add('')
    $lines.Add('Критерии: полнота текста, распознавание таблиц, отсутствие явных галлюцинаций и обрывов, согласованность фактов между извлечениями.')
    $lines.Add('Ответь строго одним JSON-объектом: {"best": "<provider-имя>", "confidence": 0-100, "agreement": "high|medium|low", "doubtful": true|false, "notes": "<короткое пояснение на русском>"}')
    $promptText = $lines -join "`n"
    $body = @{
        model = 'hermes3:8b'
        prompt = $promptText
        options = @{ temperature = 0.1; num_predict = 400 }
        stream = $false
    } | ConvertTo-Json -Depth 8
    $resp = Invoke-RestMethod -Method Post -Uri 'http://localhost:11434/api/generate' -ContentType 'application/json' -Body $body -TimeoutSec 240
    $out = $resp.response
    $m = [regex]::Match($out, '\{[\s\S]*\}')
    if ($m.Success) {
        try { return ($m.Value | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Get-JudgeVerdict {
    param([array]$Results, [bool]$OllamaOk)
    $ok = @($Results | Where-Object { $_.ok })
    if ($ok.Count -eq 0) {
        return [pscustomobject]@{ best_provider = ''; confidence = 0; doubtful = $true; doubts = @('Все провайдеры завершились ошибкой'); llm_used = $false; notes = '' }
    }
    if ($ok.Count -eq 1) {
        $r = $ok[0]
        $doubts = @()
        if ($r.table_lines -lt 1 -and $r.tokens -gt 600) { $doubts += 'В извлечении нет строк-таблиц при достаточном объёме — таблицы могли быть потеряны' }
        if ($r.chars -lt 120) { $doubts += 'Извлечённый текст подозрительно короткий' }
        $d = ($doubts.Count -gt 0)
        $conf = 60
        if ($d) { $conf = 50 }
        return [pscustomobject]@{ best_provider = $r.provider; confidence = $conf; doubtful = $d; doubts = $doubts; llm_used = $false; notes = 'Один источник, независимой проверки нет' }
    }
    $wordSets = @{}
    foreach ($r in $ok) { $wordSets[$r.provider] = Get-NormalizedWords $r.text }
    $overlaps = @{}
    for ($i = 0; $i -lt $ok.Count; $i++) {
        for ($j = $i + 1; $j -lt $ok.Count; $j++) {
            $jacc = Get-Jaccard $wordSets[$ok[$i].provider] $wordSets[$ok[$j].provider]
            $overlaps["$($ok[$i].provider)<->$($ok[$j].provider)"] = $jacc
        }
    }
    $maxLen = ($ok | Measure-Object -Property chars -Maximum).Maximum
    $maxTab = ($ok | Measure-Object -Property table_lines -Maximum).Maximum
    $scores = @{}
    foreach ($r in $ok) {
        $tabScore = 0
        if ($maxTab -gt 0) { $tabScore = $r.table_lines / $maxTab }
        $errScore = 1
        if ($r.error) { $errScore = 0 }
        $s = 0.55 * ($r.chars / $maxLen) + 0.35 * $tabScore + 0.10 * $errScore
        $scores[$r.provider] = $s
    }
    $heuristicBest = ($scores.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    $bestObj = $ok | Where-Object { $_.provider -eq $heuristicBest } | Select-Object -First 1
    $avgJacc = 0
    if ($overlaps.Count -gt 0) { $avgJacc = (($overlaps.Values | Measure-Object -Average).Average) }
    $doubts = @()
    if ($avgJacc -lt 0.55 -and $overlaps.Count -gt 0) { $doubts += ("Низкое согласие между провайдерами (Jaccard = {0:N2})" -f $avgJacc) }
    if ($maxTab -eq 0) { $doubts += 'Ни один источник не содержит таблиц' }
    $llm = $null
    $llmUsed = $false
    if ($OllamaOk -and $ok.Count -ge 2) {
        try { $llm = Invoke-OllamaJudge $ok; if ($llm) { $llmUsed = $true } } catch { }
    }
    $finalBest = $heuristicBest
    $confidence = 62
    if ($llm -and $llm.confidence) {
        $confidence = [int]$llm.confidence
        if ($llm.best -and $llm.best -ne $heuristicBest -and $confidence -ge 60) { $finalBest = $llm.best; $bestObj = $ok | Where-Object { $_.provider -eq $finalBest } | Select-Object -First 1 }
        elseif ($llm.doubtful) { $doubts += 'LLM-судья отметил результат сомнительным' }
    }
    $d = ($doubts.Count -gt 0) -or (-not $llm -and $overlaps.Count -gt 0 -and $avgJacc -lt 0.55)
    $notes = ''
    if ($llm -and $llm.notes) { $notes = $llm.notes }
    return [pscustomobject]@{ best_provider = $finalBest; confidence = $confidence; doubtful = $d; doubts = $doubts; llm_used = $llmUsed; notes = $notes; overlaps = $overlaps; scores = $scores }
}

function Select-Scheme {
    param($InputInfo, $Avail, [bool]$WantJudge)
    $scheme = [pscustomobject]@{ id = ''; description = ''; providers = @(); est_tokens = $InputInfo.est_tokens; est_cost = '0 (free tier)'; recommended = 'analyze' ; reason = '' }
    $est = $InputInfo.est_tokens
    if ($Avail.Count -eq 0) {
        $scheme.id = 'S0-analysis'
        $scheme.description = 'Анализ без извлечения (нет доступных провайдеров)'
        $scheme.reason = 'нужен ключ хотя бы одного провайдера'
        return $scheme
    }
    $ordered = @($Avail | Sort-Object priority)
    $top = @($ordered | Select-Object -First $MaxProviders)
    $scheme.providers = @($top | ForEach-Object { $_.name })
    if ($Mode -eq 'analyze') {
        $scheme.id = 'S0-analysis'
        $scheme.description = 'Анализ и рекомендация схемы без извлечения'
        $scheme.recommended = 'analyze'
        $scheme.reason = "Рекомендуемые провайдеры: $($scheme.providers -join ', '); оценка ~$($est) токенов входного документа"
        return $scheme
    }
    if ($WantJudge -and $top.Count -ge 2) {
        $scheme.id = 'S3-judge-pool'
        $scheme.description = 'Пул 2+ провайдеров c независимым судьёй (правдоподобность, сомнительные метки)'
        $scheme.reason = "конкурентная проверка: ~$($est * 2) токенов на сравнение"
        $scheme.recommended = 'judge'
    } else {
        $scheme.id = 'S2-failover-pool'
        $scheme.description = 'Пул с failover: ошибка провайдера -> следующий по приоритету'
        $scheme.reason = "минимальный расход: ~$est токенов, один провайдер"
        $scheme.recommended = 'process'
    }
    return $scheme
}

$inputInfo = $null
$pool = @()
$errors = @()
$unavailable = @()
$wantJudge = $Judge -or ($Mode -eq 'judge')
if ($NoJudge) { $wantJudge = $false }

if ($ItemsJson) {
    if (-not (Test-Path -LiteralPath $ItemsJson)) { throw "ItemsJson not found: $ItemsJson" }
    $scheme = [pscustomobject]@{ id = 'S5-external-compare'; description = 'Сравнение готовых извлечений из внешнего списка (пересуд)'; providers = @(); est_tokens = 0; est_cost = 'n/a'; recommended = 'judge'; reason = 'пересуд ранее сохранённых извлечений' }
    $raw = @(Get-Content -Raw -LiteralPath $ItemsJson | ConvertFrom-Json)
    foreach ($it in $raw) {
        $t = [string]$it.text
        $pool += [pscustomobject]@{ provider = [string]$it.provider; ok = $true; text = $t; error = ''; tokens = [math]::Max(1, [int]($t.Length / 3.2)); table_lines = ([regex]::Matches($t, '(?im)^\s*\|')).Count + ([regex]::Matches($t, '(?i)<table')).Count; chars = $t.Length; time_ms = 0 }
    }
} else {
    if (-not $InputPath) { throw 'InputPath required when ItemsJson not specified' }
    $inputInfo = Get-InputInfo $InputPath
    $available = @()
    if ($Providers) { $available = Get-AvailableProviders $inputInfo.ext $Providers }
    else { $available = Get-AvailableProviders $inputInfo.ext $null }
    foreach ($p in $providerDefs) {
        if ($p.name -in ($available | ForEach-Object { $_.name })) { continue }
        $reasons = @()
        if ($p.name -eq 'firecrawl' -and -not (Get-Command firecrawl -ErrorAction SilentlyContinue)) { $reasons += 'firecrawl CLI не установлен' }
        if ($p.name -eq 'xparse' -and -not (Get-Command xparse-cli -ErrorAction SilentlyContinue)) { $reasons += 'xparse-cli не установлен' }
        if ($p.name -notin @('firecrawl', 'xparse')) {
            $missing = @()
            foreach ($kv in $p.keyvars) { if (-not (Get-EnvStrict $kv)) { $missing += $kv } }
            if ($missing.Count -gt 0) { $reasons += "нет ключей: $($missing -join ', ')" }
        }
        if ($inputInfo.ext -and $p.exts -and $inputInfo.ext -notin $p.exts) { $reasons += 'не поддерживает формат' }
        $disabledNote = $null
        try { $disabled = Get-DisabledProviders; if ($disabled.ContainsKey($p.name)) { $disabledNote = $disabled[$p.name] } } catch {}
        if ($disabledNote) { $reasons += "отключён в конфиге ($disabledNote)" }
        if ($reasons.Count -gt 0) { $unavailable += "$($p.name) ($($reasons -join '; '))" }
    }
    $scheme = Select-Scheme $inputInfo $available $wantJudge
    if ($scheme.id -ne 'S0-analysis') {
        foreach ($p in $scheme.providers) {
            $prov = $providerDefs | Where-Object { $_.name -eq $p } | Select-Object -First 1
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $res = & $prov.method $inputInfo.input
            $sw.Stop()
            $res.time_ms = $sw.ElapsedMilliseconds
            $pool += $res
            if ($res.ok) {
                if ($scheme.recommended -eq 'process' -or ($Mode -eq 'auto' -and -not $wantJudge)) { break }
            } else {
                $errors += $res
            }
            if ($wantJudge -and ($pool | Where-Object { $_.ok }).Count -ge 2) { break }
        }
    }
}

$ollamaOk = if (-not $NoOllama) { Test-Ollama } else { $false }
$verdict = Get-JudgeVerdict $pool $ollamaOk

$outPath = $OutFile
if (-not $outPath) {
    if ($inputInfo) {
        $outPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($inputInfo.input), ("{0}_extracted.md" -f [System.IO.Path]::GetFileNameWithoutExtension($inputInfo.input)))
    } else {
        $outPath = Join-Path (Get-Location).Path 'judged-best.md'
    }
}
$best = $pool | Where-Object { $_.ok -and $_.provider -eq $verdict.best_provider } | Select-Object -First 1
if ($best) {
    try { Set-Content -LiteralPath $outPath -Value $best.text -Encoding UTF8 -Force } catch { $outPath = 'ERROR' }
}

if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$baseName = 'items'
if ($inputInfo) { $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputInfo.input) }
$reportName = "{0}_{1}.json" -f $baseName, (Get-Date -Format 'yyyyMMdd_HHmmss')
if (-not $ReportOut) { $ReportOut = Join-Path $reportDir $reportName }

$report = [pscustomobject]@{}
Add-ToObject $report 'generated' (Get-Date -Format 'o')
Add-ToObject $report 'input' $inputInfo
Add-ToObject $report 'scheme' $scheme
Add-ToObject $report 'unavailable_providers' $unavailable
Add-ToObject $report 'pool' @($pool | ForEach-Object { [pscustomobject]@{ provider = $_.provider; ok = $_.ok; error = $_.error; chars = $_.chars; tokens = $_.tokens; table_lines = $_.table_lines; time_ms = $_.time_ms } })
Add-ToObject $report 'verdict' ([pscustomobject]@{ best_provider = $verdict.best_provider; confidence = $verdict.confidence; doubtful = $verdict.doubtful; doubts = $verdict.doubts; llm_used = $verdict.llm_used; notes = $verdict.notes })
Add-ToObject $report 'output_file' $outPath

$report | ConvertTo-Json -Depth 8 | Set-Content -Path $ReportOut -Encoding UTF8

$v = $report.verdict
Write-Output ('Схема: [{0}] {1}' -f $scheme.id, $scheme.description)
Write-Output ('Оценка расхода: ~{0} токенов | стоимость: {1} | выбор: {2}' -f $scheme.est_tokens, $scheme.est_cost, $scheme.recommended)
Write-Output ('Провайдеры пула: {0}' -f (@($pool | ForEach-Object { "$($_.provider):$(if($_.ok){'OK'}else{'ERR'})" }) -join ', '))
if ($unavailable.Count) { Write-Output ('Нет ключей (пропущены): {0}' -f ($unavailable -join '; ')) }
Write-Output ('Вердикт: лучший = {0}; уверенность = {1}%; сомнительный = {2}' -f $v.best_provider, $v.confidence, $v.doubtful)
if ($v.doubts.Count) { Write-Output ('Причины сомнения: {0}' -f ($v.doubts -join '; ')) }
if ($v.notes) { Write-Output ('Пояснение судьи: {0}' -f $v.notes) }
Write-Output ('Markdown-результат: {0}' -f $outPath)
Write-Output ('JSON-отчёт: {0}' -f $ReportOut)