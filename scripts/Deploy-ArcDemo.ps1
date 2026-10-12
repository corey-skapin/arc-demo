<#
.SYNOPSIS
    Deploys the Azure Arc + Azure Monitor demo end-to-end.

.DESCRIPTION
    Runs the following phases. Each phase is idempotent — re-running the script
    after a partial failure picks up where it left off.

      1. Pre-flight checks (PS, az, bicep, signed-in tenant, RBAC)
      2. Bicep main.bicep deployment (RGs, network, KV, LAW, VMs,
         alerts, Defender, policies, budget)
      2.5 Data Collection Rules after Log Analytics table readiness
      3. NAT Gateway (deployed separately so Hibernate can tear it down)
      4. Arc onboarding service principal
      5. Arc agent install on each VM (Windows via Arc ext path,
         Linux via Azure VM ext path — see AGENTS.md Gotcha 2)
      6. AMA install + DCR associations for Monitor-supported fleet entries
         only (DCRA against the Arc resource ID — see AGENTS.md Gotcha 3)
      7. Dependency Agent for VM Insights-supported Windows entries only
      8. Change Tracking extension for Change Tracking-supported entries only
      9. (Optional/advanced) SQL Server 2022 Developer install on SQL-capable hosts
     10. (Optional/advanced) WindowsAgent.SqlServer extension to Arc-enable SQL
     11. Workbook upload
     12. Post-deploy validation (heartbeat, alert rule, workbook URL)

.PARAMETER SubscriptionId
    The Azure subscription to deploy into.

.PARAMETER TenantId
    The Entra tenant ID.

.PARAMETER DeployerPrincipalId
    Optional Entra object ID for the deploying user/service principal. Use this when
    ARM access works but Graph signed-in-user lookup is blocked by CAE.

.PARAMETER AdminEmail
    Email address for budget + alert notifications. Defaults from config\demo-skin.json when omitted.

.PARAMETER SkinPath
    Optional path to a demo skin variables JSON file. Defaults to config\demo-skin.json.

.PARAMETER Location
    Azure region. Default: australiaeast.

.PARAMETER NamePrefix
    Used to derive resource group and resource names. Default: arc-demo.
    Two RGs will be created: rg-<prefix> and rg-<prefix>-infra.

.PARAMETER DeployArcOnPrem
    Deploy the on-premises-simulated Azure VMs and Arc-enable them. Default true.

.PARAMETER DeployAzureVMs
    Deploy a monitored Azure-native VM workload (not Arc-enabled). Default false.

.PARAMETER DeployContainerApps
    Deploy the optional Container App workload with a SIMULATE_CRASH fault
    switch and RestartCount alert. Default false.

.PARAMETER DeployAks
    Pass through the optional AKS workload toggle. Default false until the
    workload module is implemented.

.PARAMETER OnPremFleetPath
    Optional path to a JSON file containing the on-prem simulated fleet array.
    See docs/legacy-os-fleet.md for the schema. If omitted, main.bicep uses
    its default mixed WS2016/2019/2022 + Ubuntu fleet.

.PARAMETER WindowsVmCount
    Deprecated compatibility input. If supplied without OnPremFleetPath, the
    script generates a count-based WS2022 fleet. Prefer OnPremFleetPath.

.PARAMETER LinuxVmCount
    Deprecated compatibility input. If supplied without OnPremFleetPath, the
    script generates a count-based Ubuntu 22.04 fleet. Prefer OnPremFleetPath.

.PARAMETER VmSize
    VM SKU. Default Standard_B2as_v2 (2 vCPU / 8 GiB AMD burstable). Probe
    with `az vm create --validate` before changing — capacity restrictions
    on B-series are common in AU regions.

.PARAMETER AutoShutdownTime
    HHmm in AutoShutdownTimezone. Default 1900.

.PARAMETER AutoShutdownTimezone
    .NET timezone ID. Default 'Cen. Australia Standard Time'.

.PARAMETER BudgetAmount
    Monthly budget threshold in subscription currency. Default 200.

.PARAMETER InstallSql
    Optional/advanced experimental path retained for historical compatibility.
    It attempts both SQL Server 2022 Developer install and Arc SQL extension setup
    on fleet entries with supportsSql=true. Skipped by default because future SQL
    work should split SQL workload simulation from SQL Server enabled by Azure Arc
    validation. Do not use this switch to claim Arc SQL support in the Azure-VM-
    backed demo.

.PARAMETER SkipSqlInstall
    Deprecated compatibility switch. The default path already skips SQL; keep
    this only for older automation that explicitly passes it.

.PARAMETER WhatIf
    Show the Bicep what-if output and stop.

