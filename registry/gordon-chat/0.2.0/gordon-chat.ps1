param(
    [string]$Ask,
    [switch]$Sessions,
    [string]$SessionId,
    [string]$Model,
    [switch]$ResetSession,
    [string]$Pipe = 'dockerAgent',
    [int]$TimeoutSec = 300,
    [switch]$ApproveTools,
    [switch]$Json
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$pipeName = "\\.\pipe\$Pipe"
$stateFile = 'C:\Scripts\tools\state\gordon-chat.json'
$agentPath = $null

function Get-PipeAgent {
    $req = Get-Http -Method GET -Path '/api/agents'
    if ($req.Status -ne 200) { throw "agents: HTTP $($req.Status)" }
    $list = $req.Body | ConvertFrom-Json
    if (-not $list -or $list.Count -eq 0) { throw 'no agents available on pipe' }
    $list[0].name
}

function Get-Http {
    param([string]$Method, [string]$Path, [string]$Body, [int]$Timeout = 60)
    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
    try {
        $client.Connect(15000)
        $sr = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8)
        if ($null -eq $Body) { $Body = '' }
        $req = "$Method $Path HTTP/1.1`r`nHost: localhost`r`n"
        if ($Body.Length -gt 0) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $req += "Content-Type: application/json`r`nContent-Length: $($bytes.Length)`r`n"
        }
        $req += "Connection: close`r`n`r`n"
        if ($Body.Length -gt 0) { $req += $Body }
        $sw = [System.IO.StreamWriter]::new($client)
        $sw.NewLine = "`n"
        $sw.Write($req)
        $sw.Flush()

        $sb = [System.Text.StringBuilder]::new()
        $deadline = (Get-Date).AddSeconds($Timeout)
        while (-not $sr.EndOfStream) {
            if ((Get-Date) -gt $deadline) { throw "response read timeout after $Timeout s" }
            $line = $sr.ReadLine()
            if ($null -eq $line) { break }
            [void]$sb.AppendLine($line)
        }
        $raw = $sb.ToString()
        $headersEnd = $raw.IndexOf("`r`n`r`n")
        if ($headersEnd -lt 0) { throw "malformed response: $($raw.Substring(0,[Math]::Min(200,$raw.Length)))" }
        $head = $raw.Substring(0, $headersEnd)
        $body = $raw.Substring($headersEnd + 4)
        $statusLine = $head.Split("`r`n")[0]
        $status = [int]($statusLine.Split(' ')[1])
        [pscustomobject]@{ Status = $status; StatusLine = $statusLine; Body = $body }
    } finally {
        $client.Dispose()
    }
}

function Send-Ask {
    param([string]$Sid, [string]$Prompt)
    $jProm = @($Prompt | ConvertTo-Json -Compress)
    if ($Model) {
        $payload = '{"messages":[{"role":"user","content":' + $jProm + '}],"model":' + ($Model | ConvertTo-Json -Compress) + '}'
    } else {
        $payload = '{"messages":[{"role":"user","content":' + $jProm + '}]}'
    }
    $path = "/api/sessions/$Sid/agent/$agentPath"
    $raw = Get-Http -Method POST -Path $path -Body $payload -Timeout $TimeoutSec
    if ($raw.Status -ne 200) { throw "agent run: HTTP $($raw.Status) $($raw.StatusLine) body=$($raw.Body)" }
    $text = ''
    $usedTool = $false
    $modelUsed = ''
    $ended = $false
    $needsApproval = $false
    $err = ''
    foreach ($line in $raw.Body -split "`n") {
        if ($line -notmatch '^data: ') { continue }
        $ev = $null
        try { $ev = ($line -replace '^data: ', '') | ConvertFrom-Json } catch { continue }
        if (-not $ev) { continue }
        switch ($ev.type) {
            'agent_choice'  { if ($ev.content) { $text += $ev.content } }
            'tool_call'     { $usedTool = $true }
            'tool_call_confirmation' { $needsApproval = $true }
            'agent_info'    { if ($ev.model) { $modelUsed = $ev.model } }
            'error'         { if ($ev.error) { $err = $ev.error } }
            'stream_stopped' { $ended = $true }
        }
    }
    [pscustomobject]@{ Text = $text; UsedTool = $usedTool; Model = $modelUsed; Ended = $ended; NeedsApproval = $needsApproval; Error = $err; SessionId = $Sid }
}

