<#
.SYNOPSIS
  Проверка каталога (по умолчанию — всего репозитория) на типовые секреты.

.DESCRIPTION
  Сканирует текстовые файлы на типовые секреты: ключи API известных провайдеров,
  токены и пароли, зашитые в код и конфигурацию, приватные ключи, строки
  подключения с учётными данными.

  ГЛАВНОЕ ПРАВИЛО: скрипт НИКОГДА не печатает и не записывает найденные
  значения. В вывод и в отчёт попадают только путь, номер строки, тип находки и
  описание правила. Значение нужно смотреть глазами в исходнике.

  Ложные срабатывания: в коде инструментов масса упоминаний имён переменных
  окружения (GEMINI_API_KEY, GetEnvironmentVariable('FIRECRAWL_API_KEY') и т.п.) —
  это не секреты, и правила срабатывают только на ЛИТЕРАЛЫ значений и строки
  подключения. Дополнительно отсекаются плейсхолдеры (sk-..., YOUR_*, <...>,
  ${...}, $env:*, changeme, redacted, xxx, ***, example.com, localhost,
  127.0.0.1), пустые значения и значения короче минимальной длины.

  Код возврата: 0 — находок нет, 1 — есть находки (для CI), 2 — ошибка запуска.

  pwsh -NoProfile -File tools\ci\scan-secrets.ps1
  pwsh -NoProfile -File tools\ci\scan-secrets.ps1 -Path C:\project\registry
  pwsh -NoProfile -File tools\ci\scan-secrets.ps1 -Report artifacts\secrets\findings.csv
#>
param(
    [string]$Path = '',
    [string]$Report = '',
    [string[]]$ExcludePath = @()
)
# UTF-8 console default (no krakozyabry)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ErrorActionPreference = 'Stop'

# По умолчанию сканируется корень репозитория целиком, включая registry\ и шимы:
# секрет может оказаться где угодно, -Path нужен только для выборочной проверки.
if (-not $Path) { $Path = Join-Path $PSScriptRoot '..\..' }
$Path = [IO.Path]::GetFullPath($Path)
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "ОШИБКА: путь не найден: $Path" -ForegroundColor Red
    exit 2
}

# Минимальная длина литерала, при которой значение считается кандидатом.
$MinSecretLength = 12

# Плейсхолдеры и «не секрет»-значения: сравнение по вхождению.
$placeholderPattern = '(?i)^(x{3,}|\*+|changeme|change_me|redacted|placeholder|example|sample|dummy|test|your[_-]?.*|none|null|nil|empty|unset|secret|password|passwd|pass|pwd|token|apikey|api_key|key|user|username|login|admin|root|not[_-]?a[_-]?key|to[_-]?be[_-]?set|replace[_-]?me|hidden|\.\.\.|sk-\.*|<[^>]*>|\$\{[^}]*\}|\{\{[^}]*\}\}|\$[A-Za-z_][\w:]*|%\w+%)$'
$placeholderSubstring = '(?i)example\.(com|org|net)|localhost|127\.0\.0\.1|0\.0\.0\.0|<[^>]+>|\$[A-Za-z_][\w:]*|\{[A-Za-z_][\w]*\}|\bplaceholder\b|\bchangeme\b|\bredacted\b|\.\.\.'

