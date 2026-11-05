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

function Get-DemoMissingCliExtension {
    [CmdletBinding()]
    param([AllowNull()]$VersionInfo, [AllowEmptyCollection()][string[]]$Required = @())
    $installed = @(if ($VersionInfo.extensions) { $VersionInfo.extensions.PSObject.Properties.Name })
    @($Required | Where-Object { $_ -notin $installed })
}

function Get-DemoPrerequisiteSet {
    <#
    .SYNOPSIS
        The resource providers, subscription features and Azure CLI extensions Deploy needs for the selected workloads.
    .DESCRIPTION
        One list shared by Deploy, the build wrapper preflight and Test-Prerequisites.ps1, so a
        read-only check cannot pass while Deploy would stop on a provider, feature or extension it skipped.
        -StandardSecurityType adds Microsoft.Compute/UseStandardSecurityType, which Compute requires before it
        accepts securityType Standard (the nested SQL parent always declares it).
    #>
    [CmdletBinding()]
    param([switch]$ContainerApps, [switch]$Aks, [switch]$StandardSecurityType)
    $providers = @('Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity',
        'Microsoft.OperationalInsights', 'Microsoft.OperationsManagement', 'Microsoft.Insights', 'Microsoft.Security',
        'Microsoft.PolicyInsights', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.KeyVault', 'Microsoft.DevTestLab',
        'Microsoft.Consumption')
    $extensions = @('connectedmachine')
    $features = @()
    if ($ContainerApps) { $providers += 'Microsoft.App'; $extensions += 'containerapp' }
    if ($Aks) { $providers += @('Microsoft.ContainerService', 'Microsoft.ManagedIdentity', 'Microsoft.Resources', 'Microsoft.Storage', 'Microsoft.ContainerInstance') }
    if ($StandardSecurityType) { $features += 'Microsoft.Compute/UseStandardSecurityType' }
    [pscustomobject]@{ Providers = $providers; Extensions = $extensions; Features = $features }
}

function Test-DemoStandardSecurityTypeRequired {
    <#
    .SYNOPSIS
        True when the deployment declares securityType Standard: the skin's nested SQL parent always does,
        and a fleet file may set it on any entry. Reads only local files.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][System.Collections.IDictionary]$Skin,
        [string]$FleetPath = '',
        [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    )
    if (Get-DemoNestedSqlGuestConfig -Skin $Skin) { return $true }
    if ([string]::IsNullOrWhiteSpace($FleetPath)) { return $false }
    $path = if ([System.IO.Path]::IsPathRooted($FleetPath)) { $FleetPath } else { Join-Path $RepoRoot $FleetPath }
    # A missing fleet file is reported by Deploy's own fleet loading, with the path.
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $fleet = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 20
    [bool]@($fleet | Where-Object { $_.securityType -eq 'Standard' }).Count
}

