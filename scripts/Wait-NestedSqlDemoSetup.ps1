#Requires -Version 5.1
<#
.SYNOPSIS
    Waits read-only for a fresh guest's unattended setup, then removes its cached answer.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][pscredential]$GuestCredential,
    [ValidateRange(60,3600)][int]$TimeoutSeconds=1200
)
$ErrorActionPreference='Stop'
$clock=[Diagnostics.Stopwatch]::StartNew()
$last='Not yet observed'
do {
    try {
        $state=Invoke-Command -VMName $VmName -Credential $GuestCredential -ScriptBlock {
            $ErrorActionPreference='Stop'
            $setup=Get-ItemProperty 'HKLM:\SYSTEM\Setup'
            [pscustomobject]@{
                ImageState=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
                OOBE=$setup.OOBEInProgress;SystemSetup=$setup.SystemSetupInProgress;ComputerName=$env:COMPUTERNAME
            }
        }
        $last=$state | ConvertTo-Json -Compress
        if ($state.ImageState -eq 'IMAGE_STATE_COMPLETE' -and $null -ne $state.OOBE -and $state.OOBE -eq 0 -and
            $null -ne $state.SystemSetup -and $state.SystemSetup -eq 0) {
            if ($PSCmdlet.ShouldProcess($VmName,'Remove completed Windows Setup cached unattended password file')) {
                Invoke-Command -VMName $VmName -Credential $GuestCredential -ScriptBlock {
                    $path='C:\Windows\Panther\unattend.xml'
                    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
                    if (Test-Path -LiteralPath $path) { throw 'Cached answer removal failed.' }
                }
            }
            $state
            return
        }
    } catch {
        if ($_.FullyQualifiedErrorId -notmatch 'PSSessionStateBroken|CreateRemoteRunspaceFailed|InvalidCredential|VMNotRunning') { throw }
        $last=$_.Exception.Message
        Write-Verbose "Setup not yet accessible: $last"
    }
    Start-Sleep 15
} while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
throw "Windows Setup did not complete within $TimeoutSeconds seconds. Last observation: $last"
