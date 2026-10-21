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
      3. Verify explicit NAT outbound before guest onboarding
      4. Arc onboarding service principal
      5. Connected Machine Agent install via VM Run Command for both OS types
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

.PARAMETER AdminPassword
    Current VM admin password as a SecureString for existing labs without the
    saved Key Vault secret. Never pass a new password for routine reconciliation.

.PARAMETER OsDiskStorageAccountType
    StandardSSD_LRS for new OS disks; Standard_LRS is an explicit retained-lab
    choice. Existing disk tiers must already match; deployment never performs
    an incidental conversion. HDD OS disks retire on 8 September 2028.

.PARAMETER OnboardingSecret
    Existing onboarding SP secret as a SecureString when new machines need
    onboarding. Existing credentials are never reset by routine deployment.

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
    Deploy the optional AKS workload. Default false. Routine redeploys of
    existing clusters preserve the sample workload/fault state.

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
    VM SKU. Default Standard_B2as_v2 (2 vCPU / 8 GiB AMD burstable). Check
    regional restrictions/quota; listings and ARM validation do not guarantee
    physical capacity. Do not create probe resources without approval.

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
    .\Deploy-ArcDemo.ps1 -SubscriptionId <SUB> -TenantId <TENANT> `
        -AdminEmail demo@contoso.com
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
    [ValidateSet('Standard_LRS', 'StandardSSD_LRS')][string]$OsDiskStorageAccountType = 'StandardSSD_LRS',
    [string]$AutoShutdownTime = '1900',
    [string]$AutoShutdownTimezone = 'Cen. Australia Standard Time',
    [int]$BudgetAmount = 200,
    [string]$SkinPath = '',
    [securestring]$AdminPassword,
    [securestring]$OnboardingSecret,
    [switch]$InstallSql,
    [switch]$SkipSqlInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force
# Preserve existing CLI call syntax while enforcing one checked, explicit target.
function Invoke-DeploymentAz { Invoke-DemoAz -Arguments $args }
Set-Alias -Name az -Value Invoke-DeploymentAz -Scope Script -WhatIf:$false

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
if (-not $PSBoundParameters.ContainsKey('OsDiskStorageAccountType')) { $OsDiskStorageAccountType = Get-DemoSkinValue -Skin $skin -Path 'compute.osDiskStorageAccountType' -Default $OsDiskStorageAccountType }
if (-not $PSBoundParameters.ContainsKey('AutoShutdownTime')) { $AutoShutdownTime = Get-DemoSkinValue -Skin $skin -Path 'operations.autoShutdownTime' -Default $AutoShutdownTime }
if (-not $PSBoundParameters.ContainsKey('AutoShutdownTimezone')) { $AutoShutdownTimezone = Get-DemoSkinValue -Skin $skin -Path 'operations.autoShutdownTimezone' -Default $AutoShutdownTimezone }
if (-not $PSBoundParameters.ContainsKey('BudgetAmount')) { $BudgetAmount = [int](Get-DemoSkinValue -Skin $skin -Path 'cost.monthlyBudgetAmount' -Default $BudgetAmount) }
Assert-DemoName $NamePrefix
if ($Location -notmatch '^[a-z0-9]+$') { throw 'Location must be an Azure region name.' }
if ($AutoShutdownTime -notmatch '^([01][0-9]|2[0-3])[0-5][0-9]$') { throw 'AutoShutdownTime must be HHmm.' }
if ($BudgetAmount -lt 1) { throw 'BudgetAmount must be positive.' }
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
if ($AdminEmail -in @('you@contoso.com', 'operator@example.com')) {
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
    $workspaceResource = $WorkspaceId
    $ready = Wait-Until -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 30 -Message "$Label tables" -Condition {
        $tables = @(Get-LogAnalyticsTableNames -WorkspaceId $workspaceResource)
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
        -Url "https://management.azure.com$ScopeResourceId/providers/Microsoft.Insights/dataCollectionRuleAssociations/${AssociationName}?api-version=2022-06-01" `
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
$providers = @('Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity',
    'Microsoft.OperationalInsights', 'Microsoft.OperationsManagement', 'Microsoft.Insights', 'Microsoft.Security',
    'Microsoft.PolicyInsights', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.KeyVault', 'Microsoft.DevTestLab', 'Microsoft.Consumption')
if ($DeployContainerApps) { $providers += 'Microsoft.App' }
if ($DeployAks) { $providers += @('Microsoft.ContainerService', 'Microsoft.ManagedIdentity', 'Microsoft.Resources', 'Microsoft.Storage', 'Microsoft.ContainerInstance') }
if ($InstallSql) { $providers += 'Microsoft.AzureArcData' }
$principalId = Test-Prerequisites -SubscriptionId $SubscriptionId -TenantId $TenantId -DeployerPrincipalId $DeployerPrincipalId -Providers $providers

$arcRg   = "rg-$NamePrefix"
$infraRg = "rg-$NamePrefix-infra"
$kvPrefix = "kv-$($NamePrefix -replace '-','')"
$kvName = Invoke-DemoAz -Arguments @('keyvault', 'list', '-g', $infraRg, '--query', "[?starts_with(name, '$kvPrefix')].name | [0]", '-o', 'tsv') -AllowNotFound
if ($kvName) {
    Write-Step "Found existing Key Vault $kvName — preserving for idempotent redeploy"
} else {
    $kvName  = New-KeyVaultName -Prefix $kvPrefix
    $kvName  = $kvName.Substring(0, [Math]::Min(24, $kvName.Length))
}

# Phase 2: generate password, deploy Bicep
Write-Header 'Generating admin password + deploying Bicep'
$existingVms = @(Invoke-DemoAz -Arguments @('vm', 'list', '-g', $infraRg, '-o', 'json') -AllowNotFound | ConvertFrom-Json)
$existingSecret = if ($existingVms.Count -and -not $AdminPassword -and -not $WhatIfPreference) {
    Invoke-DemoAz -Arguments @('keyvault', 'secret', 'show', '--vault-name', $kvName, '-n', 'vm-admin-password', '--query', 'value', '-o', 'tsv') -AllowNotFound
}
if ($AdminPassword) {
    $adminPwd = [System.Net.NetworkCredential]::new('', $AdminPassword).Password
} elseif ($existingSecret) {
    $adminPwd = $existingSecret
} elseif ($existingVms.Count -gt 0 -and -not $WhatIfPreference) {
    throw 'Existing VMs found but no saved admin credential. Supply the CURRENT password as -AdminPassword (SecureString); routine redeploy must not generate or rotate it.'
} else {
    $adminPwd = New-StrongPassword -Length 24
}

$paramFile = Join-Path ([System.IO.Path]::GetTempPath()) "arc-demo-params-$(Get-Random).json"

# Idempotency: if Activate-ArcDemo previously created a NAT Gateway, look it up
# and pass the ID through to the network module so the subnet's natGateway
# attachment is preserved on this redeploy. Without this, ARM strips the attach.
$existingNatGwId = Invoke-DemoAz -Arguments @('network', 'nat', 'gateway', 'show', '-g', $infraRg, '-n', "natgw-$NamePrefix", '--query', 'id', '-o', 'tsv') -AllowNotFound
if ($existingNatGwId) {
    Write-Step "Found existing NAT Gateway natgw-$NamePrefix — will preserve subnet attachment"
} else {
    $existingNatGwId = ''
}

# Idempotency: preserve the existing budget start date. Azure refuses to change
# the start date of an existing budget; without this guard, redeploys would fail.
$existingBudgetStart = Invoke-DemoAz -Arguments @('consumption', 'budget', 'show', '--budget-name', "budget-$NamePrefix", '--query', 'timePeriod.startDate', '-o', 'tsv') -AllowNotFound
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
    $fleetDocument = Get-Content -LiteralPath $resolvedFleetPath -Raw | ConvertFrom-Json -Depth 20 -NoEnumerate
    if ($fleetDocument -isnot [array]) { throw 'OnPremFleetPath must contain a JSON array, not an object.' }
    $onPremFleet = @($fleetDocument)
    Write-Step "Using on-prem fleet config from $resolvedFleetPath ($($onPremFleet.Count) entries)"
} elseif ($PSBoundParameters.ContainsKey('WindowsVmCount') -or $PSBoundParameters.ContainsKey('LinuxVmCount')) {
    Write-Warn 'WindowsVmCount/LinuxVmCount are deprecated; generating a count-based WS2022/Ubuntu fleet. Prefer -OnPremFleetPath for OS-mix demos.'
    $onPremFleet = @(New-CountBasedOnPremFleet -WindowsVmCount $WindowsVmCount -LinuxVmCount $LinuxVmCount)
}
if ($null -eq $onPremFleet) {
    $template = Invoke-DemoAz -Arguments @('bicep', 'build', '--file', (Join-Path $repoRoot 'bicep\main.bicep'), '--stdout') | ConvertFrom-Json -Depth 100
    $onPremFleet = @($template.parameters.onPremFleet.defaultValue)
}
Test-DemoFleet -Fleet $onPremFleet
$nativePrefix = $NamePrefix.Replace('-', '')
$expectedNativeVmName = "az-$($nativePrefix.Substring(0, [Math]::Min(9, $nativePrefix.Length)))-01"
$diskTierTargets = @($existingVms | Where-Object {
    ($DeployArcOnPrem -and $_.name -in @($onPremFleet | Where-Object deploymentMode -eq 'azure-vm').name) -or
    ($DeployAzureVMs -and $_.name -eq $expectedNativeVmName)
})
Assert-DemoOsDiskStorageAccountType -Machines $diskTierTargets -StorageAccountType $OsDiskStorageAccountType
$additionalVmCount = 0
if ($DeployArcOnPrem) {
    foreach ($entry in $onPremFleet | Where-Object deploymentMode -eq 'azure-vm') {
        if (-not @($existingVms | Where-Object { $_.name -eq $entry.name -and $_.hardwareProfile.vmSize -eq $VmSize -and $_.location -eq $Location }).Count) { $additionalVmCount++ }
    }
}
if ($DeployAzureVMs -and -not @($existingVms | Where-Object { $_.tags.workload -eq 'azure-native-vm' -and $_.tags.demoPrefix -eq $NamePrefix -and $_.hardwareProfile.vmSize -eq $VmSize }).Count) { $additionalVmCount++ }
Test-DemoComputeCapacity -Location $Location -VmSize $VmSize -AdditionalVmCount $additionalVmCount
$initializeAksWorkload = $true
if ($DeployAks) {
    $existingCluster = Invoke-DemoAz -Arguments @('aks', 'show', '-g', $infraRg, '-n', "$NamePrefix-aks", '-o', 'json') -AllowNotFound | ConvertFrom-Json
    if ($existingCluster) {
        if ($existingCluster.powerState.code -ne 'Running' -or $existingCluster.provisioningState -ne 'Succeeded') { throw 'Existing AKS must be Running/Succeeded before deployment. Use approved activation first; deploy never starts a parked cluster incidentally.' }
        $initializeAksWorkload = $false
    }
    Test-DemoComputeCapacity -Location $Location -VmSize 'Standard_B2as_v2' -AdditionalVmCount $(if ($existingCluster) { 0 } else { 1 })
}
$containerAppSimulateCrash = $false
if ($DeployContainerApps) {
    $existingApp = Invoke-DemoAz -Arguments @('containerapp', 'show', '-g', $infraRg, '-n', "ca-$NamePrefix-fault", '-o', 'json') -AllowNotFound | ConvertFrom-Json
    if ($existingApp) {
        $flag = @($existingApp.properties.template.containers.env | Where-Object name -eq 'SIMULATE_CRASH')
        if ($flag.Count -ne 1 -or $flag[0].value -notin @('true', 'false')) { throw 'Cannot preserve existing Container App SIMULATE_CRASH flag; inspect configuration before redeployment.' }
        $containerAppSimulateCrash = [bool]::Parse($flag[0].value)
    }
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
    initializeAksWorkload   = @{ value = $initializeAksWorkload }
    containerAppSimulateCrash = @{ value = $containerAppSimulateCrash }
    existingNatGatewayId    = @{ value = $existingNatGwId }
    existingBudgetStartDate = @{ value = $existingBudgetStart }
    tenantId                = @{ value = $TenantId }
    deployerPrincipalId     = @{ value = $principalId }
    keyVaultName            = @{ value = $kvName }
    adminUsername           = @{ value = 'azureuser' }
    adminPassword           = @{ value = $adminPwd }
    vmSize                  = @{ value = $VmSize }
    osDiskStorageAccountType = @{ value = $OsDiskStorageAccountType }
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

try {
if ($WhatIfPreference) {
    Write-Step 'Running Bicep what-if...'
    az deployment sub what-if --name $deploymentName --location $Location `
        --template-file $bicepFile --parameters @$paramFile --only-show-errors
    return
}

if (-not $PSCmdlet.ShouldProcess("$SubscriptionId / $NamePrefix", 'Deploy infrastructure and reconcile Arc monitoring (preserving credentials)')) {
    return
}
Write-Step "Deploying main.bicep (deployment: $deploymentName)..."
az deployment sub create --name $deploymentName --location $Location `
    --template-file $bicepFile --parameters @$paramFile --only-show-errors -o none
$outputs = az deployment sub show --name $deploymentName --query properties.outputs -o json | ConvertFrom-Json
} finally {
    [System.IO.File]::Delete($paramFile)
}
Write-Ok 'Bicep deployment complete'
if (-not $existingVms.Count -or $AdminPassword) {
    az keyvault secret set --vault-name $kvName -n vm-admin-password --value $adminPwd -o none --only-show-errors
}

$workspaceId = $outputs.workspaceId.value
$workspaceName = ($workspaceId -split '/')[-1]
$deployedFleet = @(@($outputs.vmFleet.value) | Where-Object { $_ -and $_.deployed -eq $true })
$vmNames     = @($deployedFleet | Select-Object -ExpandProperty name)
$azureVmNames = @($outputs.azureVmNames.value | Where-Object { $_ })
$azureVmResourceIds = @($outputs.azureVmResourceIds.value | Where-Object { $_ })
$dcrCoreId   = $outputs.dcrCoreId.value
$dcrVmiId    = $outputs.dcrVmiId.value
$dcrCtId     = $outputs.dcrCtId.value
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

# Phase 3: verify outbound before guest onboarding
Write-Header 'Phase 3 — NAT Gateway'
$natId = "/subscriptions/$SubscriptionId/resourceGroups/$infraRg/providers/Microsoft.Network/natGateways/natgw-$NamePrefix"
$attached = az network vnet subnet show -g $infraRg --vnet-name "vnet-$NamePrefix" -n snet-vms --query 'natGateway.id' -o tsv
if ($attached -ne $natId) { throw 'Expected demo NAT is not attached after infrastructure deployment. Inspect the subnet before guest onboarding.' }
Write-Ok 'Expected NAT Gateway attached to subnet'

if ($DeployArcOnPrem -and $vmNames.Count -gt 0) {
# Phase 4: Arc onboarding SPN (idempotent)
Write-Header 'Phase 4 — Arc onboarding service principal'
$alreadyArc = @(az connectedmachine list -g $arcRg --query "[].name" -o tsv)
$toOnboardFleet = @($deployedFleet | Where-Object { $_.name -notin $alreadyArc })
$spnMatches = @(az ad sp list --display-name "sp-$NamePrefix-onboard" --query "[?displayName=='sp-$NamePrefix-onboard'].appId" -o tsv)
if ($spnMatches.Count -gt 1) { throw 'Ambiguous onboarding service principal name. Resolve duplicates before deployment.' }
$spnAppId = $spnMatches | Select-Object -First 1
$spnSecret = ''
if ($spnAppId -and $toOnboardFleet.Count) {
    if (-not $OnboardingSecret) { throw 'New Arc onboarding is required. Supply the existing SP secret as -OnboardingSecret (SecureString); credentials are never reset automatically.' }
    $spnSecret = [System.Net.NetworkCredential]::new('', $OnboardingSecret).Password
} elseif (-not $spnAppId -and $toOnboardFleet.Count) {
    $spnJson = az ad sp create-for-rbac --name "sp-$NamePrefix-onboard" `
        --role "Azure Connected Machine Onboarding" `
        --scopes "/subscriptions/$SubscriptionId/resourceGroups/$arcRg" `
        --only-show-errors -o json | ConvertFrom-Json
    $spnAppId  = $spnJson.appId
    $spnSecret = $spnJson.password
    Write-Ok "SPN created ($spnAppId)"
}

# Helper script files
$libDir   = Join-Path ([System.IO.Path]::GetTempPath()) "arc-demo-onboard-$(Get-Random)"
New-Item -ItemType Directory -Path $libDir -Force | Out-Null
try {
$winOnboard = @"
`$ErrorActionPreference = 'Stop'
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
if (`$LASTEXITCODE -ne 0) { throw 'Arc onboarding failed' }
'ARC_DEMO_OK'
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
echo ARC_DEMO_OK
"@
$winFile = Join-Path $libDir 'arc-win.ps1'
$lnxFile = Join-Path $libDir 'arc-lnx.sh'
[System.IO.File]::WriteAllText($winFile, $winOnboard, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($lnxFile, $lnxOnboard, [System.Text.UTF8Encoding]::new($false))

# Phase 5: Arc onboarding (parallel, skips already-Connected machines)
Write-Header 'Phase 5 — Arc onboarding (parallel)'
if (-not $toOnboardFleet) {
    Write-Ok 'All VMs already Arc-onboarded — skipping'
} else {
    Write-Step "Onboarding $($toOnboardFleet.Count) of $($vmNames.Count) VMs..."
    foreach ($machine in $toOnboardFleet) {
        $vm = $machine.name
        $isWin = $machine.osType -eq 'Windows'
        $target = [pscustomobject]@{ Name = $vm; OsType = $machine.osType; Id = "/subscriptions/$SubscriptionId/resourceGroups/$infraRg/providers/Microsoft.Compute/virtualMachines/$vm" }
        Invoke-DemoGuestCommand -Machine $target -Script ($(if ($isWin) { "@$winFile" } else { "@$lnxFile" }))
    }
}
Write-Step 'Waiting for all Arc machines to report Connected...'
$ok = Wait-Until -TimeoutSeconds 600 -IntervalSeconds 30 -Message 'Arc Connected' -Condition {
    $connected = (az connectedmachine list -g $arcRg --query "[?status=='Connected'].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ }
    return @($vmNames | Where-Object { $_ -notin $connected }).Count -eq 0
}
if (-not $ok) { throw 'Timed out waiting for all Arc machines to be Connected' }
Write-Ok 'All Arc machines Connected'

Write-Step 'Tagging Arc machines with OS, monitoring, and control-plane metadata...'
foreach ($machine in $deployedFleet) {
    $tagArgs = Get-ArcMachineTagArgs -Machine $machine -BaseTags $demoTags
    az connectedmachine update -g $arcRg -n $($machine.name) --tags $tagArgs --only-show-errors -o none
}
Write-Ok 'Arc machine tags updated'

Write-Header 'Phase 5.5 — Update Manager periodic assessment'
foreach ($machine in $deployedFleet) {
    $vm = $machine.name
    $osType = [string]$machine.osType
    $profilePath = if ($osType -eq 'Windows') {
        'windows-configuration.patch-settings.assessment-mode=AutomaticByPlatform'
    } elseif ($osType -eq 'Linux') {
        'linux-configuration.patch-settings.assessment-mode=AutomaticByPlatform'
    } else {
        ''
    }

    if (-not $profilePath) {
        Write-Warn "Skipping periodic assessment for $vm — unsupported OS type '$osType'"
        continue
    }

    az connectedmachine update -g $arcRg -n $vm `
        --os-profile $profilePath `
        --only-show-errors -o none
}
Write-Ok "Periodic assessment enabled on $($deployedFleet.Count) Arc machines"

} finally {
    Remove-Item -LiteralPath $libDir -Recurse -Force
}

# Phase 6: AMA (Windows via Arc, Linux via Azure VM) + DCR associations to Arc resource
Write-Header 'Phase 6 — Azure Monitor Agent + DCR associations'

$jobs = @()
foreach ($vm in $monitorWindowsVms) {
    $jobs += Start-DemoAzJob -Arguments @('connectedmachine', 'extension', 'create', '-g', $arcRg, '--machine-name', $vm,
        '-n', 'AzureMonitorWindowsAgent', '--publisher', 'Microsoft.Azure.Monitor', '--type', 'AzureMonitorWindowsAgent', '--enable-auto-upgrade', 'true', '-o', 'none')
}
foreach ($vm in $monitorLinuxVms) {
    $jobs += Start-DemoAzJob -Arguments @('vm', 'extension', 'set', '-g', $infraRg, '--vm-name', $vm, '-n', 'AzureMonitorLinuxAgent',
        '--publisher', 'Microsoft.Azure.Monitor', '--enable-auto-upgrade', 'true', '-o', 'none')
}
if ($jobs.Count -gt 0) {
    Write-Step "Installing AMA on $($monitorVms.Count) Monitor-supported machines (parallel)..."
    Receive-DemoJobs -Jobs $jobs
    Write-Ok 'AMA installs completed'
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
    $jobs += Start-DemoAzJob -Arguments @('connectedmachine', 'extension', 'create', '-g', $arcRg, '--machine-name', $vm,
        '-n', 'DependencyAgentWindows', '--publisher', 'Microsoft.Azure.Monitoring.DependencyAgent', '--type', 'DependencyAgentWindows', '--enable-auto-upgrade', 'true', '-o', 'none')
}
if ($jobs.Count -gt 0) {
    Receive-DemoJobs -Jobs $jobs
    Write-Ok 'Dependency Agent installed on VM Insights-supported Windows VMs'
} else {
    Write-Warn 'No VM Insights-supported Windows machines — skipping Dependency Agent'
}

# Phase 8: Change Tracking extension (supported OSes only)
Write-Header 'Phase 8 — Change Tracking extension'
$jobs = @()
foreach ($vm in $changeTrackingWindowsVms) {
    $jobs += Start-DemoAzJob -Arguments @('connectedmachine', 'extension', 'create', '-g', $arcRg, '--machine-name', $vm,
        '-n', 'ChangeTracking-Windows', '--publisher', 'Microsoft.Azure.ChangeTrackingAndInventory', '--type', 'ChangeTracking-Windows', '--enable-auto-upgrade', 'true', '-o', 'none')
}
foreach ($vm in $changeTrackingLinuxVms) {
    $jobs += Start-DemoAzJob -Arguments @('vm', 'extension', 'set', '-g', $infraRg, '--vm-name', $vm,
        '-n', 'ChangeTracking-Linux', '--publisher', 'Microsoft.Azure.ChangeTrackingAndInventory', '--enable-auto-upgrade', 'true', '-o', 'none')
}
if ($jobs.Count -gt 0) {
    Receive-DemoJobs -Jobs $jobs
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
    $sqlScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) "sql-install-$(Get-Random).ps1"
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
if ((Get-Service MSSQLSERVER).Status -ne 'Running') { throw 'SQL service is not running' }
'ARC_DEMO_OK'
'@
    [System.IO.File]::WriteAllText($sqlScriptPath, $sqlScript, [System.Text.UTF8Encoding]::new($false))
    try {
    foreach ($vm in $sqlVms) {
        $target = [pscustomobject]@{ Name = $vm; OsType = 'Windows'; Id = "/subscriptions/$SubscriptionId/resourceGroups/$infraRg/providers/Microsoft.Compute/virtualMachines/$vm" }
        Invoke-DemoGuestCommand -Machine $target -Script "@$sqlScriptPath"
    }
    } finally {
        Remove-Item -LiteralPath $sqlScriptPath -Force
    }

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

function Set-WorkbookWorkspaceDefaults {
    param(
        [Parameter(Mandatory)]
        [string]$SerializedData,

        [Parameter(Mandatory)]
        [string]$DefaultWorkspaceId
    )

    $workbook = $SerializedData | ConvertFrom-Json -Depth 100
    foreach ($item in @($workbook.items)) {
        if ($item.type -ne 9 -or -not $item.content -or -not $item.content.parameters) {
            continue
        }

        foreach ($parameter in @($item.content.parameters)) {
            $name = [string]$parameter.name
            $label = [string]$parameter.label
            $isWorkspaceParameter = $parameter.type -eq 5 -and (
                $name -in @('LogAnalyticsWorkspace', 'p_ws') -or
                $label -like '*Log Analytics Workspace*'
            )
            if (-not $isWorkspaceParameter) {
                continue
            }

            if (-not $parameter.typeSettings) {
                $parameter | Add-Member -NotePropertyName typeSettings -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $parameter.typeSettings | Add-Member -NotePropertyName showDefault -NotePropertyValue $true -Force
            $parameter | Add-Member -NotePropertyName defaultValue -NotePropertyValue $DefaultWorkspaceId -Force
            $parameter | Add-Member -NotePropertyName value -NotePropertyValue $DefaultWorkspaceId -Force
        }
    }

    return ($workbook | ConvertTo-Json -Depth 100)
}

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
    $wbContent = Set-WorkbookWorkspaceDefaults -SerializedData $wbContent -DefaultWorkspaceId $workspaceId.ToLower()
    $tag = ($DisplayName -replace '[^A-Za-z0-9]', '-').ToLower()
    # Look for an existing workbook with this tag. Re-runs update the workbook
    # content so fixed queries and story changes reach existing demo labs.
    $existing = az resource list -g $arcRg --resource-type Microsoft.Insights/workbooks `
        --query "[?tags.workbookTag=='$tag'].id" -o tsv 2>$null
    $workbookId = if ($existing) {
        (($existing -split "`n") | Where-Object { $_ } | Select-Object -First 1)
    } else {
        "/subscriptions/$SubscriptionId/resourceGroups/$arcRg/providers/Microsoft.Insights/workbooks/$([guid]::NewGuid().ToString())"
    }
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
        -Url "https://management.azure.com${workbookId}?api-version=2023-06-01" `
        -Body $wbBody
    $action = if ($existing) { 'updated' } else { 'created' }
    Write-Ok "Workbook ${action}: $($r.properties.displayName)"
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
& (Join-Path $PSScriptRoot 'Test-ArcDemoReadiness.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId -NamePrefix $NamePrefix -SkinPath $SkinPath -TimeoutSeconds 600
if ($LASTEXITCODE -ne 0) { throw 'Deployment finished, but required infrastructure/monitor readiness failed or remains pending. Inspect the checks above; no faults were reset.' }

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
Write-Host "    - After operator approval, use Hibernate-ArcDemo.ps1 with the same subscription, tenant and skin; retained services still incur costs."
Write-Host ''