.EXAMPLE
    .\Deploy-ArcDemo.ps1 -SubscriptionId 6ff7d039-... -TenantId 4a2e6a7b-... `
        -AdminEmail corey@contoso.com
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$DeployerPrincipalId = '',
    [string]$AdminEmail = '',
    [string]$Location = 'australiaeast',
    [string]$NamePrefix = 'arc-demo',
    [bool]$DeployArcOnPrem = $true,
    [bool]$DeployAzureVMs = $false,
    [bool]$DeployContainerApps = $false,
    [bool]$DeployAks = $false,
    [string]$OnPremFleetPath = '',
    [ValidateRange(1, 20)][int]$WindowsVmCount = 5,
    [ValidateRange(0, 20)][int]$LinuxVmCount = 3,
    [string]$VmSize = 'Standard_B2as_v2',
    [string]$AutoShutdownTime = '1900',
    [string]$AutoShutdownTimezone = 'Cen. Australia Standard Time',
    [int]$BudgetAmount = 200,
    [string]$SkinPath = '',
    [switch]$InstallSql,
    [switch]$SkipSqlInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force

$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not $PSBoundParameters.ContainsKey('Location')) { $Location = Get-DemoSkinValue -Skin $skin -Path 'azure.location' -Default $Location }
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue -Skin $skin -Path 'azure.namePrefix' -Default $NamePrefix }
if (-not $PSBoundParameters.ContainsKey('AdminEmail')) { $AdminEmail = Get-DemoSkinValue -Skin $skin -Path 'notifications.email' -Default $AdminEmail }
if (-not $PSBoundParameters.ContainsKey('DeployArcOnPrem')) { $DeployArcOnPrem = [bool](Get-DemoSkinValue -Skin $skin -Path 'workloads.deployArcOnPrem' -Default $DeployArcOnPrem) }
if (-not $PSBoundParameters.ContainsKey('DeployAzureVMs')) { $DeployAzureVMs = [bool](Get-DemoSkinValue -Skin $skin -Path 'workloads.deployAzureVMs' -Default $DeployAzureVMs) }
if (-not $PSBoundParameters.ContainsKey('DeployContainerApps')) { $DeployContainerApps = [bool](Get-DemoSkinValue -Skin $skin -Path 'workloads.deployContainerApps' -Default $DeployContainerApps) }
if (-not $PSBoundParameters.ContainsKey('DeployAks')) { $DeployAks = [bool](Get-DemoSkinValue -Skin $skin -Path 'workloads.deployAks' -Default $DeployAks) }
if (-not $PSBoundParameters.ContainsKey('OnPremFleetPath')) { $OnPremFleetPath = Get-DemoSkinValue -Skin $skin -Path 'workloads.onPremFleetPath' -Default $OnPremFleetPath }
if (-not $PSBoundParameters.ContainsKey('VmSize')) { $VmSize = Get-DemoSkinValue -Skin $skin -Path 'compute.vmSize' -Default $VmSize }
if (-not $PSBoundParameters.ContainsKey('AutoShutdownTime')) { $AutoShutdownTime = Get-DemoSkinValue -Skin $skin -Path 'operations.autoShutdownTime' -Default $AutoShutdownTime }
if (-not $PSBoundParameters.ContainsKey('AutoShutdownTimezone')) { $AutoShutdownTimezone = Get-DemoSkinValue -Skin $skin -Path 'operations.autoShutdownTimezone' -Default $AutoShutdownTimezone }
if (-not $PSBoundParameters.ContainsKey('BudgetAmount')) { $BudgetAmount = [int](Get-DemoSkinValue -Skin $skin -Path 'cost.monthlyBudgetAmount' -Default $BudgetAmount) }
if ($PSBoundParameters.ContainsKey('InstallSql') -and $PSBoundParameters.ContainsKey('SkipSqlInstall')) {
    throw 'Use only one of -InstallSql or -SkipSqlInstall. SQL is skipped by default; pass -InstallSql only for the optional advanced SQL path.'
}
$defaultInstallSql = [bool](Get-DemoSkinValue -Skin $skin -Path 'workloads.installSql' -Default (-not [bool](Get-DemoSkinValue -Skin $skin -Path 'workloads.skipSqlInstall' -Default $true)))
if ($PSBoundParameters.ContainsKey('SkipSqlInstall')) {
    $InstallSql = -not [bool]$SkipSqlInstall
} elseif (-not $PSBoundParameters.ContainsKey('InstallSql')) {
    $InstallSql = [switch]$defaultInstallSql
}
if ([string]::IsNullOrWhiteSpace($AdminEmail)) {
    throw 'AdminEmail is required. Pass -AdminEmail or set notifications.email in config\demo-skin.json.'
}
if ($AdminEmail -ieq 'you@contoso.com') {
    throw "AdminEmail is still the placeholder '$AdminEmail'. Pass -AdminEmail with a real operator email or update notifications.email in the skin file before deploying."
}

$demoTags = Merge-DemoHashtable -Defaults ([ordered]@{
    owner = 'demo'
    purpose = 'arc-demo'
    costcenter = 'demo'
    env = 'demo'
}) -Overrides (Get-DemoSkinValue -Skin $skin -Path 'tags' -Default @{})
$arcOnboardingTags = ConvertTo-DemoTagString -Tags $demoTags
$demoTitle = Get-DemoSkinValue -Skin $skin -Path 'labels.demoTitle' -Default 'Arc Demo'
$workbookTitle = Get-DemoSkinValue -Skin $skin -Path 'labels.workbookTitle' -Default "$demoTitle — Estate Overview"

function New-CountBasedOnPremFleet {
    param(
        [int]$WindowsVmCount,
        [int]$LinuxVmCount
    )

    $fleet = @()
    for ($i = 0; $i -lt $WindowsVmCount; $i++) {
        $isSql = $i -lt 2
        $fleet += @{
            name                   = if ($isSql) { 'win-sql-0{0}' -f ($i + 1) } else { 'win-app-0{0}' -f ($i - 1) }
            role                   = if ($isSql) { 'sql' } else { 'app' }
            osType                 = 'Windows'
            osTier                 = 'WS2022'
            imagePublisher         = 'MicrosoftWindowsServer'
            imageOffer             = 'WindowsServer'
            imageSku               = '2022-datacenter-azure-edition'
            imageVersion           = 'latest'
            deploymentMode         = 'azure-vm'
            monitorTier            = 'full-monitor'
            supportsAzureMonitor   = $true
            supportsVmInsights     = $true
            supportsChangeTracking = $true
            supportsSql            = $isSql
            esuEligible            = $false
        }
    }

    for ($i = 0; $i -lt $LinuxVmCount; $i++) {
        $fleet += @{
            name                   = 'lnx-app-0{0}' -f ($i + 1)
            role                   = 'app'
            osType                 = 'Linux'
            osTier                 = 'Ubuntu22.04'
            imagePublisher         = 'Canonical'
            imageOffer             = '0001-com-ubuntu-server-jammy'
            imageSku               = '22_04-lts-gen2'
            imageVersion           = 'latest'
            deploymentMode         = 'azure-vm'
            monitorTier            = 'full-monitor-no-vmi-map'
            supportsAzureMonitor   = $true
            supportsVmInsights     = $false
            supportsChangeTracking = $true
            supportsSql            = $false
            esuEligible            = $false
        }
    }

    return $fleet
}

function Get-ArcMachineTagArgs {
    param(
        [Parameter(Mandatory)]$Machine,
        [System.Collections.IDictionary]$BaseTags = @{}
    )

    $tags = [ordered]@{}
    foreach ($key in $BaseTags.Keys) {
        $tags[$key] = $BaseTags[$key]
    }
    $tags['role'] = $Machine.role
    $tags['osType'] = $Machine.osType
    $tags['osTier'] = $Machine.osTier
    $tags['monitorTier'] = $Machine.monitorTier
    $tags['esuEligible'] = ([string]$Machine.esuEligible).ToLowerInvariant()
    $tags['updateManager'] = 'assessment'
    $tags['defender'] = 'plan2'
    $tags['machineConfig'] = 'enabled'
    $tags['inventory'] = 'arc'

    return @($tags.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value })
}

function Get-LogAnalyticsTableNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceId)

    $names = @()
    $url = "https://management.azure.com${WorkspaceId}/tables?api-version=2022-10-01"
    do {
        $response = Invoke-AzRest -Method Get -Url $url
        $names += @($response.value | ForEach-Object { $_.name } | Where-Object { $_ })
        $url = $response.nextLink
    } while ($url)

    return @($names | Sort-Object -Unique)
}

function Wait-LogAnalyticsTables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string[]]$TableNames,
        [Parameter(Mandatory)][string]$Label,
        [int]$TimeoutSeconds = 300
    )

    $script:MissingLawTables = @($TableNames)
    $ready = Wait-Until -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 30 -Message "$Label tables" -Condition {
        $tables = @(Get-LogAnalyticsTableNames -WorkspaceId $WorkspaceId)
        $script:MissingLawTables = @($TableNames | Where-Object { $_ -notin $tables })
        return $script:MissingLawTables.Count -eq 0
    }

    if ($ready) {
        Write-Ok "$Label tables ready: $($TableNames -join ', ')"
    } else {
        Write-Warn "$Label tables not all visible yet after $TimeoutSeconds seconds: $($script:MissingLawTables -join ', ')"
    }

    return $ready
}

function Invoke-DcrPutWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$DcrId,
        [Parameter(Mandatory)][hashtable]$Body,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [string[]]$RequiredTables = @(),
        [int]$TableTimeoutSeconds = 300,
        [int]$PutTimeoutSeconds = 1200
    )

    if ($RequiredTables.Count -gt 0) {
        Wait-LogAnalyticsTables -WorkspaceId $WorkspaceId -TableNames $RequiredTables -Label $DisplayName -TimeoutSeconds $TableTimeoutSeconds | Out-Null
    }

    $deadline = (Get-Date).AddSeconds($PutTimeoutSeconds)
    $attempt = 0
    do {
        $attempt++
        try {
            $null = Invoke-AzRest -Method Put `
                -Url "https://management.azure.com${DcrId}?api-version=2023-03-11" `
                -Body $Body
            Write-Ok "$DisplayName DCR upserted"
            return
        } catch {
            $detail = @($_.ErrorDetails.Message, $_.Exception.Message) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -First 1
            if ((Get-Date) -ge $deadline) {
                throw "Timed out creating $DisplayName DCR after $attempt attempts. Last error: $detail"
            }
            $sleepSeconds = [Math]::Min(60, 10 * $attempt)
            Write-Warn "$DisplayName DCR PUT attempt $attempt failed; retrying in $sleepSeconds seconds. Last error: $detail"
            Start-Sleep -Seconds $sleepSeconds
        }
    } while ((Get-Date) -lt $deadline)
}

function Set-DataCollectionRuleAssociation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScopeResourceId,
        [Parameter(Mandatory)][string]$AssociationName,
        [Parameter(Mandatory)][string]$DcrId,
        [string]$Description = ''
    )

    $properties = @{ dataCollectionRuleId = $DcrId }
    if ($Description) {
        $properties.description = $Description
    }
    $body = @{ properties = $properties }
    Invoke-AzRest -Method Put `
        -Url "https://management.azure.com$ScopeResourceId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$AssociationName?api-version=2022-06-01" `
        -Body $body | Out-Null
}

function New-CoreDcrBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Tags,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$WorkspaceName
    )

    return @{
        location = $Location
        tags = $Tags
        properties = @{
            description = 'Core perf + events + syslog for the Arc demo fleet'
            dataSources = @{
                performanceCounters = @(
                    @{
                        name = 'perfCounters'
                        streams = @('Microsoft-Perf')
                        samplingFrequencyInSeconds = 60
                        counterSpecifiers = @(
                            '\Processor Information(_Total)\% Processor Time'
                            '\Memory\% Committed Bytes In Use'
                            '\Memory\Available MBytes'
                            '\LogicalDisk(_Total)\% Free Space'
                            '\Network Interface(*)\Bytes Total/sec'
                            '\Processor(*)\% Processor Time'
                            '\Memory(*)\AvailableMemory'
                            '\Memory(*)\PercentUsedMemory'
                            '\Logical Disk(*)\FreeSpacePercentage'
                            '\Network(*)\TotalBytesTransmitted'
                            '\Network(*)\TotalBytesReceived'
                        )
                    }
                )
                windowsEventLogs = @(
                    @{
                        name = 'winEvents'
                        streams = @('Microsoft-Event')
                        xPathQueries = @(
                            'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
                            'System!*[System[(Level=1 or Level=2 or Level=3)]]'
                            'Security!*[System[(band(Keywords,4503599627370496))]]'
                        )
                    }
                )
                syslog = @(
                    @{
                        name = 'linuxSyslog'
                        streams = @('Microsoft-Syslog')
                        facilityNames = @('auth', 'authpriv', 'cron', 'daemon', 'kern', 'syslog', 'user')
                        logLevels = @('Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency')
                    }
                )
            }
            destinations = @{
                logAnalytics = @(
                    @{
                        name = $WorkspaceName
                        workspaceResourceId = $WorkspaceId
                    }
                )
            }
            dataFlows = @(
                @{ streams = @('Microsoft-Perf'); destinations = @($WorkspaceName) }
                @{ streams = @('Microsoft-Event'); destinations = @($WorkspaceName) }
                @{ streams = @('Microsoft-Syslog'); destinations = @($WorkspaceName) }
            )
        }
    }
}

function New-VmInsightsDcrBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Tags,
        [Parameter(Mandatory)][string]$WorkspaceId
    )

    return @{
        location = $Location
        tags = $Tags
        properties = @{
            description = 'VM Insights DCR (perf + map)'
            dataSources = @{
                performanceCounters = @(
                    @{
                        name = 'VMInsightsPerfCounters'
                        streams = @('Microsoft-InsightsMetrics')
                        samplingFrequencyInSeconds = 60
                        counterSpecifiers = @('\VmInsights\DetailedMetrics')
                    }
                )
                extensions = @(
                    @{
                        name = 'DependencyAgentDataSource'
                        streams = @('Microsoft-ServiceMap')
                        extensionName = 'DependencyAgent'
                    }
                )
            }
            destinations = @{
                logAnalytics = @(
                    @{
                        name = 'VMInsightsPerf-Logs-Dest'
                        workspaceResourceId = $WorkspaceId
                    }
                )
            }
            dataFlows = @(
                @{ streams = @('Microsoft-InsightsMetrics'); destinations = @('VMInsightsPerf-Logs-Dest') }
                @{ streams = @('Microsoft-ServiceMap'); destinations = @('VMInsightsPerf-Logs-Dest') }
            )
        }
    }
}

function New-ChangeTrackingDcrBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Tags,
        [Parameter(Mandatory)][string]$WorkspaceId
    )

    return @{
        location = $Location
        tags = $Tags
        properties = @{
            description = 'Change Tracking & Inventory DCR'
            dataSources = @{
                extensions = @(
                    @{
                        name = 'CTDataSource-Windows'
                        streams = @('Microsoft-ConfigurationChange', 'Microsoft-ConfigurationChangeV2', 'Microsoft-ConfigurationData')
                        extensionName = 'ChangeTracking-Windows'
                        extensionSettings = @{
                            enableFiles = $true; enableSoftware = $true; enableRegistry = $true
                            enableServices = $true; enableInventory = $true
                            registrySettings = @{ registryCollectionFrequency = 3000; registryInfo = @() }
                            fileSettings = @{ fileCollectionFrequency = 2700 }
                            softwareSettings = @{ softwareCollectionFrequency = 1800 }
                            inventorySettings = @{ inventoryCollectionFrequency = 36000 }
                            servicesSettings = @{ serviceCollectionFrequency = 1800 }
                        }
                    }
                    @{
                        name = 'CTDataSource-Linux'
                        streams = @('Microsoft-ConfigurationChange', 'Microsoft-ConfigurationChangeV2', 'Microsoft-ConfigurationData')
                        extensionName = 'ChangeTracking-Linux'
                        extensionSettings = @{
                            enableFiles = $true; enableSoftware = $true; enableRegistry = $false
                            enableServices = $true; enableInventory = $true
                            fileSettings = @{ fileCollectionFrequency = 900; fileInfo = @() }
                            softwareSettings = @{ softwareCollectionFrequency = 300 }
                            inventorySettings = @{ inventoryCollectionFrequency = 36000 }
                            servicesSettings = @{ serviceCollectionFrequency = 300 }
                        }
                    }
                )
            }
            destinations = @{
                logAnalytics = @(@{ name = 'Microsoft-CT-Dest'; workspaceResourceId = $WorkspaceId })
            }
            dataFlows = @(@{
                streams = @('Microsoft-ConfigurationChange', 'Microsoft-ConfigurationChangeV2', 'Microsoft-ConfigurationData')
                destinations = @('Microsoft-CT-Dest')
            })
        }
    }
}

# Phase 1: pre-flight
$principalId = Test-Prerequisites -SubscriptionId $SubscriptionId -TenantId $TenantId -DeployerPrincipalId $DeployerPrincipalId

$arcRg   = "rg-$NamePrefix"
$infraRg = "rg-$NamePrefix-infra"
$kvPrefix = "kv-$($NamePrefix -replace '-','')"
$kvName = az keyvault list -g $infraRg --query "[?starts_with(name, '$kvPrefix')].name | [0]" -o tsv 2>$null
if ($kvName) {
    Write-Step "Found existing Key Vault $kvName — preserving for idempotent redeploy"
} else {
    $kvName  = New-KeyVaultName -Prefix $kvPrefix
    $kvName  = $kvName.Substring(0, [Math]::Min(24, $kvName.Length))
}

# Phase 2: generate password, deploy Bicep
Write-Header 'Generating admin password + deploying Bicep'
$adminPwd = New-StrongPassword -Length 24

$paramFile = Join-Path $env:TEMP "arc-demo-params-$(Get-Random).json"

# Idempotency: if Activate-ArcDemo previously created a NAT Gateway, look it up
# and pass the ID through to the network module so the subnet's natGateway
# attachment is preserved on this redeploy. Without this, ARM strips the attach.
$existingNatGwId = az network nat gateway show -g "rg-$NamePrefix-infra" -n "natgw-$NamePrefix" --query id -o tsv 2>$null
if ($existingNatGwId) {
    Write-Step "Found existing NAT Gateway natgw-$NamePrefix — will preserve subnet attachment"
} else {
    $existingNatGwId = ''
}

# Idempotency: preserve the existing budget start date. Azure refuses to change
# the start date of an existing budget; without this guard, redeploys would fail.
$existingBudgetStart = az consumption budget show --budget-name "budget-$NamePrefix" --query "timePeriod.startDate" -o tsv 2>$null
if ($existingBudgetStart) {
    # Normalise to YYYY-MM-01 (Azure returns full ISO timestamp)
    $existingBudgetStart = $existingBudgetStart.Substring(0, 7) + '-01'
    Write-Step "Found existing budget budget-$NamePrefix (start $existingBudgetStart) — preserving"
} else {
    $existingBudgetStart = (Get-Date).ToUniversalTime().ToString('yyyy-MM-01')
}

$onPremFleet = $null
if ($OnPremFleetPath) {
    if (-not [System.IO.Path]::IsPathRooted($OnPremFleetPath)) {
        $OnPremFleetPath = Join-Path $repoRoot $OnPremFleetPath
    }
    $resolvedFleetPath = (Resolve-Path -Path $OnPremFleetPath).Path
    $onPremFleet = @((Get-Content -Path $resolvedFleetPath -Raw | ConvertFrom-Json -Depth 20))
    Write-Step "Using on-prem fleet config from $resolvedFleetPath ($($onPremFleet.Count) entries)"
} elseif ($PSBoundParameters.ContainsKey('WindowsVmCount') -or $PSBoundParameters.ContainsKey('LinuxVmCount')) {
    Write-Warn 'WindowsVmCount/LinuxVmCount are deprecated; generating a count-based WS2022/Ubuntu fleet. Prefer -OnPremFleetPath for OS-mix demos.'
    $onPremFleet = @(New-CountBasedOnPremFleet -WindowsVmCount $WindowsVmCount -LinuxVmCount $LinuxVmCount)
}

$templateParameters = @{
    location                = @{ value = $Location }
    arcResourceGroup        = @{ value = $arcRg }
    infraResourceGroup      = @{ value = $infraRg }
    namePrefix              = @{ value = $NamePrefix }
    tags                    = @{ value = $demoTags }
    demoTitle               = @{ value = $demoTitle }
    deployArcOnPrem         = @{ value = $DeployArcOnPrem }
    deployAzureVMs          = @{ value = $DeployAzureVMs }
    deployContainerApps     = @{ value = $DeployContainerApps }
    deployAks               = @{ value = $DeployAks }
    existingNatGatewayId    = @{ value = $existingNatGwId }
    existingBudgetStartDate = @{ value = $existingBudgetStart }
    tenantId                = @{ value = $TenantId }
    deployerPrincipalId     = @{ value = $principalId }
    keyVaultName            = @{ value = $kvName }
    adminUsername           = @{ value = 'azureuser' }
    adminPassword           = @{ value = $adminPwd }
    vmSize                  = @{ value = $VmSize }
    autoShutdownTime        = @{ value = $AutoShutdownTime }
    autoShutdownTimezone    = @{ value = $AutoShutdownTimezone }
    adminEmail              = @{ value = $AdminEmail }
    budgetAmount            = @{ value = $BudgetAmount }
}
if ($null -ne $onPremFleet) {
    $templateParameters.onPremFleet = @{ value = $onPremFleet }
}

@{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = $templateParameters
} | ConvertTo-Json -Depth 12 | ForEach-Object {
    # Use raw .NET write so the file is created even when the script is invoked with
    # -WhatIf. Set-Content respects ShouldProcess (because CmdletBinding declares
    # SupportsShouldProcess), which would otherwise skip the write and break the
    # subsequent `az deployment sub what-if` call that consumes this file.
    [System.IO.File]::WriteAllText($paramFile, $_, [System.Text.UTF8Encoding]::new($false))
}

$deploymentName = "arc-demo-$(Get-Date -Format yyyyMMdd-HHmmss)"
$bicepFile = Join-Path $repoRoot 'bicep\main.bicep'

if ($WhatIfPreference) {
    Write-Step 'Running Bicep what-if...'
    az deployment sub what-if --name $deploymentName --location $Location `
        --template-file $bicepFile --parameters @$paramFile --only-show-errors
    [System.IO.File]::Delete($paramFile)
    return
}