function Test-Prerequisites {
    <#
    .SYNOPSIS
        Verifies tooling, login state, and target subscription/tenant.
    .DESCRIPTION
        Read-only: it never registers providers or subscription features or installs CLI extensions. Missing
        extensions, unregistered providers and unregistered features are reported together so one pass is enough to fix them.
    .OUTPUTS
        Throws if any required check fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId,
        [string]$DeployerPrincipalId = '',
        [string[]]$Providers = (Get-DemoPrerequisiteSet).Providers,
        [string[]]$RequiredExtensions = (Get-DemoPrerequisiteSet).Extensions,
        [string[]]$Features = (Get-DemoPrerequisiteSet).Features
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
    $missingExtensions = @(Get-DemoMissingCliExtension -VersionInfo $azVerJson -Required $RequiredExtensions)
    if (-not $missingExtensions) { Write-Ok "Azure CLI extensions present: $($RequiredExtensions -join ', ')" }

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

    $unregistered = @(foreach ($rp in $Providers) {
        $state = Invoke-DemoAz -Arguments @('provider', 'show', '--namespace', $rp, '--query', 'registrationState', '-o', 'tsv')
        if ($state -ne 'Registered') { [pscustomobject]@{ Namespace = $rp; State = $state } }
    })
    $unregisteredFeatures = @(foreach ($feature in $Features) {
        $namespace, $featureName = $feature -split '/', 2
        # A feature that is no longer in the catalog (generally available) has nothing left to register.
        $state = Invoke-DemoAz -Arguments @('feature', 'show', '--namespace', $namespace, '--name', $featureName, '--query', 'properties.state', '-o', 'tsv') -AllowNotFound
        if ($null -ne $state -and $state -ne 'Registered') { [pscustomobject]@{ Feature = $feature; Namespace = $namespace; Name = $featureName; State = $state } }
    })
    $problems = @()
    if ($missingExtensions) {
        $install = ($missingExtensions | ForEach-Object { "az extension add --name $_ --yes" }) -join '; '
        $problems += "Azure CLI extension(s) not installed: $($missingExtensions -join ', '). Run: $install. Preflight never installs them: a lazy install inside parallel jobs can race."
    }
    if ($unregistered) {
        $listed = ($unregistered | ForEach-Object { "$($_.Namespace) ($($_.State))" }) -join ', '
        $problems += "Resource provider(s) not registered: $listed. An authorized operator must run, for each: az provider register --subscription $SubscriptionId --namespace <provider> --wait. Preflight never registers providers."
    }
    if ($unregisteredFeatures) {
        $listedFeatures = ($unregisteredFeatures | ForEach-Object { "$($_.Feature) ($($_.State))" }) -join ', '
        $register = ($unregisteredFeatures | ForEach-Object { "az feature register --subscription $SubscriptionId --namespace $($_.Namespace) --name $($_.Name)" }) -join '; '
        $refresh = (@($unregisteredFeatures.Namespace | Sort-Object -Unique) | ForEach-Object { "az provider register --subscription $SubscriptionId --namespace $_ --wait" }) -join '; '
        $problems += "Subscription feature(s) not registered: $listedFeatures. Without them the deployment fails partway through, after the other VMs exist (BadRequest: the value 'Standard' is not available for property 'securityType' until the feature Microsoft.Compute/UseStandardSecurityType is registered). An authorized operator must run: $register; wait until az feature show reads Registered; then run: $refresh. Preflight never registers features."
    }
    if ($problems) { throw ($problems -join ' ') }
    Write-Ok 'Required resource providers already registered (read-only check)'
    if ($Features) { Write-Ok "Required subscription features checked: $($Features -join ', ') (read-only check)" }

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
    foreach ($section in 'azure', 'workloads', 'compute', 'operations', 'cost', 'labels', 'tags', 'notifications', 'nestedSqlGuest') {
        if ($null -ne $skin.$section -and $skin.$section -isnot [System.Collections.IDictionary]) { throw "Skin $section must be a JSON object." }
    }
    if ($skin.operations -and $skin.operations.Contains('keepParkedVmNames')) {
        $names = $skin.operations.keepParkedVmNames
        if ($names -isnot [array] -or @($names | Where-Object {
            $_ -isnot [string] -or $_ -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$'
        }).Count -or @($names | Sort-Object -Unique).Count -ne $names.Count) {
            throw 'Skin operations.keepParkedVmNames must be an array of unique VM names.'
        }
    }
    foreach ($key in 'deployArcOnPrem', 'deployAzureVMs', 'deployContainerApps', 'deployAks') {
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

function Get-DemoResourceTags {
    <#
    .SYNOPSIS
        The lab's resource tags: the four default cost-allocation and owner tags plus the skin's own tags section.
    .DESCRIPTION
        Deploy puts these on everything it creates. Activate puts them on the NAT gateway and public IP it recreates,
        which Bicep does not declare again once they exist, so both read them here and a skin override reaches both.
    #>
    [CmdletBinding()]
    param([AllowNull()][System.Collections.IDictionary]$Skin)
    Merge-DemoHashtable -Defaults ([ordered]@{ owner = 'demo'; purpose = 'arc-demo'; costcenter = 'demo'; env = 'demo' }) `
        -Overrides (Get-DemoSkinValue -Skin $Skin -Path 'tags' -Default @{})
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
        for URLs containing `?` or `()` — see "Preserve platform workarounds" in AGENTS.md.
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

function ConvertTo-DemoTagMap {
    <#
    .SYNOPSIS
        A tags object, as ARM or az returns it, as a case-insensitive name -> value map. $null and {} give an empty map.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Tags)
    $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -eq $Tags) { return $map }
    if ($Tags -is [System.Collections.IDictionary]) {
        foreach ($key in $Tags.Keys) { $map[[string]$key] = [string]$Tags[$key] }
    } else {
        foreach ($property in $Tags.PSObject.Properties) { $map[$property.Name] = [string]$property.Value }
    }
    $map
}

function Set-DemoResourceTags {
    <#
    .SYNOPSIS
        Merges tags onto one resource through the ARM tags API and writes only when a wanted tag differs.
        Returns $true when it wrote and $false when every wanted tag was already in place.
    .DESCRIPTION
        Not `az connectedmachine update --tags k=v k=v`: with extension 3.0.0 that is shorthand syntax and folds every
        pair after the first into the first key's value, so a host kept four tags and `owner` held all the others. A Merge
        leaves tags it does not name alone. The skip matters too: a tag edit is a resource write, and on a Linux host a
        write can seed the Defender MDE.Linux install lock (see docs/troubleshooting.md). The write's response is read
        back and a tag that did not take its value throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/[^/]+/.+')][string]$ResourceId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Tags
    )
    $url = "https://management.azure.com$ResourceId/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
    $member = { param($object, $name) if ($object -is [System.Collections.IDictionary]) { if ($object.Contains($name)) { $object[$name] } } elseif ($object) { $found = $object.PSObject.Properties[$name]; if ($found) { $found.Value } } }
    $tagsOf = { param($response) & $member (& $member $response 'properties') 'tags' }
    $wanted = ConvertTo-DemoTagMap $Tags
    $current = ConvertTo-DemoTagMap (& $tagsOf (Invoke-AzRest -Method Get -Url $url))
    $differs = @($wanted.Keys | Where-Object { -not $current.ContainsKey($_) -or $current[$_] -cne $wanted[$_] })
    if (-not $differs.Count) { return $false }
    $merged = ConvertTo-DemoTagMap (& $tagsOf (Invoke-AzRest -Method Patch -Url $url -Body @{ operation = 'Merge'; properties = @{ tags = $wanted } }))
    $wrong = @($differs | Where-Object { -not $merged.ContainsKey($_) -or $merged[$_] -cne $wanted[$_] })
    if ($wrong.Count) { throw "Tags on $ResourceId did not take the requested value after a Merge: $($wrong -join ', ')." }
    $true
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
    <#
    .SYNOPSIS
        A random password with at least one upper-case letter, lower-case letter, digit and symbol (printable ASCII).
    .DESCRIPTION
        Drawn with a cryptographic RNG and shuffled, so every result meets the nested guest credential contract
        (24 to 128 printable ASCII characters with all four classes) as well as the Azure VM rule.
    #>
    [CmdletBinding()]
    param([ValidateRange(8, 128)][int]$Length = 24)
    $sets = @('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz', '0123456789', '!#$%&*@')
    $all = -join $sets
    $rng = [System.Security.Cryptography.RandomNumberGenerator]
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $sets) { $chars.Add($set[$rng::GetInt32($set.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[$rng::GetInt32($all.Length)]) }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = $rng::GetInt32($i + 1)
        $swap = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $swap
    }
    -join $chars
}

function New-KeyVaultName {
    [CmdletBinding()]
    param([string]$Prefix = 'kv-arcdemo')
    $rand = -join ((97..122 + 48..57) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
    return "$Prefix-$rand"
}

function Set-DemoKeyVaultSecret {
    <#
    .SYNOPSIS
        Writes a Key Vault secret through Azure Resource Manager, retrying only errors that clear by themselves.
    .DESCRIPTION
        Uses the management plane (Microsoft.KeyVault/vaults/secrets), so it works whatever the vault's network
        setting is. A tenant policy can force a new vault to publicNetworkAccess=Disabled seconds after creation;
        az keyvault secret set from a workstation then fails with ForbiddenByConnection however long it retries,
        and that error is not a role-propagation delay. The deployer already holds Owner (or Contributor), so no
        data-plane role has to propagate first. Only throttling, 5xx and connection errors are retried. The value
        is never written to output or error text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [int[]]$RetryDelaySeconds = @(5, 15, 30, 60)
    )
    if (-not $script:DemoSubscription) { throw 'Initialize the explicit demo context before writing a Key Vault secret.' }
    $url = "https://management.azure.com/subscriptions/$script:DemoSubscription/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$VaultName/secrets/${Name}?api-version=2024-11-01"
    $transient = '\b(408|429|500|502|503|504)\b|TooManyRequests|Too Many Requests|ServiceUnavailable|timed out|timeout|Connection (reset|aborted)|connection was closed|error occurred while sending the request'
    for ($attempt = 0; ; $attempt++) {
        try {
            Invoke-AzRest -Method Put -Url $url -Body @{ properties = @{ value = $Value } } | Out-Null
            return
        } catch {
            $problem = $_.Exception.Message
            $detail = @($_.ErrorDetails.Message, $problem) | Where-Object { $_ } | Select-Object -First 1
            if ($problem -notmatch $transient) {
                throw "Key Vault secret $Name could not be written to $VaultName through Azure Resource Manager: $detail"
            }
            if ($attempt -ge $RetryDelaySeconds.Count) {
                throw "Key Vault secret $Name could not be written to $VaultName after $($attempt + 1) attempts: $detail"
            }
            Write-Warn "Key Vault secret write attempt $($attempt + 1) hit a transient Azure Resource Manager error; retrying in $($RetryDelaySeconds[$attempt]) seconds."
            Start-Sleep -Seconds $RetryDelaySeconds[$attempt]
        }
    }
}

function Save-DemoSecretFile {
    <#
    .SYNOPSIS
        Saves a secret as a SecureString export (Export-Clixml) so a later run can reuse it.
    .DESCRIPTION
        On Windows the export is DPAPI-protected: only the same Windows user on the same PC can read it back. Elsewhere
        PowerShell does not encrypt it, so keep the file in a user-only folder. The folder must already exist and, like
        every credential, live outside the git worktree. The value is never written to output.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The secret is converted in memory and written only as a protected SecureString export.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Value)
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder -PathType Container)) { throw "The folder for the saved secret does not exist: $folder" }
    ConvertTo-SecureString -String $Value -AsPlainText -Force | Export-Clixml -LiteralPath $Path
    if (-not $IsWindows) { Write-Warn "Saved the secret to $Path without encryption (DPAPI is Windows-only); keep it in a user-only folder." }
}

function Read-DemoSecretFile {
    <#
    .SYNOPSIS
        Reads a file written by Save-DemoSecretFile (or a credential export) back as a SecureString; $null when the file does not exist.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { $saved = Import-Clixml -LiteralPath $Path }
    catch { throw "The saved secret file $Path could not be read (a Windows export only opens for the user and PC that wrote it): $($_.Exception.Message)" }
    if ($saved -is [pscredential]) { return $saved.Password }
    if ($saved -is [securestring]) { return $saved }
    throw "The saved secret file $Path is not a SecureString or credential export."
}

function Assert-DemoName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$NamePrefix)
    if ($NamePrefix -cnotmatch '^[a-z][a-z0-9-]{1,18}[a-z0-9]$') {
        throw 'NamePrefix must be 3-20 lowercase letters/digits/hyphens, start with a letter and end with a letter or digit.'
    }
}

function Test-DemoNotFoundText {
    <#
    .SYNOPSIS
        True when Azure CLI error text says the requested object does not exist.
    .DESCRIPTION
        CLI 2.91 reports absence as (ResourceGroupNotFound), (PolicyAssignmentNotFound), (ResourceNotFound) and
        so on, but a missing budget as '(404) No budget found matching budgetName'. Denials such as
        (AuthorizationFailed) or (Forbidden) never match.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    [bool]($Text -match '\(\w*NotFound\)|\(404\) No budget found matching budgetName')
}

function Invoke-DemoAz {
    <#
    .SYNOPSIS
        The one checked Azure CLI call: explicit subscription pinning, tenant guard for directory calls, not-found handling.
    .DESCRIPTION
        A Microsoft Graph call (az ad, or az rest against graph.microsoft.com) can be refused with a continuous
        access evaluation (CAE) challenge, "TokenCreatedWithOutdatedPolicies", while ARM calls keep working: the
        Azure CLI keeps reusing a cached CAE-capable Graph token minted before a tenant policy event, and az login
        does not clear it. The documented workaround is AZURE_IDENTITY_DISABLE_CP1=1. Because every directory call
        in the repo goes through here, a Graph call that fails with exactly that challenge is retried once with the
        variable set for that child process only, and later Graph calls in the process keep it. Nothing else is
        changed and a setting the operator made is never overridden.
    #>
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
    $isGraphCall = $Arguments[0] -eq 'ad' -or ($Arguments[0] -eq 'rest' -and ($Arguments -join ' ') -match 'graph\.microsoft\.com')
    $caePattern = 'Continuous access evaluation resulted in challenge|TokenCreatedWithOutdatedPolicies'
    $cp1Disabled = $false
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
        if ($isGraphCall -and $script:DemoGraphWithoutCae -and -not $env:AZURE_IDENTITY_DISABLE_CP1) {
            $env:AZURE_IDENTITY_DISABLE_CP1 = '1'
            $cp1Disabled = $true
        }
        $output = & $az @Arguments 2> $stderr
        $exitCode = $LASTEXITCODE
        $detail = [System.IO.File]::ReadAllText($stderr).Trim()
        if ($exitCode -ne 0 -and $isGraphCall -and -not $env:AZURE_IDENTITY_DISABLE_CP1 -and $detail -match $caePattern) {
            Write-Warn 'Microsoft Graph refused the cached token with a continuous access evaluation (CAE) challenge. Retrying this call once with AZURE_IDENTITY_DISABLE_CP1=1, for this call only (docs/troubleshooting.md).'
            $env:AZURE_IDENTITY_DISABLE_CP1 = '1'
            $cp1Disabled = $true
            $output = & $az @Arguments 2> $stderr
            $exitCode = $LASTEXITCODE
            $detail = [System.IO.File]::ReadAllText($stderr).Trim()
            if ($exitCode -eq 0) { $script:DemoGraphWithoutCae = $true }
        }
        if ($exitCode -ne 0) {
            if ($AllowNotFound -and (Test-DemoNotFoundText $detail)) { return $null }
            $hint = if ($isGraphCall -and $detail -match $caePattern) {
                ' Continuous access evaluation challenge: set $env:AZURE_IDENTITY_DISABLE_CP1 = ''1'' in the shell that runs this script, or run az logout then az login --tenant <TENANT>, and retry (docs/troubleshooting.md).'
            } else { '' }
            # Do not echo arguments: run-command and identity commands can carry credentials.
            throw "Azure CLI $($Arguments[0]) $($Arguments[1]) failed (exit $exitCode): $detail$hint"
        }
        if ($detail) { Write-Verbose $detail }
        return $output
    } finally {
        if ($cp1Disabled) { Remove-Item -Path Env:\AZURE_IDENTITY_DISABLE_CP1 -ErrorAction SilentlyContinue }
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
    param([Parameter(Mandatory)][string]$NamePrefix, [switch]$ForHibernation, [string]$NestedSqlParentVmName = '',
        [string[]]$KeepParkedVmNames = @())
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
            AksClusterIds = @($resources | Where-Object type -eq 'Microsoft.ContainerService/managedClusters' | ForEach-Object { $_.id })
            ContainerAppIds = @($resources | Where-Object type -eq 'Microsoft.App/containerApps' | ForEach-Object { $_.id }) }
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
            ChangeTracking = $entry.supportsChangeTracking; Native = $false; Actual = $actual; Role = $entry.role; OsTier = $entry.osTier }
    }
    $machines = @($machines)
    foreach ($id in $nativeIds) {
        $actual = $vmRecords | Where-Object { $_.id -eq $id } | Select-Object -First 1
        $machines += [pscustomobject]@{ Name = ($id -split '/')[-1]; Id = $id; ArcId = $null
            OsType = if ($actual) { $actual.storageProfile.osDisk.osType } else { 'Windows' }
            Monitor = $true; VmInsights = $true; ChangeTracking = $false; Native = $true; Actual = $actual }
    }
    if ($NestedSqlParentVmName) {
        if ($NestedSqlParentVmName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { throw 'Nested SQL parent VM name is invalid.' }
        $parentId = "/subscriptions/$script:DemoSubscription/resourceGroups/$infraRg/providers/Microsoft.Compute/virtualMachines/$NestedSqlParentVmName"
        if ($parentId -in $machines.Id) {
            $parent = @($machines | Where-Object Id -eq $parentId)
            if ($parent.Count -ne 1 -or -not $parent[0].Actual -or $parent[0].OsType -ne 'Windows') {
                throw 'Configured nested SQL parent must be one retained Windows VM.'
            }
        } else {
            $parent = @($vmRecords | Where-Object id -eq $parentId)
            if ($parent.Count -ne 1 -or $parent[0].storageProfile.osDisk.osType -ne 'Windows') {
                throw "Configured nested SQL parent $NestedSqlParentVmName is missing or is not a Windows VM in $infraRg."
            }
            $machines += [pscustomobject]@{ Name = $NestedSqlParentVmName; Id = $parentId; ArcId = $null
                OsType = 'Windows'; Monitor = $false; VmInsights = $false; ChangeTracking = $false; Native = $true; Actual = $parent[0] }
        }
    }
    $keptParked = @()
    foreach ($name in $KeepParkedVmNames) {
        if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$' -or $name -in $machines.Name -or $name -in $keptParked.Name) {
            throw 'Keep-parked VM names must be valid, unique and outside the active retained fleet.'
        }
        $id = "/subscriptions/$script:DemoSubscription/resourceGroups/$infraRg/providers/Microsoft.Compute/virtualMachines/$name"
        $actual = @($vmRecords | Where-Object id -eq $id)
        if ($actual.Count -ne 1 -or $actual[0].powerState -ne 'VM deallocated') {
            throw "Explicit keep-parked VM $name must exist in $infraRg and be deallocated; no start or guest command will be attempted."
        }
        $keptParked += [pscustomobject]@{ Name = $name; Id = $id; Actual = $actual[0]; KeepParked = $true }
        Write-Verbose "Leaving explicitly configured VM $name deallocated."
    }
    $unknown = @($vmRecords | Where-Object { $_.id -notin $machines.Id -and $_.id -notin $keptParked.Id })
    if ($unknown) { throw "VMs outside the retained deployment manifests found in $infraRg`: $($unknown.name -join ', '). Refusing to manage an ambiguous fleet." }
    foreach ($machine in $machines | Where-Object { $_.Actual }) {
        if ($machine.OsType -ne $machine.Actual.storageProfile.osDisk.osType) { throw "OS metadata differs from manifest for $($machine.Name)." }
    }
    return [pscustomobject]@{ ArcRg = $arcRg; InfraRg = $infraRg; Machines = $machines; ContainerAppIds = $appIds
        AksClusterIds = $clusterIds; Outputs = $deployments[0].properties.outputs; Resources = $resources; ParkedMachines = $keptParked }
}

function Get-DemoNestedSqlGuestConfig {
    [CmdletBinding()]
    param([AllowNull()][System.Collections.IDictionary]$Skin)
    if (-not $Skin -or -not $Skin.Contains('nestedSqlGuest')) { return $null }
    $config = $Skin.nestedSqlGuest
    if ($config -isnot [System.Collections.IDictionary] -or $config.enabled -isnot [bool]) {
        throw 'Skin nestedSqlGuest must be an object with a boolean enabled field.'
    }
    if (-not $config.enabled) { return $null }
    foreach ($key in 'parentVmName', 'guestVmName', 'arcMachineName') {
        if ([string]$config[$key] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') {
            throw "Enabled nestedSqlGuest requires a valid $key."
        }
    }
    # The parent needs a nested-virtualization-capable size (B-series cannot) and a data disk for the guest and media.
    $parentSize = if ([string]::IsNullOrWhiteSpace([string]$config['parentVmSize'])) { 'Standard_D4s_v5' } else { [string]$config['parentVmSize'] }
    if ($parentSize -cnotmatch '^Standard_[A-Za-z0-9_]{2,40}$') { throw 'Skin nestedSqlGuest.parentVmSize must be an Azure VM size such as Standard_D4s_v5.' }
    $parentDiskGb = if ($null -eq $config['parentDataDiskGb']) { 128 } else { $config['parentDataDiskGb'] }
    if (($parentDiskGb -isnot [int] -and $parentDiskGb -isnot [long]) -or $parentDiskGb -lt 64 -or $parentDiskGb -gt 4095) {
        throw 'Skin nestedSqlGuest.parentDataDiskGb must be an integer from 64 to 4095.'
    }
    $parentDiskType = if ([string]::IsNullOrWhiteSpace([string]$config['parentDataDiskStorageAccountType'])) { 'StandardSSD_LRS' } else { [string]$config['parentDataDiskStorageAccountType'] }
    if ($parentDiskType -cnotin @('Standard_LRS', 'StandardSSD_LRS', 'Premium_LRS')) {
        throw 'Skin nestedSqlGuest.parentDataDiskStorageAccountType must be Standard_LRS, StandardSSD_LRS or Premium_LRS.'
    }
    [pscustomobject]@{
        ParentVmName = [string]$config.parentVmName
        GuestVmName = [string]$config.guestVmName
        ArcMachineName = [string]$config.arcMachineName
        ParentVmSize = $parentSize
        ParentDataDiskGb = [int]$parentDiskGb
        ParentDataDiskStorageAccountType = $parentDiskType
    }
}

function Invoke-DemoNestedSqlGuest {
    <#
    .SYNOPSIS
        Starts or gracefully stops the nested Hyper-V guest from the parent VM through Run Command.
    .DESCRIPTION
        -AllowAbsent (Stop only) treats a parent without the Hyper-V role, or without a guest of that name, as already
        stopped instead of an error. Remove uses it: the parent and its disks are deleted anyway, so a guest that was
        never built is not worth a failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ParentMachine,
        [Parameter(Mandatory)][string]$GuestVmName,
        [Parameter(Mandatory)][ValidateSet('Start', 'Stop')][string]$Action,
        [switch]$AsJob,
        [switch]$AllowAbsent,
        [ValidateRange(30, 3600)][int]$TimeoutSeconds = 900
    )
    if ($ParentMachine.OsType -ne 'Windows') { throw 'Nested SQL lifecycle requires the configured Windows parent VM.' }
    if ($GuestVmName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { throw 'Nested SQL guest VM name is invalid.' }
    if ($AllowAbsent -and $Action -ne 'Stop') { throw '-AllowAbsent only applies to Stop: a guest that must start has to exist.' }
    $guestScript = @'
$ErrorActionPreference = 'Stop'
$guestName = '__GUEST_NAME__'
$action = '__ACTION__'
$allowAbsent = '__ALLOW_ABSENT__' -eq 'true'
if ($allowAbsent -and -not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    'The Hyper-V role is not installed on the parent, so there is no guest to stop.'
    'ARC_DEMO_OK'
    return
}
$guest = @(Get-VM -Name $guestName -ErrorAction $(if ($allowAbsent) { 'SilentlyContinue' } else { 'Stop' }))
if ($guest.Count -eq 0 -and $allowAbsent) {
    "No Hyper-V guest named $guestName exists on the parent, so there is nothing to stop."
    'ARC_DEMO_OK'
    return
}
if ($guest.Count -ne 1) { throw "Expected exactly one Hyper-V guest named $guestName." }
$guest = $guest[0]
if ($action -eq 'Start') {
    if ($guest.State -in @('Off', 'Saved')) { Start-VM -VM $guest | Out-Null }
    elseif ($guest.State -notin @('Running', 'Starting')) { throw "Guest is in unexpected state $($guest.State)." }
    $expectedState = 'Running'
} else {
    if ($guest.State -eq 'Running') {
        $stopJob = Stop-VM -VM $guest -AsJob -Confirm:$false
        if (-not (Wait-Job -Job $stopJob -Timeout 300)) { throw 'Nested SQL graceful shutdown is still pending; no forced stop.' }
        try { Receive-Job -Job $stopJob -ErrorAction Stop | Out-Null }
        finally { Remove-Job -Job $stopJob -ErrorAction Stop }
    }
    elseif ($guest.State -notin @('Off', 'Stopping')) { throw "Guest is in unexpected state $($guest.State)." }
    $expectedState = 'Off'
}
$deadline = (Get-Date).AddMinutes(5)
do {
    $guest = Get-VM -Name $guestName -ErrorAction Stop
    if ($guest.State -eq $expectedState) { break }
    if ((Get-Date) -ge $deadline) { throw "Nested SQL guest did not reach $expectedState within five minutes." }
    Start-Sleep -Seconds 5
} while ($true)
'ARC_DEMO_OK'
'@
    $guestScript = $guestScript.Replace('__GUEST_NAME__', $GuestVmName).Replace('__ACTION__', $Action).Replace('__ALLOW_ABSENT__', $(if ($AllowAbsent) { 'true' } else { 'false' }))
    Invoke-DemoGuestCommand -Machine $ParentMachine -Script $guestScript -AsJob:$AsJob -TimeoutSeconds $TimeoutSeconds
}

function Wait-DemoNestedSqlArcConnected {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArcResourceGroup,
        [Parameter(Mandatory)][string]$ArcMachineName,
        [ValidateRange(1, 7200)][int]$TimeoutSeconds = 900
    )
    $resourceGroup = $ArcResourceGroup
    Wait-Until -Message "nested SQL Arc machine $ArcMachineName connected" -TimeoutSeconds $TimeoutSeconds -Condition {
        $machine = Invoke-DemoAz -Arguments @('connectedmachine', 'show', '-g', $resourceGroup, '-n', $ArcMachineName, '-o', 'json') | ConvertFrom-Json
        $machine.status -eq 'Connected'
    } | Out-Null
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

function Get-DemoRevisionSummary {
    <#
    .SYNOPSIS
        The active revision names of one Container App, or a short reason when they cannot be read. Read-only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InfraRg, [Parameter(Mandatory)][string]$Name)
    try {
        $active = @(@(Invoke-DemoAz -Arguments @('containerapp', 'revision', 'list', '-g', $InfraRg, '-n', $Name, '-o', 'json') | ConvertFrom-Json) |
            Where-Object { $_.properties.active } | ForEach-Object { $_.name })
        [pscustomobject]@{ Readable = $true; Active = $active; Message = '' }
    } catch { [pscustomobject]@{ Readable = $false; Active = @(); Message = $_.Exception.Message } }
}

function Get-DemoParkPreview {
    <#
    .SYNOPSIS
        One line per workload that Hibernate would park, for its -WhatIf preview.
    .DESCRIPTION
        Read-only: the only call it makes is listing each Container App's revisions. The lines come from the inventory
        and network state the script has already read, so the preview says what a real run would do to this estate
        instead of one generic sentence.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory, [AllowNull()]$NestedSqlGuest, [AllowNull()]$Network)
    $lines = [System.Collections.Generic.List[string]]::new()
    $parked = @('VM deallocated', 'VM deallocating')
    $machines = @($Inventory.Machines)
    if ($NestedSqlGuest) {
        $parent = $machines | Where-Object { $_.Name -ceq $NestedSqlGuest.ParentVmName } | Select-Object -First 1
        $state = if ($parent -and $parent.Actual) { [string]$parent.Actual.powerState } else { 'unreadable' }
        $lines.Add($(if ($state -eq 'VM running') {
            "Nested SQL guest $($NestedSqlGuest.GuestVmName): stopped gracefully first, through Run Command on its parent $($NestedSqlGuest.ParentVmName) (up to 15 minutes)."
        } else { "Nested SQL guest $($NestedSqlGuest.GuestVmName): no stop command, its parent $($NestedSqlGuest.ParentVmName) is $state." }))
    }
    foreach ($machine in $machines) {
        $state = if ($machine.Actual.powerState) { [string]$machine.Actual.powerState } else { 'power state unknown' }
        $lines.Add($(if ($machine.Actual.powerState -in $parked) { "VM $($machine.Name): $state, already parked." } else { "VM $($machine.Name): $state -> deallocate (submitted without waiting)." }))
    }
    foreach ($id in @($Inventory.AksClusterIds)) { $lines.Add("AKS $(($id -split '/')[-1]): stopped if it is running.") }
    foreach ($id in @($Inventory.ContainerAppIds)) {
        $name = ($id -split '/')[-1]
        $summary = Get-DemoRevisionSummary -InfraRg $Inventory.InfraRg -Name $name
        $lines.Add($(if (-not $summary.Readable) { "Container App ${name}: revisions could not be read ($($summary.Message))." }
            elseif ($summary.Active.Count) { "Container App ${name}: active revision(s) $($summary.Active -join ', ') -> deactivate." }
            else { "Container App ${name}: no active revision, nothing to deactivate." }))
    }
    if (-not $Network) { $lines.Add('Network: not inspected.') }
    elseif (-not $Network.SafeToRemove) { $lines.Add("Network: left alone ($($Network.ConflictMessage)) NAT/PIP costs may remain.") }
    else {
        $names = @(
            if ($Network.Subnet.natGateway.id -eq $Network.NatId) { 'the subnet association' }
            if ($Network.Nat) { "NAT gateway $(($Network.NatId -split '/')[-1])" }
            if ($Network.PublicIp) { "public IP $(($Network.PublicIpId -split '/')[-1])" })
        $lines.Add($(if ($names.Count) { "Network: after compute has stopped, removed in this order: $($names -join ', ')." } else { 'Network: no NAT association, NAT gateway or public IP to remove.' }))
    }
    $lines.Add('Then: the Hibernated readiness check runs, and every required cost-state row must pass.')
    $lines.ToArray()
}