# Правила. Capture = 1, если группа 1 — извлекаемое значение (оно НЕ выводится).
$rules = @(
    [pscustomobject]@{ Name = 'Приватный ключ'; Description = 'Блок приватного ключа PEM/DER или PGP'; Capture = 0; FileOnly = ''; Pattern = '-----BEGIN\s+([A-Z0-9 ]*\s)?PRIVATE KEY( BLOCK)?-----' }
    [pscustomobject]@{ Name = 'Приватный ключ'; Description = 'Приватный ключ PuTTY'; Capture = 0; FileOnly = ''; Pattern = 'PuTTY-Private-Key-File-\d+:' }
    [pscustomobject]@{ Name = 'Ключ AWS'; Description = 'Идентификатор ключа доступа AWS'; Capture = 0; FileOnly = ''; Pattern = '\b(AKIA|ASIA)[0-9A-Z]{16}\b' }
    [pscustomobject]@{ Name = 'Токен GitHub'; Description = 'Токен или fine-grained PAT GitHub'; Capture = 0; FileOnly = ''; Pattern = '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}' }
    [pscustomobject]@{ Name = 'Ключ OpenAI'; Description = 'Ключ sk- (в т.ч. sk-proj-, sk-or-)'; Capture = 0; FileOnly = ''; Pattern = '\bsk-(?!ant-)(proj-|or-)?[A-Za-z0-9_\-]{20,}' }
    [pscustomobject]@{ Name = 'Ключ Google'; Description = 'Ключ API Google (AIza...)'; Capture = 0; FileOnly = ''; Pattern = '\bAIza[0-9A-Za-z_\-]{30,}' }
    [pscustomobject]@{ Name = 'Ключ Anthropic'; Description = 'Ключ sk-ant-api03-...'; Capture = 0; FileOnly = ''; Pattern = '\bsk-ant-api[0-9]{2}-[A-Za-z0-9_\-]{20,}' }
    [pscustomobject]@{ Name = 'Токен Slack'; Description = 'Токен Slack xoxb/xoxp/...'; Capture = 0; FileOnly = ''; Pattern = '\bxox[baprse]-[A-Za-z0-9-]{10,}' }
    [pscustomobject]@{ Name = 'Ключ Stripe'; Description = 'Живой ключ Stripe sk_live_/rk_live_'; Capture = 0; FileOnly = ''; Pattern = '\b(sk|rk)_live_[A-Za-z0-9]{16,}' }
    [pscustomobject]@{ Name = 'Ключ SendGrid'; Description = 'Ключ SendGrid SG.'; Capture = 0; FileOnly = ''; Pattern = '\bSG\.[A-Za-z0-9_\-]{20,}' }
    [pscustomobject]@{ Name = 'Токен Telegram'; Description = 'Токен бота Telegram'; Capture = 0; FileOnly = ''; Pattern = '\b\d{8,10}:[A-Za-z0-9_\-]{35,}' }
    [pscustomobject]@{ Name = 'Токен npm'; Description = 'Токен доступа npm'; Capture = 0; FileOnly = ''; Pattern = '\bnpm_[A-Za-z0-9]{30,}' }
    [pscustomobject]@{ Name = 'Токен Hugging Face'; Description = 'Токен Hugging Face hf_'; Capture = 0; FileOnly = ''; Pattern = '\bhf_[A-Za-z0-9]{30,}' }
    [pscustomobject]@{ Name = 'Ключ Twilio'; Description = 'API-ключ Twilio SK...'; Capture = 0; FileOnly = ''; Pattern = '\bSK[0-9a-fA-F]{32}\b' }
    [pscustomobject]@{ Name = 'JWT'; Description = 'JSON Web Token'; Capture = 0; FileOnly = ''; Pattern = '\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}' }
    [pscustomobject]@{ Name = 'Токен в заголовке'; Description = 'Значение заголовка Authorization: Bearer <токен>'; Capture = 1; FileOnly = ''; Pattern = '(?i)\bbearer\s+([A-Za-z0-9\-._~+/]{16,}=*)' }
    [pscustomobject]@{ Name = 'Строка подключения с учётными данными'; Description = 'URI-схема с логином и паролем (mongodb, postgres, mysql, redis, amqp, mssql)'; Capture = 1; FileOnly = ''; Pattern = '(?i)\b(?:mongodb(?:\+srv)?|postgres(?:ql)?|mysql|mariadb|amqps?|rediss?|mssql)://([^\s:/?#@"'']{1,64}:[^\s:/?#@"'']{1,128})@' }
    [pscustomobject]@{ Name = 'Учётные данные в URL'; Description = 'HTTP(S)-адрес с логином и паролем в authority'; Capture = 1; FileOnly = ''; Pattern = '(?i)\bhttps?://([^\s:/?#@"'']{1,64}:[^\s:/?#@"'']{1,128})@' }
    [pscustomobject]@{ Name = 'Пароль в коде или конфигурации'; Description = 'Литерал, присвоенный паролю (password/passwd/pwd)'; Capture = 1; FileOnly = ''; Pattern = '(?i)\b(?:pass(?:word|wd)?|pwd)\b[''"]?\s*[:=]\s*[''"]?([^\s''",;)\]}]{4,})' }
    [pscustomobject]@{ Name = 'Секрет в коде или конфигурации'; Description = 'Литерал, присвоенный api_key/apikey/secret/token/access_token/client_secret'; Capture = 1; FileOnly = ''; Pattern = '(?i)\b(?:api[-_]?key|secret[-_]?key|access[-_]?key[-_]?id|client[-_]?secret|auth[-_]?token|access[-_]?token|refresh[-_]?token|bearer[-_]?token|session[-_]?secret|private[-_]?key)\b[''"]?\s*[:=]\s*[''"]?([^\s''",;)\]}]{4,})' }
    [pscustomobject]@{ Name = 'Секрет в .env'; Description = 'Непустое присваивание секрета в файле .env'; Capture = 1; FileOnly = '.env'; Pattern = '(?i)^\s*(?:export\s+)?[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD)[A-Z0-9_]*\s*=\s*([^\s#]{4,})' }
)

