BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
    $script:deployScript = Join-Path $repo 'scripts\Deploy-ArcDemo.ps1'
}

Describe 'Get-DemoHeartbeatIds' {
    It 'asks for the latest Heartbeat per exact lower-cased resource and returns it with the ID' {
        $script:sent = $null
        Mock Get-LawQueryToken { 'token' } -ModuleName Common
        Mock Invoke-RestMethod {
            $script:sent = $Body
            [pscustomobject]@{ tables = @([pscustomobject]@{ rows = @(
                , @('/subscriptions/s/resourcegroups/rg/providers/microsoft.hybridcompute/machines/win-a', '2026-11-05T08:03:10.1234567Z')
                , @('/subscriptions/s/resourcegroups/rg/providers/microsoft.hybridcompute/machines/lnx-a', '2026-11-05T08:05:00Z')) }) }
        } -ModuleName Common
        $beats = @(Get-DemoHeartbeatIds -WorkspaceCustomerId 'workspace')
        $script:sent | Should -Match 'summarize LastHeartbeat = max\(TimeGenerated\) by ResourceId = tolower\(_ResourceId\)'
        $script:sent | Should -Match 'ago\(10m\)'
        $beats.Count | Should -Be 2
        $beats[0].Id | Should -Be '/subscriptions/s/resourcegroups/rg/providers/microsoft.hybridcompute/machines/win-a'
        $beats[0].LastHeartbeat | Should -BeOfType [datetime]
        $beats[0].LastHeartbeat.Kind | Should -Be 'Utc'
        $beats[0].LastHeartbeat.Minute | Should -Be 3
    }
    It 'stops on a query error instead of reading it as no Heartbeat' {
        Mock Get-LawQueryToken { 'token' } -ModuleName Common
        Mock Invoke-RestMethod { [pscustomobject]@{ error = [pscustomobject]@{ code = 'PathNotFoundError' } } } -ModuleName Common
        { Get-DemoHeartbeatIds -WorkspaceCustomerId 'workspace' } | Should -Throw '*PathNotFoundError*'
    }
}