function Save-State {
    param([string]$Sid)
    @{ session_id = $Sid; updated_at = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
}

if ($ResetSession) {
    if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }
    'session reset'
    exit 0
}

$running = Get-CimInstance Win32_Process -Filter "Name='docker-agent.exe'" -ErrorAction SilentlyContinue
if (-not $running) { throw 'docker-agent.exe (Docker Desktop Gordon server) is not running' }

if (-not (Test-Path -LiteralPath "\\.\pipe\$Pipe")) { throw "pipe $pipeName not found" }

if ($Sessions) {
    $r = Get-Http -Method GET -Path '/api/sessions'
    if ($r.Status -ne 200) { throw "sessions: HTTP $($r.Status)" }
    $rows = $r.Body | ConvertFrom-Json
    foreach ($s in ($rows | Sort-Object created_at -Descending)) {
        $n = @($s.messages).Count
        "{0}  {1}  msgs={2}" -f $s.id, $s.title, $n
    }
    exit 0
}

$agentPath = Get-PipeAgent

if ($Ask) {
    $sid = $SessionId
    if (-not $sid) {
        if (Test-Path -LiteralPath $stateFile) {
            $st = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            if ($st.session_id) { $sid = $st.session_id }
        }
    }
    if (-not $sid) {
        $created = Get-Http -Method POST -Path '/api/sessions' -Body '{}'
        if ($created.Status -notin 200,201) { throw "create session: HTTP $($created.Status)" }
        $sj = $created.Body | ConvertFrom-Json
        $sid = $sj.id
        Save-State $sid
    }
    if ($ApproveTools) {
        Get-Http -Method POST -Path "/api/sessions/$sid/tools/toggle" -Timeout 20 | Out-Null
    }
    $res = Send-Ask -Sid $sid -Prompt $Ask
    Save-State $sid
    if ($Json) {
        if ($res.Error) {
            @{ status = 'error'; error = $res.Error; model = $res.Model; ended = $res.Ended; session = $sid } | ConvertTo-Json -Compress
        }
        elseif ($res.NeedsApproval) {
            @{ status = 'needs_approval'; session = $sid; model = $res.Model } | ConvertTo-Json -Compress
        }
        elseif ($res.Text) {
            @{ status = 'ok'; text = $res.Text; model = $res.Model; session = $sid } | ConvertTo-Json -Compress
        }
        else {
            @{ status = 'no_text'; model = $res.Model; ended = $res.Ended; error = $res.Error; session = $sid } | ConvertTo-Json -Compress
        }
        exit 0
    }
    if ($res.NeedsApproval) {
        if ($ApproveTools) { "[tools auto-approved]" }
        else { "[Gordon asked for tool approval - resend with -ApproveTools or approve in Docker Desktop chat]" }
    }
    if ($res.Error) {
        "session=$sid model=$($res.Model) ended=$($res.Ended) [error: $($res.Error)]"
    }
    elseif (-not $res.Text -and -not $res.UsedTool) {
        "session=$sid model=$($res.Model) ended=$($res.Ended) [no text returned]"
    } else {
        "session=$sid model=$($res.Model)"
        $res.Text
        if ($res.UsedTool) { "[Gordon requested a tool - see session in Docker Desktop chat]" }
    }
    exit 0
}

"usage: gordon-chat.ps1 -Ask '<question>' [-Model <provider/model>] [-SessionId <id>] [-ResetSession] [-Json] | -Sessions"
exit 1