function Get-DemoWakePreview {
    <#
    .SYNOPSIS
        One line per step that Activate would take, for its -WhatIf preview.
    .DESCRIPTION
        Read-only: the only call it makes is listing each Container App's revisions. Nothing is started, created or tagged.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory, [AllowNull()]$NestedSqlGuest, [AllowNull()]$Network, [int]$GuestCheckMinutes = 12)
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Network) {
        $pipName = ($Network.PublicIpId -split '/')[-1]
        $natName = ($Network.NatId -split '/')[-1]
        $lines.Add($(if ($Network.PublicIp) { "Public IP ${pipName}: present." } else { "Public IP ${pipName}: absent -> created (Standard, static) before any VM starts." }))
        $lines.Add($(if ($Network.Nat) { "NAT gateway ${natName}: present." } else { "NAT gateway ${natName}: absent -> created with that public IP." }))
        $lines.Add($(if ($Network.Subnet.natGateway.id -eq $Network.NatId) { 'Subnet snet-vms: already attached to the NAT gateway.' } else { 'Subnet snet-vms: attached to the NAT gateway.' }))
        $lines.Add('The NAT gateway and public IP carry the lab tags (owner, purpose, costcenter, env and the skin''s own).')
    } else { $lines.Add('Network: not inspected.') }
    foreach ($machine in @($Inventory.Machines)) {
        $state = [string]$machine.Actual.powerState
        $lines.Add($(switch ($state) {
            'VM running' { "VM $($machine.Name): running, left alone." }
            'VM starting' { "VM $($machine.Name): already starting, waited for." }
            default { "VM $($machine.Name): $(if ($state) { $state } else { 'power state unknown' }) -> start." }
        }))
    }
    foreach ($machine in @($Inventory.ParkedMachines | Where-Object { $_ })) { $lines.Add("VM $($machine.Name): kept deallocated (operations.keepParkedVmNames); never started.") }
    if ($NestedSqlGuest) {
        $lines.Add("Nested SQL guest $($NestedSqlGuest.GuestVmName): started through Run Command on its parent $($NestedSqlGuest.ParentVmName) as a concurrent job (5-minute budget), then its Arc connection is awaited.")
    }
    foreach ($id in @($Inventory.AksClusterIds)) { $lines.Add("AKS $(($id -split '/')[-1]): started if it is stopped.") }
    foreach ($id in @($Inventory.ContainerAppIds)) {
        $name = ($id -split '/')[-1]
        $summary = Get-DemoRevisionSummary -InfraRg $Inventory.InfraRg -Name $name
        $lines.Add($(if (-not $summary.Readable) { "Container App ${name}: revisions could not be read ($($summary.Message))." }
            elseif ($summary.Active.Count) { "Container App ${name}: active revision(s) $($summary.Active -join ', ') left alone; no fault reset." }
            else { "Container App ${name}: no active revision -> its latest revision is activated; no fault reset." }))
    }
    $lines.Add("Then one shared wait of up to $GuestCheckMinutes minutes for every host: VM running, Arc Connected and, for monitored hosts, a Heartbeat after the start.")
    $lines.ToArray()
}

function Write-DemoResultFile {
    <#
    .SYNOPSIS
        Writes the JSON result of an Activate or Hibernate run, for the finally block of the script.
    .DESCRIPTION
        A result that still reads `running` here means the run was stopped (Ctrl+C or a host stop skips the catch block but
        not finally), so it is recorded as `interrupted`: steps already submitted may still be in progress. The write is
        guarded because this runs while an error may already be on its way out: a file that cannot be written only warns,
        so it can never replace the real failure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Result, [Parameter(Mandatory)][string]$Path)
    if ($Result['status'] -eq 'running') {
        $Result['status'] = 'interrupted'
        $Result['error'] = 'The run was stopped before it finished. Steps already submitted may still be in progress: read the current state before running it again.'
    }
    try { $Result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8 }
    catch { Write-Warning "The result file $Path could not be written: $($_.Exception.Message)" }
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

function Get-DemoStaleManifestDeployments {
    <#
    .SYNOPSIS
        Selects this demo's own Deploy-ArcDemo subscription deployment records for one Arc resource group.
    .DESCRIPTION
        Only finished records named arc-demo-<yyyyMMdd-HHmmss> whose outputs (or, for failed/canceled runs,
        parameters) name the Arc resource group qualify. Policy, SRE, nested module and foreign records
        are never returned.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Deployments, [Parameter(Mandatory)][string]$ArcResourceGroup)
    @($Deployments | Where-Object {
        $_.name -cmatch '^arc-demo-\d{8}-\d{6}$' -and
        $_.properties.provisioningState -in @('Succeeded', 'Failed', 'Canceled') -and
        ($_.properties.outputs.arcResourceGroup.value -eq $ArcResourceGroup -or $_.properties.parameters.arcResourceGroup.value -eq $ArcResourceGroup)
    })
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
            $tier = $observed.Trim()
            $declare = if ($tier -in @('Standard_LRS', 'StandardSSD_LRS')) {
                "To keep the disk as it is, declare what exists: set compute.osDiskStorageAccountType to $tier in the private skin (or pass -OsDiskStorageAccountType $tier) and, when a nested SQL parent is configured, nestedSqlGuest.parentDataDiskStorageAccountType to the tier of its data disk."
            } else { "Deploy can only declare Standard_LRS or StandardSSD_LRS, so a $tier disk needs a separate decision." }
            throw "OS disk tier mismatch on $($machine.name): the disk is $tier and this run requests $StorageAccountType. Deploy never converts a disk. $declare A tenant governance automation can convert a parked estate's disks to Standard HDD on its own (docs/troubleshooting.md, 'The OS disk tier changed by itself'). Converting a disk back is a separately approved stop/deallocate/restart window."
        }
    }
}

function Get-DemoGuestTarget {
    <#
    .SYNOPSIS
        Resolves one retained Windows VM from the exact demo inventory for a guest-side
        operation. The configured nested SQL parent may be a separately created VM;
        every other target must be a fleet member.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NamePrefix,
        [Parameter(Mandatory)][AllowNull()][System.Collections.IDictionary]$Skin,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$')][string]$MachineName
    )
    $nested = Get-DemoNestedSqlGuestConfig -Skin $Skin
    $inventory = Get-DemoInventory $NamePrefix -NestedSqlParentVmName $(if ($nested) { $nested.ParentVmName } else { '' }) `
        -KeepParkedVmNames @(Get-DemoSkinValue $Skin 'operations.keepParkedVmNames' @())
    Assert-DemoSkinInventory $Skin $inventory
    $targets = @($inventory.Machines | Where-Object Name -eq $MachineName)
    $isParent = $nested -and $MachineName -eq $nested.ParentVmName
    if ($targets.Count -ne 1 -or ($targets[0].Native -and -not $isParent) -or $targets[0].OsType -ne 'Windows' -or
        -not $targets[0].Actual -or $targets[0].Actual.storageProfile.osDisk.osType -ne 'Windows') {
        throw "Guest target $MachineName must be one retained Windows VM from the demo inventory (a fleet member or the configured nested SQL parent); no native/unknown VM or OS guess."
    }
    [pscustomobject]@{ Inventory = $inventory; Target = $targets[0]; NestedSqlGuest = $nested }
}

function Get-DemoMediaManifest {
    <#
    .SYNOPSIS
        Loads and validates config\demo-media.json: public Microsoft installer media pinned
        by size and SHA-256. Nothing in it is secret; acceptance is recorded privately.
    #>
    [CmdletBinding()]
    param(
        [string]$Path = '',
        [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    )
    $manifestPath = if ([string]::IsNullOrWhiteSpace($Path)) { Join-Path $RepoRoot 'config\demo-media.json' }
        elseif ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $RepoRoot $Path }
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Media manifest not found: $manifestPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable -Depth 10
    if ($manifest -isnot [System.Collections.IDictionary] -or $manifest.schemaVersion -ne 1 -or $manifest.media -isnot [System.Collections.IDictionary]) {
        throw "Invalid media manifest '$manifestPath': expected schemaVersion 1 and a media object."
    }
    foreach ($id in $manifest.media.Keys) {
        $item = $manifest.media[$id]
        $problem = if ($id -cnotmatch '^[a-z0-9][a-z0-9-]{1,50}$') { 'id must be lowercase letters, digits and hyphens' }
            elseif ($item -isnot [System.Collections.IDictionary]) { 'entry must be an object' }
            elseif ([string]$item.fileName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,100}\.iso$') { 'fileName must be a plain .iso name' }
            elseif ([string]$item.url -cnotmatch '^https://(download|go)\.microsoft\.com/') { 'url must be a download.microsoft.com or go.microsoft.com address' }
            elseif (($item.bytes -isnot [int] -and $item.bytes -isnot [long]) -or $item.bytes -le 0) { 'bytes must be a positive integer' }
            elseif ([string]$item.sha256 -cnotmatch '^[A-Fa-f0-9]{64}$') { 'sha256 must be 64 hex characters' }
            elseif ([string]$item.licenseUrl -cnotmatch '^https://') { 'licenseUrl must be an https address' }
            elseif ([string]$item.acceptanceSwitch -cnotin @('AcceptWindowsEvaluationTerms', 'AcceptSqlDeveloperTerms')) { 'acceptanceSwitch must be AcceptWindowsEvaluationTerms or AcceptSqlDeveloperTerms' }
        if ($problem) { throw "Media manifest entry '$id' is invalid: $problem." }
        [pscustomobject]@{
            Id = [string]$id; DisplayName = [string]$item.displayName; FileName = [string]$item.fileName; Url = [string]$item.url
            Bytes = [int64]$item.bytes; Sha256 = ([string]$item.sha256).ToUpperInvariant(); LicenseUrl = [string]$item.licenseUrl
            Scope = [string]$item.scope; AcceptanceSwitch = [string]$item.acceptanceSwitch
        }
    }
}

function Invoke-DemoGuestAction {
    <#
    .SYNOPSIS
        Runs one action of a repo guest script (scripts\guest\*.ps1, Windows PowerShell 5.1 as SYSTEM)
        through classic Run Command and returns its single ARC_GUEST_RESULT= JSON object.
        Unlike Invoke-DemoGuestCommand the result is returned, and the payload is a repo file
        that can be unit-tested offline. Settings travel as base64 JSON, never on a command line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]+$')][string]$Action,
        [hashtable]$Settings = @{},
        [ValidateRange(60, 7200)][int]$TimeoutSeconds = 900
    )
    if ($Machine.OsType -ne 'Windows') { throw "Guest actions need a Windows machine, not $($Machine.Name)." }
    $source = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ScriptPath).ProviderPath)
    $encodedSource = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($source))
    $encodedSettings = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($Settings | ConvertTo-Json -Depth 8 -Compress)))
    $wrapper = @'
$ErrorActionPreference = 'Stop'
$file = Join-Path $env:TEMP ('arc-demo-guest-' + [guid]::NewGuid().ToString() + '.ps1')
try {
    [IO.File]::WriteAllText($file, [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SOURCE__')), [Text.UTF8Encoding]::new($false))
    & $file -Action '__ACTION__' -SettingsBase64 '__SETTINGS__'
} catch {
    $message = $_.Exception.Message
    'ARC_GUEST_ERROR=' + (@{ message = $message.Substring(0, [Math]::Min(400, $message.Length)) } | ConvertTo-Json -Compress)
} finally {
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}
'@
    $wrapper = $wrapper.Replace('__SOURCE__', $encodedSource).Replace('__ACTION__', $Action).Replace('__SETTINGS__', $encodedSettings)
    $path = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($path, $wrapper, [System.Text.UTF8Encoding]::new($false))
        $job = Start-DemoAzJob -Arguments @('vm', 'run-command', 'invoke', '--ids', $Machine.Id,
            '--command-id', 'RunPowerShellScript', '--scripts', "@$path", '-o', 'json', '--only-show-errors')
        $raw = Receive-DemoJobs -Jobs @($job) -TimeoutSeconds $TimeoutSeconds -PassThru | ConvertFrom-Json
    } finally { [System.IO.File]::Delete($path) }
    $entries = @($raw.value | Where-Object { $_ })
    $stdout = @($entries | Where-Object { $_.code -match '^ComponentStatus/StdOut/succeeded$|^ProvisioningState/succeeded$' } | ForEach-Object { $_.message }) -join "`n"
    $errorLines = @($stdout -split '\r?\n' | Where-Object { $_.StartsWith('ARC_GUEST_ERROR=') })
    if ($errorLines.Count -eq 1) {
        throw "Guest action $Action failed on $($Machine.Name): $(($errorLines[0].Substring('ARC_GUEST_ERROR='.Length) | ConvertFrom-Json).message)"
    }
    $resultLines = @($stdout -split '\r?\n' | Where-Object { $_.StartsWith('ARC_GUEST_RESULT=') })
    if (-not $entries -or @($entries | Where-Object { $_.code -match 'failed|error' -or $_.level -eq 'Error' }).Count -or
        $stdout -notmatch '(?m)^ARC_DEMO_OK\r?$' -or $resultLines.Count -ne 1) {
        throw "Guest action $Action returned no verified result on $($Machine.Name); inspect the VM and its Run Command state before retrying."
    }
    $resultLines[0].Substring('ARC_GUEST_RESULT='.Length) | ConvertFrom-Json
}