Describe 'Readiness evidence for Heartbeat age, VM provisioning state and MDE' {
    BeforeEach {
        InModuleScope Common { $script:DemoSubscription = '11111111-1111-1111-1111-111111111111' }
        $script:arcRoot = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.HybridCompute/machines'
        $script:infraRoot = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.Compute/virtualMachines'
        $script:heartbeats = @()
        $script:vmExtensions = @(@{ name = 'AzureMonitorLinuxAgent'; provisioningState = 'Succeeded' })
        $script:arcExtensions = @(@{ name = 'AzureMonitorWindowsAgent'; properties = @{ provisioningState = 'Succeeded' } })
        Mock Get-DemoNetworkState { [pscustomobject]@{ NatId = '/nat'; PublicIpId = '/pip'; Nat = $null; PublicIp = $null; Subnet = @{ id = '/subnet' } } } -ModuleName Common
        Mock Get-DemoHeartbeatIds { $script:heartbeats } -ModuleName Common
        Mock Invoke-DemoAz {
            param($Arguments)
            $command = $Arguments[0..2] -join ' '
            if ($Arguments[0] -eq 'group') { return '{"properties":{"provisioningState":"Succeeded"}}' }
            if ($command -eq 'connectedmachine list -g') {
                return (ConvertTo-Json -InputObject @(@{ id = "$($script:arcRoot)/lnx-app-01"; status = 'Connected' }, @{ id = "$($script:arcRoot)/win-app-01"; status = 'Connected' }))
            }
            if ($Arguments[0] -eq 'monitor' -and $Arguments[1] -eq 'log-analytics') { return '{"customerId":"workspace"}' }
            if ($Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'extension') { return (ConvertTo-Json -InputObject @($script:vmExtensions) -Depth 5) }
            if ($Arguments[0] -eq 'connectedmachine' -and $Arguments[1] -eq 'extension') { return (ConvertTo-Json -InputObject @($script:arcExtensions) -Depth 5) }
            return '[]'
        } -ModuleName Common
        function New-EvidenceInventory {
            param([string]$LinuxProvisioning = 'Succeeded', [string]$WindowsProvisioning = 'Succeeded')
            $linux = @{ powerState = 'VM running' }; if ($LinuxProvisioning) { $linux.provisioningState = $LinuxProvisioning }
            $windows = @{ powerState = 'VM running' }; if ($WindowsProvisioning) { $windows.provisioningState = $WindowsProvisioning }
            [pscustomobject]@{ ArcRg = 'rg-fixture'; InfraRg = 'rg-fixture-infra'; Resources = @(); AksClusterIds = @(); ContainerAppIds = @()
                Machines = @(
                    [pscustomobject]@{ Name = 'lnx-app-01'; Id = "$($script:infraRoot)/lnx-app-01"; ArcId = "$($script:arcRoot)/lnx-app-01"; Native = $false; Monitor = $true
                        VmInsights = $false; ChangeTracking = $false; OsType = 'Linux'; Actual = $linux }
                    [pscustomobject]@{ Name = 'win-app-01'; Id = "$($script:infraRoot)/win-app-01"; ArcId = "$($script:arcRoot)/win-app-01"; Native = $false; Monitor = $true
                        VmInsights = $false; ChangeTracking = $false; OsType = 'Windows'; Actual = $windows })
            }
        }
        function Get-EvidenceChecks { param($Inventory) @(Get-DemoReadinessChecks -Inventory $Inventory -NamePrefix fixture -DesiredState Active) }
    }

    It 'puts the time and age of the latest Heartbeat in the observed text, whatever form the query result takes' {
        $now = (Get-Date).ToUniversalTime()
        $script:heartbeats = @(
            [pscustomobject]@{ Id = "$($script:arcRoot)/lnx-app-01".ToLowerInvariant(); LastHeartbeat = $now.AddMinutes(-3) }
            "$($script:arcRoot)/win-app-01".ToLowerInvariant())
        $checks = Get-EvidenceChecks (New-EvidenceInventory)
        $linux = $checks | Where-Object id -eq 'heartbeat/lnx-app-01'
        $linux.status | Should -Be 'pass'
        $linux.observed | Should -Match '^Heartbeat at \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z, [23] min before this check$'
        $linux.observed | Should -Not -BeOfType [bool]
        $windows = $checks | Where-Object id -eq 'heartbeat/win-app-01'
        $windows.status | Should -Be 'pass'
        $windows.observed | Should -Be 'Heartbeat in the last 10 minutes'
    }

    It 'keeps a missing Heartbeat pending, or failed with a failed AMA extension, and says so in plain text' {
        $script:vmExtensions = @(@{ name = 'AzureMonitorLinuxAgent'; provisioningState = 'Failed' })
        $checks = Get-EvidenceChecks (New-EvidenceInventory)
        $linux = $checks | Where-Object id -eq 'heartbeat/lnx-app-01'
        $linux.status | Should -Be 'fail'
        $linux.observed | Should -Be 'no Heartbeat in the last 10 minutes'
        $linux.required | Should -BeTrue
        ($checks | Where-Object id -eq 'heartbeat/win-app-01').status | Should -Be 'pending'
    }

    It 'adds a soft provisioning row per VM and points a stuck one at the install-lock entry' {
        $script:heartbeats = @("$($script:arcRoot)/lnx-app-01".ToLowerInvariant(), "$($script:arcRoot)/win-app-01".ToLowerInvariant())
        $checks = Get-EvidenceChecks (New-EvidenceInventory -LinuxProvisioning 'Updating' -WindowsProvisioning 'Failed')
        $linux = $checks | Where-Object id -eq 'provisioning/lnx-app-01'
        $linux.required | Should -BeFalse
        $linux.status | Should -Be 'pending'
        $linux.observed | Should -Be 'Updating'
        $linux.resourceId | Should -Be "$($script:infraRoot)/lnx-app-01"
        $linux.message | Should -Match 'Soft warning, not a readiness gate'
        $linux.message | Should -Match 'docs/troubleshooting.md, A Linux VM stays Updating behind a Defender MDE.Linux install lock'
        $windows = $checks | Where-Object id -eq 'provisioning/win-app-01'
        $windows.status | Should -Be 'fail'
        $windows.required | Should -BeFalse
        # A soft row never changes the required rows.
        @($checks | Where-Object { $_.id -match '^(provisioning|extension)/' -and $_.required }).Count | Should -Be 0
        $ok = Get-EvidenceChecks (New-EvidenceInventory)
        ($ok | Where-Object id -eq 'provisioning/lnx-app-01').status | Should -Be 'pass'
        ($ok | Where-Object id -eq 'provisioning/lnx-app-01').message | Should -Be ''
    }

    It 'adds no provisioning row when the VM record carries no provisioning state' {
        $checks = Get-EvidenceChecks (New-EvidenceInventory -LinuxProvisioning '' -WindowsProvisioning '')
        @($checks | Where-Object id -like 'provisioning/*').Count | Should -Be 0
    }

    It 'shows the MDE extension state as a soft row only when Defender installed it' {
        $script:heartbeats = @("$($script:arcRoot)/lnx-app-01".ToLowerInvariant(), "$($script:arcRoot)/win-app-01".ToLowerInvariant())
        @(Get-EvidenceChecks (New-EvidenceInventory) | Where-Object id -like 'extension/*/MDE.*').Count | Should -Be 0

        $script:vmExtensions = @(@{ name = 'AzureMonitorLinuxAgent'; provisioningState = 'Succeeded' }, @{ name = 'MDE.Linux'; provisioningState = 'Updating' })
        $script:arcExtensions = @(@{ name = 'AzureMonitorWindowsAgent'; properties = @{ provisioningState = 'Succeeded' } }, @{ name = 'MDE.Windows'; properties = @{ provisioningState = 'Succeeded' } })
        $checks = Get-EvidenceChecks (New-EvidenceInventory)
        $mdeLinux = $checks | Where-Object id -eq 'extension/lnx-app-01/MDE.Linux'
        $mdeLinux.required | Should -BeFalse
        $mdeLinux.status | Should -Be 'pending'
        $mdeLinux.observed | Should -Be 'Updating'
        $mdeLinux.resourceId | Should -Be "$($script:infraRoot)/lnx-app-01/extensions/MDE.Linux"
        $mdeWindows = $checks | Where-Object id -eq 'extension/win-app-01/MDE.Windows'
        $mdeWindows.status | Should -Be 'pass'
        $mdeWindows.resourceId | Should -Be "$($script:arcRoot)/win-app-01/extensions/MDE.Windows"
        @($checks | Where-Object { $_.id -match '^(provisioning|extension)/' -and $_.required }).Count | Should -Be 0
    }
}

