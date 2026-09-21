<#
.SYNOPSIS
  Инструмент-страж виртуальных дисков оркестратора.
  Любой диск, созданный инструментами сессии, получает корневую метку
  .devstation-created и запись в манифест. Удаление возможно ТОЛЬКО для
  дисков, у которых метка+манифест+размер сходятся; диски пользователя
  (без метки) удалить нельзя даже с -Force.

.USAGE
  pwsh vmdisk.ps1 new-vmdisk -Name test1 -SizeGB 40 -Purpose 'vm test' [-KeepMounted]
  pwsh vmdisk.ps1 list
  pwsh vmdisk.ps1 inspect -Path E:\Hyper-V\test1.vhdx
  pwsh vmdisk.ps1 mark -Path E:\Hyper-V\old.vhdx -Purpose 'legacy test'
  pwsh vmdisk.ps1 remove -Path E:\Hyper-V\test1.vhdx [-Force]
#>
param(
    [ValidateSet('new-vmdisk', 'list', 'inspect', 'mark', 'remove')]
    [string]$Action = 'list',
    [string]$Name = '',
    [int]$SizeGB = 40,
    [string]$Purpose = '',
    [string]$Path = '',
    [string]$RootDir = 'E:\Hyper-V',
    [switch]$KeepMounted,
    [switch]$Force
)
# UTF-8 console default (no krakozyabry)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'
$MarkerName = '.devstation-created'
$ManifestName = '.devstation-disks.json'
$manifestPath = Join-Path $RootDir $ManifestName

function Get-Manifest {
    if (Test-Path $manifestPath) {
        try { return @(Get-Content $manifestPath -Raw | ConvertFrom-Json) } catch { return @() }
    }
    return @()
}

function Save-Manifest([Array]$data) {
    $json = $data | ConvertTo-Json -Depth 5
    Set-Content -Path $manifestPath -Value $json -Encoding utf8
}

function New-DiskId {
    return 'dsk_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
}

function Get-Entry([string]$vhdxPath, [Array]$manifest) {
    foreach ($e in $manifest) {
        if ($e.Path -ieq $vhdxPath) { return $e }
    }
    return $null
}

function Get-MountedRoot([string]$vhdxPath) {
    $vhd = Get-VHD -Path $vhdxPath -ErrorAction SilentlyContinue
    if (-not $vhd) { return $null }
    $part = Get-Partition -DiskNumber $vhd.DiskNumber -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter }
    if ($part) { return $part.DriveLetter + ':' }
    return $null
}

function Test-AttachedToVm([string]$vhdxPath) {
    $err = $null
    try { [void](Mount-VHD -Path $vhdxPath -ReadOnly -ErrorAction Stop) } catch { $err = $_.Exception.Message }
    if (-not $err) { Dismount-VHD -Path $vhdxPath -ErrorAction SilentlyContinue; return $false }
    return $true
}

function Read-Marker([string]$vhdxPath) {
    # Возвращает JSON метки если её можно прочитать, иначе $null.
    if (Test-AttachedToVm $vhdxPath) { return $null }
    $vhd = Mount-VHD -Path $vhdxPath -ReadOnly -PassThru -ErrorAction Stop
    try {
        $part = Get-Partition -DiskNumber $vhd.DiskNumber -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }
        if (-not $part) { return $null }
        $root = $part.DriveLetter + ':\'
        $m = Join-Path $root $MarkerName
        if (Test-Path $m) {
            try { return Get-Content $m -Raw | ConvertFrom-Json } catch { return $null }
        }
        return $null
    } finally {
        Dismount-VHD -Path $vhdxPath -ErrorAction SilentlyContinue
    }
}