function Invoke-DemoGuestCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine,
        [Parameter(Mandatory, ParameterSetName = 'Submit')][string]$Script,
        [Parameter(Mandatory, ParameterSetName = 'Receive')]$Job,
        [Parameter(ParameterSetName = 'Submit')][switch]$AsJob,
        [switch]$PassThru,
        [switch]$AllowPending,
        [ValidateRange(30, 3600)][int]$TimeoutSeconds = 900
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
        $result = Receive-DemoJobs -Jobs @($Job) -TimeoutSeconds $TimeoutSeconds -PassThru | ConvertFrom-Json
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
        # Say what is awaited only when something is: a job that has already finished must not print a 15-minute budget.
        while (@($Jobs | Where-Object State -in @('NotStarted', 'Running')).Count -and (Get-Date) -lt $deadline) {
            $remaining = [Math]::Max(0, [int]($deadline - (Get-Date)).TotalSeconds)
            Write-Step "Waiting for guest/extension jobs: $(@($Jobs | Where-Object State -in @('NotStarted', 'Running')).Name -join ', ') ($remaining s remaining)"
            $Jobs | Wait-Job -Timeout ([Math]::Min(15, [Math]::Max(1, $remaining))) | Out-Null
        }
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

function Wait-DemoJobs {
    <#
    .SYNOPSIS
        Waits for already-submitted jobs until they finish or the deadline passes, naming every job still pending in each
        progress line. It neither receives nor removes them: Invoke-DemoGuestCommand -Job and Receive-DemoJobs do that.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Jobs, [ValidateRange(0, 7200)][int]$TimeoutSeconds = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $pending = @($Jobs | Where-Object State -in @('NotStarted', 'Running'))
        if (-not $pending.Count -or (Get-Date) -ge $deadline) { return }
        $remaining = [Math]::Max(0, [int]($deadline - (Get-Date)).TotalSeconds)
        Write-Step "Waiting for guest/extension jobs: $($pending.Name -join ', ') ($remaining s remaining)"
        $pending | Wait-Job -Timeout ([Math]::Min(15, [Math]::Max(1, $remaining))) | Out-Null
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
        # Optional per-entry overrides; absent means the shared default size and no data disks.
        if ($null -ne $entry.vmSize -and $entry.vmSize -cnotmatch '^Standard_[A-Za-z0-9_]{2,40}$') { throw "Fleet $($entry.name).vmSize must be an Azure VM size such as Standard_D4s_v5." }
        if ($null -ne $entry.securityType -and $entry.securityType -cnotin @('Standard', 'TrustedLaunch')) { throw "Fleet $($entry.name).securityType must be Standard or TrustedLaunch." }
        if ($null -ne $entry.dataDisks) {
            if ($entry.dataDisks -isnot [array]) { throw "Fleet $($entry.name).dataDisks must be a JSON array." }
            $diskNames = @()
            $diskLuns = @()
            foreach ($disk in $entry.dataDisks) {
                if ([string]$disk.name -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$' -or $disk.name -in $diskNames) { throw "Fleet $($entry.name).dataDisks names must be unique, lowercase letters/digits/hyphens." }
                $diskNames += $disk.name
                if (($disk.lun -isnot [int] -and $disk.lun -isnot [long]) -or $disk.lun -lt 0 -or $disk.lun -gt 63 -or $disk.lun -in $diskLuns) { throw "Fleet $($entry.name).dataDisks lun must be a unique integer from 0 to 63." }
                $diskLuns += $disk.lun
                if (($disk.sizeGb -isnot [int] -and $disk.sizeGb -isnot [long]) -or $disk.sizeGb -lt 4 -or $disk.sizeGb -gt 4095) { throw "Fleet $($entry.name).dataDisks sizeGb must be an integer from 4 to 4095." }
                if ($null -ne $disk.storageAccountType -and $disk.storageAccountType -cnotin @('Standard_LRS', 'StandardSSD_LRS', 'Premium_LRS')) { throw "Fleet $($entry.name).dataDisks storageAccountType must be Standard_LRS, StandardSSD_LRS or Premium_LRS." }
                if ($null -ne $disk.caching -and $disk.caching -cnotin @('None', 'ReadOnly', 'ReadWrite')) { throw "Fleet $($entry.name).dataDisks caching must be None, ReadOnly or ReadWrite." }
            }
        }
    }
}

function Get-DemoFleetVmSize {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$DefaultVmSize)
    if ([string]::IsNullOrWhiteSpace([string]$Entry.vmSize)) { $DefaultVmSize } else { [string]$Entry.vmSize }
}

function Get-DemoFleetWithNestedParent {
    <#
    .SYNOPSIS
        Declares the nested SQL parent's size, data disk and security type from the
        skin's nestedSqlGuest block, so the parent is deployed correctly once and a
        redeploy converges instead of reverting it. Explicit fleet-entry values win.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Fleet, [AllowNull()]$NestedSqlGuest)
    foreach ($entry in $Fleet) {
        if (-not $NestedSqlGuest -or $entry.name -ne $NestedSqlGuest.ParentVmName -or $entry.deploymentMode -ne 'azure-vm' -or $entry.osType -ne 'Windows') {
            $entry
            continue
        }
        $declared = [ordered]@{}
        if ($entry -is [System.Collections.IDictionary]) { foreach ($key in $entry.Keys) { $declared[$key] = $entry[$key] } }
        else { foreach ($property in $entry.PSObject.Properties) { $declared[$property.Name] = $property.Value } }
        if ([string]::IsNullOrWhiteSpace([string]$declared['vmSize'])) { $declared['vmSize'] = $NestedSqlGuest.ParentVmSize }
        if ([string]::IsNullOrWhiteSpace([string]$declared['securityType'])) { $declared['securityType'] = 'Standard' }
        if ($null -eq $declared['dataDisks']) {
            $declared['dataDisks'] = @([ordered]@{ name = 'nested-data'; lun = 0; sizeGb = $NestedSqlGuest.ParentDataDiskGb; storageAccountType = $NestedSqlGuest.ParentDataDiskStorageAccountType; caching = 'None' })
        }
        [pscustomobject]$declared
    }
}

function Get-DemoFleetWithoutRetainedSecurityType {
    <#
    .SYNOPSIS
        Omits securityType from fleet entries whose VM already exists. Compute fixes the
        security type when a VM is created and rejects a redeploy that sends it again
        (PropertyChangeNotAllowed), so only a VM that is being created declares it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Fleet,
        [AllowEmptyCollection()][string[]]$ExistingVmName = @()
    )
    foreach ($entry in $Fleet) {
        $isTable = $entry -is [System.Collections.IDictionary]
        $name = if ($isTable) { $entry['name'] } else { $entry.name }
        $declaresType = if ($isTable) { $entry.Contains('securityType') } else { $null -ne $entry.PSObject.Properties['securityType'] }
        if (-not $declaresType -or [string]$name -notin $ExistingVmName) {
            $entry
            continue
        }
        $kept = [ordered]@{}
        if ($isTable) { foreach ($key in $entry.Keys) { if ($key -ne 'securityType') { $kept[$key] = $entry[$key] } } }
        else { foreach ($property in $entry.PSObject.Properties) { if ($property.Name -ne 'securityType') { $kept[$property.Name] = $property.Value } } }
        [pscustomobject]$kept
    }
}

function Assert-DemoRetainedVmShape {
    <#
    .SYNOPSIS
        Refuses a redeploy that would silently resize an existing VM or detach or
        convert its data disks. Deployment preserves retained VMs; a resize or disk
        change is a separate, approved operation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Machines,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ExistingVms,
        [Parameter(Mandatory)][string]$DefaultVmSize
    )
    foreach ($machine in $Machines) {
        $existing = @($ExistingVms | Where-Object { $_.name -eq $machine.name }) | Select-Object -First 1
        if (-not $existing) { continue }
        $wanted = Get-DemoFleetVmSize -Entry $machine -DefaultVmSize $DefaultVmSize
        $actual = [string]$existing.hardwareProfile.vmSize
        if (-not $actual) { throw "Cannot read the size of existing VM $($machine.name); inspect it before deployment." }
        if ($actual -ne $wanted) {
            throw "VM $($machine.name) is $actual but this deployment requests $wanted. Deployment never resizes an existing VM. Declare the existing size (fleet vmSize, or nestedSqlGuest.parentVmSize for the nested parent), or resize it separately in an approved window with the VM deallocated."
        }
        $declared = @($machine.dataDisks | Where-Object { $_ })
        foreach ($disk in @($existing.storageProfile.dataDisks | Where-Object { $_ })) {
            $match = @($declared | Where-Object { "$($machine.name)-$($_.name)" -eq $disk.name }) | Select-Object -First 1
            if (-not $match) {
                throw "VM $($machine.name) has data disk $($disk.name) that this deployment does not declare, so it would be detached. Declare it in the fleet entry dataDisks (name without the '$($machine.name)-' prefix, lun, sizeGb, storageAccountType) or detach it separately first."
            }
            $wantedType = if ($match.storageAccountType) { [string]$match.storageAccountType } else { 'StandardSSD_LRS' }
            $actualType = [string]$disk.managedDisk.storageAccountType
            $actualSize = $disk.diskSizeGb
            $diskId = [string]$disk.managedDisk.id
            if ((-not $actualType -or -not $actualSize) -and $diskId) {
                # A deallocated VM's model reports neither the size nor the tier of its disks; the disk resource always does.
                $resource = Invoke-DemoAz -Arguments @('disk', 'show', '--ids', $diskId, '-o', 'json') | ConvertFrom-Json
                if (-not $actualType) { $actualType = [string]$resource.sku.name }
                if (-not $actualSize) { $actualSize = $resource.diskSizeGb }
            }
            if ([int]$disk.lun -ne [int]$match.lun -or ($actualSize -and [int64]$actualSize -ne [int64]$match.sizeGb) -or ($actualType -and $actualType -ne $wantedType)) {
                $governance = if ($actualType -and $actualType -ne $wantedType) { " A tenant governance automation can convert a parked estate's disks to Standard HDD on its own (docs/troubleshooting.md, 'The OS disk tier changed by itself')." } else { '' }
                throw "Data disk $($disk.name) on $($machine.name) differs from its declaration (existing lun $($disk.lun), $actualSize GiB, $actualType). Deployment never resizes, converts or moves a retained data disk; declare the existing values: nestedSqlGuest.parentDataDiskGb and parentDataDiskStorageAccountType for the nested SQL parent, or the fleet entry's dataDisks lun, sizeGb and storageAccountType for another VM.$governance"
            }
        }
    }
}

function Get-DemoVmSizeDemand {
    <#
    .SYNOPSIS
        Counts the VMs that still need allocation per distinct size, as the VmSize/VmCount
        requirements Test-DemoComputeCapacity -Requirements takes. The shared default size is
        always included (count 0 when unused) so its SKU restrictions are still checked.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Machines,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ExistingVms,
        [Parameter(Mandatory)][string]$DefaultVmSize,
        [Parameter(Mandatory)][string]$Location
    )
    $demand = [ordered]@{ $DefaultVmSize = 0 }
    foreach ($machine in $Machines) {
        $size = Get-DemoFleetVmSize -Entry $machine -DefaultVmSize $DefaultVmSize
        if (-not $demand.Contains($size)) { $demand[$size] = 0 }
        if (-not @($ExistingVms | Where-Object { $_.name -eq $machine.name -and $_.hardwareProfile.vmSize -eq $size -and $_.location -eq $Location }).Count) { $demand[$size]++ }
    }
    foreach ($size in $demand.Keys) { [pscustomobject]@{ VmSize = $size; VmCount = $demand[$size] } }
}

function ConvertTo-DemoQuotaNumber {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$QuotaName, [Parameter(Mandatory)][string]$Field, [AllowNull()][object]$Value)
    # Azure CLI 2.91 returns vCPU usage as strings; '22' + 16 concatenates to '2216' instead of adding.
    $number = 0
    if ($null -eq $Value -or -not [int]::TryParse(([string]$Value).Trim(), [ref]$number)) {
        throw "Quota $QuotaName $Field '$Value' is not a whole number; the capacity check cannot continue."
    }
    $number
}