Write-Step "Deploying main.bicep (deployment: $deploymentName)..."
az deployment sub create --name $deploymentName --location $Location `
    --template-file $bicepFile --parameters @$paramFile --only-show-errors -o none
if ($LASTEXITCODE -ne 0) {
    if ([System.IO.File]::Exists($paramFile)) { [System.IO.File]::Delete($paramFile) }
    throw "Bicep deployment failed. Inspect with: az deployment sub show --name $deploymentName"
}
$outputs = az deployment sub show --name $deploymentName --query properties.outputs -o json | ConvertFrom-Json
[System.IO.File]::Delete($paramFile)
Write-Ok 'Bicep deployment complete'

$workspaceId = $outputs.workspaceId.value
$workspaceName = ($workspaceId -split '/')[-1]
$workspaceCustomerId = $outputs.workspaceCustomerId.value
$deployedFleet = @(@($outputs.vmFleet.value) | Where-Object { $_ -and $_.deployed -eq $true })
$vmNames     = @($deployedFleet | Select-Object -ExpandProperty name)
$azureVmNames = @($outputs.azureVmNames.value | Where-Object { $_ })
$azureVmResourceIds = @($outputs.azureVmResourceIds.value | Where-Object { $_ })
$dcrCoreId   = $outputs.dcrCoreId.value
$dcrVmiId    = $outputs.dcrVmiId.value
$dcrCtId     = $outputs.dcrCtId.value
$winVms = @($deployedFleet | Where-Object { $_.osType -eq 'Windows' } | Select-Object -ExpandProperty name)
$lnxVms = @($deployedFleet | Where-Object { $_.osType -eq 'Linux' } | Select-Object -ExpandProperty name)
$monitorFleet = @($deployedFleet | Where-Object { $_.supportsAzureMonitor -eq $true })
$monitorVms = @($monitorFleet | Select-Object -ExpandProperty name)
$monitorWindowsVms = @($monitorFleet | Where-Object { $_.osType -eq 'Windows' } | Select-Object -ExpandProperty name)
$monitorLinuxVms = @($monitorFleet | Where-Object { $_.osType -eq 'Linux' } | Select-Object -ExpandProperty name)
$vmInsightsFleet = @($deployedFleet | Where-Object { $_.supportsVmInsights -eq $true })
$vmInsightsWindowsVms = @($vmInsightsFleet | Where-Object { $_.osType -eq 'Windows' } | Select-Object -ExpandProperty name)
$changeTrackingFleet = @($deployedFleet | Where-Object { $_.supportsChangeTracking -eq $true })
$changeTrackingWindowsVms = @($changeTrackingFleet | Where-Object { $_.osType -eq 'Windows' } | Select-Object -ExpandProperty name)
$changeTrackingLinuxVms = @($changeTrackingFleet | Where-Object { $_.osType -eq 'Linux' } | Select-Object -ExpandProperty name)
$sqlVms = @($deployedFleet | Where-Object { $_.supportsSql -eq $true } | Select-Object -ExpandProperty name)
$arcOnlyVms = @($deployedFleet | Where-Object { $_.supportsAzureMonitor -ne $true } | Select-Object -ExpandProperty name)

if ($deployedFleet.Count -gt 0) {
    $fleetSummary = $deployedFleet | Group-Object osTier | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }
    Write-Step "On-prem fleet: $($deployedFleet.Count) deployed entries ($($fleetSummary -join ', ')); $($monitorVms.Count) Monitor-supported, $($arcOnlyVms.Count) Arc-control-plane-only"
}

# Phase 2.5: Create all DCRs after Log Analytics/solution tables are ready.
Write-Header 'Phase 2.5 — Data Collection Rules (post-Bicep)'
$coreDcrBody = New-CoreDcrBody -Location $Location -Tags $demoTags -WorkspaceId $workspaceId -WorkspaceName $workspaceName
$vmiDcrBody = New-VmInsightsDcrBody -Location $Location -Tags $demoTags -WorkspaceId $workspaceId
$ctDcrBody = New-ChangeTrackingDcrBody -Location $Location -Tags $demoTags -WorkspaceId $workspaceId

Invoke-DcrPutWithRetry -DisplayName 'Core' -DcrId $dcrCoreId -Body $coreDcrBody -WorkspaceId $workspaceId -RequiredTables @('Perf', 'Event', 'Syslog')
Invoke-DcrPutWithRetry -DisplayName 'VM Insights' -DcrId $dcrVmiId -Body $vmiDcrBody -WorkspaceId $workspaceId -RequiredTables @('InsightsMetrics')
Invoke-DcrPutWithRetry -DisplayName 'Change Tracking' -DcrId $dcrCtId -Body $ctDcrBody -WorkspaceId $workspaceId -RequiredTables @('ConfigurationData')

if ($DeployAzureVMs -and $azureVmResourceIds.Count -gt 0) {
    Write-Header 'Phase 2.6 — Azure-native VM DCR associations'
    for ($i = 0; $i -lt $azureVmResourceIds.Count; $i++) {
        $nativeVmName = $azureVmNames[$i]
        $nativeVmId = $azureVmResourceIds[$i]
        Set-DataCollectionRuleAssociation `
            -ScopeResourceId $nativeVmId `
            -AssociationName "dcra-core-$nativeVmName" `
            -DcrId $dcrCoreId `
            -Description "Core Arc demo logs and performance for Azure-native VM $nativeVmName."
        Set-DataCollectionRuleAssociation `
            -ScopeResourceId $nativeVmId `
            -AssociationName "dcra-vmi-$nativeVmName" `
            -DcrId $dcrVmiId `
            -Description "VM Insights data for Azure-native VM $nativeVmName."
    }
    Write-Ok "Azure-native VM DCRAs created: $($azureVmResourceIds.Count * 2)"
}

# Phase 3: NAT Gateway (separate so Hibernate can delete it)
Write-Header 'Phase 3 — NAT Gateway'
$natName = "natgw-$NamePrefix"
$pipName = "pip-natgw-$NamePrefix"
$vnetName = "vnet-$NamePrefix"
$pipExists = az network public-ip show -g $infraRg -n $pipName --query id -o tsv 2>$null
if (-not $pipExists) {
    az network public-ip create -g $infraRg -n $pipName -l $Location `
        --sku Standard --allocation-method Static --only-show-errors -o none
    Write-Ok "Public IP created ($pipName)"
} else { Write-Ok 'Public IP already exists' }

