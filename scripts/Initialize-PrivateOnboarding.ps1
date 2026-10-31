#Requires -Version 7.4
<#
.SYNOPSIS
    Previews or initializes the separately approved private onboarding credential.
.DESCRIPTION
    One-shot initialization, not rotation/recovery. No parent start, guest
    enrollment, fleet operation, public vault change or original-key deletion.
    All persisted evidence is nonsecret. An incomplete journal blocks replay.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$ResultDirectory,
    [ValidateSet('Preview', 'Initialize')][string]$Action = 'Preview'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\PrivateOnboarding.psm1') -Force
$plan = Get-DemoPrivatePlan -Path $PlanPath -SubscriptionId $SubscriptionId -TenantId $TenantId
$root = [IO.Path]::GetFullPath($ResultDirectory)
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot))
if (-not (Test-Path -LiteralPath $root -PathType Container) -or $root -eq $repo -or
    ($root.StartsWith("$repo\", [StringComparison]::OrdinalIgnoreCase) -and
    $root -ne (Join-Path $repo '.local') -and -not $root.StartsWith((Join-Path $repo '.local\'), [StringComparison]::OrdinalIgnoreCase))) {
    throw 'ResultDirectory must already exist privately outside tracked source (or under .local).'
}
$journalPath = Join-Path $root 'private-onboarding.json'
$sourceHashes = [ordered]@{}
foreach ($relative in @('Initialize-PrivateOnboarding.ps1', 'lib\Common.psm1', 'lib\PrivateOnboarding.psm1',
    'guest\Set-PrivateVaultSecret.ps1', '..\bicep\modules\private-onboarding-vault.bicep', '..\bicep\modules\private-secret-placeholder.bicep')) {
    $sourceHashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $relative) -Algorithm SHA256).Hash
}
$previous = if (Test-Path -LiteralPath $journalPath) { Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20 }
if ($previous -and ($previous.state -ne 'initialized' -or $previous.planHash -ne (Get-FileHash -LiteralPath $PlanPath -Algorithm SHA256).Hash -or
    $previous.sourceHashes -isnot [System.Collections.IDictionary] -or
    @($sourceHashes.Keys | Where-Object { $previous.sourceHashes[$_] -ne $sourceHashes[$_] }).Count)) {
    throw 'Incomplete/different initialization journal exists. Inspect exact prior operations; no replay, reset or automatic rotation.'
}
$principal = Test-Prerequisites -SubscriptionId $SubscriptionId -TenantId $TenantId -Providers @('Microsoft.Network', 'Microsoft.KeyVault', 'Microsoft.ManagedIdentity')
if ($principal -ne $plan.deployerPrincipalId) { throw 'Authenticated deployer differs from the frozen plan.' }
$prefix = $plan.namePrefix
$infra = "rg-$prefix-infra"
$vaultName = ($plan.vaultResourceId -split '/')[-1]
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$infra"
$secretId = "$($plan.vaultResourceId)/secrets/arc-onboarding-client-secret"
$endpointId = "$scope/providers/Microsoft.Network/privateEndpoints/pe-$prefix-onboarding-kv"
$zoneId = "$scope/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
$linkId = "$zoneId/virtualNetworkLinks/link-$prefix-onboarding-vnet"
$groupId = "$endpointId/privateDnsZoneGroups/default"
$writer = @($plan.parents | Where-Object resourceId -eq $plan.writerParentResourceId)[0]
$officer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
$writerName = Get-DemoRoleAssignmentName -Scope $secretId -PrincipalId $writer.principalId -RoleId $officer
$writerId = "$secretId/providers/Microsoft.Authorization/roleAssignments/$writerName"
$vault = Get-DemoArmResource -ResourceId $plan.vaultResourceId -ApiVersion '2024-11-01'
if ($vault.id -ne $plan.vaultResourceId -or $vault.location -ne $plan.location -or
    $vault.properties.publicNetworkAccess -ne 'Disabled' -or $vault.properties.enableRbacAuthorization -ne $true) {
    throw 'Canonical vault identity/private RBAC mode differs; never open or rewrite the vault.'
}
$deployments = @(Invoke-DemoAz -Arguments @('deployment', 'sub', 'list', '-o', 'json') | ConvertFrom-Json |
    Where-Object { $_.properties.provisioningState -eq 'Succeeded' -and $_.properties.outputs.arcResourceGroup.value -eq "rg-$prefix" -and $_.properties.outputs.keyVaultName.value } |
    Sort-Object { $_.properties.timestamp } -Descending)
if (-not $deployments.Count -or $deployments[0].properties.outputs.keyVaultName.value -ne $vaultName) {
    throw 'Selected vault is not the latest successful exact-estate deployment output; refuse ambiguity.'
}
$vnet = Get-DemoArmResource -ResourceId $plan.vnetResourceId -ApiVersion '2024-05-01'
$subnet = Get-DemoArmResource -ResourceId $plan.subnetResourceId -ApiVersion '2024-05-01'
if ($vnet.id -ne $plan.vnetResourceId -or $vnet.location -ne $plan.location -or @($vnet.properties.dhcpOptions.dnsServers | Where-Object { $_ }).Count -or
    $subnet.id -ne $plan.subnetResourceId -or $subnet.properties.privateEndpointNetworkPolicies -ne 'Disabled' -or @($subnet.properties.delegations | Where-Object { $_ }).Count -or
    $subnet.properties.addressPrefix -ne $plan.subnetAddressPrefix) { throw 'VNet/subnet/DNS/policy/delegation drift; no network workaround.' }
$cidr = $subnet.properties.addressPrefix -split '/'
$networkAddress = $null
if (-not [Net.IPAddress]::TryParse($cidr[0], [ref]$networkAddress) -or $networkAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    [int]$cidr[1] -lt 1 -or [int]$cidr[1] -gt 29) { throw 'Unsupported/malformed endpoint subnet prefix.' }
$capacity = [math]::Pow(2, 32 - [int]$cidr[1]) - 5
if (@($subnet.properties.ipConfigurations).Count -ge $capacity) { throw 'No verified subnet allocation headroom for the single endpoint.' }
foreach ($parent in $plan.parents) {
    $vm = Get-DemoArmResource -ResourceId $parent.resourceId -ApiVersion '2024-11-01'
    if ($vm.id -ne $parent.resourceId -or $vm.properties.vmId -ne $parent.vmId -or $vm.identity.principalId -ne $parent.principalId -or
        $vm.properties.storageProfile.osDisk.osType -ne 'Windows' -or $vm.location -ne $plan.location -or $vm.properties.provisioningState -ne 'Succeeded' -or
        $vm.properties.osProfile.computerName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$') {
        throw 'Pinned parent VM/OS/system identity drift; no replacement or new grant.'
    }
    if ($parent.resourceId -eq $writer.resourceId) {
        $view = Invoke-DemoAz -Arguments @('vm', 'get-instance-view', '--ids', $parent.resourceId, '-o', 'json') | ConvertFrom-Json
        if ('PowerState/running' -notin @($view.instanceView.statuses.code)) { throw 'Private writer parent is not running. Credential setup never starts it.' }
    }
    $parent.location = $vm.location
    $parent.computerName = $vm.properties.osProfile.computerName
}
$existingEndpoint = Get-DemoArmResource -ResourceId $endpointId -ApiVersion '2024-05-01' -AllowNotFound
$existingZone = Get-DemoArmResource -ResourceId $zoneId -ApiVersion '2024-06-01' -AllowNotFound
foreach ($resource in @($existingEndpoint, $existingZone) | Where-Object { $_ }) {
    if ($resource.tags.managedBy -ne 'arc-demo-private-onboarding' -or -not $previous) { throw 'Named private infrastructure already exists without the initialized ownership journal; inspect, never adopt/replay.' }
}
$zones = @(Invoke-DemoAz -Arguments @('network', 'private-dns', 'zone', 'list', '-o', 'json') | ConvertFrom-Json)
if (@($zones | Where-Object { $_.name -eq 'privatelink.vaultcore.azure.net' -and $_.id -ne $zoneId }).Count) {
    throw 'An existing same-name private DNS zone is outside this owned change; no override/link substitution.'
}
if (@($vault.properties.privateEndpointConnections | Where-Object { $_ -and $_.properties.privateEndpoint.id -ne $endpointId }).Count) { throw 'Vault has another private endpoint connection; stop on changed scope.' }
$app = Invoke-DemoGraph -Method GET -Path "/v1.0/applications/$($plan.applicationObjectId)?`$select=id,appId,passwordCredentials,keyCredentials"
$sp = Invoke-DemoGraph -Method GET -Path "/v1.0/servicePrincipals/$($plan.servicePrincipalObjectId)?`$select=id,appId,accountEnabled"
if ($app.id -ne $plan.applicationObjectId -or $app.appId -ne $plan.applicationId -or $sp.id -ne $plan.servicePrincipalObjectId -or
    $sp.appId -ne $plan.applicationId -or $sp.accountEnabled -ne $true -or @($app.keyCredentials).Count -or
    -not @($app.passwordCredentials).Count) { throw 'Existing application/SP identity or enabled/credential metadata drift.' }
$roles = @(Invoke-DemoAz -Arguments @('role', 'assignment', 'list', '--assignee-object-id', $plan.servicePrincipalObjectId, '--all', '-o', 'json') | ConvertFrom-Json)
if ($roles.Count -ne 1 -or $roles[0].scope -ne "/subscriptions/$SubscriptionId/resourceGroups/rg-$prefix" -or
    $roles[0].roleDefinitionName -ne 'Azure Connected Machine Onboarding') { throw 'Onboarding SP permissions are not the exact dedicated RG onboarding contract.' }
$secret = Get-DemoArmResource -ResourceId $secretId -ApiVersion '2024-11-01' -AllowNotFound
if ($previous) {
    if (-not $secret -or $secret.tags.state -ne 'initialized' -or $secret.tags.keyId -ne $previous.credentialKeyId -or
        $secret.properties.secretUriWithVersion -ne $previous.secretVersionUri -or
        $previous.credentialKeyId -notin @($app.passwordCredentials.keyId) -or $secret.tags.appId -ne $plan.applicationId -or
        $secret.properties.attributes.enabled -ne $true -or
        [datetimeoffset]::FromUnixTimeSeconds($secret.properties.attributes.exp) -ne [datetimeoffset]$previous.expiresAtUtc -or
        [datetimeoffset]$previous.expiresAtUtc -lt [datetimeoffset]::UtcNow.AddHours(24) -or
        ($secret.properties.attributes.nbf -and [datetimeoffset]::FromUnixTimeSeconds($secret.properties.attributes.nbf) -gt [datetimeoffset]::UtcNow) -or
        -not $existingEndpoint -or -not $existingZone -or $existingEndpoint.properties.provisioningState -ne 'Succeeded') {
        throw 'Retained credential/private-path reference drift, invalid validity or less than 24h remaining; no rotation or secret version churn.'
    }
    if ([datetimeoffset]$previous.expiresAtUtc -le [datetimeoffset]::UtcNow.AddDays(14)) {
        $renewalWindow = if ([datetimeoffset]$previous.expiresAtUtc -le [datetimeoffset]::UtcNow.AddDays(7)) { '7-day urgent' } else { '14-day' }
        Write-Warning "$renewalWindow review: retained onboarding credential expires $($previous.expiresAtUtc); separate renewal approval required, no automatic rotation."
    }
    if (Get-DemoArmResource -ResourceId $writerId -ApiVersion '2022-04-01' -AllowNotFound) { throw 'Temporary writer is still present; initialization is not clean.' }
    $retainedLink = Get-DemoArmResource -ResourceId $linkId -ApiVersion '2024-06-01'
    $retainedGroup = Get-DemoArmResource -ResourceId $groupId -ApiVersion '2024-05-01'
    if ($existingEndpoint.id -ne $endpointId -or $existingEndpoint.properties.subnet.id -ne $plan.subnetResourceId -or
        @($existingEndpoint.properties.privateLinkServiceConnections).Count -ne 1 -or
        $existingEndpoint.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId -ne $plan.vaultResourceId -or
        $existingEndpoint.properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status -ne 'Approved' -or
        $existingZone.id -ne $zoneId -or $retainedLink.id -ne $linkId -or $retainedLink.properties.virtualNetwork.id -ne $plan.vnetResourceId -or
        $retainedLink.properties.registrationEnabled -ne $false -or $retainedGroup.id -ne $groupId -or
        @($retainedGroup.properties.privateDnsZoneConfigs).Count -ne 1 -or $retainedGroup.properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId -ne $zoneId) {
        throw 'Retained private endpoint/DNS binding drift; no repair or credential operation.'
    }
    return [pscustomobject]@{ state = 'initialized'; changed = $false; secretVersionUri = $previous.secretVersionUri; expiresAtUtc = $previous.expiresAtUtc }
}
if ($secret) { throw 'Secret scope already exists without this initialization journal; never overwrite existing material.' }
if (Get-DemoArmResource -ResourceId $writerId -ApiVersion '2022-04-01' -AllowNotFound) { throw 'Temporary writer assignment already exists; no adoption or broader grant.' }
$preview = [ordered]@{
    state = 'preview'; changed = $false; vaultResourceId = $plan.vaultResourceId; secretResourceId = $secretId
    privateEndpointId = $endpointId; privateDnsZoneId = $zoneId; vnetLinkId = $linkId; zoneGroupId = $groupId
    readerPrincipalIds = @($plan.parents.principalId); readerScope = $secretId; temporaryWriterId = $writerId
    credentialAction = 'one addPassword on the pinned existing application; exactly 30 days; originals retained'
    publicAccess = 'Disabled, unchanged'; parentPowerChanges = $false; guestEnrollment = $false
    sourceHashes = $sourceHashes
}
if ($Action -eq 'Preview' -or -not $PSCmdlet.ShouldProcess($secretId, 'Initialize approved private infrastructure and one 30-day onboarding credential; retain originals')) { return [pscustomobject]$preview }
$runId = [guid]::NewGuid().ToString('N')
$journal = [ordered]@{
    schemaVersion = 1; ownership = 'arc-demo-private-onboarding'; state = 'started'; runId = $runId
    planHash = (Get-FileHash -LiteralPath $PlanPath -Algorithm SHA256).Hash
    sourceHashes = $sourceHashes
    subscriptionId = "$SubscriptionId"; tenantId = "$TenantId"; vaultResourceId = $plan.vaultResourceId
    applicationId = $plan.applicationId; applicationObjectId = $plan.applicationObjectId; servicePrincipalObjectId = $plan.servicePrincipalObjectId
    credentialKeyId = $null; expiresAtUtc = $null; secretVersionUri = $null
    credentialRequestedAtUtc = $null; requestedExpiresAtUtc = $null
    originalCredentialKeyIds = @($app.passwordCredentials.keyId); readerAssignmentIds = @()
    privateEndpointId = $endpointId; privateDnsZoneId = $zoneId; vnetLinkId = $linkId; zoneGroupId = $groupId
    temporaryWriterId = $writerId; temporaryWriterRemoved = $false; protectedCommands = @()
    rollback = 'not-required'; error = $null
}
$claim = [IO.File]::Open($journalPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$claim.Dispose()
function Save-InitializationJournal { $journal | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $journalPath -Encoding utf8 }
Save-InitializationJournal
$writerAttempted = $false
$storageVerified = $false
$credential = $null
$parametersPath = [IO.Path]::GetTempFileName()
try {
    $values = @{
        location = $plan.location; namePrefix = $prefix; vaultName = $vaultName
        vnetName = ($plan.vnetResourceId -split '/')[-1]; initializeSecretScope = $true
        readerPrincipalIds = @($plan.parents.principalId)
    }
    $parameters = @{}
    foreach ($entry in $values.GetEnumerator()) { $parameters[$entry.Key] = @{ value = $entry.Value } }
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $parametersPath -Encoding utf8
    $journal.state = 'infrastructure-requested'; Save-InitializationJournal
    $deployment = Invoke-DemoAz -Arguments @('deployment', 'group', 'create', '-g', $infra, '-n', "private-onboarding-$($runId.Substring(0,12))",
        '--template-file', (Join-Path $PSScriptRoot '..\bicep\modules\private-onboarding-vault.bicep'), '--parameters', "@$parametersPath", '-o', 'json') | ConvertFrom-Json
    if ($deployment.properties.provisioningState -ne 'Succeeded') { throw 'Private infrastructure deployment is failed/unknown; do not replay.' }
    $journal.readerAssignmentIds = @($deployment.properties.outputs.readerAssignmentIds.value)
    if ($journal.readerAssignmentIds.Count -ne 2) { throw 'Exact-secret reader output is incomplete.' }
    foreach ($parent in $plan.parents) {
        $readerName = Get-DemoRoleAssignmentName -Scope $secretId -PrincipalId $parent.principalId -RoleId '4633458b-17de-408a-b874-0445c86b69e6'
        $readerId = "$secretId/providers/Microsoft.Authorization/roleAssignments/$readerName"
        if ($readerId -notin $journal.readerAssignmentIds) { throw 'Deployment reader role output differs from the pinned exact-secret grant.' }
        $reader = Get-DemoArmResource -ResourceId $readerId -ApiVersion '2022-04-01'
        if ($reader.id -ne $readerId -or $reader.properties.principalId -ne $parent.principalId -or $reader.properties.scope -ne $secretId -or
            ($reader.properties.roleDefinitionId -split '/')[-1] -ne '4633458b-17de-408a-b874-0445c86b69e6') { throw 'Permanent reader scope/role/principal readback differs.' }
    }
    $endpoint = Get-DemoArmResource -ResourceId $endpointId -ApiVersion '2024-05-01'
    if ($endpoint.properties.provisioningState -ne 'Succeeded' -or $endpoint.properties.subnet.id -ne $plan.subnetResourceId -or
        @($endpoint.properties.privateLinkServiceConnections).Count -ne 1 -or
        $endpoint.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId -ne $plan.vaultResourceId -or
        $endpoint.properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status -ne 'Approved') { throw 'Private endpoint target/approval is not verified.' }
    $nicId = "$scope/providers/Microsoft.Network/networkInterfaces/pe-$prefix-onboarding-kv-nic"
    if (@($endpoint.properties.networkInterfaces).Count -ne 1 -or $endpoint.properties.networkInterfaces[0].id -ne $nicId) {
        throw 'Private endpoint NIC identity differs from the owned single endpoint.'
    }
    $nic = Get-DemoArmResource -ResourceId $nicId -ApiVersion '2024-05-01'
    if ($nic.id -ne $nicId -or $nic.properties.privateEndpoint.id -ne $endpointId -or @($nic.properties.ipConfigurations).Count -ne 1 -or
        $nic.properties.ipConfigurations[0].properties.subnet.id -ne $plan.subnetResourceId -or
        $nic.properties.ipConfigurations[0].properties.privateIPAllocationMethod -ne 'Dynamic') { throw 'Private endpoint NIC/subnet/allocation binding is not verified.' }
    $addresses = @($nic.properties.ipConfigurations[0].properties.privateIPAddress)
    $endpointAddress = $null
    if (-not [Net.IPAddress]::TryParse($addresses[0], [ref]$endpointAddress) -or $endpointAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'Private endpoint NIC has no verified IPv4 address.'
    }
    $writerAttempted = $true
    $journal.state = 'temporary-writer-requested'; Save-InitializationJournal
    Invoke-AzRest -Method PUT -Url "https://management.azure.com${writerId}?api-version=2022-04-01" -Body @{
        properties = @{ principalId = $writer.principalId; principalType = 'ServicePrincipal'; roleDefinitionId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$officer" }
    } | Out-Null
    $writerRole = Get-DemoArmResource -ResourceId $writerId -ApiVersion '2022-04-01'
    if ($writerRole.id -ne $writerId -or $writerRole.properties.scope -ne $secretId -or $writerRole.properties.principalId -ne $writer.principalId -or
        ($writerRole.properties.roleDefinitionId -split '/')[-1] -ne $officer) { throw 'Temporary writer exact-scope readback differs.' }
    $markerName = "arc-onboarding-marker-$($runId.Substring(0,12))"
    $journal.protectedCommands += "$($writer.resourceId)/runCommands/$markerName"; Save-InitializationJournal
    Invoke-DemoProtectedVaultCommand -Parent $writer -VaultName $vaultName -PrivateAddresses $addresses -Operation Marker `
        -CommandName $markerName -EvidencePath (Join-Path $root "$markerName.json") | Out-Null
    $freshApp = Invoke-DemoGraph -Method GET -Path "/v1.0/applications/$($plan.applicationObjectId)?`$select=id,appId,passwordCredentials,keyCredentials"
    if ($freshApp.id -ne $plan.applicationObjectId -or $freshApp.appId -ne $plan.applicationId -or @($freshApp.keyCredentials).Count -or
        @(Compare-Object @($journal.originalCredentialKeyIds) @($freshApp.passwordCredentials.keyId)).Count) {
        throw 'Application credential metadata changed during private-path setup; stop before addPassword.'
    }
    $createdAt = [datetimeoffset]::FromUnixTimeSeconds([datetimeoffset]::UtcNow.ToUnixTimeSeconds())
    $expiry = $createdAt.AddDays(30)
    $journal.credentialRequestedAtUtc = $createdAt.UtcDateTime.ToString('o')
    $journal.requestedExpiresAtUtc = $expiry.UtcDateTime.ToString('o')
    $journal.state = 'credential-requested'; Save-InitializationJournal
    $credential = Invoke-DemoGraph -Method POST -Path "/v1.0/applications/$($plan.applicationObjectId)/addPassword" -Body @{
        passwordCredential = @{ displayName = "$prefix-private-onboarding-30d"; startDateTime = $createdAt.ToString('o'); endDateTime = $expiry.ToString('o') }
    }
    $newKey = [guid]::Empty
    if ($credential -and [guid]::TryParse([string]$credential.keyId, [ref]$newKey) -and $newKey -ne [guid]::Empty -and "$newKey" -notin $journal.originalCredentialKeyIds) {
        $journal.credentialKeyId = "$newKey"; $journal.expiresAtUtc = $expiry.UtcDateTime.ToString('o'); Save-InitializationJournal
    }
    if (-not $journal.credentialKeyId -or [string]::IsNullOrWhiteSpace($credential.secretText) -or [datetimeoffset]$credential.startDateTime -ne $createdAt -or
        [datetimeoffset]$credential.endDateTime -ne $expiry) { throw 'addPassword response is incomplete/unknown. Inspect application metadata; never retry.' }
    $storeName = "arc-onboarding-store-$($runId.Substring(0,12))"
    $journal.protectedCommands += "$($writer.resourceId)/runCommands/$storeName"; Save-InitializationJournal
    $stored = Invoke-DemoProtectedVaultCommand -Parent $writer -VaultName $vaultName -PrivateAddresses $addresses -Operation Initialize `
        -CommandName $storeName -EvidencePath (Join-Path $root "$storeName.json") -SecretValue $credential.secretText `
        -ApplicationId $plan.applicationId -CredentialKeyId $journal.credentialKeyId -ExpiresAtUtc $journal.expiresAtUtc
    if ($stored.result.enabled -ne $true -or [datetimeoffset]$stored.result.expiresAtUtc -ne $expiry) { throw 'Protected storage metadata differs from created credential.' }
    $freshApp = Invoke-DemoGraph -Method GET -Path "/v1.0/applications/$($plan.applicationObjectId)?`$select=id,appId,passwordCredentials"
    if ($freshApp.id -ne $plan.applicationObjectId -or $freshApp.appId -ne $plan.applicationId -or
        @(Compare-Object @($journal.originalCredentialKeyIds + $journal.credentialKeyId) @($freshApp.passwordCredentials.keyId)).Count) {
        throw 'Post-storage application key set differs; original credential preservation/new-key ownership not verified.'
    }
    $journal.secretVersionUri = $stored.result.secretVersionUri
    $storageVerified = $true
    $journal.state = 'stored-awaiting-writer-cleanup'; Save-InitializationJournal
} catch {
    $failedStage = $journal.state
    $journal.error = "Failure at $($journal.state): $($_.Exception.Message)"
    $journal.state = 'failed-or-unknown'
    if ($journal.credentialKeyId -and -not $storageVerified) {
        try {
            Invoke-DemoGraph -Method POST -Path "/v1.0/applications/$($plan.applicationObjectId)/removePassword" -Body @{ keyId = $journal.credentialKeyId } | Out-Null
            $after = Invoke-DemoGraph -Method GET -Path "/v1.0/applications/$($plan.applicationObjectId)?`$select=id,appId,passwordCredentials"
            if ($journal.credentialKeyId -in @($after.passwordCredentials.keyId) -or @($journal.originalCredentialKeyIds | Where-Object { $_ -notin @($after.passwordCredentials.keyId) }).Count) {
                throw 'Rollback/original-credential preservation not verified.'
            }
            $journal.rollback = 'only-new-key-removed'
        } catch {
            $journal.rollback = "failed: $($_.Exception.Message)"
            $journal.error += " Returned-key rollback failed; inspect journal: $($_.Exception.Message)"
        }
    } elseif ($failedStage -eq 'credential-requested') {
        $journal.rollback = 'no-returned-owned-key; inspect metadata; no guessed deletion'
    }
    Save-InitializationJournal
    throw $journal.error
} finally {
    $credential = $null
    [IO.File]::Delete($parametersPath)
    if ($writerAttempted) {
        try {
            $role = Get-DemoArmResource -ResourceId $writerId -ApiVersion '2022-04-01' -AllowNotFound
            if ($role) {
                if ($role.properties.principalId -ne $writer.principalId -or $role.properties.scope -ne $secretId -or
                    ($role.properties.roleDefinitionId -split '/')[-1] -ne $officer) { throw 'Temporary assignment ownership drift; no foreign delete.' }
                Invoke-AzRest -Method DELETE -Url "https://management.azure.com${writerId}?api-version=2022-04-01" | Out-Null
            }
            if (Get-DemoArmResource -ResourceId $writerId -ApiVersion '2022-04-01' -AllowNotFound) { throw 'Temporary writer removal not verified.' }
            $journal.temporaryWriterRemoved = $true
        } catch {
            $journal.state = 'writer-cleanup-failed'
            $journal.error = "$($journal.error) Temporary writer cleanup: $($_.Exception.Message)".Trim()
            Save-InitializationJournal
            throw $journal.error
        }
    }
    Save-InitializationJournal
}
if (-not $storageVerified -or -not $journal.temporaryWriterRemoved) { throw 'Private initialization is not verified complete.' }
$journal.state = 'initialized'; Save-InitializationJournal
[pscustomobject]@{ state = 'initialized'; changed = $true; secretVersionUri = $journal.secretVersionUri; expiresAtUtc = $journal.expiresAtUtc; journalPath = $journalPath }