function Test-DemoComputeCapacity {
    <#
    .SYNOPSIS
        Read-only SKU restriction and regional/family vCPU quota check for every distinct VM size.
    .DESCRIPTION
        Use -VmSize/-AdditionalVmCount for one size, or -Requirements with objects that have VmSize and VmCount
        so sizes in the same family are added together before they are compared with that family's quota.
        This never changes a size or region and does not prove physical capacity.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Single')]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory, ParameterSetName = 'Single')][string]$VmSize,
        [Parameter(ParameterSetName = 'Single')][int]$AdditionalVmCount = 0,
        [Parameter(Mandatory, ParameterSetName = 'Multiple')][object[]]$Requirements
    )
    if ($PSCmdlet.ParameterSetName -eq 'Single') { $Requirements = @([pscustomobject]@{ VmSize = $VmSize; VmCount = $AdditionalVmCount }) }
    # One listing covers every size: the CLI downloads the whole regional SKU list however the result is filtered.
    Write-Step "Checking SKU restrictions and vCPU quota in $Location. The CLI downloads the whole regional SKU list, so this takes about 4 minutes and creates nothing."
    $skuList = @(Invoke-DemoAz -Arguments @('vm', 'list-skus', '-l', $Location, '--resource-type', 'virtualMachines', '--all', '-o', 'json') | ConvertFrom-Json)
    $demand = foreach ($size in $Requirements | Group-Object { ([string]$_.VmSize).Trim() }) {
        if (-not $size.Name) { throw 'Every capacity requirement needs a VM size.' }
        $sku = @($skuList | Where-Object name -eq $size.Name)
        if ($sku.Count -ne 1) { throw "SKU $($size.Name) is not uniquely available in $Location." }
        if (@($sku[0].restrictions | Where-Object type -eq 'Location').Count) {
            throw "SKU $($size.Name) has subscription/location restrictions in $Location. Choose another size or region explicitly; deployment never switches either on its own."
        }
        $cores = [int]($sku[0].capabilities | Where-Object name -eq 'vCPUs' | Select-Object -First 1).value
        if ($cores -lt 1) { throw "Unable to determine vCPU requirements for $($size.Name)." }
        if (-not $sku[0].family) { throw "Unable to determine the VM family for $($size.Name)." }
        $vmCount = [Math]::Max(0, [int](($size.Group | ForEach-Object { [int]$_.VmCount } | Measure-Object -Sum).Sum))
        [pscustomobject]@{ VmSize = $size.Name; Family = [string]$sku[0].family; VmCount = $vmCount; VCpus = $vmCount * $cores }
    }
    $usage = @(Invoke-DemoAz -Arguments @('vm', 'list-usage', '-l', $Location, '-o', 'json') | ConvertFrom-Json)
    $checks = @([pscustomobject]@{ Name = 'cores'; Sizes = @($demand) })
    $checks += foreach ($family in $demand | Group-Object Family) { [pscustomobject]@{ Name = $family.Name; Sizes = @($family.Group) } }
    foreach ($check in $checks) {
        $quota = @($usage | Where-Object { $_.name.value -eq $check.Name })
        if ($quota.Count -ne 1) { throw "Quota $($check.Name) could not be checked in $Location." }
        $used = ConvertTo-DemoQuotaNumber -QuotaName $check.Name -Field currentValue -Value $quota[0].currentValue
        $limit = ConvertTo-DemoQuotaNumber -QuotaName $check.Name -Field limit -Value $quota[0].limit
        $needed = [int](($check.Sizes | Measure-Object VCpus -Sum).Sum)
        $detail = (@($check.Sizes | Where-Object VmCount | ForEach-Object { "$($_.VmSize) x $($_.VmCount)" }) -join ', ')
        if ($used + $needed -gt $limit) {
            throw "Insufficient $($check.Name) vCPU quota in $Location`: $used in use + $needed needed ($detail) exceeds the limit of $limit. Request quota or reduce the fleet before deployment; deployment never switches VM size or region on its own."
        }
        Write-Ok "$($check.Name) vCPU quota: $used in use + $needed needed of $limit"
    }
    Write-Warn 'SKU restrictions and vCPU quota passed. This does not prove physical capacity; ARM what-if/validation is not an allocation guarantee.'
}

function Get-DemoDeploymentState {
    <#
    .SYNOPSIS
        Reads one subscription deployment's provisioning state and error; $null when it does not exist.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $raw = Invoke-DemoAz -Arguments @('deployment', 'sub', 'show', '--name', $Name, '--query', '{state:properties.provisioningState,error:properties.error}', '-o', 'json') -AllowNotFound
    $text = (@($raw) -join "`n").Trim()
    if (-not $text) { return $null }
    $text | ConvertFrom-Json
}

