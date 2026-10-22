# Shared functions for deployment, lifecycle and read-only readiness.
function Write-Header {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host ('━' * 70) -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host ('━' * 70) -ForegroundColor Cyan
}

function Write-Step {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "→ $Message" -ForegroundColor White
}

function Write-Ok {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  ✅ $Message" -ForegroundColor Green
}

function Write-Warn {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  ⚠  $Message" -ForegroundColor Yellow
}

function Write-Fail {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  ❌ $Message" -ForegroundColor Red
}

function Test-Prerequisites {
    <#
    .SYNOPSIS
        Verifies tooling, login state, and target subscription/tenant.
    .OUTPUTS
        Throws if any required check fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId,
        [string]$DeployerPrincipalId = '',
        [string[]]$Providers = @('Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity',
            'Microsoft.OperationalInsights', 'Microsoft.OperationsManagement', 'Microsoft.Insights', 'Microsoft.Security',
            'Microsoft.PolicyInsights', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.KeyVault', 'Microsoft.DevTestLab',
            'Microsoft.Consumption')
    )

    Write-Header 'Pre-flight checks'
    Initialize-DemoContext -SubscriptionId $SubscriptionId -TenantId $TenantId

    # PowerShell version
    if ($PSVersionTable.PSVersion -lt [version]'7.4') {
        throw "PowerShell 7.4+ required. Detected: $($PSVersionTable.PSVersion)"
    }
    Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

    # Azure CLI
    try {
        $azVerJson = az version -o json 2>$null | ConvertFrom-Json
        $azVer = $azVerJson.'azure-cli'
        if (-not $azVer) { throw "Could not parse Azure CLI version" }
        if ([version]$azVer -lt [version]'2.60') {
            throw "Azure CLI 2.60+ required. Detected: $azVer"
        }
        Write-Ok "Azure CLI $azVer"
    } catch { throw "Azure CLI not found or unreadable. Install from https://aka.ms/installazurecliwindows. Error: $($_.Exception.Message)" }

    # Bicep CLI
    try {
        $bicepOut = az bicep version 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $bicepOut) { throw "az bicep version failed" }
        $bicepText = ($bicepOut | Where-Object { $_ -match 'Bicep CLI' } | Select-Object -First 1).Trim()
        Write-Ok $bicepText
    } catch { throw "Bicep CLI not found. Run: az bicep install" }

    # Active subscription
    $ctx = Invoke-DemoAz -Arguments @('account', 'show', '--query', '{id:id,tenantId:tenantId,user:user.name}', '-o', 'json') | ConvertFrom-Json
    if (-not $ctx) { throw "Not signed in. Run: az login --tenant $TenantId" }
    if ($ctx.tenantId -ne $TenantId) {
        throw "Active tenant is $($ctx.tenantId), not requested $TenantId. Run: az login --tenant $TenantId"
    }
    Write-Ok "Signed in as $($ctx.user) in tenant $TenantId"

    # Owner role (or higher — inherited via MG is normal for MCAPS). Some MCAPS
    # lab tenants can satisfy ARM RBAC while Graph user lookup is blocked by a
    # CAE challenge, so allow the deploy script to pass the known object id.
    $principalId = $DeployerPrincipalId
    if (-not $principalId) {
        $principalId = Invoke-DemoAz -Arguments @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv')
    }
    if (-not $principalId) { throw "Unable to resolve signed-in user object id" }
    $roles = @(Invoke-DemoAz -Arguments @('role', 'assignment', 'list', '--assignee-object-id', $principalId,
        '--scope', "/subscriptions/$SubscriptionId", '--include-inherited', '--include-groups', '--query', '[].roleDefinitionName', '-o', 'tsv'))
    if ('Owner' -notin $roles -and -not ('Contributor' -in $roles -and 'User Access Administrator' -in $roles)) {
        throw 'Subscription Owner, or Contributor plus User Access Administrator, is required (including inherited/group assignments). Activate PIM/access and retry.'
    }
    Write-Ok 'Required subscription permissions verified'

    foreach ($rp in $Providers) {
        $state = Invoke-DemoAz -Arguments @('provider', 'show', '--namespace', $rp, '--query', 'registrationState', '-o', 'tsv')
        if ($state -ne 'Registered') {
            throw "Provider $rp is $state. An authorized operator must run: az provider register --subscription $SubscriptionId --namespace $rp --wait. Preflight never registers providers."
        }
    }
    Write-Ok 'Required resource providers already registered (read-only check)'

    return $principalId
}

function Get-DemoSkin {
    <#
    .SYNOPSIS
        Loads the repo-level reskin variables file.
    #>
    [CmdletBinding()]
    param(
        [string]$Path = '',
        [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    )

    $skinPath = if ([string]::IsNullOrWhiteSpace($Path)) {
        Join-Path $RepoRoot 'config\demo-skin.json'
    } elseif ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        Join-Path $RepoRoot $Path
    }

    if (-not (Test-Path -LiteralPath $skinPath)) {
        throw "Demo skin not found: $skinPath"
    }

    $skin = Get-Content -LiteralPath $skinPath -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    if ($skin -isnot [System.Collections.IDictionary] -or $skin.schemaVersion -ne 1) {
        throw "Invalid demo skin '$skinPath': expected an object with schemaVersion 1."
    }
    foreach ($section in 'azure', 'workloads', 'compute', 'operations', 'cost', 'labels', 'tags', 'notifications') {
        if ($null -ne $skin.$section -and $skin.$section -isnot [System.Collections.IDictionary]) { throw "Skin $section must be a JSON object." }
    }
    foreach ($key in 'deployArcOnPrem', 'deployAzureVMs', 'deployContainerApps', 'deployAks', 'installSql', 'skipSqlInstall') {
        if ($skin.workloads -and $skin.workloads.Contains($key) -and $skin.workloads[$key] -isnot [bool]) {
            throw "Skin workloads.$key must be a JSON boolean, not a string."
        }
    }
    if ($skin.azure.namePrefix) { Assert-DemoName -NamePrefix $skin.azure.namePrefix }
    if ($skin.azure.location -and $skin.azure.location -notmatch '^[a-z0-9]+$') { throw 'Skin azure.location must be an Azure region name.' }
    return $skin
}