function Out-DiskRow($entry, $vhdxPath, $sizeGB, $attached, $markerOk) {
    $e = if ($entry) { $entry } else { $null }
    [pscustomobject]@{
        Name      = if ($e) { $e.Name } else { [IO.Path]::GetFileNameWithoutExtension($vhdxPath) }
        SizeGB    = [math]::Round($sizeGB, 1)
        Purpose   = if ($e) { $e.Purpose } else { '(не размечен)' }
        Marker    = if ($markerOk) { 'OK' } elseif ($entry) { 'нет' } else { 'нет' }
        Attached  = $attached
        DiskId    = if ($e) { $e.DiskId } else { '-' }
        Created   = if ($e) { $e.CreatedAt } else { '-' }
    }
}

switch ($Action) {

    'new-vmdisk' {
        if (-not $Name) { throw "new-vmdisk требует -Name" }
        if (-not $Purpose) { throw "new-vmdisk требует -Purpose" }
        New-Item -ItemType Directory -Path $RootDir -Force | Out-Null
        $vhdx = Join-Path $RootDir ($Name + '.vhdx')
        if (Test-Path $vhdx) { throw "Уже существует: $vhdx" }
        $diskId = New-DiskId

        "Создаю динамический VHD: $vhdx ($SizeGB ГБ)"
        New-VHD -Path $vhdx -SizeBytes ([int64]$SizeGB * 1GB) -Dynamic | Out-Null
        $vhd = Mount-VHD -Path $vhdx -PassThru
        try {
            Initialize-Disk -Number $vhd.Number -PartitionStyle MBR -ErrorAction Stop
            $p = New-Partition -DiskNumber $vhd.Number -UseMaximumSize -AssignDriveLetter
            Format-Volume -DriveLetter $p.DriveLetter -FileSystem NTFS -NewFileSystemLabel ('DEVSTATION-' + $Name.Substring(0, [Math]::Min(10, $Name.Length)) ) -Confirm:$false | Out-Null
            $root = $p.DriveLetter + ':\'
            $marker = @{
                tool         = 'vmdisk.ps1'
                createdBy    = 'opencode'
                createdAt    = (Get-Date).ToUniversalTime().ToString('o')
                purpose      = $Purpose
                diskId       = $diskId
                sizeGB       = $SizeGB
                guardVersion = 1
            } | ConvertTo-Json
            Set-Content -Path (Join-Path $root $MarkerName) -Value $marker -Encoding utf8
            "Метка $MarkerName размещена на корне $root"
        } finally {
            if (-not $KeepMounted) { Dismount-VHD -Path $vhdx -ErrorAction SilentlyContinue }
        }

        $manifest = Get-Manifest
        $manifest += [pscustomobject]@{
            Name      = $Name
            Path      = $vhdx
            SizeGB    = $SizeGB
            Purpose   = $Purpose
            DiskId    = $diskId
            CreatedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        Save-Manifest $manifest
        "Записано в манифест: $manifestPath"
    }

    'list' {
        Get-ChildItem -Path $RootDir -Filter '*.vhdx' | ForEach-Object {
            $entry = Get-Entry $_.FullName (Get-Manifest)
            $attached = Test-AttachedToVm $_.FullName
            $marker = if ($entry) { $null -ne (Read-Marker $_.FullName) } else { $false }
            Out-DiskRow $entry $_.FullName ($_.Length / 1GB) $attached $marker
        } | Format-Table -AutoSize | Out-String
    }

    'inspect' {
        if (-not $Path) { throw "inspect требует -Path" }
        if (-not (Test-Path $Path)) { throw "Нет файла: $Path" }
        $entry = Get-Entry $Path (Get-Manifest)
        $attached = Test-AttachedToVm $Path
        $marker = Read-Marker $Path
        "Файл        : $Path"
        "Размер      : $([math]::Round((Get-Item $Path).Length / 1GB, 2)) ГБ"
        "Прикреплён  : $attached"
        "К манифесте : $(if ($entry) { $entry.DiskId } else { 'НЕТ (диск пользователя)' })"
        "Метка       : $(if ($marker) { "OK diskId=$($marker.diskId) purpose=$($marker.purpose)" } else { 'НЕТ (диск пользователя)' })"
    }

    'mark' {
        if (-not $Path) { throw "mark требует -Path" }
        if (-not (Test-Path $Path)) { throw "Нет файла: $Path" }
        if (-not $Purpose) { throw "mark требует -Purpose" }
        $attached = Test-AttachedToVm $Path
        if ($attached) { throw "Диск примонтирован к работающей VM — схемы нет. Остановите VM и повторите." }
        $existing = Read-Marker $Path
        if ($existing) { throw "Диск уже размечен (diskId=$($existing.diskId)). remove использует метку, mark не нужен." }
        $diskId = New-DiskId
        $vhd = Mount-VHD -Path $Path -PassThru
        try {
            $part = Get-Partition -DiskNumber $vhd.Number | Where-Object { $_.DriveLetter }
            if (-not $part) { throw "В VHD нет смонтированного тома с буквой — разметка не выполнена." }
            $root = $part.DriveLetter + ':\'
            $marker = @{
                tool         = 'vmdisk.ps1'
                createdBy    = 'opencode'
                createdAt    = (Get-Date).ToUniversalTime().ToString('o')
                purpose      = $Purpose
                diskId       = $diskId
                sizeGB       = [math]::Round((Get-Item $Path).Length / 1GB, 1)
                guardVersion = 1
            } | ConvertTo-Json
            Set-Content -Path (Join-Path $root $MarkerName) -Value $marker -Encoding utf8
            "Метка размещена на корне $root"
        } finally {
            Dismount-VHD -Path $Path -ErrorAction SilentlyContinue
        }
        $manifest = Get-Manifest
        $manifest += [pscustomobject]@{
            Name      = [IO.Path]::GetFileNameWithoutExtension($Path)
            Path      = $Path
            SizeGB    = [math]::Round((Get-Item $Path).Length / 1GB, 1)
            Purpose   = $Purpose
            DiskId    = $diskId
            CreatedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        Save-Manifest $manifest
        "Записано в манифест: $manifestPath"
    }

    'remove' {
        if (-not $Path) { throw "remove требует -Path" }
        if (-not (Test-Path $Path)) { throw "Нет файла: $Path" }
        $abs = [IO.Path]::GetFullPath($Path)
        $entry = Get-Entry $abs (Get-Manifest)
        if (-not $entry) {
            throw "ОТКАЗ: диск $abs отсутствует в манифесте и без метки .devstation-created — это диск пользователя. Удаление запрещено."
        }
        $marker = Read-Marker $abs
        $sizeGB = (Get-VHD -Path $abs).Size / 1GB
        $sizeOk = [math]::Abs($sizeGB - $entry.SizeGB) -lt [math]::Max(1, $entry.SizeGB * 0.3)
        if (-not $marker) {
            throw "ОТКАЗ: диск отмечен в манифесте, но корневой метки нет (реальный размер $([math]::Round($sizeGB,1)) ГБ). Вероятно поверх записали данные — удаление запрещено."
        }
        if ($marker.diskId -ne $entry.DiskId) {
            throw "ОТКАЗ: diskId метки ($($marker.diskId)) != манифест ($($entry.DiskId)). Отказываюсь удалять."
        }
        if (-not $sizeOk) {
            throw "ОТКАЗ: размер ($([math]::Round($sizeGB,1)) ГБ) не совпадает с записью ($($entry.SizeGB) ГБ). Удаление запрещено."
        }
        if (Test-AttachedToVm $abs) {
            throw "ОТКАЗ: диск примонтирован к работе — остановите VM."
        }
        if (-not $Force) {
            "Подтвердите удаление: $abs ($([math]::Round($sizeGB,1)) ГБ, purpose='$($entry.Purpose)')"
            $ans = Read-Host 'Удалить? [y/N]'
            if ($ans -notin @('y', 'Y', 'д', 'Д')) { 'Отменено.'; exit 0 }
        }
        Remove-Item $abs -Force
        $manifest = Get-Manifest | Where-Object { $_.Path -ine $abs }
        Save-Manifest $manifest
        "Удалён: $abs"
    }
}