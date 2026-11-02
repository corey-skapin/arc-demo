#Requires -Version 5.1
<#
.SYNOPSIS
    Guest side of Prepare-NestedSqlParent.ps1: actions on the nested SQL Hyper-V parent.
.DESCRIPTION
    Runs inside the parent as SYSTEM (Windows PowerShell 5.1) through Run Command. Every
    action is idempotent, takes its settings as base64 JSON and prints one ARC_GUEST_RESULT=
    JSON line plus ARC_DEMO_OK. Inspect only reads. The role reboot is issued from Azure by
    the operator script, never from here.

      Inspect  data volume, Hyper-V role/service/hypervisor, switch/vNIC/NAT, media files
      Volume   initialise the blank Azure data disk as the data volume (default D:, NestedSQL);
               the empty virtual DVD-ROM that a size without a temp disk puts on D: moves to Z:
      HyperV   install the Hyper-V role with management tools (a restart is needed afterwards)
      Network  internal switch, host address and NAT for the nested guest
#>
param(
    [Parameter(Mandatory)][ValidateSet('Inspect', 'Volume', 'HyperV', 'Network')][string]$Action,
    [Parameter(Mandatory)][string]$SettingsBase64
)
$ErrorActionPreference = 'Stop'

function ConvertTo-IPv4Range {
    param([string]$Cidr)
    $parts = $Cidr.Split('/')
    $bytes = [System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
    [Array]::Reverse($bytes)
    $address = [int64][BitConverter]::ToUInt32($bytes, 0)
    $length = [int]$parts[1]
    $size = [int64][Math]::Pow(2, 32 - $length)
    $start = $address - ($address % $size)
    [pscustomobject]@{ Start = $start; End = $start + $size - 1 }
}

function Test-IPv4Overlap {
    param($First, $Second)
    $First.Start -le $Second.End -and $Second.Start -le $First.End
}

function Get-DataVolumeState {
    param($Settings)
    $letter = [string]$Settings.driveLetter
    $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    if (-not $volume) { return [pscustomobject]@{ present = $false } }
    # A size without a temp disk (Dsv5) leaves D: to the empty virtual DVD-ROM; that is not a data volume.
    if ([string]$volume.DriveType -eq 'CD-ROM' -and -not [int64]$volume.Size) { return [pscustomobject]@{ present = $false; opticalDrive = $true } }
    $lun = $null
    $partition = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
    if ($partition) {
        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction SilentlyContinue
        if ($disk -and [string]$disk.Location -match 'LUN (\d+)$') { $lun = [int]$Matches[1] }
    }
    [pscustomobject]@{
        present = $true; fileSystem = [string]$volume.FileSystem; label = [string]$volume.FileSystemLabel
        sizeBytes = [int64]$volume.Size; freeBytes = [int64]$volume.SizeRemaining; lun = $lun
        vmsFolder = [bool](Test-Path -LiteralPath (Join-Path $Settings.root 'VMs'))
        mediaFolder = [bool](Test-Path -LiteralPath (Join-Path $Settings.root 'Media'))
    }
}

function Get-HyperVState {
    $feature = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
    $service = Get-Service -Name vmms -ErrorAction SilentlyContinue
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    $hostOk = $false
    $running = 0
    if (Get-Command Get-VMHost -ErrorAction SilentlyContinue) {
        try { $null = Get-VMHost -ErrorAction Stop; $hostOk = $true } catch { $hostOk = $false }
    }
    if ($hostOk -and (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        $running = @(Get-VM -ErrorAction SilentlyContinue | Where-Object { [string]$_.State -ne 'Off' }).Count
    }
    [pscustomobject]@{
        installed = [bool]($feature -and $feature.Installed)
        vmms = $(if ($service) { [string]$service.Status } else { 'Missing' })
        hypervisorPresent = [bool]$computer.HypervisorPresent
        vmHostOk = $hostOk
        runningGuests = $running
    }
}

function Get-NetworkState {
    param($Settings)
    $switch = $null
    if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) { $switch = Get-VMSwitch -Name $Settings.switchName -ErrorAction SilentlyContinue }
    $alias = 'vEthernet (' + $Settings.switchName + ')'
    $addresses = @(Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } | ForEach-Object { $_.IPAddress + '/' + $_.PrefixLength })
    $nats = @(Get-NetNat -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ name = [string]$_.Name; prefix = [string]$_.InternalIPInterfaceAddressPrefix } })
    [pscustomobject]@{
        switchExists = [bool]$switch; switchType = $(if ($switch) { [string]$switch.SwitchType } else { '' })
        addresses = $addresses; nats = $nats
    }
}

