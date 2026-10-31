#Requires -Version 5.1
<#
.SYNOPSIS
    Removes one exact nested demo guest and only its private VM directory.
.DESCRIPTION
    Run on the parent. Shared storage, switch, NAT and other guests are retained.
    Preflight performs all ownership checks without stopping or deleting.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][guid]$VmId,
    [Parameter(Mandatory)][string]$VmRoot,
    [switch]$Preflight
)
$ErrorActionPreference='Stop'
$root = [IO.Path]::GetFullPath($VmRoot).TrimEnd('\')
if ($VmId -eq [guid]::Empty -or $root -ine "D:\NestedSQL\VMs\$VmName" -or $VmName -eq 'NestedSqlGuest') {
    throw 'Only an explicitly identified new demo guest directory may be removed.'
}
$vms=@(Get-VM)
$vm = $vms | Where-Object Name -EQ $VmName
if (-not $vm -and -not (Test-Path -LiteralPath $root) -and -not @($vms | Where-Object VMId -EQ $VmId).Count) {
    [pscustomobject]@{Name=$VmName;Removed=$true;AlreadyAbsent=$true;FreeBytesAfter=([IO.DriveInfo]::new('D:\')).AvailableFreeSpace}
    return
}
if (-not $vm) { throw 'Guest missing but its folder or GUID remains; inspect partial state.' }
if ($vm.VMId -ne $VmId -or [IO.Path]::GetFullPath($vm.Path).TrimEnd('\') -notin @($root,"$root\$VmName")) {
    throw 'Guest GUID or configuration root differs.'
}
$expected = @("$root\$VmName-OS.vhdx","$root\$VmName-SQLData.vhdx")
$disks = @(Get-VMHardDiskDrive -VM $vm | Select-Object -ExpandProperty Path)
if ($disks.Count -ne 2 -or @($expected | Where-Object { $_ -notin $disks }).Count) { throw 'Guest disk paths differ.' }
$others = @(Get-VM | Where-Object VMId -NE $VmId)
foreach ($other in $others) {
    if ([IO.Path]::GetFullPath($other.Path).StartsWith("$root\",[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFullPath($other.Path).TrimEnd('\') -ieq $root) { throw 'Another VM uses this root.' }
    foreach ($disk in @(Get-VMHardDiskDrive -VM $other)) {
        if ($disk.Path -and [IO.Path]::GetFullPath($disk.Path).StartsWith("$root\",[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Another VM uses a disk in this root.'
        }
    }
}
$items = @(Get-Item -LiteralPath $root) + @(Get-ChildItem -LiteralPath $root -Recurse -Force)
if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Reparse point in guest root.' }
$actualVhds = @($items | Where-Object { -not $_.PSIsContainer -and $_.Extension -in @('.vhd','.vhdx','.avhd','.avhdx') } | Select-Object -ExpandProperty FullName)
if ($actualVhds.Count -ne 2 -or @($expected | Where-Object { $_ -notin $actualVhds }).Count) { throw 'Unexpected disks or checkpoints in root.' }
$before = ([IO.DriveInfo]::new('D:\')).AvailableFreeSpace
if ($Preflight) {
    [pscustomobject]@{Name=$VmName;VmId=$vm.VMId;Root=$root;Disks=$expected;FreeBytesBefore=$before}
    return
}
if (-not $PSCmdlet.ShouldProcess("$VmName / $VmId / $root",'Gracefully stop, remove VM and delete only its own directory')) { return }
if ([string]$vm.State -eq 'Running') {
    $job=Stop-VM -VM $vm -AsJob -Confirm:$false
    if (-not (Wait-Job -Job $job -Timeout 180)) { throw 'Graceful stop still pending; no deletion or hard stop.' }
    Receive-Job -Job $job -ErrorAction Stop | Out-Null
    Remove-Job -Job $job
} elseif ([string]$vm.State -ne 'Off') { throw "Cannot remove guest in state $($vm.State)." }
if ([string](Get-VM -Id $VmId).State -ne 'Off') { throw 'Guest did not gracefully stop; no deletion.' }
Remove-VM -VM $vm -Force -Confirm:$false
Remove-Item -LiteralPath $root -Recurse -Force -Confirm:$false
if (@(Get-VM | Where-Object { $_.VMId -eq $VmId -or $_.Name -eq $VmName }).Count -or (Test-Path -LiteralPath $root)) {
    throw 'Guest or directory remains after removal.'
}
$after = ([IO.DriveInfo]::new('D:\')).AvailableFreeSpace
if ($after -le $before) { throw 'Guest removed but D: free-space increase was not observed.' }
[pscustomobject]@{Name=$VmName;Removed=$true;FreeBytesBefore=$before;FreeBytesAfter=$after;ReclaimedBytes=($after-$before)}
