#Requires -Version 5.1
<#
.SYNOPSIS
    Allows only the separately approved Arc SQL extension on a nested guest.
.DESCRIPTION
    Run on the parent. Verifies existing SYSTEM CONNECT SQL, then removes only
    the SQL extension block entry. Does not grant SQL rights or install extensions.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][pscredential]$GuestCredential
)
$ErrorActionPreference = 'Stop'
if (-not $PSCmdlet.ShouldProcess($VmName, 'Allow the approved Arc SQL extension without manual SQL grants')) { return }
Invoke-Command -VMName $VmName -Credential $GuestCredential -ScriptBlock {
    $ErrorActionPreference = 'Stop'
    $connection = [Data.SqlClient.SqlConnection]::new('Server=localhost;Database=master;Integrated Security=True;Connect Timeout=15')
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = "EXECUTE AS LOGIN = 'NT AUTHORITY\SYSTEM'; SELECT HAS_PERMS_BY_NAME(NULL,NULL,'CONNECT SQL'); REVERT;"
        if ($command.ExecuteScalar() -ne 1) { throw 'Existing SYSTEM CONNECT SQL required; no grant attempted' }
    } finally { $connection.Dispose() }
    $agent = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
    $block = & $agent config get extensions.blocklist --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Extension block list read failed' }
    $entries = @($block.Data.Trim().Trim([char[]]'[]') -split ',' | ForEach-Object Trim)
    if ($entries -contains 'Microsoft.AzureData/WindowsAgent.SqlServer') {
        & $agent config set extensions.blocklist 'Microsoft.AzureData/WindowsAgent.SqlServer' --remove --json
        if ($LASTEXITCODE -ne 0) { throw 'SQL-only unblock failed' }
        $block = & $agent config get extensions.blocklist --json | ConvertFrom-Json
    }
    $entries = @($block.Data.Trim().Trim([char[]]'[]') -split ',' | ForEach-Object Trim)
    if ($LASTEXITCODE -ne 0 -or $entries -contains 'Microsoft.AzureData/WindowsAgent.SqlServer') { throw 'SQL block removal not verified' }
    $block
}
