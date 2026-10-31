#Requires -Version 7.4
<#
.SYNOPSIS
    Runs a repository nested-demo step on its explicitly selected Hyper-V parent.
.DESCRIPTION
    Sends the credential only as a managed Run Command protected parameter.
    No automatic mutation retry. Completed temporary commands from this runner
    may be removed to stay within the VM's managed-command limit.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][string]$ParentResourceGroup,
    [Parameter(Mandatory)][string]$ParentVmName,
    [Parameter(Mandatory)][guid]$ParentVmId,
    [Parameter(Mandatory)][ValidateSet('New','WaitSetup','Connect','Engine','EnableExtension','Test','Remove')][string]$Step,
    [Parameter(Mandatory)][hashtable]$Parameters,
    [pscredential]$GuestCredential,
    [ValidateRange(60,7200)][int]$TimeoutSeconds = 1800
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Initialize-DemoContext $SubscriptionId $TenantId
$id = "/subscriptions/$SubscriptionId/resourceGroups/$ParentResourceGroup/providers/Microsoft.Compute/virtualMachines/$ParentVmName"
$parent = Invoke-AzRest -Method Get -Url "https://management.azure.com${id}?api-version=2024-07-01"
if ($parent.id -ine $id -or $parent.properties.vmId -ne "$ParentVmId") { throw 'Parent VM identity differs.' }
$files = @{
    New='New-NestedSqlDemoGuest.ps1'; WaitSetup='Wait-NestedSqlDemoSetup.ps1'
    Connect='Connect-NestedSqlDemoGuest.ps1'; Engine='Install-NestedSqlDemoEngine.ps1'
    EnableExtension='Enable-NestedSqlDemoExtension.ps1'; Test='Test-NestedSqlDemoGuest.ps1'
    Remove='Remove-NestedSqlDemoGuest.ps1'
}
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $files[$Step]))
if ($Step -eq 'New') {
    $module = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\NestedSqlDemo.psm1'))
    $module = $module -replace 'Export-ModuleMember -Function New-NestedSqlAnswerXml',''
    $source = $source.Replace("Import-Module (Join-Path `$PSScriptRoot 'lib\NestedSqlDemo.psm1') -Force",$module)
}
$json = $Parameters | ConvertTo-Json -Depth 10 -Compress
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
$credentialMode = if ($Step -eq 'New') { 'Password' } elseif ($Step -eq 'Remove') { 'None' } else { 'Credential' }
if ($credentialMode -ne 'None' -and -not $GuestCredential) { throw 'This step requires the retained guest credential.' }
$userName = if ($GuestCredential) { $GuestCredential.UserName.Replace("'","''") } else { '' }
$scriptText = @"
param([string]`$GuestPassword)
`$ErrorActionPreference='Stop'
`$values=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encoded')))
`$arguments=@{}
`$values.PSObject.Properties | ForEach-Object { `$arguments[`$_.Name]=`$_.Value }
if ('$Step' -ne 'Test') { `$arguments.Confirm=`$false }
`$secure=`$null
try {
    if ('$credentialMode' -ne 'None') {
        `$secure=ConvertTo-SecureString `$GuestPassword -AsPlainText -Force
        `$GuestPassword=`$null
        if ('$credentialMode' -eq 'Password') { `$arguments.AdministratorPassword=`$secure }
        else { `$arguments.GuestCredential=[pscredential]::new('$userName',`$secure) }
    }
    `$step={
$source
    }
    & `$step @arguments | ConvertTo-Json -Depth 10 -Compress
    if ('$Step' -eq 'New') { Write-Output ('NESTED_DEMO_VM_ID=' + (Get-VM -Name `$arguments.VmName).VMId) }
} finally { if (`$secure) { `$secure.Dispose() } }
"@
if (-not $PSCmdlet.ShouldProcess($id,"Run repository nested demo step $Step")) { return }
$collection = "https://management.azure.com${id}/runCommands?api-version=2024-07-01"
$commands = Invoke-AzRest -Method Get -Url $collection
if (@($commands.value).Count -ge 25) {
    $freed = $false
    foreach ($candidate in @($commands.value | Where-Object { $_.name -like 'nestedDemo20*' -or $_.name -like 'handsOn20*' } | Sort-Object name)) {
        $url = "https://management.azure.com$($candidate.id)?api-version=2024-07-01"
        $old = Invoke-AzRest -Method Get -Url ($url + '&$expand=instanceView')
        if ($old.properties.instanceView.executionState -in @('Succeeded','Failed','Canceled','TimedOut')) {
            $null = Invoke-AzRest -Method Delete -Url $url
            $freed = $true
            break
        }
    }
    if (-not $freed) { throw 'Managed-command slots full; no completed command owned by this runner to remove.' }
}
$name = 'nestedDemo' + [datetime]::UtcNow.ToString('yyyyMMddHHmmssfff')
$url = "https://management.azure.com${id}/runCommands/${name}?api-version=2024-07-01"
$body = @{
    location=$parent.location
    properties=@{source=@{script=$scriptText};timeoutInSeconds=$TimeoutSeconds;asyncExecution=$true}
}
if ($GuestCredential) {
    $body.properties.protectedParameters = @(@{name='GuestPassword';value=$GuestCredential.GetNetworkCredential().Password})
}
$clock = [Diagnostics.Stopwatch]::StartNew()
try { $null = Invoke-AzRest -Method Put -Url $url -Body $body }
finally { $body=$null }
Write-Verbose "Managed command: $name"
do {
    Start-Sleep 10
    $command = Invoke-AzRest -Method Get -Url ($url + '&$expand=instanceView')
    $state = $command.properties.instanceView
    if ($state.executionState -in @('Succeeded','Failed','Canceled','TimedOut')) {
        $result = [pscustomobject]@{
            Step=$Step;CommandId=$command.id;ElapsedSeconds=[math]::Round($clock.Elapsed.TotalSeconds,1)
            ExecutionState=$state.executionState;ExitCode=$state.exitCode;Output=$state.output;Error=$state.error
        }
        $result
        if ($state.executionState -ne 'Succeeded' -or $state.exitCode -ne 0) { throw "Repository step $Step failed: $($state.error)" }
        return
    }
} while ($clock.Elapsed.TotalSeconds -lt ($TimeoutSeconds + 300))
throw "Observation timed out for $name; inspect this command, do not resubmit it."
