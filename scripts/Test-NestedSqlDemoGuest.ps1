#Requires -Version 5.1
<#
.SYNOPSIS
    Checks Windows Setup, Arc identity and a real SQL query in the nested demo guest.
.DESCRIPTION
    Run on the Hyper-V parent with the retained credential. Read-only; does not
    install, enroll, restart, repair, or prove Azure SQL-extension inventory.
    SetupOnly returns setup/process diagnostics, not full readiness.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][pscredential]$GuestCredential,
    [Parameter(Mandatory)][string]$ExpectedArcResourceId,
    [ValidateRange(1, 900)][int]$TimeoutSeconds = 300,
    [switch]$RequireSqlExtension,
    [switch]$SetupOnly
)
$ErrorActionPreference = 'Stop'
Invoke-Command -VMName $VmName -Credential $GuestCredential -ArgumentList $ExpectedArcResourceId,$TimeoutSeconds,([bool]$RequireSqlExtension),([bool]$SetupOnly) -ScriptBlock {
    param($ArcId,$WaitSeconds,$CheckExtension,$OnlySetup)
    $ErrorActionPreference = 'Stop'
    $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
    $image = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'
    $setupComplete = $image.ImageState -eq 'IMAGE_STATE_COMPLETE' -and
        $null -ne $setup.OOBEInProgress -and $setup.OOBEInProgress -eq 0 -and
        $null -ne $setup.SystemSetupInProgress -and $setup.SystemSetupInProgress -eq 0
    if ($OnlySetup) {
        [pscustomobject]@{
            ComputerName=$env:COMPUTERNAME;SetupComplete=$setupComplete;ImageState=$image.ImageState
            OOBE=$setup.OOBEInProgress;SystemSetup=$setup.SystemSetupInProgress
            SetupProcesses=@(Get-Process | Where-Object ProcessName -EQ setup | Select-Object Id,ProcessName,Path,StartTime)
            SqlServicePresent=@(Get-Service | Where-Object Name -EQ MSSQLSERVER).Count -eq 1
        }
        return
    }
    $agent = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
    $deadline = [datetime]::UtcNow.AddSeconds($WaitSeconds)
    do {
        $arc = & $agent show --json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Arc state read failed' }
        if ($arc.resourceId -ne $ArcId) { throw 'Unexpected Arc identity; no reconnect attempted' }
        if ($arc.status -eq 'Connected') { break }
        if ($arc.status -ne 'Disconnected') { throw "Arc state unknown: $($arc.status)" }
        if ([datetime]::UtcNow -ge $deadline) { throw 'Arc heartbeat remains disconnected after wake' }
        Start-Sleep 10
    } while ($true)
    $arcConnected = $arc.status -eq 'Connected' -and $arc.resourceId -eq $ArcId
    $block = & $agent config get extensions.blocklist --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Extension block list read failed' }
    $service = Get-Service MSSQLSERVER
    $service.WaitForStatus('Running', [timespan]::FromSeconds($WaitSeconds))
    $connection = [Data.SqlClient.SqlConnection]::new('Server=localhost;Database=master;Integrated Security=True;Connect Timeout=15')
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 15
        $command.CommandText = "SELECT CONVERT(nvarchar(128),SERVERPROPERTY('Edition')) + ' / ' + CONVERT(nvarchar(128),SERVERPROPERTY('ProductVersion'))"
        $sqlVersion = $command.ExecuteScalar()
        $extensionLogin=$false
        if ($CheckExtension) {
            $command.CommandText = "SELECT COUNT(*) FROM sys.server_principals WHERE name=N'NT SERVICE\SqlServerExtension'"
            $extensionLogin=$command.ExecuteScalar() -eq 1
        }
    } finally { $connection.Dispose() }
    $sqlRunning = (Get-Service MSSQLSERVER).Status -eq 'Running'
    $extensionService=$null
    if ($CheckExtension) {
        (Get-Service SqlServerExtension).WaitForStatus('Running',[timespan]::FromSeconds($WaitSeconds))
        $extensionService=Get-CimInstance Win32_Service -Filter "Name='SqlServerExtension'"
        if ($extensionService.State -ne 'Running' -or $extensionService.StartName -ine 'NT Service\SqlServerExtension' -or -not $extensionLogin) {
            throw 'Least-privilege SQL extension service account or managed SQL login not verified.'
        }
    }
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        SetupComplete = $setupComplete
        ArcConnected = $arcConnected
        ArcResourceId = $arc.resourceId
        ArcAgentVmId = $arc.vmId
        ExtensionBlockList = $block.Data
        SqlRunning = $sqlRunning
        SqlVersion = $sqlVersion
        SqlExtensionAccount = $extensionService.StartName
        SqlExtensionState = $extensionService.State
        SqlExtensionLoginVerified = $extensionLogin
        SqlExtensionInventoryVerified = $false
        CheckedAtUtc = [datetime]::UtcNow.ToString('o')
    }
    if (-not $setupComplete -or -not $arcConnected -or -not $sqlRunning -or
        $sqlVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($sqlVersion)) {
        throw 'Nested demo Windows/Arc/SQL checks did not all pass.'
    }
}
