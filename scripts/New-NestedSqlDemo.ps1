#Requires -Version 7.4
<#
.SYNOPSIS
    Creates the approved scratch Windows/Arc/SQL demo using repository steps only.
.DESCRIPTION
    Ensures the Azure Connected Machine Onboarding role at the Arc resource group, mints
    one one-day credential on the existing onboarding application for this build and
    removes it in a finally block. A failure stops the sequence; no automatic deletion,
    repair or retry.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][string]$ParentResourceGroup,
    [Parameter(Mandatory)][string]$ParentVmName,
    [Parameter(Mandatory)][guid]$ParentVmId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][string]$VmRoot,
    [Parameter(Mandatory)][string]$SwitchName,
    [Parameter(Mandatory)][string]$WindowsIsoPath,
    [Parameter(Mandatory)][string]$SqlIsoPath,
    [Parameter(Mandatory)][pscredential]$GuestCredential,
    [Parameter(Mandatory)][string]$GuestAddress,
    [Parameter(Mandatory)][string]$Gateway,
    [Parameter(Mandatory)][string]$DnsServer,
    [Parameter(Mandatory)][guid]$OnboardingApplicationId,
    [string]$SkinPath = ''
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force

if ($SkinPath) {
    $nested = Get-DemoNestedSqlGuestConfig -Skin (Get-DemoSkin -Path $SkinPath)
    if (-not $nested -or $ParentVmName -ne $nested.ParentVmName -or
        $VmName -ne $nested.GuestVmName -or $VmName -ne $nested.ArcMachineName) {
        throw 'Scratch build parent, guest and Arc names must match the enabled private skin.'
    }
}
Initialize-DemoContext $SubscriptionId $TenantId
if (-not $PSCmdlet.ShouldProcess("$VmName on $ParentVmName",'Create approved Windows guest, enroll Arc, install SQL and approved LicenseOnly extension')) { return }
$arcId="/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$VmName"
$sqlId="/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureArcData/sqlServerInstances/$VmName"
$timings=[Collections.Generic.List[object]]::new()
$total=[Diagnostics.Stopwatch]::StartNew()
$guestCredentialForSteps=$GuestCredential
$buildInputs=[pscustomobject]@{
    SubscriptionId=$SubscriptionId;TenantId=$TenantId;ParentResourceGroup=$ParentResourceGroup
    ParentVmName=$ParentVmName;ParentVmId=$ParentVmId;ResourceGroup=$ResourceGroup;Location=$Location
    VmName=$VmName;VmRoot=$VmRoot;SwitchName=$SwitchName;WindowsIsoPath=$WindowsIsoPath;SqlIsoPath=$SqlIsoPath
    GuestAddress=$GuestAddress;Gateway=$Gateway;DnsServer=$DnsServer;OnboardingApplicationId=$OnboardingApplicationId
}
function Invoke-ParentStep {
    param([string]$Name,[hashtable]$Values,[int]$Seconds=1800,[securestring]$OnboardingSecret)
    $stepArguments = @{
        SubscriptionId=$buildInputs.SubscriptionId;TenantId=$buildInputs.TenantId
        ParentResourceGroup=$buildInputs.ParentResourceGroup;ParentVmName=$buildInputs.ParentVmName
        ParentVmId=$buildInputs.ParentVmId;GuestCredential=$guestCredentialForSteps
        Step=$Name;Parameters=$Values;TimeoutSeconds=$Seconds;Confirm=$false
    }
    if ($OnboardingSecret) { $stepArguments.OnboardingSecret = $OnboardingSecret }
    $result=& (Join-Path $PSScriptRoot 'Invoke-NestedSqlDemoStep.ps1') @stepArguments
    $result | Format-List | Out-Host
    $timings.Add([pscustomobject]@{Step=$Name;Seconds=$result.ElapsedSeconds})
    $result
}
$action = {
    param([string]$OnboardingApplicationIdValue,[securestring]$OnboardingSecret)
    $created=Invoke-ParentStep New @{
        VmName=$buildInputs.VmName;VmRoot=$buildInputs.VmRoot;WindowsIsoPath=$buildInputs.WindowsIsoPath
        SwitchName=$buildInputs.SwitchName;Start=$true;Confirm=$false
    }
    if ($created.Output -notmatch 'NESTED_DEMO_VM_ID=([0-9a-fA-F-]{36})') { throw 'New guest GUID missing from create result.' }
    $guestId=[guid]$Matches[1]
    $null=Invoke-ParentStep WaitSetup @{VmName=$buildInputs.VmName;TimeoutSeconds=1200;Confirm=$false} 1500
    $null=Invoke-ParentStep Connect @{
        VmName=$buildInputs.VmName;GuestAddress=$buildInputs.GuestAddress;Gateway=$buildInputs.Gateway;DnsServer=$buildInputs.DnsServer
        SubscriptionId="$($buildInputs.SubscriptionId)";TenantId="$($buildInputs.TenantId)"
        ResourceGroup=$buildInputs.ResourceGroup;Location=$buildInputs.Location;ArcName=$buildInputs.VmName
        OnboardingApplicationId=$OnboardingApplicationIdValue;Confirm=$false
    } -OnboardingSecret $OnboardingSecret
    $machine=Invoke-AzRest -Method Get -Url "https://management.azure.com${arcId}?api-version=2024-07-10"
    if ($machine.id -ine $arcId -or $machine.properties.status -ne 'Connected' -or
        $machine.tags.ArcSQLServerExtensionDeployment -ne 'Disabled') { throw 'Arc Connected and suppression tag not verified before SQL.' }
    $agentVmId=$machine.properties.vmId
    $null=Invoke-ParentStep Engine @{VmName=$buildInputs.VmName;SqlIsoPath=$buildInputs.SqlIsoPath;ExpectedArcResourceId=$arcId;Confirm=$false} 2400
    $null=Invoke-ParentStep EnableExtension @{VmName=$buildInputs.VmName;Confirm=$false}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    & (Join-Path $PSScriptRoot 'Install-ArcSqlDemoExtension.ps1') -SubscriptionId $buildInputs.SubscriptionId -TenantId $buildInputs.TenantId `
        -ResourceGroup $buildInputs.ResourceGroup -ArcName $buildInputs.VmName -Location $buildInputs.Location -Confirm:$false | Out-Host
    $timings.Add([pscustomobject]@{Step='InstallExtension';Seconds=[math]::Round($clock.Elapsed.TotalSeconds,1)})
    $clock.Restart()
    Wait-Until -TimeoutSeconds 1200 -IntervalSeconds 20 -Message 'Azure SQL instance and database inventory' -Condition {
        try {
            $sql=Invoke-AzRest -Method Get -Url "https://management.azure.com${sqlId}?api-version=2026-01-01"
            $databases=Invoke-AzRest -Method Get -Url "https://management.azure.com${sqlId}/databases?api-version=2026-01-01"
            return ($sql.properties.status -eq 'Connected' -and @($databases.value).Count -gt 0)
        } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $false }
            throw
        }
    } | Out-Null
    $inventory=& (Join-Path $PSScriptRoot 'Test-ArcSqlDemoInventory.ps1') -SubscriptionId $buildInputs.SubscriptionId -TenantId $buildInputs.TenantId `
        -ResourceGroup $buildInputs.ResourceGroup -ArcName $buildInputs.VmName -SqlResourceName $buildInputs.VmName
    $inventory | Format-List | Out-Host
    $timings.Add([pscustomobject]@{Step='Inventory';Seconds=[math]::Round($clock.Elapsed.TotalSeconds,1)})
    $null=Invoke-ParentStep Test @{VmName=$buildInputs.VmName;ExpectedArcResourceId=$arcId;TimeoutSeconds=300;RequireSqlExtension=$true}
    [pscustomobject]@{
        VmName=$buildInputs.VmName;VmId=$guestId;ArcMachineId=$arcId;ArcAgentVmId=$agentVmId;SqlInstanceId=$sqlId
        TotalSeconds=[math]::Round($total.Elapsed.TotalSeconds,1);Steps=$timings.ToArray();Inventory=$inventory
    }
}
$credentialName = "nested-$VmName-$([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N').Substring(0,8))"
Initialize-DemoOnboardingIdentity -ApplicationId $OnboardingApplicationId -ResourceGroup $ResourceGroup -DisplayName $credentialName -Action $action