function Get-DemoSkinValue {
    [CmdletBinding()]
    param(
        [AllowNull()][System.Collections.IDictionary]$Skin,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][object]$Default
    )

    $current = $Skin
    foreach ($part in ($Path -split '\.')) {
        if ($current -isnot [System.Collections.IDictionary] -or -not $current.Contains($part)) { return $Default }
        $current = $current[$part]
    }

    if ($null -eq $current -or ([string]$current -eq '')) {
        return $Default
    }

    return $current
}

function Merge-DemoHashtable {
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary]$Defaults = @{},
        [AllowNull()][System.Collections.IDictionary]$Overrides
    )

    $result = [ordered]@{}
    foreach ($key in $Defaults.Keys) {
        $result[$key] = $Defaults[$key]
    }

    if ($Overrides) {
        foreach ($key in $Overrides.Keys) {
            if ($null -ne $Overrides[$key] -and ([string]$Overrides[$key] -ne '')) {
                $result[$key] = $Overrides[$key]
            }
        }
    }

    return $result
}

function ConvertTo-DemoTagString {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Tags = @{})

    return (($Tags.GetEnumerator() | Sort-Object Key | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ',')
}

function Get-MgmtToken {
    [CmdletBinding()]
    param()
    return (Invoke-DemoAz -Arguments @('account', 'get-access-token', '--resource', 'https://management.azure.com', '--query', 'accessToken', '-o', 'tsv'))
}

function Get-LawQueryToken {
    [CmdletBinding()]
    param()
    return (Invoke-DemoAz -Arguments @('account', 'get-access-token', '--resource', 'https://api.loganalytics.io', '--query', 'accessToken', '-o', 'tsv'))
}

function Invoke-AzRest {
    <#
    .SYNOPSIS
        Wrapper for Azure Resource Manager REST calls. Use this instead of `az rest`
        for URLs containing `?` or `()` — see AGENTS.md Gotcha 5.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [Parameter()][object]$Body
    )
    $token = Get-MgmtToken
    $hdr = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $params = @{ Method = $Method; Uri = $Url; Headers = $hdr; TimeoutSec = 60 }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params['Body'] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 25 }
    }
    Invoke-RestMethod @params
}

function Wait-Until {
    <#
    .SYNOPSIS
        Polls a script block until it returns $true or the timeout is reached.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [ValidateRange(0, 7200)][int]$TimeoutSeconds = 600,
        [ValidateRange(1, 300)][int]$IntervalSeconds = 15,
        [string]$Message = 'Waiting',
        [switch]$AllowTimeout
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            if (& $Condition) { return $true }
        } catch {
            throw "Inspection failed while waiting for $Message`: $($_.Exception.Message)"
        }
        $remaining = [Math]::Max(0, [int]($deadline - (Get-Date)).TotalSeconds)
        if ($remaining -eq 0) { break }
        Write-Step "$Message... ($remaining s remaining)"
        Start-Sleep -Seconds ([Math]::Min($IntervalSeconds, $remaining))
    } while ((Get-Date) -lt $deadline)
    if ($AllowTimeout) { return $false }
    throw "Timed out after $TimeoutSeconds seconds waiting for $Message. Inspect the expected resource identities and observed state before retrying."
}

function New-StrongPassword {
    [CmdletBinding()]
    param([int]$Length = 24)
    $chars = ((48..57) + (65..90) + (97..122) + @(33, 35, 36, 37, 38, 42, 64))
    -join (($chars | Get-Random -Count $Length) | ForEach-Object { [char]$_ })
}

function New-KeyVaultName {
    [CmdletBinding()]
    param([string]$Prefix = 'kv-arcdemo')
    $rand = -join ((97..122 + 48..57) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
    return "$Prefix-$rand"
}

function Assert-DemoName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$NamePrefix)
    if ($NamePrefix -cnotmatch '^[a-z][a-z0-9-]{1,18}[a-z0-9]$') {
        throw 'NamePrefix must be 3-20 lowercase letters/digits/hyphens, start with a letter and end with a letter or digit.'
    }
}

function Invoke-DemoAz {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowNotFound
    )
    $az = (Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    if ($script:DemoSubscription -and '--subscription' -notin $Arguments -and $Arguments[0] -notin @('version', 'bicep', 'ad')) {
        $Arguments += @('--subscription', $script:DemoSubscription)
    }
    $stderr = [System.IO.Path]::GetTempFileName()
    $captureWhatIfPreference = $WhatIfPreference
    try {
        # Caller ShouldProcess guards Azure writes; preview must still capture local stderr.
        $WhatIfPreference = $false
        if ($Arguments[0] -eq 'ad') {
            if (-not $script:DemoTenant) { throw 'Initialize the explicit demo tenant before a directory operation.' }
            $defaultTenant = & $az account show --query tenantId -o tsv 2> $stderr
            if ($LASTEXITCODE -ne 0) { throw 'Unable to verify the Azure CLI default tenant before a directory operation.' }
            if (($defaultTenant -join '').Trim() -ne $script:DemoTenant) {
                throw 'Directory operations use the CLI default tenant, which differs from the explicitly requested tenant. Select the intended tenant before retrying; no CLI defaults were changed.'
            }
        }
        $output = & $az @Arguments 2> $stderr
        $exitCode = $LASTEXITCODE
        $detail = [System.IO.File]::ReadAllText($stderr).Trim()
        if ($exitCode -ne 0) {
            if ($AllowNotFound -and $detail -match '\((ResourceNotFound|ResourceGroupNotFound|NotFound|SecretNotFound|BudgetNotFound)\)') { return $null }
            # Do not echo arguments: run-command and identity commands can carry credentials.
            throw "Azure CLI $($Arguments[0]) $($Arguments[1]) failed (exit $exitCode): $detail"
        }
        if ($detail) { Write-Verbose $detail }
        return $output
    } finally {
        $WhatIfPreference = $captureWhatIfPreference
        [System.IO.File]::Delete($stderr)
    }
}