Describe 'Readiness expects the core data collection rule the Bicep creates, whatever the name prefix' {
    BeforeEach {
        InModuleScope Common { $script:DemoSubscription = '11111111-1111-1111-1111-111111111111' }
        $script:arcRg = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture'
        $script:arcRoot = "$($script:arcRg)/providers/Microsoft.HybridCompute/machines"
        $script:infraRoot = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.Compute/virtualMachines'
        $script:dcrRoot = "$($script:arcRg)/providers/Microsoft.Insights/dataCollectionRules"
        $script:resourceIds = @()
        $script:associatedRules = @('dcr-arc-demo', 'dcr-vminsights', 'dcr-changetracking')
        Mock Get-DemoNetworkState { [pscustomobject]@{ NatId = '/nat'; PublicIpId = '/pip'; Nat = $null; PublicIp = $null; Subnet = @{ id = '/subnet' } } } -ModuleName Common
        Mock Get-DemoHeartbeatIds { @() } -ModuleName Common
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'group') { return '{"properties":{"provisioningState":"Succeeded"}}' }
            if (($Arguments[0..1] -join ' ') -eq 'resource list') {
                return (ConvertTo-Json -InputObject @($script:resourceIds | ForEach-Object { @{ id = $_; type = 'Microsoft.Insights/fixture' } }) -Depth 4)
            }
            if (($Arguments[0..2] -join ' ') -eq 'connectedmachine list -g') {
                return (ConvertTo-Json -InputObject @(@{ id = "$($script:arcRoot)/win-app-01"; status = 'Connected' }))
            }
            if ($Arguments[0] -eq 'monitor' -and $Arguments[1] -eq 'log-analytics') { return '{"customerId":"workspace"}' }
            if (($Arguments[0..4] -join ' ') -eq 'monitor data-collection rule association list') {
                return (ConvertTo-Json -InputObject @($script:associatedRules | ForEach-Object { @{ dataCollectionRuleId = "$($script:dcrRoot)/$_" } }) -Depth 4)
            }
            return '[]'
        } -ModuleName Common
        # bicep/modules/dcrs.bicep names the three rules with literals, so the core rule never carries the prefix.
        function Set-LabResources {
            param([string]$Prefix)
            $script:resourceIds = @(
                "$($script:arcRg)/providers/Microsoft.OperationalInsights/workspaces/law-$Prefix"
                "$($script:dcrRoot)/dcr-arc-demo"
                "$($script:dcrRoot)/dcr-vminsights"
                "$($script:dcrRoot)/dcr-changetracking"
                "$($script:arcRg)/providers/Microsoft.Insights/actionGroups/ag-$Prefix"
                "$($script:arcRg)/providers/Microsoft.Insights/scheduledQueryRules/alert-$Prefix-host-missing-heartbeat")
        }
        function New-DcrInventory {
            [pscustomobject]@{ ArcRg = 'rg-fixture'; InfraRg = 'rg-fixture-infra'; Resources = @(); AksClusterIds = @(); ContainerAppIds = @()
                Machines = @([pscustomobject]@{ Name = 'win-app-01'; Id = "$($script:infraRoot)/win-app-01"; ArcId = "$($script:arcRoot)/win-app-01"; Native = $false; Monitor = $true
                    VmInsights = $true; ChangeTracking = $true; OsType = 'Windows'; Actual = @{ powerState = 'VM running' } }) }
        }
    }

    It 'fails no resource or association row for the prefix <Prefix> when the estate holds the rules the Bicep creates' -TestCases @(
        @{ Prefix = 'example-arc' }
        @{ Prefix = 'arc-demo' }
    ) {
        param($Prefix)
        Set-LabResources $Prefix
        $checks = @(Get-DemoReadinessChecks -Inventory (New-DcrInventory) -NamePrefix $Prefix -DesiredState Active)
        @($checks | Where-Object { $_.id -match '^(resource|dcra)/' -and $_.status -ne 'pass' } | ForEach-Object id) | Should -BeNullOrEmpty
        @($checks | Where-Object id -like 'resource/dcr-*' | ForEach-Object id) | Should -Be @('resource/dcr-arc-demo', 'resource/dcr-vminsights', 'resource/dcr-changetracking')
        ($checks | Where-Object id -eq 'dcra/win-app-01/dcr-arc-demo').status | Should -Be 'pass'
    }

    It 'still fails the core rule row when the estate lacks the rule the Bicep creates' {
        Set-LabResources 'example-arc'
        $script:resourceIds = @($script:resourceIds | Where-Object { $_ -notlike '*/dcr-arc-demo' })
        $script:associatedRules = @('dcr-vminsights', 'dcr-changetracking')
        $checks = @(Get-DemoReadinessChecks -Inventory (New-DcrInventory) -NamePrefix example-arc -DesiredState Active)
        ($checks | Where-Object id -eq 'resource/dcr-arc-demo').status | Should -Be 'fail'
        ($checks | Where-Object id -eq 'dcra/win-app-01/dcr-arc-demo').status | Should -Be 'fail'
    }
}
