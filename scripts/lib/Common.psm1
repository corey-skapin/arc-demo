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
        [Parameter(Mandatory)][string]$TenantId
    )

    Write-Header 'Pre-flight checks'

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
    $ctx = az account show --query "{id:id,tenantId:tenantId,user:user.name}" -o json 2>$null | ConvertFrom-Json
    if (-not $ctx) { throw "Not signed in. Run: az login --tenant $TenantId" }
    if ($ctx.id -ne $SubscriptionId) {
        Write-Warn "Active subscription is $($ctx.id), not requested $SubscriptionId. Switching..."
        az account set --subscription $SubscriptionId
        $ctx = az account show --query "{id:id,tenantId:tenantId,user:user.name}" -o json | ConvertFrom-Json
    }
    if ($ctx.tenantId -ne $TenantId) {
        throw "Active tenant is $($ctx.tenantId), not requested $TenantId. Run: az login --tenant $TenantId"
    }
    Write-Ok "Signed in as $($ctx.user) in tenant $TenantId"

    # Owner role (or higher — inherited via MG is normal for MCAPS)
    $principalId = (az ad signed-in-user show --query id -o tsv 2>$null)
    $userUpn     = (az ad signed-in-user show --query userPrincipalName -o tsv 2>$null)
    if (-not $principalId) { throw "Unable to resolve signed-in user object id" }
    # Include inherited assignments by using --all + UPN (the object-id query
    # only returns direct sub-scope assignments, missing MG-inherited Owner)
    $roles = az role assignment list --all --assignee $userUpn --query "[?contains(scope,'/subscriptions/$SubscriptionId') || contains(scope,'/providers/Microsoft.Management') || scope=='/'].roleDefinitionName" -o tsv 2>$null
    if ($roles -match '^(Owner|User Access Administrator)$') {
        Write-Ok "User has Owner/UAA role on the subscription (direct or inherited)"
    } else {
        Write-Warn "User does not appear to have Owner on this subscription. Some operations (policy, role assignments) may fail."
    }

    # Resource provider registrations
    $rps = @(
        'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity',
        'Microsoft.AzureArcData', 'Microsoft.OperationalInsights', 'Microsoft.OperationsManagement',
        'Microsoft.Insights', 'Microsoft.Security', 'Microsoft.PolicyInsights',
        'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.Logic'
    )
    Write-Step "Ensuring $($rps.Count) resource providers registered..."
    foreach ($rp in $rps) {
        $state = az provider show --namespace $rp --query registrationState -o tsv 2>$null
        if ($state -ne 'Registered') {
            az provider register --namespace $rp --only-show-errors | Out-Null
        }
    }
    Write-Ok "Resource providers registration triggered (may take a few minutes to fully register)"

    return $principalId
}

#endregion

#region Az REST helpers

function Get-MgmtToken {
    [CmdletBinding()]
    param()
    return (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
}

function Get-LawQueryToken {
    [CmdletBinding()]
    param()
    return (az account get-access-token --resource https://api.loganalytics.io --query accessToken -o tsv)
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
    $params = @{ Method = $Method; Uri = $Url; Headers = $hdr }
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
        [int]$TimeoutSeconds = 600,
        [int]$IntervalSeconds = 15,
        [string]$Message = 'Waiting'
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            if (& $Condition) { return $true }
        } catch {
            Write-Verbose "Wait-Until condition threw: $($_.Exception.Message)"
        }
        $remaining = [int]($deadline - (Get-Date)).TotalSeconds
        Write-Step "$Message... ($remaining s remaining)"
        Start-Sleep $IntervalSeconds
    } while ((Get-Date) -lt $deadline)
    return $false
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

Export-ModuleMember -Function * -Variable *