function Initialize-DemoContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$SubscriptionId,
        [Parameter(Mandatory)][guid]$TenantId
    )
    $context = Invoke-DemoAz -Arguments @('account', 'show', '--subscription', "$SubscriptionId", '-o', 'json', '--only-show-errors') | ConvertFrom-Json
    if ($context.id -ne "$SubscriptionId" -or $context.tenantId -ne "$TenantId") {
        throw 'Azure context does not match the explicitly requested subscription and tenant. Sign in to the intended tenant first.'
    }
    $script:DemoSubscription = "$SubscriptionId"
    $script:DemoTenant = "$TenantId"
}

function Get-DemoInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$NamePrefix, [switch]$ForHibernation)
    Assert-DemoName $NamePrefix
    $arcRg = "rg-$NamePrefix"
    $infraRg = "rg-$NamePrefix-infra"
    $resources = @(Invoke-DemoAz -Arguments @('resource', 'list', '-g', $infraRg, '-o', 'json') | ConvertFrom-Json)
    $vmRecords = @(Invoke-DemoAz -Arguments @('vm', 'list', '-g', $infraRg, '--show-details', '-o', 'json') | ConvertFrom-Json)
    if ($ForHibernation) {
        $root = "/subscriptions/$script:DemoSubscription/resourceGroups/$infraRg/providers/"
        if (@(@($resources) + @($vmRecords) | Where-Object { -not $_.id.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) }).Count) {
            throw 'Inventory returned an ID outside the explicitly targeted demo infra group.'
        }
        $machines = @($vmRecords | ForEach-Object { [pscustomobject]@{ Name = $_.name; Id = $_.id; Actual = $_ } })
        $machines += @($resources | Where-Object { $_.type -eq 'Microsoft.Compute/virtualMachines' -and $_.id -notin $vmRecords.id } |
            ForEach-Object { [pscustomobject]@{ Name = $_.name; Id = $_.id; Actual = $null } })
        return [pscustomobject]@{ ArcRg = $arcRg; InfraRg = $infraRg; Resources = $resources; Machines = $machines
            AksClusterIds = @($resources | Where-Object type -eq 'Microsoft.ContainerService/managedClusters' | ForEach-Object id)
            ContainerAppIds = @($resources | Where-Object type -eq 'Microsoft.App/containerApps' | ForEach-Object id) }
    }
    $deployments = @(Invoke-DemoAz -Arguments @('deployment', 'sub', 'list', '--query',
        "[?properties.provisioningState=='Succeeded' && properties.outputs.arcResourceGroup.value=='$arcRg']", '-o', 'json') | ConvertFrom-Json |
        Sort-Object { $_.properties.timestamp } -Descending)
    if (-not $deployments) { throw "No successful deployment manifest for $arcRg. Restore deployment history or deploy the intended skin before lifecycle operations." }
    # Workload-only incremental deployments can return empty fleet arrays. They do
    # not delete resources from earlier deployments.
    $fleetDeployment = $deployments | Where-Object { $_.properties.outputs.vmFleet.value } | Select-Object -First 1
    $fleet = @($fleetDeployment.properties.outputs.vmFleet.value | Where-Object { $_.deployed })
    $nativeIds = @($deployments | ForEach-Object { $_.properties.outputs.azureVmResourceIds.value } | Where-Object { $_ } | Sort-Object -Unique)
    $appIds = @($deployments | ForEach-Object { $_.properties.outputs.containerAppIds.value } | Where-Object { $_ } | Sort-Object -Unique)
    $clusterIds = @($deployments | ForEach-Object { $_.properties.outputs.aksClusterIds.value } | Where-Object { $_ } | Sort-Object -Unique)
    # Older manifests did not emit AKS IDs.
    $clusterIds = @(@($clusterIds) + @($resources | Where-Object { $_.type -eq 'Microsoft.ContainerService/managedClusters' -and $_.tags.workload -eq 'aks' } | ForEach-Object { $_.id }) | Sort-Object -Unique)
    foreach ($id in @($nativeIds) + @($appIds) + @($clusterIds)) {
        if (-not $id.StartsWith("/subscriptions/$script:DemoSubscription/resourceGroups/$infraRg/providers/", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Deployment manifest includes a workload ID outside the explicitly targeted demo resource group.'
        }
    }
    $machines = foreach ($entry in $fleet) {
        $id = "/subscriptions/$script:DemoSubscription/resourceGroups/$infraRg/providers/Microsoft.Compute/virtualMachines/$($entry.name)"
        $actual = $vmRecords | Where-Object { $_.id -eq $id } | Select-Object -First 1
        [pscustomobject]@{ Name = $entry.name; Id = $id; ArcId = "/subscriptions/$script:DemoSubscription/resourceGroups/$arcRg/providers/Microsoft.HybridCompute/machines/$($entry.name)"
            OsType = $entry.osType; Monitor = $entry.supportsAzureMonitor; VmInsights = $entry.supportsVmInsights
            ChangeTracking = $entry.supportsChangeTracking; Native = $false; Actual = $actual }
    }
    $machines = @($machines)
    foreach ($id in $nativeIds) {
        $actual = $vmRecords | Where-Object { $_.id -eq $id } | Select-Object -First 1
        $machines += [pscustomobject]@{ Name = ($id -split '/')[-1]; Id = $id; ArcId = $null
            OsType = if ($actual) { $actual.storageProfile.osDisk.osType } else { 'Windows' }
            Monitor = $true; VmInsights = $true; ChangeTracking = $false; Native = $true; Actual = $actual }
    }
    $unknown = @($vmRecords | Where-Object { $_.id -notin $machines.Id })
    if ($unknown) { throw "VMs outside the retained deployment manifests found in $infraRg`: $($unknown.name -join ', '). Refusing to manage an ambiguous fleet." }
    foreach ($machine in $machines | Where-Object { $_.Actual }) {
        if ($machine.OsType -ne $machine.Actual.storageProfile.osDisk.osType) { throw "OS metadata differs from manifest for $($machine.Name)." }
    }
    return [pscustomobject]@{ ArcRg = $arcRg; InfraRg = $infraRg; Machines = $machines; ContainerAppIds = $appIds
        AksClusterIds = $clusterIds; Outputs = $deployments[0].properties.outputs; Resources = $resources }
}

