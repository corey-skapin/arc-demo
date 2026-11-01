#Requires -Version 7.4
<#
.SYNOPSIS
    Creates the approved scratch Windows/Arc/SQL demo using repository steps only.
.DESCRIPTION
    Mints one onboarding credential for this build and removes it in a finally
    block. A failure stops the sequence; no automatic deletion, repair or retry.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The one-build Graph secret is immediately converted in memory before protected delivery.')]
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

function Invoke-NestedSqlGraphRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [hashtable]$Body
    )
    $arguments = @('rest','--method',$Method,'--url',$Url,'--output','json','--only-show-errors')
    $bodyPath = $null
    if ($PSBoundParameters.ContainsKey('Body')) {
        $bodyPath = Join-Path ([IO.Path]::GetTempPath()) "nested-sql-graph-$([guid]::NewGuid().ToString('N')).json"
        [IO.File]::WriteAllText($bodyPath,($Body | ConvertTo-Json -Depth 5 -Compress),[Text.UTF8Encoding]::new($false))
        $arguments += @('--headers','Content-Type=application/json','--body',"@$bodyPath")
    }
    try {
        $response = Invoke-DemoAz -Arguments $arguments
        if ($null -eq $response -or @($response).Count -eq 0) { return $null }
        if ($response -isnot [string] -and $response -isnot [array]) { return $response }
        $text = @($response) -join "`n"
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $text | ConvertFrom-Json
    } finally {
        if ($bodyPath -and (Test-Path -LiteralPath $bodyPath)) {
            Remove-Item -LiteralPath $bodyPath -Force
        }
    }
}

function Get-NestedSqlApplication {
    param([Parameter(Mandatory)][string]$Url,[Parameter(Mandatory)][guid]$ApplicationId)
    $application = Invoke-NestedSqlGraphRequest -Method GET -Url $Url
    if (-not $application -or [guid]$application.appId -ne $ApplicationId) {
        throw 'Graph returned a different onboarding application.'
    }
    $application
}

function Get-NestedSqlCredentialKeyIdSet {
    param([Parameter(Mandatory)]$Application)
    @($Application.passwordCredentials | ForEach-Object { "$($_.keyId)".ToLowerInvariant() } | Sort-Object -Unique)
}

function Test-NestedSqlCredentialSet {
    param([string[]]$Expected,[string[]]$Actual)
    (@($Expected | Sort-Object -Unique) -join '|') -ceq (@($Actual | Sort-Object -Unique) -join '|')
}

function Invoke-NestedSqlCredentialBuild {
    param(
        [Parameter(Mandatory)][guid]$ApplicationId,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $appRoute = "applications%28appId%3D%27$ApplicationId%27%29"
    $appUrl = "https://graph.microsoft.com/v1.0/$appRoute`?%24select=id,appId,passwordCredentials"
    $application = Get-NestedSqlApplication -Url $appUrl -ApplicationId $ApplicationId
    $baselineIds = @(Get-NestedSqlCredentialKeyIdSet -Application $application)
    $createdKeyId = $null
    $secret = $null
    $actionFailure = $null
    $cleanupFailure = $null
    $result = $null
    try {
        $expiry = [datetime]::UtcNow.AddDays(1)
        $credential = Invoke-NestedSqlGraphRequest -Method POST -Url "https://graph.microsoft.com/v1.0/$appRoute/addPassword" -Body @{
            passwordCredential=@{
                displayName=$DisplayName
                endDateTime=$expiry.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            }
        }
        if (-not $credential.secretText -or -not $credential.keyId) {
            throw 'Graph did not return the new credential secret and key ID.'
        }
        $createdKeyId = "$($credential.keyId)".ToLowerInvariant()
        if ($createdKeyId -in $baselineIds) { throw 'Graph returned a pre-existing credential key ID.' }
        $secretText = [string]$credential.secretText
        $secret = ConvertTo-SecureString $secretText -AsPlainText -Force
        $secretText = $null
        $credential = $null

        $afterMint = Get-NestedSqlApplication -Url $appUrl -ApplicationId $ApplicationId
        $expectedMinted = @($baselineIds + $createdKeyId | Sort-Object -Unique)
        if (-not (Test-NestedSqlCredentialSet -Expected $expectedMinted -Actual @(Get-NestedSqlCredentialKeyIdSet $afterMint))) {
            throw 'Onboarding application credential IDs changed unexpectedly after minting.'
        }
        $afterMint = $null
        try { $result = & $Action $secret }
        catch { $actionFailure = $_ }
    } catch {
        if (-not $actionFailure) { $actionFailure = $_ }
    } finally {
        if ($createdKeyId) {
            try {
                $null = Invoke-NestedSqlGraphRequest -Method POST -Url "https://graph.microsoft.com/v1.0/$appRoute/removePassword" -Body @{
                    keyId=$createdKeyId
                }
                $deadline = [datetime]::UtcNow.AddSeconds(90)
                do {
                    $remaining = Get-NestedSqlApplication -Url $appUrl -ApplicationId $ApplicationId
                    $remainingIds = @(Get-NestedSqlCredentialKeyIdSet $remaining)
                    if (@($baselineIds | Where-Object { $_ -notin $remainingIds }).Count -gt 0 -or
                        @($remainingIds | Where-Object { $_ -ne $createdKeyId -and $_ -notin $baselineIds }).Count -gt 0) {
                        throw 'Onboarding application credential IDs changed beyond the minted credential.'
                    }
                    if ($createdKeyId -notin $remainingIds) {
                        if (-not (Test-NestedSqlCredentialSet -Expected $baselineIds -Actual $remainingIds)) {
                            throw 'Existing onboarding credential IDs were not preserved exactly.'
                        }
                        break
                    }
                    if ([datetime]::UtcNow -ge $deadline) { throw 'Graph still reports the one-build credential after removal.' }
                    Start-Sleep -Seconds 5
                } while ($true)
            } catch {
                $cleanupFailure = $_
            }
        }
        if ($secret) { $secret.Dispose() }
        $secretText = $null
        $credential = $null
    }
    if ($cleanupFailure) {
        $message = "One-build onboarding credential cleanup/verification failed; it expires at $($expiry.ToString('u')). $($cleanupFailure.Exception.Message)"
        if ($actionFailure) { $message += " Build failure: $($actionFailure.Exception.Message)" }
        throw $message
    }
    if ($actionFailure) { throw $actionFailure }
    $result
}

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
    param([securestring]$OnboardingSecret)
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
        OnboardingApplicationId="$($buildInputs.OnboardingApplicationId)";Confirm=$false
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
Invoke-NestedSqlCredentialBuild -ApplicationId $OnboardingApplicationId -DisplayName $credentialName -Action $action
