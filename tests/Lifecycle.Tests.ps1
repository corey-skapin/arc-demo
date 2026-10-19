BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'scripts\lib\Common.psm1')
}
BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1')
}

Describe 'Bounded mandatory waits' {
    InModuleScope Common {
        It 'throws instead of returning false on a required timeout' {
            { Wait-Until -Condition { $false } -TimeoutSeconds 0 -Message 'expected host' } | Should -Throw '*expected host*'
        }
        It 'keeps the last inspection error actionable' {
            { Wait-Until -Condition { throw 'permission denied' } -TimeoutSeconds 0 } | Should -Throw '*permission denied*'
        }
        It 'allows an explicit optional timeout' {
            Wait-Until -Condition { $false } -TimeoutSeconds 0 -AllowTimeout | Should -BeFalse
        }
        It 'succeeds immediately without sleeping' {
            Mock Start-Sleep { throw 'must not sleep' }
            Wait-Until -Condition { $true } -TimeoutSeconds 0 | Should -BeTrue
        }
    }
}

Describe 'Skin and fleet validation' {
    It 'rejects an explicitly missing skin' {
        { Get-DemoSkin -Path 'missing.json' -RepoRoot $TestDrive } | Should -Throw '*not found*'
    }
    It 'rejects malformed JSON' {
        Set-Content (Join-Path $TestDrive 'bad.json') '{broken'
        { Get-DemoSkin -Path 'bad.json' -RepoRoot $TestDrive } | Should -Throw
    }
    It 'rejects string booleans instead of treating false as true' {
        Set-Content (Join-Path $TestDrive 'bad.json') '{"schemaVersion":1,"workloads":{"deployAks":"false"}}'
        { Get-DemoSkin -Path 'bad.json' -RepoRoot $TestDrive } | Should -Throw '*JSON boolean*'
    }
    It 'loads a non-default skin' {
        Set-Content (Join-Path $TestDrive 'retail.json') '{"schemaVersion":1,"azure":{"namePrefix":"retail-demo"},"workloads":{"deployAks":false}}'
        $skin = Get-DemoSkin -Path 'retail.json' -RepoRoot $TestDrive
        Get-DemoSkinValue $skin 'azure.namePrefix' '' | Should -Be 'retail-demo'
        Get-DemoSkinValue $skin 'workloads.deployAks' $true | Should -BeFalse
    }
    It 'rejects unsafe resource prefixes' -ForEach @('Bad_Prefix', 'a', 'prefix-', "a' || true") {
        { Assert-DemoName $_ } | Should -Throw
    }
    It 'rejects a malformed fleet instead of silently defaulting' {
        { Test-DemoFleet @([pscustomobject]@{ name = 'broken'; osType = 'Solaris' }) } | Should -Throw '*Invalid OS*'
    }
}