$natExists = az network nat gateway show -g $infraRg -n $natName --query id -o tsv 2>$null
if (-not $natExists) {
    az network nat gateway create -g $infraRg -n $natName -l $Location `
        --public-ip-addresses $pipName --idle-timeout 10 --only-show-errors -o none
    Write-Ok "NAT Gateway created ($natName)"
} else { Write-Ok 'NAT Gateway already exists' }

$attached = az network vnet subnet show -g $infraRg --vnet-name $vnetName -n snet-vms --query "natGateway.id" -o tsv 2>$null
if (-not $attached) {
    az network vnet subnet update -g $infraRg --vnet-name $vnetName -n snet-vms `
        --nat-gateway $natName --only-show-errors -o none
    Write-Ok 'NAT Gateway attached to subnet'
} else { Write-Ok 'Subnet already has NAT GW' }

if ($DeployArcOnPrem -and $vmNames.Count -gt 0) {
# Phase 4: Arc onboarding SPN (idempotent)
Write-Header 'Phase 4 — Arc onboarding service principal'
$spnAppId = az ad sp list --display-name "sp-$NamePrefix-onboard" --query "[0].appId" -o tsv 2>$null
if ($spnAppId) {
    Write-Ok "SPN already exists ($spnAppId). Resetting credential to allow re-onboarding..."
    $spnSecret = az ad sp credential reset --id $spnAppId --query password -o tsv
} else {
    $spnJson = az ad sp create-for-rbac --name "sp-$NamePrefix-onboard" `
        --role "Azure Connected Machine Onboarding" `
        --scopes "/subscriptions/$SubscriptionId/resourceGroups/$arcRg" `
        --only-show-errors -o json | ConvertFrom-Json
    $spnAppId  = $spnJson.appId
    $spnSecret = $spnJson.password
    Write-Ok "SPN created ($spnAppId)"
}

# Helper script files
$libDir   = Join-Path $env:TEMP "arc-demo-onboard-$(Get-Random)"
New-Item -ItemType Directory -Path $libDir -Force | Out-Null
$winOnboard = @"
`$env:MSFT_ARC_TEST = 'true'
[Environment]::SetEnvironmentVariable('MSFT_ARC_TEST','true','Machine')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri https://aka.ms/AzureConnectedMachineAgent -OutFile `$env:TEMP\acm.msi -UseBasicParsing
Start-Process msiexec.exe -Wait -ArgumentList "/i `$env:TEMP\acm.msi /qn"
& "`$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe" connect ``
  --service-principal-id $spnAppId --service-principal-secret '$spnSecret' ``
  --resource-group $arcRg --tenant-id $TenantId --location $Location ``
  --subscription-id $SubscriptionId ``
  --tags "$arcOnboardingTags"
"@
$lnxOnboard = @"
set -e
curl -sSL https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -o /tmp/pmp.deb
sudo dpkg -i /tmp/pmp.deb
sudo apt-get update -qq
sudo apt-get install -y azcmagent
sudo MSFT_ARC_TEST=true azcmagent connect \
  --service-principal-id $spnAppId --service-principal-secret '$spnSecret' \
  --resource-group $arcRg --tenant-id $TenantId --location $Location \
  --subscription-id $SubscriptionId \
  --tags "$arcOnboardingTags"
"@
$winFile = Join-Path $libDir 'arc-win.ps1'
$lnxFile = Join-Path $libDir 'arc-lnx.sh'
[System.IO.File]::WriteAllText($winFile, $winOnboard, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($lnxFile, $lnxOnboard, [System.Text.UTF8Encoding]::new($false))

# Phase 5: Arc onboarding (parallel, skips already-Connected machines)
Write-Header 'Phase 5 — Arc onboarding (parallel)'
$alreadyArc = (az connectedmachine list -g $arcRg --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ }
$toOnboardFleet = @($deployedFleet | Where-Object { $_.name -notin $alreadyArc })
if (-not $toOnboardFleet) {
    Write-Ok 'All VMs already Arc-onboarded — skipping'
} else {
    Write-Step "Onboarding $($toOnboardFleet.Count) of $($vmNames.Count) VMs..."
    $jobs = @()
    foreach ($machine in $toOnboardFleet) {
        $vm = $machine.name
        $isWin = $machine.osType -eq 'Windows'
        $jobs += Start-Job -Name "onboard-$vm" -ScriptBlock {
            param($vm, $isWin, $infraRg, $f)
            $cmdId = if ($isWin) { 'RunPowerShellScript' } else { 'RunShellScript' }
            az vm run-command invoke -g $infraRg -n $vm --command-id $cmdId --scripts "@$f" --only-show-errors -o tsv 2>&1
        } -ArgumentList $vm, $isWin, $infraRg, ($(if ($isWin) { $winFile } else { $lnxFile }))
    }
    $jobs | Wait-Job -Timeout 1800 | Out-Null
    foreach ($j in $jobs) {
        $out = (Receive-Job $j 2>&1 | Out-String)
        if ($out -match 'Successfully Onboarded|ProvisioningState/succeeded|Connected') {
            Write-Ok $j.Name
        } else {
            Write-Warn "$($j.Name) — check Arc portal"
        }
        Remove-Job $j -Force
    }
}
Write-Step 'Waiting for all Arc machines to report Connected...'
$ok = Wait-Until -TimeoutSeconds 600 -IntervalSeconds 30 -Message 'Arc Connected' -Condition {
    $connected = (az connectedmachine list -g $arcRg --query "[?status=='Connected'].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ }
    return $connected.Count -ge $vmNames.Count
}
if (-not $ok) { throw 'Timed out waiting for all Arc machines to be Connected' }
Write-Ok 'All Arc machines Connected'

Write-Step 'Tagging Arc machines with OS, monitoring, and control-plane metadata...'
foreach ($machine in $deployedFleet) {
    $tagArgs = Get-ArcMachineTagArgs -Machine $machine -BaseTags $demoTags
    az connectedmachine update -g $arcRg -n $($machine.name) --tags $tagArgs --only-show-errors -o none
}
Write-Ok 'Arc machine tags updated'

Remove-Item $libDir -Recurse -Force

# Phase 6: AMA (Windows via Arc, Linux via Azure VM) + DCR associations to Arc resource
Write-Header 'Phase 6 — Azure Monitor Agent + DCR associations'

$jobs = @()
foreach ($vm in $monitorWindowsVms) {
    $jobs += Start-Job -ScriptBlock {
        param($vm, $rg)
        az connectedmachine extension create -g $rg --machine-name $vm `
          -n AzureMonitorWindowsAgent --publisher Microsoft.Azure.Monitor `
          --type AzureMonitorWindowsAgent --enable-auto-upgrade true `
          --only-show-errors -o tsv 2>&1 | Out-Null
    } -ArgumentList $vm, $arcRg
}
foreach ($vm in $monitorLinuxVms) {
    $jobs += Start-Job -ScriptBlock {
        param($vm, $rg)
        az vm extension set -g $rg --vm-name $vm -n AzureMonitorLinuxAgent `
          --publisher Microsoft.Azure.Monitor --enable-auto-upgrade true `
          --only-show-errors -o tsv 2>&1 | Out-Null
    } -ArgumentList $vm, $infraRg
}
if ($jobs.Count -gt 0) {
    Write-Step "Installing AMA on $($monitorVms.Count) Monitor-supported machines (parallel)..."
    $jobs | Wait-Job -Timeout 1800 | Out-Null
    $jobs | ForEach-Object { Remove-Job $_ -Force }
    Write-Ok 'AMA installs submitted'
} else {
    Write-Warn 'No Monitor-supported machines in the deployed fleet — skipping AMA installs'
}

$dcraCount = 0
Write-Step 'Associating DCRs only with Monitor-supported Arc resources...'
foreach ($machine in $monitorFleet) {
    $vm = $machine.name
    $resId = "/subscriptions/$SubscriptionId/resourceGroups/$arcRg/providers/Microsoft.HybridCompute/machines/$vm"
    foreach ($pair in @(
        @{ name = "dcra-core-$vm"; id = $dcrCoreId; enabled = $machine.supportsAzureMonitor }
        @{ name = "dcra-vmi-$vm";  id = $dcrVmiId; enabled = $machine.supportsVmInsights }
        @{ name = "dcra-ct-$vm";   id = $dcrCtId; enabled = $machine.supportsChangeTracking }
    ) | Where-Object { $_.enabled -eq $true }) {
        $body = @{ properties = @{ dataCollectionRuleId = $pair.id } }
        Invoke-AzRest -Method Put `
            -Url "https://management.azure.com$resId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($pair.name)?api-version=2022-06-01" `
            -Body $body | Out-Null
        $dcraCount++
    }
}
Write-Ok "DCRAs created: $dcraCount associations across $($monitorVms.Count) Monitor-supported machines"
if ($arcOnlyVms.Count -gt 0) {
    Write-Ok "Arc-control-plane-only machines skipped for AMA/DCR/VM Insights/Change Tracking: $($arcOnlyVms -join ', ')"
}

# Phase 7: Dependency Agent (Windows VM Insights-supported only)
Write-Header 'Phase 7 — Dependency Agent (VM Insights-supported Windows only)'
$jobs = @()
foreach ($vm in $vmInsightsWindowsVms) {
    $jobs += Start-Job -ScriptBlock {
        param($vm, $rg)
        az connectedmachine extension create -g $rg --machine-name $vm `
          -n DependencyAgentWindows --publisher Microsoft.Azure.Monitoring.DependencyAgent `
          --type DependencyAgentWindows --enable-auto-upgrade true `
          --only-show-errors -o tsv 2>&1 | Out-Null
    } -ArgumentList $vm, $arcRg
}
if ($jobs.Count -gt 0) {
    $jobs | Wait-Job -Timeout 1800 | Out-Null
    $jobs | ForEach-Object { Remove-Job $_ -Force }
    Write-Ok 'Dependency Agent installed on VM Insights-supported Windows VMs'
} else {
    Write-Warn 'No VM Insights-supported Windows machines — skipping Dependency Agent'
}

# Phase 8: Change Tracking extension (supported OSes only)
Write-Header 'Phase 8 — Change Tracking extension'
$jobs = @()
foreach ($vm in $changeTrackingWindowsVms) {
    $jobs += Start-Job -ScriptBlock {
        param($vm, $rg)
        az connectedmachine extension create -g $rg --machine-name $vm `
          -n ChangeTracking-Windows --publisher Microsoft.Azure.ChangeTrackingAndInventory `
          --type ChangeTracking-Windows --enable-auto-upgrade true `
          --only-show-errors -o tsv 2>&1 | Out-Null
    } -ArgumentList $vm, $arcRg
}
foreach ($vm in $changeTrackingLinuxVms) {
    $jobs += Start-Job -ScriptBlock {
        param($vm, $rg)
        az connectedmachine extension create -g $rg --machine-name $vm `
          -n ChangeTracking-Linux --publisher Microsoft.Azure.ChangeTrackingAndInventory `
          --type ChangeTracking-Linux --enable-auto-upgrade true `
          --only-show-errors -o tsv 2>&1 | Out-Null
    } -ArgumentList $vm, $arcRg
}
if ($jobs.Count -gt 0) {
    $jobs | Wait-Job -Timeout 1800 | Out-Null
    $jobs | ForEach-Object { Remove-Job $_ -Force }
    Write-Ok 'Change Tracking extension installed on supported machines'
} else {
    Write-Warn 'No Change Tracking-supported machines — skipping extension'
}

# Phase 9: Optional/advanced SQL install
if (-not $InstallSql) {
    if ($sqlVms) {
        Write-Warn 'SQL optional/advanced path disabled — leaving SQL-capable hosts as Windows VMs. SQL Server can still be added later as a workload simulation, but do not claim Arc SQL validation in this Azure-VM-backed lab; see docs/sql-arc-spike.md.'
    } else {
        Write-Warn 'No SQL-capable machines — skipping SQL optional/advanced path'
    }
} elseif ($sqlVms) {
    Write-Header "Phase 9 — Experimental SQL Server 2022 Developer install on $($sqlVms.Count) Azure-VM-backed hosts (~20 min; not a supported Arc SQL validation target)"
    Write-Warn 'This legacy path mixes workload simulation with Arc SQL extension registration. Use only for experimentation; do not claim Arc SQL validation in this Azure-VM-backed lab. See docs/sql-arc-spike.md.'
    $sqlScriptPath = Join-Path $env:TEMP "sql-install-$(Get-Random).ps1"
    $sqlScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$mediaDir = 'C:\SQL2022'
New-Item -ItemType Directory -Path $mediaDir -Force | Out-Null
Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2215158' `
    -OutFile "$mediaDir\SSEI.exe" -UseBasicParsing
& "$mediaDir\SSEI.exe" /ACTION=Download /MEDIAPATH=$mediaDir /MEDIATYPE=ISO /QUIET | Out-Null
Start-Sleep 60
$iso = Get-ChildItem $mediaDir -Filter '*.iso' | Select-Object -First 1
$mount = Mount-DiskImage -ImagePath $iso.FullName -PassThru
$drive = (Get-Volume -DiskImage $mount).DriveLetter
& "${drive}:\setup.exe" /Q /ACTION=Install /FEATURES=SQLENGINE /INSTANCENAME=MSSQLSERVER `
    /SQLSVCACCOUNT='NT AUTHORITY\NETWORK SERVICE' /SQLSYSADMINACCOUNTS='BUILTIN\Administrators' `
    /AGTSVCACCOUNT='NT AUTHORITY\NETWORK SERVICE' /TCPENABLED=1 /SECURITYMODE=SQL `
    /SAPWD='P@ssw0rd-DemoSQL-2026!' /IACCEPTSQLSERVERLICENSETERMS `
    /SUPPRESSPRIVACYSTATEMENTNOTICE /UPDATEENABLED=0 /SQLCOLLATION='SQL_Latin1_General_CP1_CI_AS'
Dismount-DiskImage -ImagePath $iso.FullName | Out-Null
Get-Service MSSQLSERVER | Format-List Name, Status
'@
    [System.IO.File]::WriteAllText($sqlScriptPath, $sqlScript, [System.Text.UTF8Encoding]::new($false))
    $jobs = @()
    foreach ($vm in $sqlVms) {
        $jobs += Start-Job -Name "sql-$vm" -ScriptBlock {
            param($vm, $rg, $f)
            az vm run-command invoke -g $rg -n $vm --command-id RunPowerShellScript --scripts "@$f" --only-show-errors --query "value[0].message" -o tsv 2>&1
        } -ArgumentList $vm, $infraRg, $sqlScriptPath
    }
    $jobs | Wait-Job -Timeout 3600 | Out-Null
    foreach ($j in $jobs) {
        $out = (Receive-Job $j 2>&1 | Out-String)
        if ($out -match 'MSSQLSERVER\s+Running|Status\s*:\s*Running') { Write-Ok $j.Name }
        else { Write-Warn $j.Name }
        Remove-Job $j -Force
    }
    Remove-Item $sqlScriptPath -Force

    Write-Header 'Phase 10 — Arc-enable SQL (BPA + Defender for SQL)'
    foreach ($vm in $sqlVms) {
        az connectedmachine extension create -g $arcRg --machine-name $vm `
          -n WindowsAgent.SqlServer --publisher Microsoft.AzureData --type WindowsAgent.SqlServer `
          --enable-auto-upgrade true `
          --settings '{\"SqlManagement\":{\"IsEnabled\":true}, \"LicenseType\":\"Paid\", \"AzureBestPracticesAssessment\":{\"IsEnabled\":true}}' `
          --only-show-errors -o tsv | Out-Null
    }
    Write-Ok 'WindowsAgent.SqlServer extension installed on SQL hosts'
} else {
    Write-Warn 'InstallSql requested but no deployed fleet entries have supportsSql=true — skipping SQL optional/advanced path'
}
} else {
    Write-Header 'Phases 4-10 — Arc server workload'
    Write-Warn 'DeployArcOnPrem is false or no VM outputs were returned — skipping Arc onboarding, Arc agent extensions, DCR associations, Dependency Agent, Change Tracking extension, and SQL phases'
}

# Phase 11: Workbooks (custom + Nic's library)
Write-Header 'Phase 11 — Workbooks'

function Publish-Workbook {
    param(
        [string]$FilePath,
        [string]$DisplayName,
        [string]$Category = 'workbook'
    )
    if (-not (Test-Path $FilePath)) {
        Write-Warn "Skipping $DisplayName — file not found: $FilePath"
        return
    }
    $wbContent = Get-Content $FilePath -Raw
    # Strip any incoming $schema-incompatible chars
    $wbContent = $wbContent.TrimStart([char]0xFEFF)
    $tag = ($DisplayName -replace '[^A-Za-z0-9]', '-').ToLower()
    # Look for an existing workbook with this tag (idempotent re-runs)
    $existing = az resource list -g $arcRg --resource-type Microsoft.Insights/workbooks `
        --query "[?tags.workbookTag=='$tag'].id" -o tsv 2>$null
    if ($existing) {
        Write-Ok "Workbook '$DisplayName' already exists — skipping"
        return $existing
    }
    $wbGuid = [guid]::NewGuid().ToString()
    $wbBody = @{
        location = $Location
        tags = Merge-DemoHashtable -Defaults $demoTags -Overrides @{ workbookTag = $tag }
        kind = 'shared'
        properties = @{
            displayName    = $DisplayName
            serializedData = $wbContent
            version        = 'Notebook/1.0'
            category       = $Category
            sourceId       = $workspaceId.ToLower()
        }
    }
    $r = Invoke-AzRest -Method Put `
        -Url "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$arcRg/providers/Microsoft.Insights/workbooks/${wbGuid}?api-version=2023-06-01" `
        -Body $wbBody
    Write-Ok "Workbook created: $($r.properties.displayName)"
    return $r.id
}

# Custom one-pager
$customWb = Join-Path $repoRoot 'workbooks\arc-demo-overview.workbook.json'
$wbId = Publish-Workbook -FilePath $customWb -DisplayName $workbookTitle

# Nic Seilaz's workbook collection (vendored snapshot)
$nseilazDir = Join-Path $repoRoot 'workbooks\nseilaz'
$nseilazSet = @(
    @{ file = 'Arc_Compliance_Security_Governance_example.json'; name = 'Arc — Compliance, Security & Governance' }
    @{ file = 'ArcMachineIntelligenceCenter.json';               name = 'Arc — Machine Intelligence Center' }
    @{ file = 'Asset_Inventory_Workbook_Example.json';           name = 'Arc — Asset Inventory' }
    @{ file = 'GovernanceComplianceWorkbook_Experiment.json';    name = 'Arc — Governance & Compliance (experimental)' }
    @{ file = 'SQL_Estate_Dashboard.json';                       name = 'Arc — SQL Estate Dashboard' }
)
foreach ($wb in $nseilazSet) {
    Publish-Workbook -FilePath (Join-Path $nseilazDir $wb.file) -DisplayName $wb.name | Out-Null
}

# Phase 12: validation
Write-Header 'Phase 12 — Validation'
if ($DeployArcOnPrem -and $monitorVms.Count -gt 0) {
Write-Step 'Waiting up to 10 min for first Heartbeats...'
$lawCustId = $workspaceCustomerId
$ok = Wait-Until -TimeoutSeconds 600 -IntervalSeconds 30 -Message 'Heartbeat' -Condition {
    $token = Get-LawQueryToken
    $hdr = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $body = @{ query = 'Heartbeat | where TimeGenerated > ago(10m) | summarize Hosts = dcount(Computer)' } | ConvertTo-Json
    try {
        $r = Invoke-RestMethod -Method Post -Headers $hdr -Body $body `
          -Uri "https://api.loganalytics.io/v1/workspaces/$lawCustId/query"
        $hosts = if ($r.tables[0].rows) { $r.tables[0].rows[0][0] } else { 0 }
        return $hosts -ge $monitorVms.Count
    } catch { return $false }
}
if ($ok) { Write-Ok "Heartbeat received from all $($monitorVms.Count) Monitor-supported hosts" }
else { Write-Warn "Heartbeat not yet from all hosts — check portal, may need a few more minutes" }
} else {
    Write-Warn 'DeployArcOnPrem is false or no Monitor-supported VM outputs were returned — skipping Arc Heartbeat validation'
}

Write-Header '🎉 Deploy complete'
$wbUrl = "https://portal.azure.com/#@$TenantId/resource$wbId"
Write-Host ''
Write-Host "  Workbook:  $wbUrl"
Write-Host "  Arc RG:    https://portal.azure.com/#@$TenantId/resource/subscriptions/$SubscriptionId/resourceGroups/$arcRg/overview"
Write-Host "  Infra RG:  https://portal.azure.com/#@$TenantId/resource/subscriptions/$SubscriptionId/resourceGroups/$infraRg/overview"
Write-Host ''
Write-Host "  Next steps:"
Write-Host "    - Wait ~12h for MCSB/NIST compliance scores to populate."
if ($InstallSql) {
    Write-Host "    - Wait ~30-60m for SQL Best Practice Assessment first run."
} else {
    Write-Host "    - SQL Server/Arc SQL/BPA was skipped by default; use -InstallSql only for the optional advanced path."
}
Write-Host "    - Use ./scripts/Hibernate-ArcDemo.ps1 between demos (~AUD 35/mo)."
Write-Host ''