function Invoke-DemoSubscriptionDeployment {
    <#
    .SYNOPSIS
        Starts a subscription-scope deployment, then polls it with progress until it finishes.
    .DESCRIPTION
        One synchronous az deployment sub create held a single CLI call open for the whole build (17 to 54 minutes
        in practice): a client-side connection reset ended it with nothing to resume from, and a slow module (a VM
        waiting behind a vendor extension update, a Container Apps environment) left the console silent for tens
        of minutes. This submits with --no-wait, which returns as soon as Azure Resource Manager has accepted the
        request, then polls the deployment's own state. It prints which modules are still running when that
        changes (and every five minutes), tolerates a few failed reads, and gives up at -TimeoutMinutes without
        stopping the deployment in Azure. A transient client error while submitting is checked against Azure
        before anything is submitted again. -RemoveParametersFileWhenAccepted deletes the parameters file as soon
        as the request is accepted: it holds the VM admin password in plain text. Failed and Canceled throw the
        deployment's error text, so capacity guidance can still match it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$TemplateFile,
        [Parameter(Mandatory)][string]$ParametersFile,
        [switch]$RemoveParametersFileWhenAccepted,
        [ValidateRange(1, 1440)][int]$TimeoutMinutes = 240,
        [ValidateRange(1, 300)][int]$PollSeconds = 30
    )
    $transient = 'Connection (reset|aborted)|ConnectionReset|timed out|timeout|temporarily unavailable|ServiceUnavailable|TooManyRequests|Too Many Requests|\b50[234]\b|connection was closed|error occurred while sending'
    for ($attempt = 1; ; $attempt++) {
        try {
            Invoke-DemoAz -Arguments @('deployment', 'sub', 'create', '--name', $Name, '--location', $Location, '--template-file', $TemplateFile,
                '--parameters', "@$ParametersFile", '--no-wait', '--only-show-errors', '-o', 'none') | Out-Null
            break
        } catch {
            $submitFailure = $_
            # A reset can arrive after Azure accepted the request: look before submitting a second deployment.
            $accepted = $false
            try { $accepted = $null -ne (Get-DemoDeploymentState -Name $Name) } catch { Write-Verbose "Could not check whether $Name was accepted: $($_.Exception.Message)" }
            if ($accepted) { Write-Warn "Submitting deployment $Name reported an error after Azure had accepted it; following the accepted deployment."; break }
            if ($submitFailure.Exception.Message -notmatch $transient -or $attempt -ge 3) { throw $submitFailure }
            Write-Warn "Submitting deployment $Name failed with a transient client error and Azure has no record of it, so nothing was created. Retrying in 15 seconds (attempt $attempt of 3)."
            Start-Sleep -Seconds 15
        }
    }
    if ($RemoveParametersFileWhenAccepted) { [System.IO.File]::Delete($ParametersFile) }
    Write-Step "Deployment $Name accepted by Azure; polling every $PollSeconds seconds (a Container Apps environment or a vendor extension update on a VM can take 20 to 40 minutes)."
    $started = Get-Date
    $deadline = $started.AddMinutes($TimeoutMinutes)
    $readFailures = 0
    $missing = 0
    $lastActive = $null
    $lastPrinted = $started
    while ($true) {
        $state = $null
        try {
            $state = Get-DemoDeploymentState -Name $Name
            $readFailures = 0
        } catch {
            if (++$readFailures -ge 5) {
                throw "Could not read deployment $Name after $readFailures attempts: $($_.Exception.Message) Azure keeps running it; check it with: az deployment sub show --name $Name --query properties.provisioningState -o tsv"
            }
            Write-Warn "Reading deployment $Name failed ($readFailures of 5); retrying: $($_.Exception.Message)"
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        $minutes = [int]((Get-Date) - $started).TotalMinutes
        if ($null -eq $state) {
            if (++$missing -ge 3) { throw "Deployment $Name is not visible in Azure after it was accepted; inspect it with: az deployment sub show --name $Name" }
        } else {
            $missing = 0
            if ($state.state -eq 'Succeeded') { Write-Ok "Deployment $Name succeeded after $minutes min"; return }
            if ($state.state -in @('Failed', 'Canceled')) {
                throw "Deployment $Name $($state.state) after $minutes min: $(ConvertTo-Json -InputObject $state.error -Depth 12 -Compress)"
            }
            $active = @()
            try {
                $active = @(Invoke-DemoAz -Arguments @('deployment', 'operation', 'sub', 'list', '--name', $Name, '--query',
                    "[?properties.provisioningState=='Running'].properties.targetResource.resourceName", '-o', 'json') | ConvertFrom-Json | Where-Object { $_ } | Sort-Object)
            } catch { Write-Verbose "Could not list the running modules of ${Name}: $($_.Exception.Message)" }
            $label = $active -join ', '
            if ($label -ne $lastActive -or ((Get-Date) - $lastPrinted).TotalMinutes -ge 5) {
                Write-Step "Deployment $Name is $($state.state) after $minutes min$(if ($label) { "; still running: $label" })"
                $lastActive = $label
                $lastPrinted = Get-Date
            }
        }
        if ((Get-Date) -ge $deadline) {
            throw "Deployment $Name is still $($state.state) after $TimeoutMinutes minutes. Azure keeps running it. Do not start another: wait until 'az deployment sub show --name $Name --query properties.provisioningState -o tsv' reads Succeeded or Failed, then rerun the same command (it resumes; see docs/troubleshooting.md)."
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-DemoAllocationGuidance {
    <#
    .SYNOPSIS
        Explains a capacity/allocation deployment failure; returns $null for any other error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ErrorText,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$VmSize,
        [string]$SubscriptionId = '<SUB>'
    )
    $code = if ($ErrorText -match '(SkuNotAvailable|ZonalAllocationFailed|AllocationFailed|OverconstrainedZonalAllocationRequest|OverconstrainedAllocationRequest|NotAvailableForSubscription|QuotaExceeded)') { $Matches[1] }
    elseif ($ErrorText -match 'Capacity Restrictions|currently not available in location|exceeding approved .* quota') { 'capacity restriction' }
    else { return $null }
    @(
        "Azure could not provide the requested compute capacity ($code; size $VmSize, region $Location). Deploy never switches VM size or region on its own, and nothing was changed to work around this."
        'Choose explicitly:'
        '  1. Retry later with the same command. Capacity varies through the day and a re-run resumes where it stopped.'
        "  2. New lab only: another size via -VmSize (or compute.vmSize in the skin). Check it first: az vm list-skus --subscription $SubscriptionId -l $Location --size <size> --all -o table"
        '  3. New lab only: another region via -Location (or azure.location in the skin). An existing estate cannot move region.'
        "  4. Quota errors: request more vCPU quota. Current usage: az vm list-usage --subscription $SubscriptionId -l $Location -o table"
        'SKU listings, what-if and validation never guarantee physical allocation.'
        "Original error: $ErrorText"
    ) -join [Environment]::NewLine
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
    <#
    .SYNOPSIS
        The resources with a Heartbeat in the last 10 minutes: one object per exact lower-cased _ResourceId, with the
        UTC time of its latest Heartbeat so that evidence can show how fresh it is.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceCustomerId)
    $token = Get-LawQueryToken
    $response = Invoke-RestMethod -Method Post -TimeoutSec 60 `
        -Uri "https://api.loganalytics.io/v1/workspaces/$WorkspaceCustomerId/query" `
        -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' `
        -Body (@{ query = 'Heartbeat | where TimeGenerated > ago(10m) | summarize LastHeartbeat = max(TimeGenerated) by ResourceId = tolower(_ResourceId)' } | ConvertTo-Json)
    if ($response.error) { throw "Log Analytics returned a query error: $($response.error.code)" }
    return @($response.tables[0].rows | ForEach-Object { [pscustomobject]@{ Id = [string]$_[0]; LastHeartbeat = (ConvertTo-DemoUtc $_[1]) } })
}

function Get-DemoReadinessChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][string]$NamePrefix,
        [ValidateSet('Active', 'Ready', 'Hibernated')][string]$DesiredState = 'Ready'
    )
    $parked = $DesiredState -eq 'Hibernated'
    foreach ($machine in @($Inventory.Machines) + @($Inventory.ParkedMachines) | Where-Object { $_ }) {
        $power = if ($parked -or $machine.KeepParked) { 'VM deallocated' } else { 'VM running' }
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
        New-DemoCheck "containerapp/$name" $id $(if ($parked) { 'no active revisions' } else { 'healthy active revision' }) @($active | ForEach-Object { $_.name }) $(if (($parked -and $active.Count -eq 0) -or (-not $parked -and $healthy.Count -gt 0)) { 'pass' } else { 'pending' })
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
    $heartbeats = @{}
    if (@($Inventory.Machines | Where-Object Monitor).Count -gt 0) {
        $workspace = Invoke-DemoAz -Arguments @('monitor', 'log-analytics', 'workspace', 'show', '--ids', $workspaceId, '-o', 'json') | ConvertFrom-Json
        foreach ($entry in @(Get-DemoHeartbeatIds -WorkspaceCustomerId $workspace.customerId)) {
            if ($entry -is [string]) { $heartbeats[$entry.ToLowerInvariant()] = $null }
            else { $heartbeats[([string]$entry.Id).ToLowerInvariant()] = $entry.LastHeartbeat }
        }
    }
    foreach ($machine in $Inventory.Machines) {
        $actual = $machine.Actual
        $arc = $null
        if (-not $machine.Native) {
            $arc = $arcMachines | Where-Object { $_.id -eq $machine.ArcId } | Select-Object -First 1
            New-DemoCheck "arc/$($machine.Name)" $machine.ArcId 'Connected' $arc.status $(if (-not $arc) { 'fail' } elseif ($arc.status -eq 'Connected') { 'pass' } else { 'pending' })
            if ($arc -and $machine.Role -and $machine.OsTier) {
                # The workbooks group and filter on these two tags; a host that is Connected but mistagged is not ready to present.
                $tagMap = ConvertTo-DemoTagMap $arc.tags
                $found = foreach ($tagName in 'role', 'osTier') { "$tagName=$(if ($tagMap.ContainsKey($tagName)) { $tagMap[$tagName] } else { '(missing)' })" }
                $expectedTags = "role=$($machine.Role), osTier=$($machine.OsTier)"
                $observedTags = $found -join ', '
                $tagsOk = $observedTags -ceq $expectedTags
                New-DemoCheck "tags/$($machine.Name)" $machine.ArcId $expectedTags $observedTags $(if ($tagsOk) { 'pass' } else { 'fail' }) `
                    -Message $(if ($tagsOk) { '' } else { 'The role/osTier tags the workbooks filter on are missing or wrong. Deploy merges them through the ARM tags API and skips a host that already matches; see docs/troubleshooting.md, Arc machine tags are missing or one tag holds the rest.' })
            }
        }
        $scope = if ($machine.Native) { $machine.Id } else { $machine.ArcId }
        $extensionScope = if ($machine.Native -or $machine.OsType -eq 'Linux') { $machine.Id } else { $machine.ArcId }
        $provisioning = if ($actual) { [string]$actual.provisioningState }
        if ($provisioning) {
            # Soft: a Linux VM can sit Updating for about 90 minutes behind a Defender MDE.Linux install lock while the guest is healthy.
            $provisioningStatus = if ($provisioning -eq 'Succeeded') { 'pass' } elseif ($provisioning -eq 'Failed') { 'fail' } else { 'pending' }
            New-DemoCheck "provisioning/$($machine.Name)" $machine.Id 'Succeeded' $provisioning $provisioningStatus -Required $false `
                -Message $(if ($provisioningStatus -eq 'pass') { '' } else { "ARM provisioning state $provisioning. Soft warning, not a readiness gate: a Linux VM can stay Updating for about 90 minutes behind a Defender MDE.Linux install lock while the guest is healthy and its Heartbeat is fresh. See docs/troubleshooting.md, A Linux VM stays Updating behind a Defender MDE.Linux install lock." })
        }
        $extensions = @()
        if ($machine.Monitor -and $actual) {
            $extensions = if ($machine.Native -or $machine.OsType -eq 'Linux') {
                @(Invoke-DemoAz -Arguments @('vm', 'extension', 'list', '-g', $Inventory.InfraRg, '--vm-name', $machine.Name, '-o', 'json') | ConvertFrom-Json)
            } else {
                @(Invoke-DemoAz -Arguments @('connectedmachine', 'extension', 'list', '-g', $Inventory.ArcRg, '--machine-name', $machine.Name, '-o', 'json') | ConvertFrom-Json)
            }
        }
        $amaName = if ($machine.OsType -eq 'Windows') { 'AzureMonitorWindowsAgent' } else { 'AzureMonitorLinuxAgent' }
        $amaExtension = $extensions | Where-Object name -eq $amaName | Select-Object -First 1
        $amaState = if ($amaExtension.provisioningState) { $amaExtension.provisioningState } else { $amaExtension.properties.provisioningState }
        if ($machine.Monitor) {
            $beatKey = $scope.ToLowerInvariant()
            $seen = $heartbeats.ContainsKey($beatKey)
            $lastBeat = if ($seen) { $heartbeats[$beatKey] }
            $observedBeat = if (-not $seen) { 'no Heartbeat in the last 10 minutes' }
                elseif ($lastBeat) { "Heartbeat at $($lastBeat.ToString('yyyy-MM-ddTHH:mm:ssZ')), $([int][Math]::Max(0, ((Get-Date).ToUniversalTime() - $lastBeat).TotalMinutes)) min before this check" }
                else { 'Heartbeat in the last 10 minutes' }
            $amaFailed = -not $seen -and $amaState -eq 'Failed'
            New-DemoCheck "heartbeat/$($machine.Name)" $scope 'Heartbeat within 10 minutes by _ResourceId' $observedBeat $(if ($seen) { 'pass' } elseif ($amaFailed) { 'fail' } else { 'pending' }) `
                -Message $(if ($amaFailed) { 'No recent Heartbeat and the AMA extension is Failed: a real failure, not telemetry lag.' } else { '' })
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
        $extensionNames = @($amaName)
        if ($machine.VmInsights) { $extensionNames += 'DependencyAgentWindows' }
        if ($machine.ChangeTracking) { $extensionNames += "ChangeTracking-$($machine.OsType)" }
        # Defender for Servers installs MDE itself, so its row exists only when the extension does; its state is as soft as the others.
        $mdeName = if ($machine.OsType -eq 'Windows') { 'MDE.Windows' } else { 'MDE.Linux' }
        if (@($extensions | Where-Object name -eq $mdeName).Count) { $extensionNames += $mdeName }
        # Extension provisioning is a soft diagnostic. Only the heartbeat row can gate readiness.
        $connectedMinutes = if ($arc.status -eq 'Connected' -and $arc.lastStatusChange) {
            [int][Math]::Max(0, ((Get-Date).ToUniversalTime() - (ConvertTo-DemoUtc $arc.lastStatusChange)).TotalMinutes)
        }
        foreach ($name in $extensionNames) {
            $extension = $extensions | Where-Object name -eq $name | Select-Object -First 1
            $state = if ($extension.provisioningState) { $extension.provisioningState } else { $extension.properties.provisioningState }
            $status = if (-not $extension -or $state -eq 'Failed') { 'fail' } elseif ($state -eq 'Succeeded') { 'pass' } else { 'pending' }
            $message = switch ($status) {
                'pass' { '' }
                'fail' { 'Extension missing or Failed. Soft warning, not a readiness gate; with no recent Heartbeat the heartbeat row fails.' }
                default {
                    $age = if ($null -ne $connectedMinutes) { "; Arc connected $connectedMinutes min ago" } else { '' }
                    $pointer = if ($null -eq $connectedMinutes -or $connectedMinutes -ge 30) { ' See docs/troubleshooting.md, Linux ARM Updating while monitoring guest handlers are healthy.' } else { '' }
                    "ARM state $state$age. Soft warning, not a readiness gate: the heartbeat row is the authority.$pointer"
                }
            }
            New-DemoCheck "extension/$($machine.Name)/$name" "$extensionScope/extensions/$name" 'Succeeded' $state $status -Required $false -Message $message
        }
    }
}

function ConvertTo-DemoUtc {
    [CmdletBinding()]
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace("$Value")) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    [DateTimeOffset]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}

function Get-DemoHeartbeatTimes {
    <#
    .SYNOPSIS
        One Log Analytics query: the latest Heartbeat generated per exact lower-cased _ResourceId.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceCustomerId, [string]$Token = '')
    if (-not $Token) { $Token = Get-LawQueryToken }
    $query = 'Heartbeat | where TimeGenerated > ago(7d) | summarize LastHeartbeat = max(TimeGenerated) by ResourceId = tolower(_ResourceId)'
    $response = Invoke-RestMethod -Method Post -TimeoutSec 60 `
        -Uri "https://api.loganalytics.io/v1/workspaces/$WorkspaceCustomerId/query" `
        -Headers @{ Authorization = "Bearer $Token" } -ContentType 'application/json' `
        -Body (@{ query = $query } | ConvertTo-Json)
    if ($response.error) { throw "Log Analytics returned a query error: $($response.error.code)" }
    $times = @{}
    foreach ($row in @($response.tables[0].rows)) { $times[[string]$row[0]] = ConvertTo-DemoUtc $row[1] }
    $times
}

function Invoke-DemoArmGetParallel {
    <#
    .SYNOPSIS
        Time-boxed parallel read-only ARM GETs in one process. Failures and timeouts are returned, never thrown.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Uri,
        [Parameter(Mandatory)][string]$Token,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 20,
        [ValidateRange(1, 32)][int]$ThrottleLimit = 12
    )
    if (-not $Uri.Count) { return @() }
    $headers = @{ Authorization = "Bearer $Token" }
    $callTimeout = $TimeoutSeconds
    @($Uri | ForEach-Object -ThrottleLimit $ThrottleLimit -TimeoutSeconds $TimeoutSeconds -Parallel {
        try { [pscustomobject]@{ Uri = $_; Body = (Invoke-RestMethod -Method Get -Uri $_ -Headers $using:headers -TimeoutSec $using:callTimeout); Error = $null } }
        catch { [pscustomobject]@{ Uri = $_; Body = $null; Error = $_.Exception.Message } }
    })
}

function Get-DemoHostArmStates {
    <#
    .SYNOPSIS
        Soft ARM facts in one parallel, time-boxed batch: extension provisioning states for monitored hosts
        and, for the named hosts only, the backing VM's power, guest agent and in-flight extension state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Machines,
        [Parameter(Mandatory)][string]$Token,
        [string[]]$VmStateFor = @(),
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 20
    )
    $arm = 'https://management.azure.com'
    $requests = @(foreach ($machine in $Machines) {
        if ($machine.Monitor) {
            # Same extension path as the readiness rows: Windows Arc hosts use Arc extensions, everything else the VM.
            $uri = if (-not $machine.Native -and $machine.OsType -eq 'Windows') { "$arm$($machine.ArcId)/extensions?api-version=2024-07-10" }
            else { "$arm$($machine.Id)/extensions?api-version=2024-07-01" }
            [pscustomobject]@{ Name = $machine.Name; Kind = 'extensions'; Uri = $uri }
        }
        if ($machine.Name -in $VmStateFor) {
            [pscustomobject]@{ Name = $machine.Name; Kind = 'vm'; Uri = "$arm$($machine.Id)/instanceView?api-version=2024-07-01" }
        }
    })
    $states = [pscustomobject]@{ Extensions = @{}; Vm = @{}; Errors = @{} }
    if (-not $requests.Count) { return $states }
    $responses = @(Invoke-DemoArmGetParallel -Uri @($requests.Uri) -Token $Token -TimeoutSeconds $TimeoutSeconds)
    foreach ($request in $requests) {
        $response = $responses | Where-Object { $_.Uri -eq $request.Uri } | Select-Object -First 1
        $key = "$($request.Name)/$($request.Kind)"
        if (-not $response) { $states.Errors[$key] = 'ARM read did not finish inside the time box'; continue }
        if ($response.Error) { $states.Errors[$key] = [string]$response.Error; continue }
        if ($request.Kind -eq 'extensions') {
            $byName = [ordered]@{}
            foreach ($extension in @($response.Body.value)) { $byName[[string]$extension.name] = [string]$extension.properties.provisioningState }
            $states.Extensions[$request.Name] = $byName
        } else {
            $view = $response.Body
            $states.Vm[$request.Name] = [pscustomobject]@{
                Power = [string](@($view.statuses | Where-Object { $_.code -like 'PowerState/*' } | ForEach-Object { $_.displayStatus }) | Select-Object -First 1)
                AgentReady = @($view.vmAgent.statuses | Where-Object { $_.displayStatus -eq 'Ready' }).Count -gt 0
                Updating = @($view.statuses | Where-Object { $_.code -eq 'ProvisioningState/updating' }).Count -gt 0
                TransitioningExtensions = @($view.extensions | Where-Object { @($_.statuses | Where-Object { $_.displayStatus -eq 'Transitioning' }).Count } | ForEach-Object { [string]$_.name })
            }
        }
    }
    $states
}

function New-DemoGuestCheckScript {
    <#
    .SYNOPSIS
        Builds the guest health script for one host (opt-in Run Command path). Services restart only when asked.
        Returns $null when the host has nothing to check.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [switch]$Restart)
    $services = @()
    if (-not $Machine.Native) { $services += if ($Machine.OsType -eq 'Windows') { 'himds' } else { 'himdsd' } }
    if ($Machine.Monitor -and $Machine.OsType -eq 'Linux') { $services += 'azuremonitoragent' }
    if (-not $services -and -not $Machine.Monitor) { return $null }
    if ($Machine.OsType -eq 'Windows') {
        $commands = @("`$ErrorActionPreference='Stop'")
        if ($services) {
            if ($Restart) { $commands += "Restart-Service $($services -join ',') -Force" }
            $commands += ('if (@(Get-Service -Name {0} | Where-Object {{ $_.Status -ne ''Running'' }}).Count) {{ throw ''Required Arc service is not running.'' }}' -f ($services -join ','))
        }
        if ($Machine.Monitor) {
            $commands += @'
$deadline = (Get-Date).AddMinutes(10)
while (-not @(Get-Process -ErrorAction Stop | Where-Object ProcessName -eq 'MonAgentCore').Count) {
    if ((Get-Date) -ge $deadline) { Write-Warning 'AMA startup remains pending after 10 minutes; re-check exact-ID Heartbeat.'; 'ARC_DEMO_PENDING'; return }
    Write-Progress -Activity 'Waiting for AMA MonAgentCore' -Status 'Cold start; no repair or restart'
    Start-Sleep -Seconds 15
}
'@
        }
        $commands += "'ARC_DEMO_OK'"
        $text = $commands -join "`n"
    } else {
        $restartCommand = if ($Restart) { "sudo systemctl restart $($services -join ' ')" } else { '' }
        $text = "set -e`n$restartCommand`nfor service in $($services -join ' '); do sudo systemctl is-active --quiet `"`$service`"; done`necho ARC_DEMO_OK"
    }
    [pscustomobject]@{ Script = $text; Services = $services }
}

function Get-DemoArcTestServiceEnvScript {
    <#
    .SYNOPSIS
        Bash that gives the Linux Arc agent daemons MSFT_ARC_TEST=true, which Arc simulation on an Azure VM needs.
        systemd drop-ins survive reboots (a wake); set-environment covers units started before the next reboot.
        Idempotent, so it is also the one-off fix for a host onboarded before the drop-ins existed.
    #>
    [CmdletBinding()]
    param()
    @(
        'for svc in himdsd extd gcad; do'
        '  sudo mkdir -p "/etc/systemd/system/${svc}.service.d"'
        '  printf ''[Service]\nEnvironment=MSFT_ARC_TEST=true\n'' | sudo tee "/etc/systemd/system/${svc}.service.d/msft-arc-test.conf" > /dev/null'
        'done'
        'sudo systemctl set-environment MSFT_ARC_TEST=true'
        'sudo systemctl daemon-reload'
    ) -join "`n"
}

function New-DemoArcLinuxOnboardScript {
    <#
    .SYNOPSIS
        Builds the Linux Arc onboarding script for an Azure VM, with LF line endings whatever the checkout uses.
        MSFT_ARC_TEST is set for azcmagent connect and, through systemd drop-ins, for the agent daemons;
        without it the extension manager and guest configuration services keep exiting and restarting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ServicePrincipalId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ServicePrincipalSecret,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Tags
    )
    @(
        'set -e'
        'curl -sSL https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -o /tmp/pmp.deb'
        'sudo dpkg -i /tmp/pmp.deb'
        'sudo apt-get update -qq'
        'sudo apt-get install -y azcmagent'
        Get-DemoArcTestServiceEnvScript
        'sudo MSFT_ARC_TEST=true azcmagent connect \'
        "  --service-principal-id $ServicePrincipalId --service-principal-secret '$ServicePrincipalSecret' \"
        "  --resource-group $ResourceGroup --tenant-id $TenantId --location $Location \"
        "  --subscription-id $SubscriptionId \"
        "  --tags `"$Tags`""
        'sudo systemctl restart extd gcad || echo ''WARN: could not restart extd/gcad; they read MSFT_ARC_TEST on their next start.'''
        'echo ARC_DEMO_OK'
    ) -join "`n"
}

function Remove-DemoGuestJob {
    [CmdletBinding()]
    param([AllowNull()]$Job)
    if ($Job.Id) { Get-Job -Id $Job.Id -ErrorAction SilentlyContinue | Stop-Job -PassThru | Remove-Job -Force }
    if ($Job.DemoScriptPath) { [System.IO.File]::Delete($Job.DemoScriptPath) }
}