Describe 'Retained workload identity classification' {
    InModuleScope Common {
        BeforeEach {
            $script:DemoSubscription = '11111111-1111-1111-1111-111111111111'
            $script:infraRoot = "/subscriptions/$script:DemoSubscription/resourceGroups/rg-retail-demo-infra/providers"
            $script:deploymentFixtures = @(
                @{ properties = @{ timestamp = '2026-10-19'; outputs = @{ vmFleet = @{ value = @() }; azureVmResourceIds = @{ value = @("$script:infraRoot/Microsoft.Compute/virtualMachines/az-retail-01") } } } },
                @{ properties = @{ timestamp = '2026-10-18'; outputs = @{ vmFleet = @{ value = @(
                    @{ name = 'branch-01'; osType = 'Windows'; deployed = $true; supportsAzureMonitor = $true; supportsVmInsights = $true; supportsChangeTracking = $true }
                ) } } } }
            )
            $script:vmFixtures = @(
                @{ name = 'branch-01'; id = "$script:infraRoot/Microsoft.Compute/virtualMachines/branch-01"; storageProfile = @{ osDisk = @{ osType = 'Windows' } }; powerState = 'VM running' },
                @{ name = 'az-retail-01'; id = "$script:infraRoot/Microsoft.Compute/virtualMachines/az-retail-01"; storageProfile = @{ osDisk = @{ osType = 'Windows' } }; powerState = 'VM running' }
            )
            Mock Invoke-DemoAz {
                param($Arguments)
                switch ($Arguments[0]) {
                    'deployment' { ConvertTo-Json -InputObject $script:deploymentFixtures -Depth 20 }
                    'resource' { '[]' }
                    'vm' { ConvertTo-Json -InputObject $script:vmFixtures -Depth 20 }
                    default { throw 'unexpected CLI operation' }
                }
            }
        }
        It 'retains an earlier Arc manifest after an additive empty-fleet deployment' {
            $inventory = Get-DemoInventory 'retail-demo'
            $inventory.Machines.Count | Should -Be 2
            @($inventory.Machines | Where-Object { -not $_.Native }).Name | Should -Be 'branch-01'
        }
        It 'classifies an az-prefixed Windows native host by metadata, not name' {
            $native = (Get-DemoInventory 'retail-demo').Machines | Where-Object Native
            $native.OsType | Should -Be 'Windows'
            $native.ArcId | Should -BeNullOrEmpty
            $native.Monitor | Should -BeTrue
        }
        It 'retains missing expected identities rather than passing a reduced count' {
            $script:vmFixtures = @($script:vmFixtures | Where-Object name -ne 'branch-01')
            $inventory = Get-DemoInventory 'retail-demo'
            ($inventory.Machines | Where-Object Name -eq 'branch-01').Actual | Should -BeNullOrEmpty
        }
        It 'rejects unknown VMs rather than starting/deallocating them' {
            $script:vmFixtures += @{ name = 'foreign-01'; id = "$script:infraRoot/Microsoft.Compute/virtualMachines/foreign-01" }
            { Get-DemoInventory 'retail-demo' } | Should -Throw '*ambiguous fleet*'
        }
        It 'rejects OS drift between the manifest and actual VM' {
            $script:vmFixtures[0].storageProfile.osDisk.osType = 'Linux'
            { Get-DemoInventory 'retail-demo' } | Should -Throw '*OS metadata*'
        }
        It 'rejects a foreign subscription workload ID' {
            $script:deploymentFixtures[0].properties.outputs.azureVmResourceIds.value = @('/subscriptions/other/resourceGroups/foreign/providers/Microsoft.Compute/virtualMachines/x')
            { Get-DemoInventory 'retail-demo' } | Should -Throw '*outside*'
        }
    }
}