function Get-DemoNetworkState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InfraRg,
        [Parameter(Mandatory)][string]$NamePrefix,
        [switch]$ForHibernation
    )
    $root = "/subscriptions/$script:DemoSubscription/resourceGroups/$InfraRg/providers/Microsoft.Network"
    $natId = "$root/natGateways/natgw-$NamePrefix"
    $pipId = "$root/publicIPAddresses/pip-natgw-$NamePrefix"
    $subnetId = "$root/virtualNetworks/vnet-$NamePrefix/subnets/snet-vms"
    $subnetJson = Invoke-DemoAz -Arguments @('network', 'vnet', 'subnet', 'show', '--ids', $subnetId, '-o', 'json') -AllowNotFound:$ForHibernation
    $subnet = if ($null -ne $subnetJson) { $subnetJson | ConvertFrom-Json }
    $natJson = Invoke-DemoAz -Arguments @('network', 'nat', 'gateway', 'show', '--ids', $natId, '-o', 'json') -AllowNotFound
    $nat = if ($null -ne $natJson) { $natJson | ConvertFrom-Json }
    $pipJson = Invoke-DemoAz -Arguments @('network', 'public-ip', 'show', '--ids', $pipId, '-o', 'json') -AllowNotFound
    $pip = if ($null -ne $pipJson) { $pipJson | ConvertFrom-Json }
    if ((-not $ForHibernation -and -not $subnet) -or ($subnet -and $subnet.id -ne $subnetId) -or ($nat -and $nat.id -ne $natId) -or ($pip -and $pip.id -ne $pipId)) {
        throw 'Network inspection returned an unexpected resource identity; refusing lifecycle changes.'
    }
    $conflicts = @(
        if ($subnet.natGateway.id -and $subnet.natGateway.id -ne $natId) { 'Demo subnet has an unexpected NAT Gateway.' }
        if (@($nat.subnets | Where-Object { $_ -and $_.id -ne $subnetId }).Count) { 'Demo NAT Gateway is shared with another subnet.' }
        if (@($nat.publicIpAddresses | Where-Object { $_ -and $_.id -ne $pipId }).Count -or @($nat.publicIpPrefixes | Where-Object { $_ }).Count) { 'Demo NAT Gateway uses unexpected public IP resources.' }
        if (($pip.natGateway.id -and $pip.natGateway.id -ne $natId) -or $pip.ipConfiguration.id) { 'Demo public IP is used by another resource.' }
    )
    if ($conflicts -and -not $ForHibernation) { throw ($conflicts -join ' ') }
    [pscustomobject]@{ Subnet = $subnet; Nat = $nat; PublicIp = $pip; NatId = $natId; PublicIpId = $pipId; SafeToRemove = -not $conflicts; ConflictMessage = $conflicts -join ' ' }
}

function Get-DemoRemovalChecks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$NamePrefix)
    $scope = "/subscriptions/$script:DemoSubscription"
    foreach ($rg in "rg-$NamePrefix", "rg-$NamePrefix-infra") {
        $exists = Invoke-DemoAz -Arguments @('group', 'exists', '-n', $rg, '-o', 'json') | ConvertFrom-Json
        New-DemoCheck "group/$rg" "$scope/resourceGroups/$rg" 'absent' $(if ($exists) { 'exists' } else { 'absent' }) $(if ($exists) { 'pending' } else { 'pass' })
    }
    foreach ($name in "mcsb-$NamePrefix", "nist-$NamePrefix") {
        $assignment = Invoke-DemoAz -Arguments @('policy', 'assignment', 'show', '-n', $name, '--scope', $scope, '-o', 'json') -AllowNotFound
        New-DemoCheck "policy/$name" "$scope/providers/Microsoft.Authorization/policyAssignments/$name" 'absent' $(if ($assignment) { 'exists' } else { 'absent' }) $(if ($assignment) { 'pending' } else { 'pass' })
    }
    $budget = Invoke-DemoAz -Arguments @('consumption', 'budget', 'show', '--budget-name', "budget-$NamePrefix", '-o', 'json') -AllowNotFound
    New-DemoCheck 'budget' "$scope/providers/Microsoft.Consumption/budgets/budget-$NamePrefix" 'absent' $(if ($budget) { 'exists' } else { 'absent' }) $(if ($budget) { 'pending' } else { 'pass' })
    New-DemoCheck 'exception/tenant-identity' '' 'separate opt-in cleanup' $null 'skipped' $false 'Tenant onboarding identity/application is not inspected here. Use RemoveOnboardingIdentity for scoped SP deletion; directory access is not needed for default removal.'
    New-DemoCheck 'exception/shared-services' $scope 'preserved unless explicitly approved' $null 'skipped' $false 'Subscription Defender and shared resources are excluded. Soft-deleted vaults and retained applications can persist; no purge or zero-bill claim.'
}