function Wait-DemoHostsReady {
    <#
    .SYNOPSIS
        One shared wait, under one global deadline, for running demo VMs to be healthy after a wake.
    .DESCRIPTION
        A host passes when its VM is running, its Arc identity is Connected (hosts with an Arc identity) and, for
        monitored hosts, a Heartbeat was generated after the VM start time. Cost does not grow with host count: each
        poll is one connectedmachine list, one Log Analytics query and one parallel, time-boxed ARM read.
        Extension provisioning state (AMA, Change Tracking, MDE) is a soft warning, never a gate. Run Command guest
        checks are opt-in and share the deadline. The nested guest start Run Command is submitted by the caller,
        runs concurrently and has its own budget. A host with no Heartbeat at the deadline is pending, not failed,
        unless its AMA extension is Failed. A stopped VM or an Arc identity that never connects fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][string]$NamePrefix,
        [Parameter(Mandatory)][datetime]$AttemptStartedUtc,
        [hashtable]$StartedAtUtc = @{},
        [ValidateRange(1, 120)][int]$DeadlineMinutes = 12,
        [ValidateSet('None', 'WhenStalled', 'Always')][string]$GuestChecks = 'None',
        [ValidateRange(1, 120)][int]$StallMinutes = 9,
        [switch]$RepairStalledAgents,
        [AllowNull()]$NestedGuest = $null,
        [ValidateRange(1, 120)][int]$PollSeconds = 15
    )
    $loopStarted = (Get-Date).ToUniversalTime()
    $deadline = $loopStarted.AddMinutes($DeadlineMinutes)
    $workspaceId = "/subscriptions/$script:DemoSubscription/resourceGroups/$($Inventory.ArcRg)/providers/Microsoft.OperationalInsights/workspaces/law-$NamePrefix"
    $watched = '^(AzureMonitor(Windows|Linux)Agent|ChangeTracking-(Windows|Linux)|DependencyAgentWindows|MDE\.(Windows|Linux))$'
    $items = @(foreach ($machine in @($Inventory.Machines)) {
        $scope = if ($machine.Native) { $machine.Id } else { $machine.ArcId }
        $startedAt = if ($StartedAtUtc.ContainsKey($machine.Id)) { $StartedAtUtc[$machine.Id] } else { $AttemptStartedUtc }
        [pscustomobject]@{
            Machine = $machine; Name = $machine.Name; Scope = "$scope".ToLowerInvariant()
            NeedsArc = -not $machine.Native; NeedsHeartbeat = [bool]$machine.Monitor
            StartedAt = ConvertTo-DemoUtc $startedAt; Started = $StartedAtUtc.ContainsKey($machine.Id)
            ArcConnected = $false; ArcStatus = $null; LastHeartbeat = $null; HeartbeatSeen = $false
            Extensions = [ordered]@{}; ExtensionSince = @{}
            Job = $null; RunCommand = 'not-run'; Completion = $null; Restarted = @(); GateWarned = $false
            Status = 'pending'; Message = ''; Warnings = [System.Collections.Generic.List[string]]::new()
        }
    })
    $nested = if ($NestedGuest) {
        [ordered]@{ parentVmName = $NestedGuest.Parent.Name; guestVmName = $NestedGuest.GuestVmName; arcMachineName = $NestedGuest.ArcMachineName
            startCommand = 'running'; arcStatus = $null; status = 'pending'; message = '' }
    }
    $arcList = @(); $heartbeats = @{}; $workspaceCustomerId = $null; $lawToken = $null; $armToken = $null
    $lastArmPoll = $null; $armStates = $null; $readFailures = 0; $alwaysSubmitted = $false
    $applyExtensionStates = {
        param($states, $at)
        foreach ($item in $items) {
            foreach ($name in @($states.Extensions[$item.Name].Keys | Where-Object { $_ -match $watched })) {
                $state = $states.Extensions[$item.Name][$name]
                $item.Extensions[$name] = $state
                if ($state -eq 'Succeeded') { $item.ExtensionSince.Remove($name) }
                elseif (-not $item.ExtensionSince.ContainsKey($name)) { $item.ExtensionSince[$name] = $at }
            }
        }
    }
    try {
        while ($true) {
            $now = (Get-Date).ToUniversalTime()
            $open = @($items | Where-Object { $_.Status -eq 'pending' })
            $readable = $true
            try {
                if (@($open | Where-Object { $_.NeedsArc }).Count -or ($nested -and $nested.status -eq 'pending')) {
                    $arcList = @(Invoke-DemoAz -Arguments @('connectedmachine', 'list', '-g', $Inventory.ArcRg, '-o', 'json') | ConvertFrom-Json)
                }
                if (@($open | Where-Object { $_.NeedsHeartbeat -and -not $_.HeartbeatSeen }).Count) {
                    if (-not $workspaceCustomerId) {
                        $workspaceCustomerId = (Invoke-DemoAz -Arguments @('monitor', 'log-analytics', 'workspace', 'show', '--ids', $workspaceId, '-o', 'json') | ConvertFrom-Json).customerId
                        $lawToken = Get-LawQueryToken
                    }
                    $heartbeats = Get-DemoHeartbeatTimes -WorkspaceCustomerId $workspaceCustomerId -Token $lawToken
                }
                $readFailures = 0
            } catch {
                $readable = $false
                if (++$readFailures -ge 3) { throw "Inspection failed while waiting for guest readiness: $($_.Exception.Message)" }
                Write-Warn "Guest readiness read failed ($readFailures of 3); retrying: $($_.Exception.Message)"
            }
            if ($readable) {
                foreach ($item in $open) {
                    if ($item.NeedsArc) {
                        $arc = $arcList | Where-Object { $_.id -eq $item.Machine.ArcId } | Select-Object -First 1
                        $item.ArcStatus = [string]$arc.status
                        if ($item.ArcStatus -eq 'Connected') { $item.ArcConnected = $true }
                    }
                    if ($item.NeedsHeartbeat -and $heartbeats.Contains($item.Scope)) {
                        $item.LastHeartbeat = $heartbeats[$item.Scope]
                        if ($item.LastHeartbeat -gt $item.StartedAt) { $item.HeartbeatSeen = $true }
                    }
                }
                if ($GuestChecks -eq 'Always' -and -not $alwaysSubmitted) {
                    $alwaysSubmitted = $true
                    foreach ($item in $open) {
                        $restart = $RepairStalledAgents.IsPresent -and ($item.Started -or ($item.NeedsArc -and -not $item.ArcConnected))
                        $check = New-DemoGuestCheckScript -Machine $item.Machine -Restart:$restart
                        if (-not $check) { continue }
                        $item.Job = Invoke-DemoGuestCommand -Machine $item.Machine -Script $check.Script -AsJob
                        $item.RunCommand = 'running'
                        $item.Restarted = @(if ($restart) { $check.Services })
                    }
                }
                foreach ($item in $items | Where-Object { $_.RunCommand -eq 'running' -and $_.Status -eq 'pending' }) {
                    if ($item.Job.State -in @('NotStarted', 'Running')) { continue }
                    try {
                        $item.Completion = Invoke-DemoGuestCommand -Machine $item.Machine -Job $item.Job -PassThru -AllowPending:($item.Machine.Monitor -and $item.Machine.OsType -eq 'Windows')
                        $item.RunCommand = $item.Completion.status
                    } catch {
                        $item.RunCommand = 'fail'; $item.Status = 'fail'; $item.Message = $_.Exception.Message
                        Write-Warning $item.Message
                    }
                    $item.Job = $null
                }
                if ($nested -and $nested.status -eq 'pending') {
                    if ($nested.startCommand -eq 'running') {
                        if ($NestedGuest.Job.State -notin @('NotStarted', 'Running')) {
                            try {
                                Invoke-DemoGuestCommand -Machine $NestedGuest.Parent -Job $NestedGuest.Job -PassThru | Out-Null
                                $nested.startCommand = 'pass'
                            } catch {
                                $nested.startCommand = 'fail'; $nested.status = 'fail'; $nested.message = $_.Exception.Message
                                Write-Warning $nested.message
                            }
                        } elseif (($now - $NestedGuest.SubmittedUtc).TotalMinutes -ge $NestedGuest.BudgetMinutes) {
                            Remove-DemoGuestJob $NestedGuest.Job
                            $nested.startCommand = 'timeout'
                            $nested.message = "The guest start command did not finish within $($NestedGuest.BudgetMinutes) minutes (queued behind a VM extension operation?); waiting for the guest Arc connection."
                            Write-Warning $nested.message
                        }
                    }
                    if ($nested.status -eq 'pending') {
                        $arc = $arcList | Where-Object { $_.name -eq $NestedGuest.ArcMachineName } | Select-Object -First 1
                        $nested.arcStatus = [string]$arc.status
                        if ($nested.arcStatus -eq 'Connected' -and $nested.startCommand -in @('pass', 'timeout')) { $nested.status = 'pass' }
                    }
                }
                foreach ($item in $items | Where-Object { $_.Status -eq 'pending' }) {
                    $ready = (-not $item.NeedsArc -or $item.ArcConnected) -and (-not $item.NeedsHeartbeat -or $item.HeartbeatSeen) -and
                        -not ($GuestChecks -eq 'Always' -and $item.RunCommand -eq 'running')
                    if ($ready) { $item.Status = 'pass'; Write-Ok "Host ready: $($item.Name)" }
                }
                $stalled = @()
                if ($GuestChecks -eq 'WhenStalled') {
                    $stalled = @($items | Where-Object { $_.Status -eq 'pending' -and $_.RunCommand -eq 'not-run' -and ($now - $_.StartedAt).TotalMinutes -ge $StallMinutes })
                }
                if (-not $lastArmPoll -or ($now - $lastArmPoll).TotalSeconds -ge 60) {
                    try {
                        if (-not $armToken) { $armToken = Get-MgmtToken }
                        $armStates = Get-DemoHostArmStates -Machines @($Inventory.Machines) -Token $armToken -VmStateFor @($stalled.Name)
                        $lastArmPoll = $now
                        & $applyExtensionStates $armStates $now
                    } catch { Write-Warning "ARM extension read failed (soft; not a gate): $($_.Exception.Message)" }
                    foreach ($item in $stalled) {
                        $vm = $armStates.Vm[$item.Name]
                        if ($vm -and $vm.Power -eq 'VM running' -and $vm.AgentReady -and -not $vm.Updating -and -not @($vm.TransitioningExtensions).Count) {
                            $restart = $RepairStalledAgents.IsPresent
                            $check = New-DemoGuestCheckScript -Machine $item.Machine -Restart:$restart
                            if (-not $check) { continue }
                            $item.Job = Invoke-DemoGuestCommand -Machine $item.Machine -Script $check.Script -AsJob
                            $item.RunCommand = 'running'
                            $item.Restarted = @(if ($restart) { $check.Services })
                        } elseif (-not $item.GateWarned) {
                            $item.GateWarned = $true
                            $item.Warnings.Add('Run Command guest check not submitted: the VM agent is not Ready or a VM extension operation is in flight, so it would queue behind it.')
                            Write-Warning "$($item.Name): $($item.Warnings[-1])"
                        }
                    }
                }
            }
            $open = @($items | Where-Object { $_.Status -eq 'pending' })
            if (-not $open.Count -and (-not $nested -or $nested.status -ne 'pending')) { break }
            $remaining = ($deadline - (Get-Date).ToUniversalTime()).TotalSeconds
            if ($remaining -le 0) { break }
            $waitingFor = @($open.Name) + @(if ($nested -and $nested.status -eq 'pending') { $nested.guestVmName })
            Write-Step "Waiting for guest readiness (Heartbeat after VM start): $($waitingFor -join ', ') ($([int]$remaining) s remaining)"
            Start-Sleep -Seconds ([Math]::Min($PollSeconds, [Math]::Max(1, [int][Math]::Ceiling($remaining))))
        }

        $unresolved = @($items | Where-Object { $_.Status -eq 'pending' })
        $finalNow = (Get-Date).ToUniversalTime()
        if ($armToken -and ($unresolved.Count -or -not $lastArmPoll -or ($finalNow - $lastArmPoll).TotalSeconds -ge 45)) {
            try {
                $armStates = Get-DemoHostArmStates -Machines @($Inventory.Machines) -Token $armToken -VmStateFor @($unresolved.Name)
                & $applyExtensionStates $armStates $finalNow
            } catch { Write-Warning "ARM state read failed (soft; not a gate): $($_.Exception.Message)" }
        }
        foreach ($item in $unresolved) {
            $vm = $armStates.Vm[$item.Name]
            $amaName = if ($item.Machine.OsType -eq 'Windows') { 'AzureMonitorWindowsAgent' } else { 'AzureMonitorLinuxAgent' }
            if ($vm -and $vm.Power -and $vm.Power -ne 'VM running') {
                $item.Status = 'fail'; $item.Message = "The VM is not running (power state: $($vm.Power))."
            } elseif ($item.NeedsArc -and -not $item.ArcConnected) {
                $item.Status = 'fail'; $item.Message = "The Arc identity is not Connected after $DeadlineMinutes minutes (last status: $($item.ArcStatus))."
            } elseif ($item.NeedsHeartbeat -and -not $item.HeartbeatSeen) {
                if ($item.Extensions[$amaName] -eq 'Failed') {
                    $item.Status = 'fail'; $item.Message = 'No Heartbeat after VM start and the AMA extension is Failed; this is not telemetry lag.'
                } else {
                    $item.Message = "No Heartbeat generated after VM start within $DeadlineMinutes minutes. Pending, not failed; re-check readiness."
                }
            } else {
                $item.Message = 'The Run Command guest check did not finish before the deadline (queued behind a VM extension operation?). Pending, not failed.'
            }
        }
        foreach ($item in $items | Where-Object { $_.Status -eq 'pass' }) {
            $item.Message = if ($item.NeedsHeartbeat) { 'VM running, Arc Connected where applicable, Heartbeat generated after VM start.' } else { 'VM running; no Heartbeat expected for this host.' }
        }
        if ($nested -and $nested.status -eq 'pending') {
            $nested.status = 'fail'
            $nested.message = "The nested guest's Arc machine is not Connected after $DeadlineMinutes minutes (last status: $($nested.arcStatus))."
        }
        foreach ($item in $items) {
            foreach ($name in $item.ExtensionSince.Keys) {
                $state = $item.Extensions[$name]
                $minutes = [int][Math]::Floor(($finalNow - $item.ExtensionSince[$name]).TotalMinutes)
                $item.Warnings.Add($(
                    if ($state -eq 'Failed') { "extension $name is Failed (not a gate)" }
                    elseif ($minutes -ge 1) { "extension $name $state for at least $minutes min (not a gate)" }
                    else { "extension $name $state (age unknown; not a gate)" }))
                Write-Warning "$($item.Name): $($item.Warnings[-1])"
            }
            if ($item.Status -eq 'pending') { Write-Warning "$($item.Name): $($item.Message)" }
        }
    } finally {
        foreach ($item in $items) { Remove-DemoGuestJob $item.Job }
    }
    $hosts = @(foreach ($item in $items) {
        [ordered]@{
            machineName = $item.Name; resourceId = $item.Machine.Id; status = $item.Status
            method = $(if ($item.NeedsHeartbeat) { 'arm+heartbeat' } else { 'arm' }) + $(if ($item.RunCommand -ne 'not-run') { '+run-command' } else { '' })
            startedAtUtc = $item.StartedAt.ToString('o')
            lastHeartbeatUtc = $(if ($item.LastHeartbeat) { $item.LastHeartbeat.ToString('o') } else { $null })
            arcStatus = $(if ($item.NeedsArc) { $item.ArcStatus } else { 'not-applicable' })
            extensionStates = $item.Extensions
            monitorCheck = $(if ($item.NeedsHeartbeat) { 'Heartbeat after VM start' } else { 'not-required' })
            restartedServices = @($item.Restarted); completion = $item.Completion
            message = $item.Message; warnings = @($item.Warnings)
        }
    })
    $worst = if (@($hosts | Where-Object { $_.status -eq 'fail' }).Count -or $nested.status -eq 'fail') { 'fail' }
        elseif (@($hosts | Where-Object { $_.status -eq 'pending' }).Count) { 'pending' } else { 'pass' }
    [pscustomobject]@{ Status = $worst; Hosts = $hosts; NestedGuest = $nested
        ElapsedSeconds = [int]((Get-Date).ToUniversalTime() - $loopStarted).TotalSeconds }
}

