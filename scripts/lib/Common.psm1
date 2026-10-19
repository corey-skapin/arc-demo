<#
.SYNOPSIS
  Shared utility functions for arc-demo scripts.

.DESCRIPTION
  Import with:
    Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force
#>

#region Logging

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

#endregion

#region Prereqs

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

#endregion

#region Demo skin helpers

function ConvertTo-DemoHashtable {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) {
        return @{}
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertTo-DemoHashtable -InputObject $InputObject[$key]
        }
        return $result
    }

    if ($InputObject -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-DemoHashtable -InputObject $property.Value
        }
        return $result
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return @($InputObject | ForEach-Object { ConvertTo-DemoHashtable -InputObject $_ })
    }

    return $InputObject
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

    $skin = Get-Content -LiteralPath $skinPath -Raw | ConvertFrom-Json -Depth 30
    if ($skin -isnot [pscustomobject] -or $skin.schemaVersion -ne 1) {
        throw "Invalid demo skin '$skinPath': expected an object with schemaVersion 1."
    }
    foreach ($section in 'azure', 'workloads', 'compute', 'operations', 'cost', 'labels', 'tags', 'notifications') {
        if ($null -ne $skin.$section -and $skin.$section -isnot [pscustomobject]) { throw "Skin $section must be a JSON object." }
    }
    foreach ($property in $skin.workloads.PSObject.Properties) {
        if ($property.Name -in @('deployArcOnPrem', 'deployAzureVMs', 'deployContainerApps', 'deployAks', 'installSql', 'skipSqlInstall') -and $property.Value -isnot [bool]) {
            throw "Skin workloads.$($property.Name) must be a JSON boolean, not a string."
        }
    }
    if ($skin.azure.namePrefix) { Assert-DemoName -NamePrefix $skin.azure.namePrefix }
    if ($skin.azure.location -and $skin.azure.location -notmatch '^[a-z0-9]+$') { throw 'Skin azure.location must be an Azure region name.' }
    return ConvertTo-DemoHashtable -InputObject $skin
}