function Assert-DemoOsDiskStorageAccountType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Machines,
        [Parameter(Mandatory)][ValidateSet('Standard_LRS', 'StandardSSD_LRS')][string]$StorageAccountType
    )
    foreach ($machine in $Machines) {
        $diskId = [string]$machine.storageProfile.osDisk.managedDisk.id
        if (-not $diskId) { throw "Cannot verify retained OS disk for $($machine.name). Deployment will not infer or convert its tier." }
        $observed = Invoke-DemoAz -Arguments @('disk', 'show', '--ids', $diskId, '--query', 'sku.name', '-o', 'tsv')
        if ([string]::IsNullOrWhiteSpace($observed)) { throw "OS disk tier unreadable for $($machine.name); inspect the retained disk before deployment." }
        if ($observed.Trim() -ne $StorageAccountType) {
            throw "OS disk tier mismatch on $($machine.name): existing $($observed.Trim()), requested $StorageAccountType. Preserve the existing tier with -OsDiskStorageAccountType or compute.osDiskStorageAccountType. Disk conversion requires a separately approved stop/deallocate/restart window; deployment will not perform it."
        }
    }
}

function Invoke-DemoGuestCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine,
        [Parameter(Mandatory, ParameterSetName = 'Submit')][string]$Script,
        [Parameter(Mandatory, ParameterSetName = 'Receive')]$Job,
        [Parameter(ParameterSetName = 'Submit')][switch]$AsJob,
        [switch]$PassThru,
        [switch]$AllowPending
    )
    $cmd = if ($Machine.OsType -eq 'Windows') { 'RunPowerShellScript' } else { 'RunShellScript' }
    $scriptPath = if ($Job) { $Job.DemoScriptPath } else { $null }
    try {
        if (-not $Job -and $Script.StartsWith('@')) {
            $sourcePath = (Resolve-Path -LiteralPath $Script.Substring(1) -ErrorAction Stop).ProviderPath
            if (-not [System.IO.File]::Exists($sourcePath)) { throw 'Guest script input must be a file.' }
            $scriptArgument = "@$sourcePath"
        } elseif (-not $Job) {
            # az.cmd can truncate multiline arguments. Keep the file until the job finishes.
            $scriptPath = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($scriptPath, $Script, [System.Text.UTF8Encoding]::new($false))
            $scriptArgument = "@$scriptPath"
        }
        if (-not $Job) {
            $Job = Start-DemoAzJob -Arguments @('vm', 'run-command', 'invoke', '--ids', $Machine.Id,
                '--command-id', $cmd, '--scripts', $scriptArgument, '-o', 'json', '--only-show-errors')
            $Job | Add-Member -NotePropertyName DemoScriptPath -NotePropertyValue $scriptPath
        }
        if ($AsJob) { return $Job }
        $result = Receive-DemoJobs -Jobs @($Job) -TimeoutSeconds 900 -PassThru | ConvertFrom-Json
    } finally {
        if ($scriptPath -and (-not $AsJob -or -not $Job)) { [System.IO.File]::Delete($scriptPath) }
    }
    $entries = @($result.value | Where-Object { $_ })
    $stdout = @($entries | Where-Object {
        $_.code -match '^ComponentStatus/StdOut/succeeded$|^ProvisioningState/succeeded$'
    } | ForEach-Object { $_.message }) -join "`n"
    $marker = $stdout -match '(?m)^ARC_DEMO_OK\r?$'
    $pending = $AllowPending -and $stdout -match '(?m)^ARC_DEMO_PENDING\r?$'
    $failed = @($entries | Where-Object { $_.code -match 'failed|error' -or $_.level -eq 'Error' })
    $stderrPresent = @($entries | Where-Object { $_.code -match '^ComponentStatus/StdErr/' -and $_.message }).Count -gt 0
    $codes = @($entries | ForEach-Object { [string]$_.code })
    if (-not $entries -or $failed -or (-not $marker -and -not $pending)) {
        # Do not expose arbitrary guest output: onboarding scripts can contain secrets.
        throw "Guest command failed on $($Machine.Name); stdout completion marker=$marker; stderr present=$stderrPresent; status codes=$($codes -join ', '). Required completion marker absent or failure reported."
    }
    if ($PassThru) {
        [pscustomobject]@{
            machineName = $Machine.Name; resourceId = $Machine.Id; status = $(if ($pending) { 'pending' } else { 'pass' })
            completionMarker = $(if ($pending) { 'ARC_DEMO_PENDING' } else { 'ARC_DEMO_OK' }); statusCodes = $codes; stderrPresent = $stderrPresent
        }
    }
}

function Receive-DemoJobs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Jobs,
        [int]$TimeoutSeconds = 1800,
        [switch]$PassThru
    )
    try {
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            $remaining = [Math]::Max(0, [int]($deadline - (Get-Date)).TotalSeconds)
            Write-Step "Waiting for guest/extension jobs: $($Jobs.Name -join ', ') ($remaining s remaining)"
            $Jobs | Wait-Job -Timeout ([Math]::Min(15, $remaining)) | Out-Null
        } while (@($Jobs | Where-Object State -in @('NotStarted', 'Running')).Count -and (Get-Date) -lt $deadline)
        foreach ($job in $Jobs) {
            if ($job.State -ne 'Completed') { throw "Job $($job.Name) did not complete: $($job.State). Inspect the target resource before retrying." }
            $output = Receive-Job $job -ErrorAction Stop
            if ($PassThru) { $output }
            if ($job.ChildJobs.Error.Count -gt 0) { throw "Job $($job.Name) reported errors." }
        }
    } finally {
        $Jobs | Where-Object State -eq 'Running' | Stop-Job
        $Jobs | Remove-Job -Force
    }
}