function Invoke-DemoGraphRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [hashtable]$Body
    )
    $arguments = @('rest', '--method', $Method, '--url', $Url, '--output', 'json', '--only-show-errors')
    $bodyPath = $null
    if ($PSBoundParameters.ContainsKey('Body')) {
        $bodyPath = Join-Path ([IO.Path]::GetTempPath()) "demo-graph-$([guid]::NewGuid().ToString('N')).json"
        [IO.File]::WriteAllText($bodyPath, ($Body | ConvertTo-Json -Depth 5 -Compress), [Text.UTF8Encoding]::new($false))
        $arguments += @('--headers', 'Content-Type=application/json', '--body', "@$bodyPath")
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

function Get-DemoGraphApplication {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][guid]$ApplicationId)
    $application = Invoke-DemoGraphRequest -Method GET -Url $Url
    if (-not $application -or [guid]$application.appId -ne $ApplicationId) {
        throw 'Graph returned a different onboarding application.'
    }
    $application
}

function Get-DemoCredentialKeyIdSet {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Application)
    @($Application.passwordCredentials | ForEach-Object { "$($_.keyId)".ToLowerInvariant() } | Sort-Object -Unique)
}

function Test-DemoCredentialSet {
    [CmdletBinding()]
    param([string[]]$Expected, [string[]]$Actual)
    (@($Expected | Sort-Object -Unique) -join '|') -ceq (@($Actual | Sort-Object -Unique) -join '|')
}

function Invoke-DemoOnboardingCredential {
    <#
    .SYNOPSIS
        Mints a one-day password credential on the onboarding application, runs -Action with it, then removes it.
    .DESCRIPTION
        The secret reaches the action only as a SecureString, after any -ActionArguments. The credential is removed
        in a finally block, also when the action fails, and the original credential key IDs are verified unchanged.
        Existing credentials are never read beyond their key IDs and never changed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The one-run Graph secret is immediately converted in memory before protected delivery.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$ApplicationId,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][scriptblock]$Action,
        [object[]]$ActionArguments = @()
    )
    $appRoute = "applications%28appId%3D%27$ApplicationId%27%29"
    $appUrl = "https://graph.microsoft.com/v1.0/$appRoute`?%24select=id,appId,passwordCredentials"
    $application = Get-DemoGraphApplication -Url $appUrl -ApplicationId $ApplicationId
    $baselineIds = @(Get-DemoCredentialKeyIdSet -Application $application)
    $createdKeyId = $null
    $secret = $null
    $actionFailure = $null
    $cleanupFailure = $null
    $result = $null
    try {
        $expiry = [datetime]::UtcNow.AddDays(1)
        try {
            $credential = Invoke-DemoGraphRequest -Method POST -Url "https://graph.microsoft.com/v1.0/$appRoute/addPassword" -Body @{
                passwordCredential = @{
                    displayName = $DisplayName
                    endDateTime = $expiry.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                }
            }
        } catch {
            throw "Could not add a one-day credential to the onboarding application: $($_.Exception.Message) The signed-in operator must own the application or hold an application administrator role; otherwise supply the current onboarding secret (Deploy: -OnboardingSecret)."
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

        $afterMint = Get-DemoGraphApplication -Url $appUrl -ApplicationId $ApplicationId
        $expectedMinted = @($baselineIds + $createdKeyId | Sort-Object -Unique)
        if (-not (Test-DemoCredentialSet -Expected $expectedMinted -Actual @(Get-DemoCredentialKeyIdSet $afterMint))) {
            throw 'Onboarding application credential IDs changed unexpectedly after minting.'
        }
        $afterMint = $null
        try { $result = & $Action @ActionArguments $secret }
        catch { $actionFailure = $_ }
    } catch {
        if (-not $actionFailure) { $actionFailure = $_ }
    } finally {
        if ($createdKeyId) {
            try {
                $null = Invoke-DemoGraphRequest -Method POST -Url "https://graph.microsoft.com/v1.0/$appRoute/removePassword" -Body @{
                    keyId = $createdKeyId
                }
                $deadline = [datetime]::UtcNow.AddSeconds(90)
                do {
                    $remaining = Get-DemoGraphApplication -Url $appUrl -ApplicationId $ApplicationId
                    $remainingIds = @(Get-DemoCredentialKeyIdSet $remaining)
                    if (@($baselineIds | Where-Object { $_ -notin $remainingIds }).Count -gt 0 -or
                        @($remainingIds | Where-Object { $_ -ne $createdKeyId -and $_ -notin $baselineIds }).Count -gt 0) {
                        throw 'Onboarding application credential IDs changed beyond the minted credential.'
                    }
                    if ($createdKeyId -notin $remainingIds) {
                        if (-not (Test-DemoCredentialSet -Expected $baselineIds -Actual $remainingIds)) {
                            throw 'Existing onboarding credential IDs were not preserved exactly.'
                        }
                        break
                    }
                    if ([datetime]::UtcNow -ge $deadline) { throw 'Graph still reports the one-run credential after removal.' }
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
        $message = "One-run onboarding credential cleanup/verification failed; it expires at $($expiry.ToString('u')). $($cleanupFailure.Exception.Message)"
        if ($actionFailure) { $message += " Failure: $($actionFailure.Exception.Message)" }
        throw $message
    }
    if ($actionFailure) { throw $actionFailure }
    $result
}

function Remove-DemoCreationCredential {
    <#
    .SYNOPSIS
        Removes the one-year credential that az ad sp create-for-rbac adds when it creates the onboarding service principal.
    .DESCRIPTION
        Only a credential that was absent before the creation and is named rbac is removed, by its exact key ID, and the
        credentials that were there before are verified unchanged. A new credential with another name is left alone and
        reported. Throws, naming the manual command, when a removal or the verification fails.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$ApplicationId, [string[]]$BaselineKeyId = @())
    $appRoute = "applications%28appId%3D%27$ApplicationId%27%29"
    $appUrl = "https://graph.microsoft.com/v1.0/$appRoute`?%24select=id,appId,passwordCredentials"
    $baseline = @($BaselineKeyId | Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object -Unique)
    $application = Get-DemoGraphApplication -Url $appUrl -ApplicationId $ApplicationId
    $added = @($application.passwordCredentials | Where-Object { "$($_.keyId)".ToLowerInvariant() -notin $baseline })
    $creation = @($added | Where-Object { $_.displayName -eq 'rbac' })
    $others = @($added | Where-Object { $_.displayName -ne 'rbac' })
    if ($others.Count) {
        Write-Warn "The onboarding application has $($others.Count) credential(s) that were not there before and are not named rbac; they are left alone: $(($others | ForEach-Object { "$($_.displayName) ($($_.keyId))" }) -join ', ')."
    }
    foreach ($credential in $creation) {
        $keyId = "$($credential.keyId)".ToLowerInvariant()
        try {
            $null = Invoke-DemoGraphRequest -Method POST -Url "https://graph.microsoft.com/v1.0/$appRoute/removePassword" -Body @{ keyId = $keyId }
        } catch {
            throw "The one-year credential added when the onboarding application was created could not be removed ($($_.Exception.Message)). Remove it with: az ad app credential delete --id $ApplicationId --key-id $keyId"
        }
    }
    if (-not $creation.Count) { return }
    $expected = @($baseline + @($others | ForEach-Object { "$($_.keyId)".ToLowerInvariant() }) | Sort-Object -Unique)
    $deadline = [datetime]::UtcNow.AddSeconds(90)
    do {
        $remaining = @(Get-DemoCredentialKeyIdSet (Get-DemoGraphApplication -Url $appUrl -ApplicationId $ApplicationId))
        if (Test-DemoCredentialSet -Expected $expected -Actual $remaining) { return }
        if ([datetime]::UtcNow -ge $deadline) {
            throw "Could not verify that the one-year credential was removed and the original credentials were kept. Check the application's credentials; remove the key with: az ad app credential delete --id $ApplicationId --key-id $(($creation | ForEach-Object { $_.keyId }) -join ',')"
        }
        Start-Sleep -Seconds 5
    } while ($true)
}

function Initialize-DemoOnboardingIdentity {
    <#
    .SYNOPSIS
        Runs -Action with a credential for the demo's Arc onboarding service principal that exists only for the call.
    .DESCRIPTION
        Existing service principal (found as sp-<NamePrefix>-onboard, or by -ApplicationId): its credentials are never
        read, changed or reset. The Azure Connected Machine Onboarding role is ensured at the Arc resource group
        (which must already exist: a rebuild deletes the old assignment with the group), a one-day credential is
        minted through Graph, handed to -Action as a SecureString and removed in a finally block, and the original
        key IDs are verified unchanged. -ExistingSecret skips minting and passes the supplied secret through.
        No service principal: it is created with the role at the group, as before, and the one-year credential that
        creation adds is handed to -Action and then removed (only that credential, by key ID); nothing is stored.
        -Action receives the application ID (string) and the secret (SecureString).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The secret returned by service principal creation is converted in memory before delivery.')]
    [CmdletBinding(DefaultParameterSetName = 'ByPrefix')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByPrefix')][string]$NamePrefix,
        [Parameter(Mandatory, ParameterSetName = 'ByApplication')][guid]$ApplicationId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][scriptblock]$Action,
        [securestring]$ExistingSecret,
        [string]$DisplayName = '',
        [ValidateRange(0, 600)][int]$RolePropagationSeconds = 90
    )
    if (-not $script:DemoSubscription) { throw 'Initialize the explicit demo context before the onboarding identity.' }
    $roleName = 'Azure Connected Machine Onboarding'
    $scope = "/subscriptions/$script:DemoSubscription/resourceGroups/$ResourceGroup"
    if (-not (Invoke-DemoAz -Arguments @('group', 'exists', '-n', $ResourceGroup, '-o', 'json') | ConvertFrom-Json)) {
        throw "Resource group $ResourceGroup does not exist yet. The onboarding role can only be granted after the group is created."
    }
    if ($PSCmdlet.ParameterSetName -eq 'ByPrefix') {
        $spName = "sp-$NamePrefix-onboard"
        $found = @(Invoke-DemoAz -Arguments @('ad', 'sp', 'list', '--display-name', $spName, '--query', "[?displayName=='$spName'].{id:id,appId:appId}", '-o', 'json') | ConvertFrom-Json)
        if ($found.Count -gt 1) { throw 'Ambiguous onboarding service principal name. Resolve duplicates before deployment.' }
        $principal = $found | Select-Object -First 1
        if (-not $principal) {
            # create-for-rbac reuses an application of that name and adds a one-year credential either way. Note the keys that
            # are already there so that only the credential it adds is removed once onboarding has used it.
            $namedApps = @(Invoke-DemoAz -Arguments @('ad', 'app', 'list', '--display-name', $spName, '--query', "[?displayName=='$spName'].{appId:appId,keys:passwordCredentials[].keyId}", '-o', 'json') | ConvertFrom-Json)
            if ($namedApps.Count -gt 1) { throw 'Ambiguous onboarding application name. Resolve duplicates before deployment.' }
            $baselineKeys = @(if ($namedApps.Count) { @($namedApps[0].keys) | Where-Object { $_ } })
            $created = Invoke-DemoAz -Arguments @('ad', 'sp', 'create-for-rbac', '--name', $spName, '--role', $roleName, '--scopes', $scope, '--only-show-errors', '-o', 'json') | ConvertFrom-Json
            $createdAppId = [string]$created.appId
            $secret = ConvertTo-SecureString ([string]$created.password) -AsPlainText -Force
            $created = $null
            Write-Ok "Onboarding service principal created ($createdAppId); its secret is not stored and its one-year credential is removed after onboarding"
            Write-Step "Waiting $RolePropagationSeconds seconds for the new role assignment to propagate..."
            Start-Sleep -Seconds $RolePropagationSeconds
            $result = $null
            $actionFailure = $null
            try { $result = & $Action $createdAppId $secret } catch { $actionFailure = $_ } finally { $secret.Dispose() }
            $cleanupFailure = $null
            try { Remove-DemoCreationCredential -ApplicationId $createdAppId -BaselineKeyId $baselineKeys } catch { $cleanupFailure = $_ }
            if ($cleanupFailure) {
                $message = $cleanupFailure.Exception.Message
                if ($actionFailure) { $message += " Failure: $($actionFailure.Exception.Message)" }
                throw $message
            }
            if ($actionFailure) { throw $actionFailure }
            return $result
        }
    } else {
        $principal = Invoke-DemoAz -Arguments @('ad', 'sp', 'show', '--id', "$ApplicationId", '--query', '{id:id,appId:appId}', '-o', 'json') | ConvertFrom-Json
        if (-not $principal) { throw "No service principal exists for onboarding application $ApplicationId." }
    }
    $appId = [string]$principal.appId
    $assignments = @(Invoke-DemoAz -Arguments @('role', 'assignment', 'list', '--assignee-object-id', $principal.id, '--scope', $scope, '--role', $roleName, '-o', 'json') | ConvertFrom-Json)
    if (@($assignments | Where-Object { $_.scope -ieq $scope }).Count) {
        Write-Ok "$roleName is already assigned on $ResourceGroup"
    } else {
        Invoke-DemoAz -Arguments @('role', 'assignment', 'create', '--assignee-object-id', $principal.id, '--assignee-principal-type', 'ServicePrincipal', '--role', $roleName, '--scope', $scope, '-o', 'none') | Out-Null
        Write-Ok "Granted $roleName on $ResourceGroup"
        Write-Step "Waiting $RolePropagationSeconds seconds for the new role assignment to propagate..."
        Start-Sleep -Seconds $RolePropagationSeconds
    }
    if ($ExistingSecret) { return (& $Action $appId $ExistingSecret) }
    if (-not $DisplayName) { $DisplayName = "onboarding-$([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 8))" }
    Write-Step 'Minting a one-day onboarding credential; it is removed when onboarding finishes.'
    Invoke-DemoOnboardingCredential -ApplicationId $appId -DisplayName $DisplayName -Action $Action -ActionArguments @($appId)
}

Export-ModuleMember -Function * -Variable *