# Текстовые расширения: бинарные файлы не читаем. .pem/.key/.ppk — там обычно
# лежит приватный ключ, поэтому их тоже читаем.
$textExtensions = @('.ps1', '.psm1', '.psd1', '.ps1xml', '.json', '.yaml', '.yml', '.py', '.js', '.mjs', '.cjs', '.ts',
    '.cmd', '.bat', '.sh', '.ini', '.toml', '.xml', '.config', '.txt', '.md', '.csv', '.html', '.css',
    '.pem', '.key', '.ppk', '.gitignore')
$skipDirs = @('.git', 'node_modules', 'artifacts', '__pycache__', '.venv', 'venv', 'dist', 'bin', 'obj')

$selfPath = ''
try { $selfPath = [IO.Path]::GetFullPath($PSCommandPath) } catch { $selfPath = '' }

$excludes = @($skipDirs) + @($ExcludePath)

$files = Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $full = $_.FullName
        $name = $_.Name
        if ($selfPath -and $full -eq $selfPath) { return $false }   # сам скрипт не сканируется
        if ($excludes | Where-Object { $_ -and $full -like "*\$_*" }) { return $false }
        if ($name -like '.env' -or $name -like '.env.*') { return $true }
        $ext = [IO.Path]::GetExtension($name).ToLowerInvariant()
        return ($textExtensions -contains $ext)
    } |
    Sort-Object FullName

$findings = New-Object System.Collections.Generic.List[object]
$skippedLarge = 0

function Test-IsSecretLiteral {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $v = $Value.Trim()
    if ($v -match $placeholderPattern) { return $false }
    if ($v -match $placeholderSubstring) { return $false }
    if ($v.Length -lt $script:MinSecretLength) { return $false }
    if ($v -match '^[0-9.,\-\s]+$') { return $false }   # числа, порты, даты
    # Учётные данные вида user:pass: имя пользователя секретом не считается,
    # типовой пароль (password/changeme/...) — тоже не считается.
    if ($v -match ':') {
        $secretPart = ($v -split ':')[-1]
        if ($secretPart.Trim() -match $placeholderPattern) { return $false }
    }
    return $true
}

foreach ($f in $files) {
    if ($f.Length -gt 2MB) { $skippedLarge++; continue }
    $rel = $f.FullName.Substring($Path.Length).TrimStart('\', '/').Replace('\', '/')
    $lines = $null
    try { $lines = [IO.File]::ReadAllLines($f.FullName) } catch { continue }
    if ($null -eq $lines) { continue }

    foreach ($rule in $rules) {
        # Правила с FileOnly применяются только к файлам своего типа.
        if ($rule.FileOnly -and $f.Name -notlike "$($rule.FileOnly)*") { continue }
        $rx = [regex]::new($rule.Pattern)
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $m = $rx.Match($lines[$i])
            if (-not $m.Success) { continue }
            if ($rule.Capture -eq 1) {
                if (-not (Test-IsSecretLiteral -Value $m.Groups[1].Value)) { continue }
            }
            $findings.Add([pscustomobject]@{
                File        = $rel
                Line        = ($i + 1)
                Rule        = $rule.Name
                Description = $rule.Description
            })
        }
    }
}

Write-Host "Сканирование: $Path"
if ($skippedLarge -gt 0) { Write-Host "Пропущено файлов больше 2 МБ: $skippedLarge" }
Write-Host "Проверено файлов: $(@($files).Count)"
Write-Host "Найдено: $($findings.Count)"

foreach ($x in ($findings | Sort-Object File, Line, Rule)) {
    # Только место и тип находки. Значение не выводится принципиально.
    Write-Host ("{0}:{1} [{2}] {3}" -f $x.File, $x.Line, $x.Rule, $x.Description) -ForegroundColor Yellow
}

if ($Report) {
    $reportDir = Split-Path -Parent $Report
    if ($reportDir) { New-Item -ItemType Directory -Force -Path $reportDir | Out-Null }
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    # Только File, Line, Rule, Description — значений в отчёте нет по определению.
    $csvLines = @('File,Line,Rule,Description')
    if ($findings.Count -gt 0) {
        $csvLines += foreach ($x in ($findings | Sort-Object File, Line, Rule)) {
            ('{0},{1},"{2}","{3}"' -f $x.File, $x.Line, $x.Rule, $x.Description)
        }
    }
    try {
        [IO.File]::WriteAllLines($Report, [string[]]$csvLines, $utf8NoBom)
    } catch {
        Write-Host "ОШИБКА: не удалось записать отчёт $Report : $($_.Exception.Message)" -ForegroundColor Red
        exit 2
    }
    Write-Host "Отчёт: $Report"
}

if ($findings.Count -gt 0) { exit 1 }
exit 0