function Get-MediaState {
    param($Settings)
    foreach ($item in @($Settings.media)) {
        $path = Join-Path (Join-Path $Settings.root 'Media') $item.fileName
        $present = Test-Path -LiteralPath $path
        $bytes = 0
        $hashMatches = $null
        if ($present) {
            $bytes = (Get-Item -LiteralPath $path).Length
            if ($Settings.hashMedia -and $bytes -eq [int64]$item.bytes) {
                $hashMatches = ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq [string]$item.sha256)
            }
        }
        [pscustomobject]@{ id = [string]$item.id; path = $path; present = [bool]$present; bytes = [int64]$bytes; sha256Matches = $hashMatches }
    }
}

function Move-EmptyOpticalDrive {
    param([string]$Letter)
    $from = "${Letter}:"
    $drives = @(Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = '$from' AND DriveType = 5")
    if ($drives.Count -ne 1 -or $drives[0].Capacity) { throw "Drive ${from} is not one empty optical drive; refusing to change it." }
    $taken = @(Get-CimInstance -ClassName Win32_Volume | Where-Object { $_.DriveLetter } | ForEach-Object { ([string]$_.DriveLetter).Substring(0, 1).ToUpperInvariant() })
    $spare = @('Z', 'Y', 'X', 'W') | Where-Object { $_ -notin $taken } | Select-Object -First 1
    if (-not $spare) { throw "No spare drive letter (Z to W) is free for the optical drive on ${from}." }
    Set-CimInstance -InputObject $drives[0] -Property @{ DriveLetter = "${spare}:" }
    if (@(Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = '$from'").Count) { throw "Drive ${from} is still taken after moving the optical drive to ${spare}:." }
    $spare
}

function Initialize-DataVolume {
    param($Settings)
    $letter = [string]$Settings.driveLetter
    $state = Get-DataVolumeState $Settings
    $movedTo = $null
    if ($state.opticalDrive) {
        $movedTo = Move-EmptyOpticalDrive $letter
        $state = Get-DataVolumeState $Settings
    }
    if ($state.present) {
        if ($state.label -ne [string]$Settings.label -or $state.fileSystem -ne 'NTFS') {
            throw "Drive ${letter}: is already used by another volume; refusing to change it."
        }
        $created = $false
        foreach ($folder in 'VMs', 'Media') {
            $path = Join-Path $Settings.root $folder
            if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null; $created = $true }
        }
        return [pscustomobject]@{ changed = $created }
    }
    $candidates = @(Get-Disk | Where-Object {
        -not $_.IsBoot -and -not $_.IsSystem -and [string]$_.Location -match ('LUN ' + [int]$Settings.lun + '$') -and $_.Size -eq [int64]$Settings.sizeBytes })
    if ($candidates.Count -ne 1) { throw "Expected exactly one data disk at Azure LUN $($Settings.lun) of the declared size, found $($candidates.Count)." }
    $disk = $candidates[0]
    $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object { [string]$_.Type -ne 'Reserved' })
    if ($partitions.Count -gt 0 -or ([string]$disk.PartitionStyle -ne 'RAW' -and [string]$disk.PartitionStyle -ne 'GPT')) {
        throw 'Refusing to initialise a data disk that already has partitions.'
    }
    if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
    if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
    if ([string]$disk.PartitionStyle -eq 'RAW') { Initialize-Disk -Number $disk.Number -PartitionStyle GPT }
    New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $letter | Out-Null
    Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel ([string]$Settings.label) -AllocationUnitSize 65536 -Confirm:$false | Out-Null
    foreach ($folder in 'VMs', 'Media') { New-Item -ItemType Directory -Path (Join-Path $Settings.root $folder) -Force | Out-Null }
    [pscustomobject]@{ changed = $true; opticalDriveMovedTo = $movedTo }
}

function Install-HyperVRole {
    $feature = Get-WindowsFeature -Name Hyper-V
    if ($feature.Installed) { return [pscustomobject]@{ changed = $false; restartNeeded = $false } }
    $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
    if (-not $result.Success) { throw "Hyper-V role installation failed ($($result.ExitCode))." }
    [pscustomobject]@{ changed = $true; restartNeeded = ([string]$result.RestartNeeded -ne 'No') }
}

function Initialize-NestedNetwork {
    param($Settings)
    if (-not (Get-Command New-VMSwitch -ErrorAction SilentlyContinue)) { throw 'Hyper-V management tools are missing; install the role and restart first.' }
    $prefix = [string]$Settings.prefix
    $guest = ConvertTo-IPv4Range $prefix
    foreach ($azure in @($Settings.azurePrefixes)) {
        if (Test-IPv4Overlap $guest (ConvertTo-IPv4Range ([string]$azure))) { throw "Guest prefix $prefix overlaps the Azure address space $azure." }
    }
    $alias = 'vEthernet (' + $Settings.switchName + ')'
    foreach ($route in @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.DestinationPrefix -ne '0.0.0.0/0' -and $_.InterfaceAlias -ne $alias -and $_.DestinationPrefix -notmatch '^(127\.|224\.|255\.255\.255\.255|169\.254\.)' })) {
        if (Test-IPv4Overlap $guest (ConvertTo-IPv4Range ([string]$route.DestinationPrefix))) {
            throw "Guest prefix $prefix overlaps the existing route $($route.DestinationPrefix) on $($route.InterfaceAlias)."
        }
    }
    $nats = @(Get-NetNat -ErrorAction SilentlyContinue)
    $sameName = @($nats | Where-Object { $_.Name -eq $Settings.natName })
    $samePrefix = @($nats | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $prefix })
    if (($sameName.Count -gt 0 -and $samePrefix.Count -ne 1) -or $samePrefix.Count -gt 1) { throw 'An existing NAT conflicts with the nested subnet; refusing to change it.' }
    if ($samePrefix.Count -eq 1 -and $samePrefix[0].Name -ne $Settings.natName) { throw 'Another NAT already claims the nested subnet.' }
    $changed = $false
    $switch = Get-VMSwitch -Name $Settings.switchName -ErrorAction SilentlyContinue
    if ($switch -and [string]$switch.SwitchType -ne 'Internal') { throw "Switch $($Settings.switchName) exists with type $($switch.SwitchType), not Internal." }
    if (-not $switch) { New-VMSwitch -Name $Settings.switchName -SwitchType Internal | Out-Null; $changed = $true }
    $adapter = $null
    for ($attempt = 0; $attempt -lt 10 -and -not $adapter; $attempt++) {
        $adapter = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
        if (-not $adapter) { Start-Sleep -Seconds 2 }
    }
    if (-not $adapter) { throw "Adapter $alias did not appear after creating the switch." }
    $length = [int]$prefix.Split('/')[1]
    $addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' })
    if ($addresses.Count -gt 1 -or ($addresses.Count -eq 1 -and ($addresses[0].IPAddress -ne $Settings.gateway -or [int]$addresses[0].PrefixLength -ne $length))) {
        throw 'The nested switch adapter has conflicting IPv4 configuration; refusing to change it.'
    }
    if ($addresses.Count -eq 0) {
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Settings.gateway -PrefixLength $length -AddressFamily IPv4 | Out-Null
        $changed = $true
    }
    if ($sameName.Count -eq 0) { New-NetNat -Name $Settings.natName -InternalIPInterfaceAddressPrefix $prefix | Out-Null; $changed = $true }
    [pscustomobject]@{ changed = $changed }
}

$settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($SettingsBase64)) | ConvertFrom-Json
switch ($Action) {
    'Inspect' {
        $result = [pscustomobject]@{
            volume = Get-DataVolumeState $settings; hyperV = Get-HyperVState
            network = Get-NetworkState $settings; media = @(Get-MediaState $settings)
        }
    }
    'Volume' { $result = Initialize-DataVolume $settings }
    'HyperV' { $result = Install-HyperVRole }
    'Network' { $result = Initialize-NestedNetwork $settings }
}
'ARC_GUEST_RESULT=' + ($result | ConvertTo-Json -Compress -Depth 6)
'ARC_DEMO_OK'