Describe 'Checked guest execution and jobs' {
    InModuleScope Common {
        BeforeEach {
            $global:ArcGuestTransportFixture = @{}
            Mock Start-DemoAzJob {
                param($Arguments)
                $global:ArcGuestTransportFixture.arguments = $Arguments
                $global:ArcGuestTransportFixture.path = $Arguments[[Array]::IndexOf($Arguments, '--scripts') + 1].TrimStart('@')
                $global:ArcGuestTransportFixture.content = [System.IO.File]::ReadAllText($global:ArcGuestTransportFixture.path)
                [pscustomobject]@{ Name = 'fake' }
            }
            $script:machine = [pscustomobject]@{ Name = 'native-win'; Id = '/vm/native-win'; OsType = 'Windows' }
        }
        AfterEach { Remove-Variable ArcGuestTransportFixture -Scope Global -ErrorAction SilentlyContinue }
        It 'transports every script line through a file for <OsType>' -TestCases @(
            @{ OsType = 'Windows'; Command = 'RunPowerShellScript' }
            @{ OsType = 'Linux'; Command = 'RunShellScript' }
        ) {
            param($OsType, $Command)
            $script:machine.OsType = $OsType
            Mock Receive-DemoJobs {
                [System.IO.File]::Exists($global:ArcGuestTransportFixture.path) | Should -BeTrue
                '{"value":[{"code":"ProvisioningState/succeeded","message":"ARC_DEMO_OK\n"}]}'
            }
            $scriptText = "first line`nsecond line with 'quotes' and | pipes`nARC_DEMO_OK"
            Invoke-DemoGuestCommand -Machine $script:machine -Script $scriptText
            $global:ArcGuestTransportFixture.content | Should -BeExactly $scriptText
            $arguments = $global:ArcGuestTransportFixture.arguments
            $arguments[[Array]::IndexOf($arguments, '--command-id') + 1] | Should -Be $Command
            $arguments[[Array]::IndexOf($arguments, '--scripts') + 1] | Should -BeExactly "@$($global:ArcGuestTransportFixture.path)"
            [System.IO.File]::Exists($global:ArcGuestTransportFixture.path) | Should -BeFalse
        }
        It 'removes the script file when guest submission fails' {
            Mock Receive-DemoJobs { throw 'injected guest submission failure' }
            { Invoke-DemoGuestCommand -Machine $script:machine -Script "line one`nline two" } | Should -Throw '*injected guest submission failure*'
            [System.IO.File]::Exists($global:ArcGuestTransportFixture.path) | Should -BeFalse
        }
        It 'preserves caller-owned script files used by onboarding and SQL' {
            $path = Join-Path ([System.IO.Path]::GetTempPath()) "arc guest $([guid]::NewGuid()).ps1"
            try {
                [System.IO.File]::WriteAllText($path, "line one`nline two")
                Mock Receive-DemoJobs { '{"value":[{"code":"ProvisioningState/succeeded","message":"ARC_DEMO_OK\n"}]}' }
                Invoke-DemoGuestCommand -Machine $script:machine -Script "@$path"
                $global:ArcGuestTransportFixture.content | Should -BeExactly "line one`nline two"
                [System.IO.File]::Exists($path) | Should -BeTrue
            } finally { [System.IO.File]::Delete($path) }
        }
        It 'rejects a missing caller script before starting any job' {
            { Invoke-DemoGuestCommand -Machine $script:machine -Script "@$(Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).ps1")" } | Should -Throw
            Should -Invoke Start-DemoAzJob -Times 0
        }
        It 'rejects provisioning success without guest completion' {
            Mock Receive-DemoJobs { '{"value":[{"code":"ProvisioningState/succeeded","message":"script exited 1"}]}' }
            { Invoke-DemoGuestCommand -Machine $script:machine -Script 'bad command' } | Should -Throw '*native-win*'
        }
        It 'accepts the exact completion marker' {
            Mock Receive-DemoJobs { '{"value":[{"code":"ProvisioningState/succeeded","message":"ARC_DEMO_OK\n"}]}' }
            { Invoke-DemoGuestCommand -Machine $script:machine -Script 'valid' } | Should -Not -Throw
        }
        It 'rejects a failed guest result even with the marker present' {
            Mock Receive-DemoJobs { '{"value":[{"code":"ProvisioningState/failed","message":"ARC_DEMO_OK"}]}' }
            { Invoke-DemoGuestCommand -Machine $script:machine -Script 'partial' } | Should -Throw
        }
        It 'surfaces failed background job state and cleans it up' {
            $job = Start-Job { throw 'extension failure' }
            { Receive-DemoJobs -Jobs @($job) -TimeoutSeconds 10 } | Should -Throw
            Get-Job -Id $job.Id -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }
}

Describe 'WhatIf lifecycle safety' {
    BeforeEach {
        Mock Import-Module {}
        Mock Initialize-DemoContext {}
        Mock Assert-DemoSkinInventory {}
        Mock Get-DemoInventory {
            [pscustomobject]@{ Machines = @(); ArcRg = 'rg-retail-demo'; InfraRg = 'rg-retail-demo-infra'; ContainerAppIds = @(); AksClusterIds = @(); Resources = @() }
        }
        Mock Invoke-DemoAz { throw 'WhatIf must not execute mutation commands' }
    }
    It 'activation performs no mutations' {
        & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -WhatIf
        Should -Invoke Invoke-DemoAz -Times 0
    }
    It 'hibernation performs no mutations' {
        & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -WhatIf
        Should -Invoke Invoke-DemoAz -Times 0
    }
    It 'removal performs no mutations' {
        & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -WhatIf
        Should -Invoke Invoke-DemoAz -Times 0
    }
    It 'deployment preview never registers providers or writes Azure resources' {
        Mock Test-Prerequisites { '33333333-3333-3333-3333-333333333333' }
        Mock Test-DemoComputeCapacity {}
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'list') { return '[]' }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if') { return 'preview' }
            if ($Arguments[0] -eq 'bicep') { return '{"parameters":{"onPremFleet":{"defaultValue":[]}}}' }
            if ($Arguments[0] -in @('keyvault', 'network', 'consumption')) { return $null }
            throw "Unexpected preview operation: $($Arguments[0..1] -join ' ')"
        }
        & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -AdminEmail 'test@example.com' -WhatIf
        Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if' }
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'register' -in $Arguments -or 'create' -in $Arguments -or 'set' -in $Arguments -or 'reset' -in $Arguments }
    }
    It 'preserves Container App fault and skips AKS sample bootstrap in a redeploy preview' {
        Mock Test-Prerequisites { '33333333-3333-3333-3333-333333333333' }
        Mock Test-DemoComputeCapacity {}
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'vm') { return '[]' }
            if ($Arguments[0] -eq 'bicep') { return '{"parameters":{"onPremFleet":{"defaultValue":[]}}}' }
            if ($Arguments[0] -eq 'aks') { return '{"powerState":{"code":"Running"},"provisioningState":"Succeeded"}' }
            if ($Arguments[0] -eq 'containerapp') { return '{"properties":{"template":{"containers":[{"env":[{"name":"SIMULATE_CRASH","value":"true"}]}]}}}' }
            if ($Arguments[0] -eq 'deployment') {
                $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1].TrimStart('@')
                $global:ArcPreviewParameters = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            }
        }
        try {
            & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -AdminEmail 'test@example.com' -DeployContainerApps $true -DeployAks $true -WhatIf
            $global:ArcPreviewParameters.parameters.containerAppSimulateCrash.value | Should -BeTrue
            $global:ArcPreviewParameters.parameters.initializeAksWorkload.value | Should -BeFalse
        } finally {
            Remove-Variable ArcPreviewParameters -Scope Global -ErrorAction SilentlyContinue
        }
    }
}

    Describe 'Idempotent lifecycle state transitions' {
        BeforeEach {
            Mock Import-Module {}
            Mock Initialize-DemoContext {}
            Mock Assert-DemoSkinInventory {}
            Mock Invoke-DemoGuestCommand { throw 'Already-correct guests must not be restarted' }
            $script:root = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-retail-demo-infra/providers'
            $script:machine = [pscustomobject]@{
                Name = 'az-retail-01'; Id = "$script:root/Microsoft.Compute/virtualMachines/az-retail-01"
                Native = $true; Monitor = $true; OsType = 'Windows'
                Actual = [pscustomobject]@{ id = "$script:root/Microsoft.Compute/virtualMachines/az-retail-01"; powerState = 'VM running' }
            }
            $script:clusterState = 'Running'
            $script:nat = "$script:root/Microsoft.Network/natGateways/natgw-retail-demo"
            $script:resources = @(
                @{ id = $script:nat; type = 'Microsoft.Network/natGateways'; name = 'natgw-retail-demo' }
                @{ id = "$script:root/Microsoft.Network/publicIPAddresses/pip-natgw-retail-demo"; type = 'Microsoft.Network/publicIPAddresses'; name = 'pip-natgw-retail-demo' }
            )
            $global:ArcLifecycleFixture = @{ root = $script:root; machine = $script:machine; clusterState = $script:clusterState; nat = $script:nat; resources = $script:resources }
            Mock Get-DemoInventory {
                $f = $global:ArcLifecycleFixture
                [pscustomobject]@{ Machines = @($f.machine); ArcRg = 'rg-retail-demo'; InfraRg = 'rg-retail-demo-infra'
                    ContainerAppIds = @(); AksClusterIds = @("$($f.root)/Microsoft.ContainerService/managedClusters/retail-demo-aks"); Resources = $f.resources }
            }
            Mock Get-DemoReadinessChecks { New-DemoCheck 'fixture' '/id' 'parked' 'parked' 'pass' }
            Mock Invoke-DemoAz {
                param($Arguments)
                $f = $global:ArcLifecycleFixture
                $command = $Arguments[0..1] -join ' '
                switch ($command) {
                    'network vnet' { return (@{ id = "$($f.root)/Microsoft.Network/virtualNetworks/vnet-retail-demo/subnets/snet-vms"; natGateway = @{ id = $f.nat } } | ConvertTo-Json -Depth 5) }
                    'vm list' { return (ConvertTo-Json -InputObject @($f.machine.Actual) -Depth 5) }
                    'connectedmachine list' { return '[]' }
                    'aks show' { return (@{ name = 'retail-demo-aks'; powerState = @{ code = $f.clusterState }; provisioningState = 'Succeeded' } | ConvertTo-Json -Depth 5) }
                    'resource list' { return (ConvertTo-Json -InputObject $f.resources -Depth 5) }
                    default { throw "Unexpected mutation or inspection: $command" }
                }
                AfterEach { Remove-Variable -Name ArcLifecycleFixture -Scope Global -ErrorAction SilentlyContinue }
            }
        }
        It 'does not restart or update an already-running native Windows VM and AKS' {
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment
            Should -Invoke Invoke-DemoGuestCommand -Times 0
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'start' -in $Arguments -or 'create' -in $Arguments -or 'update' -in $Arguments }
            Should -Invoke Invoke-DemoAz -Times 1 -ParameterFilter { $Arguments[0] -eq 'aks' -and '-g' -in $Arguments -and '-n' -in $Arguments -and '--ids' -notin $Arguments }
        }
        It 'does not repeat completed deallocation or delete absent NAT on a hibernation rerun' {
            $global:ArcLifecycleFixture.machine.Actual.powerState = 'VM deallocated'
            $global:ArcLifecycleFixture.clusterState = 'Stopped'
            $global:ArcLifecycleFixture.nat = ''
            $global:ArcLifecycleFixture.resources = @()
            & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'deallocate' -in $Arguments -or 'stop' -in $Arguments -or 'delete' -in $Arguments -or 'update' -in $Arguments }
        }
        It 'does not remove outbound NAT when deallocation verification fails' {
            $global:ArcLifecycleFixture.clusterState = 'Stopped'
            Mock Invoke-DemoAz {} -ParameterFilter { $Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'deallocate' }
            Mock Wait-Until { throw 'deallocation timeout' }
            { & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo } | Should -Throw '*timeout*'
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'delete' -in $Arguments -or 'update' -in $Arguments }
        }
    }

    Describe 'Native process failures and target verification' {
        InModuleScope Common {
            BeforeEach {
                $script:DemoSubscription = $null
                $script:pwshPath = (Get-Process -Id $PID).Path
            }
            It 'throws on a nonzero native exit even when stdout looks successful' {
                Mock Get-Command { [pscustomobject]@{ Source = $script:pwshPath } } -ParameterFilter { $Name -eq 'az' }
                { Invoke-DemoAz -Arguments @('-NoProfile', '-Command', 'Write-Output success; [Console]::Error.WriteLine("denied"); exit 7') } | Should -Throw '*exit 7*denied*'
            }
            It 'never treats authentication failures as resource absence' {
                Mock Get-Command { [pscustomobject]@{ Source = $script:pwshPath } } -ParameterFilter { $Name -eq 'az' }
                { Invoke-DemoAz -Arguments @('-NoProfile', '-Command', '[Console]::Error.WriteLine("AuthorizationFailed"); exit 1') -AllowNotFound } | Should -Throw '*AuthorizationFailed*'
            }
            It 'rejects a tenant mismatch without switching defaults' {
                Mock Invoke-DemoAz { '{"id":"11111111-1111-1111-1111-111111111111","tenantId":"33333333-3333-3333-3333-333333333333"}' }
                { Initialize-DemoContext '11111111-1111-1111-1111-111111111111' '22222222-2222-2222-2222-222222222222' } | Should -Throw '*does not match*'
                Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'set' -in $Arguments }
            }
        }
    }
