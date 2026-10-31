#Requires -Version 5.1
<#
.SYNOPSIS
    Applies an approved Windows Server image to a new Hyper-V demo guest.
.DESCRIPTION
    Run on the Hyper-V parent. Uses existing media and storage; never replaces
    an existing guest or disk. Leaves partial new artifacts on failure.
    SQL and Arc enrollment are subsequent steps, not part of Windows Setup.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][string]$WindowsIsoPath,
    [Parameter(Mandatory)][string]$VmRoot,
    [Parameter(Mandatory)][string]$SwitchName,
    [Parameter(Mandatory)][securestring]$AdministratorPassword,
    [ValidateRange(1, 100)][int]$ImageIndex = 2,
    [guid]$ExistingVmId = [guid]::Empty,
    [switch]$Start
)
$ErrorActionPreference = 'Stop'
if ($ExistingVmId -ne [guid]::Empty) {
    $vm = Get-VM -Id $ExistingVmId
    $expectedRoot = [IO.Path]::GetFullPath($VmRoot).TrimEnd('\')
    if ($vm.Name -ne $VmName -or
        [IO.Path]::GetFullPath($vm.Path).TrimEnd('\') -notin @($expectedRoot, "$expectedRoot\$VmName")) {
        throw 'Retained guest identity or root differs.'
    }
    $expectedDisks = @((Join-Path $VmRoot "$VmName-OS.vhdx"), (Join-Path $VmRoot "$VmName-SQLData.vhdx"))
    $disks = @(Get-VMHardDiskDrive -VM $vm | Select-Object -ExpandProperty Path)
    if ($disks.Count -ne 2 -or @($expectedDisks | Where-Object { $_ -notin $disks }).Count) {
        throw 'Retained guest disks differ.'
    }
    if ($Start -and [string]$vm.State -eq 'Off' -and $PSCmdlet.ShouldProcess($VmName, 'Start retained demo guest without rebuilding')) {
        Start-VM -VM $vm
    }
    Get-VM -Id $ExistingVmId | Select-Object Name,VMId,State,Path
    return
}
Import-Module (Join-Path $PSScriptRoot 'lib\NestedSqlDemo.psm1') -Force
$answer = New-NestedSqlAnswerXml -ComputerName $VmName -AdministratorPassword $AdministratorPassword
if (@(Get-VM | Where-Object Name -EQ $VmName).Count -or (Test-Path -LiteralPath $VmRoot)) {
    throw 'The new guest name/root already exists. Inspect it instead of overwriting.'
}
$null = Get-VMSwitch -Name $SwitchName
$null = Get-Item -LiteralPath $WindowsIsoPath
$volume=Get-Volume -DriveLetter ([IO.Path]::GetPathRoot($VmRoot).Substring(0,1))
if ($volume.SizeRemaining -lt 24GB) { throw 'At least 24 GiB free space is required for this dynamic-disk demo build.' }
if (-not $PSCmdlet.ShouldProcess($VmName, 'Create a new Windows guest from existing approved media')) {
    $answer = $null
    return
}
$osPath = Join-Path $VmRoot "$VmName-OS.vhdx"
$dataPath = Join-Path $VmRoot "$VmName-SQLData.vhdx"
$isoMounted = $false
$vhdMounted = $false
try {
    New-Item -ItemType Directory -Path $VmRoot | Out-Null
    $iso = Mount-DiskImage -ImagePath $WindowsIsoPath -PassThru
    $isoMounted = $true
    $mediaLetter = ($iso | Get-Volume).DriveLetter
    New-VHD -Path $osPath -SizeBytes 64GB -Dynamic | Out-Null
    New-VHD -Path $dataPath -SizeBytes 32GB -Dynamic | Out-Null
    $vm = New-VM -Name $VmName -Generation 2 -Path $VmRoot -MemoryStartupBytes 8GB -VHDPath $osPath -SwitchName $SwitchName
    Set-VM -VM $vm -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -CheckpointType Disabled
    Set-VMProcessor -VM $vm -Count 2
    Add-VMHardDiskDrive -VM $vm -Path $dataPath
    $disk = Mount-VHD -Path $osPath -PassThru
    $vhdMounted = $true
    Initialize-Disk -Number $disk.DiskNumber -PartitionStyle GPT
    $efi = New-Partition -DiskNumber $disk.DiskNumber -Size 260MB -GptType '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}' -AssignDriveLetter
    Format-Volume -Partition $efi -FileSystem FAT32 -Confirm:$false | Out-Null
    New-Partition -DiskNumber $disk.DiskNumber -Size 16MB -GptType '{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}' | Out-Null
    $os = New-Partition -DiskNumber $disk.DiskNumber -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $os -FileSystem NTFS -Confirm:$false | Out-Null
    $osRoot = "$($os.DriveLetter):\"
    & dism.exe /Apply-Image "/ImageFile:${mediaLetter}:\sources\install.wim" "/Index:$ImageIndex" "/ApplyDir:$osRoot" /CheckIntegrity
    if ($LASTEXITCODE -ne 0) { throw "DISM failed: $LASTEXITCODE" }
    $windows = Join-Path $osRoot 'Windows'
    $panther = New-Item -ItemType Directory -Path (Join-Path $windows 'Panther') -Force
    $answerPath = Join-Path $panther.FullName 'unattend.xml'
    $null = New-Item -ItemType File -Path $answerPath
    & icacls.exe $answerPath /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Answer-file ACL failed' }
    [IO.File]::WriteAllText($answerPath, $answer, [Text.UTF8Encoding]::new($false))
    $answer = $null
    & (Join-Path $windows 'System32\bcdboot.exe') $windows /s "$($efi.DriveLetter):\" /f UEFI
    if ($LASTEXITCODE -ne 0) { throw "Image-matched BCDBoot failed: $LASTEXITCODE" }
    Dismount-VHD -Path $osPath
    $vhdMounted = $false
    $boot = Get-VMHardDiskDrive -VM $vm | Where-Object Path -EQ $osPath
    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -FirstBootDevice $boot
    if ($Start) { Start-VM -VM $vm }
    Get-VM -Id $vm.VMId | Select-Object Name,VMId,State,Path
} finally {
    $answer = $null
    if ($vhdMounted) { Dismount-VHD -Path $osPath }
    if ($isoMounted) { Dismount-DiskImage -ImagePath $WindowsIsoPath }
}