function Start-DemoAzJob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    $target = 'operation'
    foreach ($option in '--machine-name', '--vm-name', '--ids') {
        $index = [Array]::IndexOf($Arguments, $option)
        if ($index -ge 0) { $target = ($Arguments[$index + 1] -split '/')[-1]; break }
    }
    Start-Job -Name "$($Arguments[0])-$target" -ScriptBlock {
        param($module, $subscription, $tenant, $cliArguments)
        $ErrorActionPreference = 'Stop'
        Import-Module $module -Force
        Initialize-DemoContext -SubscriptionId $subscription -TenantId $tenant
        Invoke-DemoAz -Arguments $cliArguments
    } -ArgumentList $PSCommandPath, $script:DemoSubscription, $script:DemoTenant, $Arguments
}

function Test-DemoFleet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Fleet)
    $names = @()
    foreach ($entry in $Fleet) {
        if ($entry.name -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,13}[a-zA-Z0-9]$' -or $entry.name -in $names) { throw 'Fleet names must be unique, 2-15 letters/digits/hyphens, and valid Windows computer names.' }
        $names += $entry.name
        if ($entry.osType -notin @('Windows', 'Linux')) { throw "Invalid OS for $($entry.name)." }
        if ($entry.deploymentMode -notin @('azure-vm', 'represent-not-run')) { throw "Invalid deploymentMode for $($entry.name)." }
        foreach ($field in 'supportsAzureMonitor', 'supportsVmInsights', 'supportsChangeTracking', 'supportsSql', 'esuEligible') {
            if ($entry.$field -isnot [bool]) { throw "Fleet $($entry.name).$field must be a JSON boolean." }
        }
        if (-not $entry.supportsAzureMonitor -and ($entry.supportsVmInsights -or $entry.supportsChangeTracking)) { throw "Monitoring capability flags conflict for $($entry.name)." }
        if ($entry.osType -eq 'Linux' -and $entry.supportsVmInsights) { throw 'Linux VM Insights is not validated in this lab; supportsVmInsights must be false.' }
        foreach ($field in 'role', 'osTier', 'imagePublisher', 'imageOffer', 'imageSku', 'imageVersion', 'monitorTier') {
            if ([string]::IsNullOrWhiteSpace($entry.$field)) { throw "Fleet $($entry.name) is missing $field." }
        }
    }
}

function Test-DemoComputeCapacity {
    [CmdletBinding()]
    param([string]$Location, [string]$VmSize, [int]$AdditionalVmCount)
    $sku = @(Invoke-DemoAz -Arguments @('vm', 'list-skus', '-l', $Location, '--size', $VmSize, '--resource-type', 'virtualMachines', '--all', '-o', 'json') | ConvertFrom-Json |
        Where-Object name -eq $VmSize)
    if ($sku.Count -ne 1) { throw "SKU $VmSize is not uniquely available in $Location." }
    if (@($sku[0].restrictions | Where-Object type -eq 'Location').Count) { throw "SKU $VmSize has subscription/location restrictions in $Location." }
    $cores = [int]($sku[0].capabilities | Where-Object name -eq 'vCPUs' | Select-Object -First 1).value
    if ($cores -lt 1) { throw "Unable to determine vCPU requirements for $VmSize." }
    $usage = @(Invoke-DemoAz -Arguments @('vm', 'list-usage', '-l', $Location, '-o', 'json') | ConvertFrom-Json)
    foreach ($name in 'cores', $sku[0].family) {
        $quota = $usage | Where-Object { $_.name.value -eq $name } | Select-Object -First 1
        if (-not $quota) { throw "Quota $name could not be checked in $Location." }
        if (($quota.currentValue + [Math]::Max(0, $AdditionalVmCount) * $cores) -gt $quota.limit) {
            throw "Insufficient $name vCPU quota in $Location. Request quota or reduce the fleet before deployment."
        }
    }
    Write-Warn 'SKU restrictions and vCPU quota passed. This does not prove physical capacity; ARM what-if/validation is not an allocation guarantee.'
}

function Assert-DemoSkinInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Skin, [Parameter(Mandatory)]$Inventory)
    $requirements = @(
        @{ Flag = 'deployArcOnPrem'; Count = @($Inventory.Machines | Where-Object { -not $_.Native }).Count }
        @{ Flag = 'deployAzureVMs'; Count = @($Inventory.Machines | Where-Object Native).Count }
        @{ Flag = 'deployContainerApps'; Count = @($Inventory.ContainerAppIds).Count }
        @{ Flag = 'deployAks'; Count = @($Inventory.AksClusterIds).Count }
    )
    foreach ($requirement in $requirements) {
        if ((Get-DemoSkinValue $Skin "workloads.$($requirement.Flag)" $false) -and $requirement.Count -eq 0) {
            throw "Skin requires $($requirement.Flag), but no retained workload manifest exists. Reconcile deployment before lifecycle operations."
        }
    }
    $fleetPath = Get-DemoSkinValue $Skin 'workloads.onPremFleetPath' ''
    if ($fleetPath) {
        if (-not [System.IO.Path]::IsPathRooted($fleetPath)) { $fleetPath = Join-Path (Split-Path (Split-Path $PSScriptRoot)) $fleetPath }
        $fleet = Get-Content -LiteralPath $fleetPath -Raw -ErrorAction Stop | ConvertFrom-Json -NoEnumerate
        if ($fleet -isnot [array]) { throw 'Fleet file must contain a JSON array of fleet objects.' }
        Test-DemoFleet $fleet
        foreach ($entry in $fleet | Where-Object deploymentMode -eq 'azure-vm') {
            $machine = $Inventory.Machines | Where-Object Name -eq $entry.name | Select-Object -First 1
            if (-not $machine -or $machine.Native -or $machine.OsType -ne $entry.osType -or $machine.Monitor -ne $entry.supportsAzureMonitor -or
                $machine.VmInsights -ne $entry.supportsVmInsights -or $machine.ChangeTracking -ne $entry.supportsChangeTracking) {
                throw "Skin fleet and retained manifest differ for $($entry.name). Reconcile deployment first."
            }
        }
    }
}