Describe 'Readiness CLI contract' {
    BeforeEach {
        Mock Import-Module {}
        Mock Initialize-DemoContext {}
        Mock Assert-DemoSkinInventory {}
        Mock Get-DemoInventory { [pscustomobject]@{ Machines = @(); Resources = @() } }
    }

    Describe 'Tenant-scoped Azure directory commands' {
        InModuleScope Common {
            BeforeEach {
                $global:ArcDirectoryFixture = @{
                    calls = @(); tenant = '22222222-2222-2222-2222-222222222222'; exitCode = 0
                    previousTenant = $script:DemoTenant; previousSubscription = $script:DemoSubscription
                    previousExitCode = $global:LASTEXITCODE
                    path = Join-Path ([System.IO.Path]::GetTempPath()) "arc-fake-cli-$([guid]::NewGuid()).ps1"
                }
                $fakeCli = {
                    $global:ArcDirectoryFixture.calls += ,@($args)
                    $global:LASTEXITCODE = $global:ArcDirectoryFixture.exitCode
                    if ($args[0] -eq 'account') { $global:ArcDirectoryFixture.tenant } else { '{"id":"demo-sp"}' }
                }
                [System.IO.File]::WriteAllText($global:ArcDirectoryFixture.path, $fakeCli.ToString())
                $script:DemoTenant = '22222222-2222-2222-2222-222222222222'
                $script:DemoSubscription = '11111111-1111-1111-1111-111111111111'
                Mock Get-Command { [pscustomobject]@{ Source = $global:ArcDirectoryFixture.path } }
            }
            AfterEach {
                [System.IO.File]::Delete($global:ArcDirectoryFixture.path)
                $script:DemoTenant = $global:ArcDirectoryFixture.previousTenant
                $script:DemoSubscription = $global:ArcDirectoryFixture.previousSubscription
                $global:LASTEXITCODE = $global:ArcDirectoryFixture.previousExitCode
                Remove-Variable ArcDirectoryFixture -Scope Global
            }
            It 'verifies the actual default tenant without appending an unsupported subscription argument' {
                Invoke-DemoAz -Arguments @('ad', 'sp', 'show', '--id', 'demo-sp') | Should -Be '{"id":"demo-sp"}'
                $global:ArcDirectoryFixture.calls.Count | Should -Be 2
                $global:ArcDirectoryFixture.calls[0] | Should -Not -Contain '--subscription'
                $global:ArcDirectoryFixture.calls[1] | Should -Not -Contain '--subscription'
            }
            It 'blocks directory operations when the default tenant differs' {
                $global:ArcDirectoryFixture.tenant = '33333333-3333-3333-3333-333333333333'
                { Invoke-DemoAz -Arguments @('ad', 'sp', 'show', '--id', 'demo-sp') } | Should -Throw '*default tenant*'
                $global:ArcDirectoryFixture.calls.Count | Should -Be 1
            }
            It 'blocks directory operations when default context inspection fails' {
                $global:ArcDirectoryFixture.exitCode = 1
                { Invoke-DemoAz -Arguments @('ad', 'sp', 'show', '--id', 'demo-sp') } | Should -Throw '*Unable to verify*'
                $global:ArcDirectoryFixture.calls.Count | Should -Be 1
            }
            It 'requires explicit tenant initialization before directory operations' {
                $script:DemoTenant = $null
                { Invoke-DemoAz -Arguments @('ad', 'sp', 'show', '--id', 'demo-sp') } | Should -Throw '*explicit demo tenant*'
                $global:ArcDirectoryFixture.calls.Count | Should -Be 0
            }
            It 'still pins resource operations to the requested subscription' {
                Invoke-DemoAz -Arguments @('resource', 'list', '-g', 'rg-retail-demo') | Out-Null
                $global:ArcDirectoryFixture.calls[0][-2] | Should -Be '--subscription'
                $global:ArcDirectoryFixture.calls[0][-1] | Should -Be $script:DemoSubscription
            }
        }
    }

    Describe 'Container App readiness state enumeration' {
        InModuleScope Common {
            BeforeEach {
                $script:DemoSubscription = '11111111-1111-1111-1111-111111111111'
                Mock Invoke-DemoAz {
                    param($Arguments)
                    if ($Arguments[0] -eq 'group') { return '{"properties":{"provisioningState":"Succeeded"}}' }
                    if ($Arguments[0] -eq 'network') { return '{"id":"/subnet"}' }
                    if ($Arguments[0] -eq 'containerapp') { return '[{"name":"revision-01","properties":{"active":true,"healthState":"Healthy","runningState":"RunningAtMaxScale"}}]' }
                    return '[]'
                }
            }
            It 'accepts a healthy RunningAtMaxScale revision without modifying it' {
                $inventory = [pscustomobject]@{ ArcRg = 'rg-retail-demo'; InfraRg = 'rg-retail-demo-infra'; Resources = @(); Machines = @(); AksClusterIds = @()
                    ContainerAppIds = @('/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-retail-demo-infra/providers/Microsoft.App/containerApps/ca-retail-demo-fault') }
                $checks = @(Get-DemoReadinessChecks -Inventory $inventory -NamePrefix retail-demo)
                ($checks | Where-Object id -eq 'containerapp/ca-retail-demo-fault').status | Should -Be 'pass'
                Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'update' -in $Arguments -or 'set' -in $Arguments -or 'activate' -in $Arguments }
            }
        }
    }
    It 'returns one schemaVersion 1 JSON object and exit 0 for pass' {
        Mock Get-DemoReadinessChecks { New-DemoCheck 'fixture' '/expected/id' 'ready' 'ready' 'pass' }
        $output = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -OutputFormat Json
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json
        $result.schemaVersion | Should -Be 1
        $result.workload | Should -Be 'arc-demo'
        $result.checks[0].resourceId | Should -Be '/expected/id'
    }
    It 'returns exit 2 for pending at the zero-second deadline' {
        Mock Get-DemoReadinessChecks { New-DemoCheck 'fixture' '/expected/id' 'ready' 'starting' 'pending' }
        $output = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -OutputFormat Json -TimeoutSeconds 0
        $LASTEXITCODE | Should -Be 2
        ($output | ConvertFrom-Json).status | Should -Be 'pending'
    }
    It 'returns an actionable error record and exit 1 on inspection failure' {
        Mock Get-DemoReadinessChecks { throw 'permission denied' }
        $output = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -OutputFormat Json
        $LASTEXITCODE | Should -Be 1
        ($output | ConvertFrom-Json).checks[-1].message | Should -Be 'permission denied'
    }
}