function Get-DemoSkinValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Skin,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][object]$Default
    )

    $current = $Skin
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $current) {
            return $Default
        }

        if ($current -is [System.Collections.IDictionary] -and $current.Contains($part)) {
            $current = $current[$part]
            continue
        }

        $property = $current.PSObject.Properties[$part]
        if ($property) {
            $current = $property.Value
            continue
        }

        return $Default
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
        [AllowNull()][object]$Overrides
    )

    $result = [ordered]@{}
    foreach ($key in $Defaults.Keys) {
        $result[$key] = $Defaults[$key]
    }

    $overrideTable = ConvertTo-DemoHashtable -InputObject $Overrides
    if ($overrideTable -is [System.Collections.IDictionary]) {
        foreach ($key in $overrideTable.Keys) {
            if ($null -ne $overrideTable[$key] -and ([string]$overrideTable[$key] -ne '')) {
                $result[$key] = $overrideTable[$key]
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

#endregion

#region Az REST helpers

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

#endregion

#region Wait helpers

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

#endregion

#region Misc

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

#endregion

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
    try {
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
    param([Parameter(Mandatory)][string]$NamePrefix)
    Assert-DemoName $NamePrefix
    $arcRg = "rg-$NamePrefix"
    $infraRg = "rg-$NamePrefix-infra"
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
    $resources = @(Invoke-DemoAz -Arguments @('resource', 'list', '-g', $infraRg, '-o', 'json') | ConvertFrom-Json)
    # Older manifests did not emit AKS IDs.
    $clusterIds = @(@($clusterIds) + @($resources | Where-Object { $_.type -eq 'Microsoft.ContainerService/managedClusters' -and $_.tags.workload -eq 'aks' } | ForEach-Object { $_.id }) | Sort-Object -Unique)
    foreach ($id in @($nativeIds) + @($appIds) + @($clusterIds)) {
        if (-not $id.StartsWith("/subscriptions/$script:DemoSubscription/resourceGroups/$infraRg/providers/", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Deployment manifest includes a workload ID outside the explicitly targeted demo resource group.'
        }
    }
    $vmRecords = @(Invoke-DemoAz -Arguments @('vm', 'list', '-g', $infraRg, '--show-details', '-o', 'json') | ConvertFrom-Json)
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

function Invoke-DemoGuestCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine,
        [Parameter(Mandatory)][string]$Script
    )
    $cmd = if ($Machine.OsType -eq 'Windows') { 'RunPowerShellScript' } else { 'RunShellScript' }
    $scriptPath = $null
    try {
        if ($Script.StartsWith('@')) {
            $sourcePath = (Resolve-Path -LiteralPath $Script.Substring(1) -ErrorAction Stop).ProviderPath
            if (-not [System.IO.File]::Exists($sourcePath)) { throw 'Guest script input must be a file.' }
            $scriptArgument = "@$sourcePath"
        } else {
            # az.cmd can truncate multiline arguments. Keep the file until the job finishes.
            $scriptPath = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($scriptPath, $Script, [System.Text.UTF8Encoding]::new($false))
            $scriptArgument = "@$scriptPath"
        }
        $job = Start-DemoAzJob -Arguments @('vm', 'run-command', 'invoke', '--ids', $Machine.Id,
            '--command-id', $cmd, '--scripts', $scriptArgument, '-o', 'json', '--only-show-errors')
        $result = Receive-DemoJobs -Jobs @($job) -TimeoutSeconds 900 -PassThru | ConvertFrom-Json
    } finally {
        if ($scriptPath) { [System.IO.File]::Delete($scriptPath) }
    }
    $messages = @($result.value | ForEach-Object { $_.message }) -join "`n"
    if ($result.value.code -match 'failed' -or $messages -notmatch '(?m)^ARC_DEMO_OK\s*$') {
        throw "Guest command failed on $($Machine.Name); required completion marker absent or failure reported. Review VM Run Command output."
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
        $Jobs | Wait-Job -Timeout $TimeoutSeconds | Out-Null
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
        [ValidateSet('Ready', 'Hibernated')][string]$DesiredState = 'Ready'
    )
    $parked = $DesiredState -eq 'Hibernated'
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
    $natId = "$root/$($Inventory.InfraRg)/providers/Microsoft.Network/natGateways/natgw-$NamePrefix"
    $pipId = "$root/$($Inventory.InfraRg)/providers/Microsoft.Network/publicIPAddresses/pip-natgw-$NamePrefix"
    foreach ($id in $natId, $pipId) {
        $exists = $id -in $Inventory.Resources.id
        New-DemoCheck "network/$(($id -split '/')[-1])" $id (-not $parked) $exists $(if ($exists -ne $parked) { 'pass' } else { 'fail' })
    }
    $subnet = Invoke-DemoAz -Arguments @('network', 'vnet', 'subnet', 'show', '-g', $Inventory.InfraRg, '--vnet-name', "vnet-$NamePrefix", '-n', 'snet-vms', '-o', 'json') | ConvertFrom-Json
    $expectedNat = if ($parked) { '' } else { $natId }
    New-DemoCheck 'network/nat-association' $subnet.id $expectedNat ([string]$subnet.natGateway.id) $(if ([string]$subnet.natGateway.id -eq $expectedNat) { 'pass' } else { 'fail' })
    $arcMachines = @(Invoke-DemoAz -Arguments @('connectedmachine', 'list', '-g', $Inventory.ArcRg, '-o', 'json') | ConvertFrom-Json)
    $heartbeatIds = @()
    if (-not $parked -and @($Inventory.Machines | Where-Object Monitor).Count -gt 0) {
        $workspace = Invoke-DemoAz -Arguments @('monitor', 'log-analytics', 'workspace', 'show', '--ids', $workspaceId, '-o', 'json') | ConvertFrom-Json
        $heartbeatIds = @(Get-DemoHeartbeatIds -WorkspaceCustomerId $workspace.customerId)
    }
    foreach ($machine in $Inventory.Machines) {
        $power = if ($parked) { 'VM deallocated' } else { 'VM running' }
        $actual = $machine.Actual
        New-DemoCheck "vm/$($machine.Name)/power" $machine.Id $power $actual.powerState $(if (-not $actual) { 'fail' } elseif ($actual.powerState -eq $power) { 'pass' } else { 'pending' })
        if (-not $machine.Native) {
            $arc = $arcMachines | Where-Object { $_.id -eq $machine.ArcId } | Select-Object -First 1
            New-DemoCheck "arc/$($machine.Name)" $machine.ArcId $(if ($parked) { 'retained' } else { 'Connected' }) $arc.status $(if (-not $arc) { 'fail' } elseif ($parked -or $arc.status -eq 'Connected') { 'pass' } else { 'pending' })
        }
        $scope = if ($machine.Native) { $machine.Id } else { $machine.ArcId }
        if ($machine.Monitor -and -not $parked) {
            New-DemoCheck "heartbeat/$($machine.Name)" $scope 'Heartbeat within 10 minutes by _ResourceId' ($scope.ToLowerInvariant() -in $heartbeatIds) $(if ($scope.ToLowerInvariant() -in $heartbeatIds) { 'pass' } else { 'pending' })
        } else {
            New-DemoCheck "heartbeat/$($machine.Name)" $scope 'not required for parked/unsupported host' $null 'skipped' $false
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
    foreach ($id in $Inventory.AksClusterIds) {
        $cluster = Invoke-DemoAz -Arguments @('aks', 'show', '-g', $Inventory.InfraRg, '-n', ($id -split '/')[-1], '-o', 'json') | ConvertFrom-Json
        $state = if ($parked) { 'Stopped' } else { 'Running' }
        New-DemoCheck "aks/$($cluster.name)" $id $state $cluster.powerState.code $(if ($cluster.provisioningState -eq 'Failed') { 'fail' } elseif ($cluster.powerState.code -eq $state -and $cluster.provisioningState -eq 'Succeeded') { 'pass' } else { 'pending' })
    }
    foreach ($id in $Inventory.ContainerAppIds) {
        $name = ($id -split '/')[-1]
        $revisions = @(Invoke-DemoAz -Arguments @('containerapp', 'revision', 'list', '-g', $Inventory.InfraRg, '-n', $name, '-o', 'json') | ConvertFrom-Json)
        $active = @($revisions | Where-Object { $_.properties.active })
        $healthy = @($active | Where-Object { $_.properties.healthState -eq 'Healthy' -and $_.properties.runningState -in @('Running', 'RunningAtMaxScale', 'RunningAtMinScale') })
        New-DemoCheck "containerapp/$name" $id $(if ($parked) { 'no active revisions' } else { 'healthy active revision' }) @($active.name) $(if (($parked -and $active.Count -eq 0) -or (-not $parked -and $healthy.Count -gt 0)) { 'pass' } else { 'pending' })
    }
}

Export-ModuleMember -Function * -Variable *