function New-DemoCheck {
    [CmdletBinding()]
    param(
        [string]$Id, [string]$ResourceId, [object]$Expected, [AllowNull()][object]$Observed,
        [ValidateSet('pass', 'fail', 'pending', 'skipped')][string]$Status,
        [bool]$Required = $true, [string]$Message = ''
    )
    [pscustomobject]@{ id = $Id; resourceId = $ResourceId; required = $Required; expected = $Expected
        observed = $Observed; status = $Status; message = $Message }
}

function Get-DemoHeartbeatIds {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceCustomerId)
    $token = Get-LawQueryToken
    $response = Invoke-RestMethod -Method Post -TimeoutSec 60 `
        -Uri "https://api.loganalytics.io/v1/workspaces/$WorkspaceCustomerId/query" `
        -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' `
        -Body (@{ query = 'Heartbeat | where TimeGenerated > ago(10m) | distinct tolower(_ResourceId)' } | ConvertTo-Json)
    if ($response.error) { throw "Log Analytics returned a query error: $($response.error.code)" }
    return @($response.tables[0].rows | ForEach-Object { [string]$_[0] })
}

function Get-DemoReadinessChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][string]$NamePrefix,
        [ValidateSet('Active', 'Ready', 'Hibernated')][string]$DesiredState = 'Ready'
    )
    $parked = $DesiredState -eq 'Hibernated'
    foreach ($machine in $Inventory.Machines) {
        $power = if ($parked) { 'VM deallocated' } else { 'VM running' }
        $observed = $machine.Actual.powerState
        New-DemoCheck "vm/$($machine.Name)/power" $machine.Id $power $observed $(if (-not $observed) { 'fail' } elseif ($observed -eq $power) { 'pass' } else { 'pending' }) -Message $(if (-not $observed) { 'Power state unknown; not verified stopped.' } else { '' })
    }
    foreach ($id in $Inventory.AksClusterIds) {
        $cluster = Invoke-DemoAz -Arguments @('aks', 'show', '-g', $Inventory.InfraRg, '-n', ($id -split '/')[-1], '-o', 'json') | ConvertFrom-Json
        $state = if ($parked) { 'Stopped' } else { 'Running' }
        New-DemoCheck "aks/$($cluster.name)" $id $state $cluster.powerState.code $(if (-not $cluster.powerState.code -or $cluster.provisioningState -eq 'Failed') { 'fail' } elseif ($cluster.powerState.code -eq $state -and $cluster.provisioningState -eq 'Succeeded') { 'pass' } else { 'pending' })
    }
    foreach ($id in $Inventory.ContainerAppIds) {
        $name = ($id -split '/')[-1]
        $revisions = @(Invoke-DemoAz -Arguments @('containerapp', 'revision', 'list', '-g', $Inventory.InfraRg, '-n', $name, '-o', 'json') | ConvertFrom-Json)
        $active = @($revisions | Where-Object { $_.properties.active })
        $healthy = @($active | Where-Object { $_.properties.healthState -eq 'Healthy' -and $_.properties.runningState -in @('Running', 'RunningAtMaxScale', 'RunningAtMinScale') })
        New-DemoCheck "containerapp/$name" $id $(if ($parked) { 'no active revisions' } else { 'healthy active revision' }) @($active.name) $(if (($parked -and $active.Count -eq 0) -or (-not $parked -and $healthy.Count -gt 0)) { 'pass' } else { 'pending' })
    }
    $network = Get-DemoNetworkState -InfraRg $Inventory.InfraRg -NamePrefix $NamePrefix -ForHibernation:$parked
    foreach ($id in $network.NatId, $network.PublicIpId) {
        $exists = if ($id -eq $network.NatId) { [bool]$network.Nat } else { [bool]$network.PublicIp }
        New-DemoCheck "network/$(($id -split '/')[-1])" $id (-not $parked) $exists $(if ($exists -ne $parked) { 'pass' } else { 'fail' }) -Required (-not $parked) -Message $(if ($parked -and $exists) { "Compute parked independently; networking may still bill. $($network.ConflictMessage)" } else { '' })
    }
    $subnet = $network.Subnet
    $expectedNat = if ($parked) { '' } else { $network.NatId }
    New-DemoCheck 'network/nat-association' $subnet.id $expectedNat ([string]$subnet.natGateway.id) $(if ([string]$subnet.natGateway.id -eq $expectedNat) { 'pass' } else { 'fail' }) -Required (-not $parked) -Message $network.ConflictMessage
    if ($parked) { return }
    $root = "/subscriptions/$script:DemoSubscription/resourceGroups"
    $arcResources = @(Invoke-DemoAz -Arguments @('resource', 'list', '-g', $Inventory.ArcRg, '-o', 'json') | ConvertFrom-Json)
    foreach ($rg in $Inventory.ArcRg, $Inventory.InfraRg) {
        $group = Invoke-DemoAz -Arguments @('group', 'show', '-n', $rg, '-o', 'json') | ConvertFrom-Json
        New-DemoCheck "group/$rg" "$root/$rg" 'Succeeded' $group.properties.provisioningState $(if ($group.properties.provisioningState -eq 'Succeeded') { 'pass' } else { 'pending' })
    }
    $workspaceId = "$root/$($Inventory.ArcRg)/providers/Microsoft.OperationalInsights/workspaces/law-$NamePrefix"
    $requiredIds = @($workspaceId,
        "$root/$($Inventory.ArcRg)/providers/Microsoft.Insights/dataCollectionRules/dcr-$NamePrefix",
        "$root/$($Inventory.ArcRg)/providers/Microsoft.Insights/dataCollectionRules/dcr-vminsights",
        "$root/$($Inventory.ArcRg)/providers/Microsoft.Insights/dataCollectionRules/dcr-changetracking",
        "$root/$($Inventory.ArcRg)/providers/Microsoft.Insights/actionGroups/ag-$NamePrefix",
        "$root/$($Inventory.ArcRg)/providers/Microsoft.Insights/scheduledQueryRules/alert-$NamePrefix-host-missing-heartbeat")
    foreach ($id in $requiredIds) {
        New-DemoCheck "resource/$(($id -split '/')[-1])" $id 'exists' $(if ($id -in $arcResources.id) { 'exists' } else { 'missing' }) $(if ($id -in $arcResources.id) { 'pass' } else { 'fail' })
    }
    $workbooks = @($arcResources | Where-Object { $_.type -eq 'Microsoft.Insights/workbooks' })
    New-DemoCheck 'workbook' "$root/$($Inventory.ArcRg)/providers/Microsoft.Insights/workbooks" 'at least one workbook' $workbooks.Count $(if ($workbooks) { 'pass' } else { 'fail' })
    $arcMachines = @(Invoke-DemoAz -Arguments @('connectedmachine', 'list', '-g', $Inventory.ArcRg, '-o', 'json') | ConvertFrom-Json)
    $heartbeatIds = @()
    if (@($Inventory.Machines | Where-Object Monitor).Count -gt 0) {
        $workspace = Invoke-DemoAz -Arguments @('monitor', 'log-analytics', 'workspace', 'show', '--ids', $workspaceId, '-o', 'json') | ConvertFrom-Json
        $heartbeatIds = @(Get-DemoHeartbeatIds -WorkspaceCustomerId $workspace.customerId)
    }
    foreach ($machine in $Inventory.Machines) {
        $actual = $machine.Actual
        if (-not $machine.Native) {
            $arc = $arcMachines | Where-Object { $_.id -eq $machine.ArcId } | Select-Object -First 1
            New-DemoCheck "arc/$($machine.Name)" $machine.ArcId 'Connected' $arc.status $(if (-not $arc) { 'fail' } elseif ($arc.status -eq 'Connected') { 'pass' } else { 'pending' })
        }
        $scope = if ($machine.Native) { $machine.Id } else { $machine.ArcId }
        if ($machine.Monitor) {
            New-DemoCheck "heartbeat/$($machine.Name)" $scope 'Heartbeat within 10 minutes by _ResourceId' ($scope.ToLowerInvariant() -in $heartbeatIds) $(if ($scope.ToLowerInvariant() -in $heartbeatIds) { 'pass' } else { 'pending' })
        } else {
            New-DemoCheck "heartbeat/$($machine.Name)" $scope 'unsupported host' $null 'skipped' $false
        }
        if (-not $machine.Monitor -or -not $actual) { continue }
        $associationList = @(Invoke-DemoAz -Arguments @('monitor', 'data-collection', 'rule', 'association', 'list', '--resource', $scope, '-o', 'json') | ConvertFrom-Json)
        $rules = @("dcr-$NamePrefix")
        if ($machine.VmInsights) { $rules += 'dcr-vminsights' }
        if ($machine.ChangeTracking) { $rules += 'dcr-changetracking' }
        foreach ($rule in $rules) {
            $ruleId = "$root/$($Inventory.ArcRg)/providers/Microsoft.Insights/dataCollectionRules/$rule"
            New-DemoCheck "dcra/$($machine.Name)/$rule" $scope $ruleId @($associationList.dataCollectionRuleId) $(if ($ruleId -in $associationList.dataCollectionRuleId) { 'pass' } else { 'fail' })
        }
        $extensionScope = if ($machine.Native -or $machine.OsType -eq 'Linux') { $machine.Id } else { $machine.ArcId }
        $extensions = if ($machine.Native -or $machine.OsType -eq 'Linux') {
            @(Invoke-DemoAz -Arguments @('vm', 'extension', 'list', '-g', $Inventory.InfraRg, '--vm-name', $machine.Name, '-o', 'json') | ConvertFrom-Json)
        } else {
            @(Invoke-DemoAz -Arguments @('connectedmachine', 'extension', 'list', '-g', $Inventory.ArcRg, '--machine-name', $machine.Name, '-o', 'json') | ConvertFrom-Json)
        }
        $extensionNames = @(if ($machine.OsType -eq 'Windows') { 'AzureMonitorWindowsAgent' } else { 'AzureMonitorLinuxAgent' })
        if ($machine.VmInsights) { $extensionNames += 'DependencyAgentWindows' }
        if ($machine.ChangeTracking) { $extensionNames += "ChangeTracking-$($machine.OsType)" }
        foreach ($name in $extensionNames) {
            $extension = $extensions | Where-Object name -eq $name | Select-Object -First 1
            $state = if ($extension.provisioningState) { $extension.provisioningState } else { $extension.properties.provisioningState }
            New-DemoCheck "extension/$($machine.Name)/$name" "$extensionScope/extensions/$name" 'Succeeded' $state $(if (-not $extension -or $state -eq 'Failed') { 'fail' } elseif ($state -eq 'Succeeded') { 'pass' } else { 'pending' })
        }
    }
}

Export-ModuleMember -Function * -Variable *
