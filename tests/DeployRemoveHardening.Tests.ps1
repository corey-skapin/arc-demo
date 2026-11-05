BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'scripts\lib\Common.psm1')
}
BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1')
    $target = @{ SubscriptionId = '11111111-1111-1111-1111-111111111111'; TenantId = '22222222-2222-2222-2222-222222222222' }
}

Describe 'AllowNotFound against Azure CLI 2.91 error text' {
    BeforeAll {
        # A real process stands in for az so the real stderr capture, exit code and -AllowNotFound handling run.
        $fakeBin = Join-Path $TestDrive 'bin'
        $null = New-Item -ItemType Directory -Path $fakeBin
        $script:fakeStderr = Join-Path $TestDrive 'stderr.txt'
        if ($IsWindows) {
            Set-Content -Path (Join-Path $fakeBin 'az.cmd') -Value "@echo off`r`ntype `"$script:fakeStderr`" 1>&2`r`nexit /b 3"
        } else {
            Set-Content -Path (Join-Path $fakeBin 'az') -Value "#!/bin/sh`ncat '$script:fakeStderr' >&2`nexit 3"
            chmod +x (Join-Path $fakeBin 'az')
        }
        $script:originalPath = $env:PATH
        $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $env:PATH
    }
    AfterAll { $env:PATH = $script:originalPath }

    It 'treats <Name> as absent when the caller allows it' -ForEach @(
        @{ Name = 'a missing policy assignment'; Text = "ERROR: (PolicyAssignmentNotFound) The policy assignment 'mcsb-fixture' is not found.`nCode: PolicyAssignmentNotFound`nMessage: The policy assignment 'mcsb-fixture' is not found."; Command = @('policy', 'assignment', 'show', '-n', 'mcsb-fixture') }
        @{ Name = 'a missing budget'; Text = "WARNING: Command group 'consumption' is in preview and under development.`nReference and support levels: https://aka.ms/CLI_refstatus`nERROR: (404) No budget found matching budgetName: budget-fixture, under storageScope: EntityType = Subscription, EntityId = 11111111-1111-1111-1111-111111111111, ChildScope = , MetaData =   (Request ID: 00000000-0000-0000-0000-000000000000)`nCode: 404`nMessage: No budget found matching budgetName: budget-fixture"; Command = @('consumption', 'budget', 'show', '--budget-name', 'budget-fixture') }
        @{ Name = 'a missing resource group'; Text = "ERROR: (ResourceGroupNotFound) Resource group 'rg-fixture-infra' could not be found.`nCode: ResourceGroupNotFound`nMessage: Resource group 'rg-fixture-infra' could not be found."; Command = @('vm', 'list', '-g', 'rg-fixture-infra') }
        @{ Name = 'a missing resource'; Text = "ERROR: (ResourceNotFound) The Resource 'Microsoft.Network/natGateways/natgw-fixture' under resource group 'rg-fixture-infra' was not found."; Command = @('network', 'nat', 'gateway', 'show') }
    ) {
        Set-Content -Path $script:fakeStderr -Value $Text
        Invoke-DemoAz -Arguments $Command -AllowNotFound | Should -BeNullOrEmpty
        { Invoke-DemoAz -Arguments $Command } | Should -Throw '*failed (exit 3)*'
    }
    It 'never turns a denial or an unknown failure into absence' -ForEach @(
        @{ Text = "ERROR: (AuthorizationFailed) The client 'operator' with object id '00000000-0000-0000-0000-000000000000' does not have authorization to perform action 'Microsoft.Consumption/budgets/read' over scope '/subscriptions/11111111-1111-1111-1111-111111111111'." }
        @{ Text = 'ERROR: (Forbidden) Caller is not authorized to perform action on resource.' }
        @{ Text = 'ERROR: (InternalServerError) The server encountered an internal error.' }
    ) {
        Set-Content -Path $script:fakeStderr -Value $Text
        { Invoke-DemoAz -Arguments @('consumption', 'budget', 'show') -AllowNotFound } | Should -Throw '*failed (exit 3)*'
    }
}

Describe 'Compute capacity preflight with Azure CLI 2.91 string quotas' {
    InModuleScope Common {
        BeforeEach {
            # Azure CLI 2.91 returns every vCPU usage number as a string.
            $script:skus = @{
                Standard_B2as_v2 = '{"name":"Standard_B2as_v2","family":"standardBasv2Family","resourceType":"virtualMachines","capabilities":[{"name":"vCPUs","value":"2"},{"name":"MemoryGB","value":"8"}],"restrictions":[]}'
                Standard_B4as_v2 = '{"name":"Standard_B4as_v2","family":"standardBasv2Family","resourceType":"virtualMachines","capabilities":[{"name":"vCPUs","value":"4"}],"restrictions":[]}'
                Standard_D4s_v5  = '{"name":"Standard_D4s_v5","family":"standardDSv5Family","resourceType":"virtualMachines","capabilities":[{"name":"vCPUs","value":"4"}],"restrictions":[{"type":"Zone","reasonCode":"NotAvailableForSubscription","restrictionInfo":{"zones":["2"]}}]}'
            }
            $script:usage = [ordered]@{ cores = @('22', '100'); standardBasv2Family = @('14', '100'); standardDSv5Family = @('8', '100') }
            $script:usageAsNumbers = $false
            Mock Write-Ok {}
            Mock Write-Warn {}
            Mock Invoke-DemoAz {
                param($Arguments)
                if ($Arguments[1] -eq 'list-skus') { return ('[' + (@($script:skus.Values) -join ',') + ']') }
                if ($Arguments[1] -eq 'list-usage') {
                    $rows = foreach ($name in $script:usage.Keys) {
                        [ordered]@{
                            currentValue = if ($script:usageAsNumbers) { [int]$script:usage[$name][0] } else { [string]$script:usage[$name][0] }
                            limit = if ($script:usageAsNumbers) { [int]$script:usage[$name][1] } else { [string]$script:usage[$name][1] }
                            name = [ordered]@{ value = $name; localizedValue = $name }
                            unit = 'Count'
                        }
                    }
                    return (ConvertTo-Json -InputObject @($rows) -Depth 4)
                }
                throw "Unexpected Azure CLI call: $($Arguments -join ' ')"
            }
        }

        It 'passes with 22 of 100 vCPUs in use and 16 more needed (the string-concatenation regression)' {
            { Test-DemoComputeCapacity -Location australiaeast -Requirements @([pscustomobject]@{ VmSize = 'Standard_B2as_v2'; VmCount = 8 }) } | Should -Not -Throw
            Should -Invoke Write-Ok -Times 1 -ParameterFilter { $Message -eq 'cores vCPU quota: 22 in use + 16 needed of 100' }
        }
        It 'adds two to 22 instead of concatenating to 222' {
            Test-DemoComputeCapacity -Location australiaeast -VmSize Standard_B2as_v2 -AdditionalVmCount 1
            Should -Invoke Write-Ok -Times 1 -ParameterFilter { $Message -eq 'cores vCPU quota: 22 in use + 2 needed of 100' }
        }
        It 'still reads numeric quota values from older CLI versions' {
            $script:usageAsNumbers = $true
            { Test-DemoComputeCapacity -Location australiaeast -Requirements @(@{ VmSize = 'Standard_B2as_v2'; VmCount = 8 }) } | Should -Not -Throw
        }
        It 'names the family when 90 of 100 family vCPUs are in use and 16 are needed' {
            $script:usage.standardBasv2Family = @('90', '100')
            { Test-DemoComputeCapacity -Location australiaeast -Requirements @([pscustomobject]@{ VmSize = 'Standard_B2as_v2'; VmCount = 8 }) } |
                Should -Throw '*standardBasv2Family vCPU quota*90 in use + 16 needed*Standard_B2as_v2 x 8*limit of 100*'
        }
        It 'names the regional quota when the region is nearly full' {
            $script:usage.cores = @('90', '100')
            { Test-DemoComputeCapacity -Location australiaeast -Requirements @([pscustomobject]@{ VmSize = 'Standard_B2as_v2'; VmCount = 8 }) } |
                Should -Throw '*Insufficient cores vCPU quota*90 in use + 16 needed*'
        }
        It 'accepts a total that exactly reaches the limit' {
            $script:usage.standardBasv2Family = @('84', '100')
            { Test-DemoComputeCapacity -Location australiaeast -Requirements @([pscustomobject]@{ VmSize = 'Standard_B2as_v2'; VmCount = 8 }) } | Should -Not -Throw
        }
        It 'checks the D4s_v5 family separately from the B2as_v2 family' {
            $script:usage.standardDSv5Family = @('18', '20')
            $requirements = @(
                [pscustomobject]@{ VmSize = 'Standard_B2as_v2'; VmCount = 8 }
                [pscustomobject]@{ VmSize = 'Standard_D4s_v5'; VmCount = 1 }
            )
            { Test-DemoComputeCapacity -Location australiaeast -Requirements $requirements } |
                Should -Throw '*standardDSv5Family vCPU quota*18 in use + 4 needed*Standard_D4s_v5 x 1*limit of 20*'
            $script:usage.standardDSv5Family = @('16', '20')
            { Test-DemoComputeCapacity -Location australiaeast -Requirements $requirements } | Should -Not -Throw
            Should -Invoke Write-Ok -ParameterFilter { $Message -eq 'cores vCPU quota: 22 in use + 20 needed of 100' }
        }
        It 'ignores a zone-only restriction on a regional deployment' {
            { Test-DemoComputeCapacity -Location australiaeast -Requirements @([pscustomobject]@{ VmSize = 'Standard_D4s_v5'; VmCount = 1 }) } | Should -Not -Throw
        }
        It 'adds sizes of one family together before comparing with the family quota' {
            $script:usage.standardBasv2Family = @('90', '100')
            $fits = @([pscustomobject]@{ VmSize = 'Standard_B2as_v2'; VmCount = 3 }, [pscustomobject]@{ VmSize = 'Standard_B4as_v2'; VmCount = 1 })
            { Test-DemoComputeCapacity -Location australiaeast -Requirements $fits } | Should -Not -Throw
            $overflows = @([pscustomobject]@{ VmSize = 'Standard_B2as_v2'; VmCount = 3 }, [pscustomobject]@{ VmSize = 'Standard_B4as_v2'; VmCount = 2 })
            { Test-DemoComputeCapacity -Location australiaeast -Requirements $overflows } | Should -Throw '*standardBasv2Family*90 in use + 14 needed*'
        }
        It 'adds repeated entries for the same size together' {
            $script:usage.standardBasv2Family = @('90', '100')
            $requirements = @([pscustomobject]@{ VmSize = 'Standard_B2as_v2'; VmCount = 3 }, [pscustomobject]@{ VmSize = 'standard_b2as_v2'; VmCount = 3 })
            { Test-DemoComputeCapacity -Location australiaeast -Requirements $requirements } | Should -Throw '*90 in use + 12 needed*'
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'list-skus' }
        }
        It 'refuses a quota number it cannot read instead of passing silently' {
            $script:usage.cores = @('n/a', '100')
            { Test-DemoComputeCapacity -Location australiaeast -VmSize Standard_B2as_v2 -AdditionalVmCount 1 } | Should -Throw '*cores currentValue*not a whole number*'
        }
        It 'refuses a location-restricted size and never offers an automatic switch' {
            $script:skus.Standard_B2as_v2 = $script:skus.Standard_B2as_v2.Replace('"restrictions":[]', '"restrictions":[{"type":"Location","reasonCode":"NotAvailableForSubscription"}]')
            { Test-DemoComputeCapacity -Location australiaeast -VmSize Standard_B2as_v2 -AdditionalVmCount 1 } | Should -Throw '*restrictions*never switches either*'
        }
        It 'refuses a size that is not in the regional SKU list' {
            $script:skus.Remove('Standard_B2as_v2')
            { Test-DemoComputeCapacity -Location australiaeast -VmSize Standard_B2as_v2 -AdditionalVmCount 1 } | Should -Throw '*not uniquely available*'
        }
        It 'refuses an ambiguous SKU entry' {
            $script:skus.Standard_B2as_v2_again = $script:skus.Standard_B2as_v2
            { Test-DemoComputeCapacity -Location australiaeast -VmSize Standard_B2as_v2 -AdditionalVmCount 1 } | Should -Throw '*not uniquely available*'
        }
        It 'downloads the regional SKU list once however many sizes are checked' {
            Test-DemoComputeCapacity -Location australiaeast -Requirements @(
                [pscustomobject]@{ VmSize = 'Standard_B2as_v2'; VmCount = 8 }
                [pscustomobject]@{ VmSize = 'Standard_B4as_v2'; VmCount = 1 }
                [pscustomobject]@{ VmSize = 'Standard_D4s_v5'; VmCount = 1 }
            )
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'list-skus' }
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'list-usage' }
        }
        It 'refuses a quota that does not exist in the region' {
            $script:usage.Remove('standardBasv2Family')
            { Test-DemoComputeCapacity -Location australiaeast -VmSize Standard_B2as_v2 -AdditionalVmCount 1 } | Should -Throw '*Quota standardBasv2Family could not be checked*'
        }
        It 'keeps the single-size parameters and validates the size with zero additional VMs' {
            { Test-DemoComputeCapacity -Location australiaeast -VmSize Standard_B2as_v2 -AdditionalVmCount 0 } | Should -Not -Throw
            { Test-DemoComputeCapacity -Location australiaeast -VmSize Standard_B2as_v2 -AdditionalVmCount 50 } | Should -Throw '*Insufficient*'
        }
        It 'only reads SKUs and usage' {
            Test-DemoComputeCapacity -Location australiaeast -Requirements @([pscustomobject]@{ VmSize = 'Standard_B2as_v2'; VmCount = 8 }, [pscustomobject]@{ VmSize = 'Standard_D4s_v5'; VmCount = 1 })
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[1] -notin @('list-skus', 'list-usage') }
        }
    }
}

Describe 'Preflight reports every missing CLI extension and provider in one pass' {
    InModuleScope Common {
        BeforeEach {
            $script:versionJson = '{"azure-cli":"2.91.0","azure-cli-core":"2.91.0","azure-cli-telemetry":"1.1.0","extensions":{"connectedmachine":"3.0.0","monitor-control-service":"1.2.0"}}'
            $script:providerStates = @{}
            $script:featureStates = @{}
            Mock Write-Header {}
            Mock Write-Ok {}
            Mock Initialize-DemoContext {}
            Mock az {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'version') { return $script:versionJson }
                if ($args[0] -eq 'bicep') { return 'Bicep CLI version 0.30.3 (fixture)' }
                throw "Unexpected az call: $($args -join ' ')"
            }
            Mock Invoke-DemoAz {
                param($Arguments)
                if ($Arguments[0] -eq 'account') { return '{"id":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222","user":"operator@example.com"}' }
                if ($Arguments[0] -eq 'role') { return 'Owner' }
                if ($Arguments[0] -eq 'provider') {
                    $state = $script:providerStates[$Arguments[3]]
                    return $(if ($state) { $state } else { 'Registered' })
                }
                if ($Arguments[0] -eq 'feature') {
                    $state = $script:featureStates["$($Arguments[3])/$($Arguments[5])"]
                    if ($state -eq 'absent') { return $null }
                    return $(if ($state) { $state } else { 'Registered' })
                }
                throw "Unexpected Azure CLI call: $($Arguments -join ' ')"
            }
            $script:preflight = @{ SubscriptionId = '11111111-1111-1111-1111-111111111111'; TenantId = '22222222-2222-2222-2222-222222222222'; DeployerPrincipalId = '33333333-3333-3333-3333-333333333333' }
        }

        It 'finds extensions in realistic az version output' {
            $info = $script:versionJson | ConvertFrom-Json
            Get-DemoMissingCliExtension -VersionInfo $info -Required @('connectedmachine', 'containerapp') | Should -Be @('containerapp')
            Get-DemoMissingCliExtension -VersionInfo ('{"azure-cli":"2.91.0","extensions":{}}' | ConvertFrom-Json) -Required @('connectedmachine') | Should -Be @('connectedmachine')
            @(Get-DemoMissingCliExtension -VersionInfo $info -Required @()).Count | Should -Be 0
        }
        It 'passes unchanged when the defaults are present and every provider is registered' {
            $preflight = $script:preflight
            Test-Prerequisites @preflight | Should -Be '33333333-3333-3333-3333-333333333333'
        }
        It 'fails once, naming every missing extension and every unregistered provider with the exact fix' {
            $script:providerStates['Microsoft.App'] = 'NotRegistered'
            $script:providerStates['Microsoft.DevTestLab'] = 'Registering'
            $thrown = $null
            $preflight = $script:preflight
            try { Test-Prerequisites @preflight -Providers @('Microsoft.Compute', 'Microsoft.App', 'Microsoft.DevTestLab') -RequiredExtensions @('connectedmachine', 'containerapp') }
            catch { $thrown = $_.Exception.Message }
            $thrown | Should -BeLike '*extension(s) not installed: containerapp. Run: az extension add --name containerapp --yes*'
            $thrown | Should -BeLike '*provider(s) not registered: Microsoft.App (NotRegistered), Microsoft.DevTestLab (Registering)*az provider register --subscription 11111111-1111-1111-1111-111111111111*'
            $thrown | Should -BeLike '*Preflight never registers providers*'
        }
        It 'never installs an extension or registers a provider' {
            $script:providerStates['Microsoft.App'] = 'NotRegistered'
            $preflight = $script:preflight
            { Test-Prerequisites @preflight -Providers @('Microsoft.App') -RequiredExtensions @('containerapp') } | Should -Throw
            Should -Invoke az -Times 0 -ParameterFilter { $args[0] -eq 'extension' }
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'register' -in $Arguments }
        }
        It 'adds the Container Apps and AKS prerequisites only for the workloads selected' {
            $base = Get-DemoPrerequisiteSet
            $base.Extensions | Should -Be @('connectedmachine')
            $base.Providers | Should -Not -Contain 'Microsoft.App'
            $base.Providers | Should -Not -Contain 'Microsoft.ContainerService'
            $apps = Get-DemoPrerequisiteSet -ContainerApps
            $apps.Extensions | Should -Be @('connectedmachine', 'containerapp')
            $apps.Providers | Should -Contain 'Microsoft.App'
            $apps.Providers | Should -Not -Contain 'Microsoft.ContainerService'
            $aks = Get-DemoPrerequisiteSet -Aks
            $aks.Extensions | Should -Be @('connectedmachine')
            $aks.Providers | Should -Contain 'Microsoft.ContainerService'
            $aks.Providers | Should -Not -Contain 'Microsoft.App'
            $aks.Features.Count | Should -Be 0
            $base.Features.Count | Should -Be 0
        }
        It 'adds the Standard security type feature only when asked' {
            (Get-DemoPrerequisiteSet -StandardSecurityType).Features | Should -Be @('Microsoft.Compute/UseStandardSecurityType')
            (Get-DemoPrerequisiteSet -ContainerApps -StandardSecurityType).Extensions | Should -Be @('connectedmachine', 'containerapp')
        }
        It 'passes when the required subscription feature is Registered, checking it read-only' {
            $preflight = $script:preflight
            Test-Prerequisites @preflight -Features @('Microsoft.Compute/UseStandardSecurityType') | Should -Be '33333333-3333-3333-3333-333333333333'
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter {
                $Arguments[0] -eq 'feature' -and $Arguments[1] -eq 'show' -and $Arguments[3] -eq 'Microsoft.Compute' -and $Arguments[5] -eq 'UseStandardSecurityType'
            }
        }
        It 'names an unregistered feature with the exact commands and never registers it' {
            $script:featureStates['Microsoft.Compute/UseStandardSecurityType'] = 'NotRegistered'
            $preflight = $script:preflight
            $thrown = $null
            try { Test-Prerequisites @preflight -Features @('Microsoft.Compute/UseStandardSecurityType') }
            catch { $thrown = $_.Exception.Message }
            $thrown | Should -BeLike '*feature(s) not registered: Microsoft.Compute/UseStandardSecurityType (NotRegistered)*'
            $thrown | Should -BeLike '*until the feature Microsoft.Compute/UseStandardSecurityType is registered*'
            $thrown | Should -BeLike '*az feature register --subscription 11111111-1111-1111-1111-111111111111 --namespace Microsoft.Compute --name UseStandardSecurityType*'
            $thrown | Should -BeLike '*az provider register --subscription 11111111-1111-1111-1111-111111111111 --namespace Microsoft.Compute --wait*'
            $thrown | Should -BeLike '*Preflight never registers features*'
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'register' -in $Arguments }
        }
        It 'reports a missing feature together with a missing extension and an unregistered provider' {
            $script:featureStates['Microsoft.Compute/UseStandardSecurityType'] = 'Pending'
            $script:providerStates['Microsoft.App'] = 'NotRegistered'
            $preflight = $script:preflight
            $thrown = $null
            try { Test-Prerequisites @preflight -Providers @('Microsoft.App') -RequiredExtensions @('containerapp') -Features @('Microsoft.Compute/UseStandardSecurityType') }
            catch { $thrown = $_.Exception.Message }
            $thrown | Should -BeLike '*extension(s) not installed: containerapp*'
            $thrown | Should -BeLike '*provider(s) not registered: Microsoft.App (NotRegistered)*'
            $thrown | Should -BeLike '*feature(s) not registered: Microsoft.Compute/UseStandardSecurityType (Pending)*'
        }
        It 'has nothing to register for a feature that is no longer in the catalog' {
            $script:featureStates['Microsoft.Compute/UseStandardSecurityType'] = 'absent'
            $preflight = $script:preflight
            { Test-Prerequisites @preflight -Features @('Microsoft.Compute/UseStandardSecurityType') } | Should -Not -Throw
        }
    }
}

Describe 'Which deployments need the Standard security type feature' {
    BeforeAll {
        $script:nestedSkinTable = @{ nestedSqlGuest = @{ enabled = $true; parentVmName = 'win-sql-02'; guestVmName = 'g'; arcMachineName = 'g' } }
        $script:fleetFile = Join-Path $TestDrive 'fleet.json'
    }
    It 'needs it for a nested SQL parent' {
        Test-DemoStandardSecurityTypeRequired -Skin $script:nestedSkinTable | Should -BeTrue
    }
    It 'does not need it for the base fleet' {
        Test-DemoStandardSecurityTypeRequired -Skin @{ schemaVersion = 1 } | Should -BeFalse
        Test-DemoStandardSecurityTypeRequired -Skin @{ nestedSqlGuest = @{ enabled = $false } } | Should -BeFalse
        Test-DemoStandardSecurityTypeRequired -Skin $null | Should -BeFalse
    }
    It 'needs it when a fleet entry declares Standard, and not for TrustedLaunch or no declaration' {
        Set-Content -LiteralPath $script:fleetFile -Value '[{"name":"a","securityType":"Standard"},{"name":"b"}]'
        Test-DemoStandardSecurityTypeRequired -Skin @{} -FleetPath $script:fleetFile | Should -BeTrue
        Set-Content -LiteralPath $script:fleetFile -Value '[{"name":"a","securityType":"TrustedLaunch"},{"name":"b"}]'
        Test-DemoStandardSecurityTypeRequired -Skin @{} -FleetPath $script:fleetFile | Should -BeFalse
        Set-Content -LiteralPath $script:fleetFile -Value '[{"name":"a"}]'
        Test-DemoStandardSecurityTypeRequired -Skin @{} -FleetPath $script:fleetFile | Should -BeFalse
    }
    It 'leaves a missing fleet file to Deploy, which reports its path' {
        Test-DemoStandardSecurityTypeRequired -Skin @{} -FleetPath (Join-Path $TestDrive 'absent.json') | Should -BeFalse
    }
}

Describe 'Key Vault secret write goes through Azure Resource Manager' {
    InModuleScope Common {
        BeforeEach {
            $script:attempts = 0
            $script:previousSubscription = $script:DemoSubscription
            $script:DemoSubscription = '11111111-1111-1111-1111-111111111111'
            Mock Write-Warn {}
            Mock Start-Sleep {}
        }
        AfterEach { $script:DemoSubscription = $script:previousSubscription }
        It 'writes once with an ARM PUT on the vault secret resource and never touches the data plane' {
            Mock Invoke-AzRest { $script:attempts++ }
            Mock Invoke-DemoAz { throw 'fixture: the data plane must not be used' }
            Set-DemoKeyVaultSecret -ResourceGroup rg-fixture-infra -VaultName kv-fixture-abc123 -Name vm-admin-password -Value 'Synthetic-Value-1'
            $script:attempts | Should -Be 1
            Should -Invoke Invoke-AzRest -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Put' -and
                $Url -eq 'https://management.azure.com/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.KeyVault/vaults/kv-fixture-abc123/secrets/vm-admin-password?api-version=2024-11-01' -and
                $Body.properties.value -eq 'Synthetic-Value-1'
            }
            Should -Invoke Invoke-DemoAz -Times 0
            Should -Invoke Start-Sleep -Times 0
        }
        It 'retries throttling and 5xx with increasing waits' {
            Mock Invoke-AzRest {
                $script:attempts++
                if ($script:attempts -lt 3) { throw 'Response status code does not indicate success: 503 (Service Unavailable).' }
            }
            Set-DemoKeyVaultSecret -ResourceGroup rg-fixture-infra -VaultName kv-fixture-abc123 -Name vm-admin-password -Value 'Synthetic-Value-1' -RetryDelaySeconds @(5, 7, 9)
            $script:attempts | Should -Be 3
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
            Should -Invoke Start-Sleep -Times 0 -ParameterFilter { $Seconds -eq 9 }
        }
        It 'does not retry a refusal that will not clear by itself, such as 403' {
            Mock Invoke-AzRest { $script:attempts++; throw 'Response status code does not indicate success: 403 (Forbidden).' }
            { Set-DemoKeyVaultSecret -ResourceGroup rg-fixture-infra -VaultName kv-fixture-abc123 -Name vm-admin-password -Value 'Synthetic-Value-1' } |
                Should -Throw '*could not be written to kv-fixture-abc123 through Azure Resource Manager*403*'
            $script:attempts | Should -Be 1
            Should -Invoke Start-Sleep -Times 0
        }
        It 'gives up after the bounded backoff and never prints the secret' {
            Mock Invoke-AzRest { $script:attempts++; throw 'Response status code does not indicate success: 429 (Too Many Requests).' }
            $thrown = $null
            try { Set-DemoKeyVaultSecret -ResourceGroup rg-fixture-infra -VaultName kv-fixture-abc123 -Name vm-admin-password -Value 'Synthetic-Value-1' -RetryDelaySeconds @(1, 2) }
            catch { $thrown = $_.Exception.Message }
            $thrown | Should -BeLike '*vm-admin-password could not be written to kv-fixture-abc123 after 3 attempts*'
            $thrown | Should -Not -BeLike '*Synthetic-Value-1*'
            $script:attempts | Should -Be 3
        }
        It 'needs the explicit demo context' {
            $script:DemoSubscription = $null
            { Set-DemoKeyVaultSecret -ResourceGroup rg -VaultName kv -Name n -Value v } | Should -Throw '*Initialize the explicit demo context*'
        }
    }
}

Describe 'Saved secret files' {
    It 'round-trips a secret as a SecureString and returns null when the file is absent' {
        $path = Join-Path $TestDrive 'secret.clixml'
        Read-DemoSecretFile -Path $path | Should -BeNullOrEmpty
        Save-DemoSecretFile -Path $path -Value 'Synthetic-Value-1' 3>$null
        $read = Read-DemoSecretFile -Path $path
        $read | Should -BeOfType [securestring]
        [System.Net.NetworkCredential]::new('', $read).Password | Should -Be 'Synthetic-Value-1'
        (Get-Content -LiteralPath $path -Raw) | Should -Not -BeLike '*Synthetic-Value-1*'
    }
    It 'also reads a credential export and refuses other content or a missing folder' {
        $path = Join-Path $TestDrive 'credential.clixml'
        [pscredential]::new('azureuser', (ConvertTo-SecureString 'Synthetic-Value-2' -AsPlainText -Force)) | Export-Clixml -LiteralPath $path
        [System.Net.NetworkCredential]::new('', (Read-DemoSecretFile -Path $path)).Password | Should -Be 'Synthetic-Value-2'
        Set-Content -LiteralPath (Join-Path $TestDrive 'text.clixml') -Value 'plain text'
        { Read-DemoSecretFile -Path (Join-Path $TestDrive 'text.clixml') } | Should -Throw '*could not be read*'
        { Save-DemoSecretFile -Path (Join-Path $TestDrive 'no-such-folder\secret.clixml') -Value 'x' } | Should -Throw '*folder for the saved secret does not exist*'
    }
}

Describe 'Subscription deployment is submitted without blocking and polled with progress' {
    InModuleScope Common {
        BeforeEach {
            $script:states = [System.Collections.Generic.Queue[string]]::new()
            $script:lastState = $null
            $script:submitFailures = [System.Collections.Generic.Queue[string]]::new()
            $script:operations = [System.Collections.Generic.Queue[string]]::new()
            $script:created = [System.Collections.Generic.List[object]]::new()
            $script:paramFile = Join-Path $TestDrive "params-$([guid]::NewGuid().ToString('N')).json"
            Set-Content -LiteralPath $script:paramFile -Value '{}'
            $script:fakeNow = [datetime]'2026-11-05T00:00:00Z'
            Mock Write-Step {}
            Mock Write-Ok {}
            Mock Write-Warn {}
            Mock Start-Sleep { $script:fakeNow = $script:fakeNow.AddSeconds($Seconds) }
            Mock Get-Date { $script:fakeNow }
            Mock Invoke-DemoAz {
                param($Arguments)
                if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'create') {
                    $script:created.Add($Arguments)
                    if ($script:submitFailures.Count) { throw $script:submitFailures.Dequeue() }
                    return
                }
                if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'show') {
                    if ($script:states.Count) { $script:lastState = $script:states.Dequeue() }
                    if ($script:lastState -eq 'missing') { return $null }
                    if ($script:lastState -like 'throw:*') { throw $script:lastState.Substring(6) }
                    return $script:lastState
                }
                if ($Arguments[0] -eq 'deployment' -and $Arguments[1] -eq 'operation') {
                    return $(if ($script:operations.Count) { $script:operations.Dequeue() } else { '[]' })
                }
                throw "Unexpected operation: $($Arguments -join ' ')"
            }
        }
        BeforeAll {
            function script:Invoke-Fixture {
                param([switch]$RemoveFile, [int]$TimeoutMinutes = 240)
                Invoke-DemoSubscriptionDeployment -Name arc-demo-20261105-100000 -Location australiaeast -TemplateFile 'main.bicep' -ParametersFile $script:paramFile `
                    -RemoveParametersFileWhenAccepted:$RemoveFile -TimeoutMinutes $TimeoutMinutes -PollSeconds 30
            }
        }

        It 'submits with --no-wait, deletes the plain-text parameters file once accepted and returns on Succeeded' {
            foreach ($s in '{"state":"Accepted"}', '{"state":"Running"}', '{"state":"Running"}', '{"state":"Succeeded"}') { $script:states.Enqueue($s) }
            Invoke-Fixture -RemoveFile
            $script:created.Count | Should -Be 1
            $script:created[0] | Should -Contain '--no-wait'
            $script:created[0] | Should -Contain "@$script:paramFile"
            Test-Path -LiteralPath $script:paramFile | Should -BeFalse
            Should -Invoke Write-Ok -Times 1 -Exactly -ParameterFilter { $Message -like '*arc-demo-20261105-100000 succeeded after*' }
        }
        It 'keeps the parameters file unless asked to remove it' {
            $script:states.Enqueue('{"state":"Accepted"}'); $script:states.Enqueue('{"state":"Succeeded"}')
            Invoke-Fixture
            Test-Path -LiteralPath $script:paramFile | Should -BeTrue
        }
        It 'throws the deployment error text on Failed so capacity guidance can still match it' {
            $script:states.Enqueue('{"state":"Accepted"}')
            $script:states.Enqueue('{"state":"Failed","error":{"code":"DeploymentFailed","details":[{"code":"SkuNotAvailable","message":"Standard_B2as_v2 is not available"}]}}')
            $thrown = $null
            try { Invoke-Fixture } catch { $thrown = $_.Exception.Message }
            $thrown | Should -BeLike '*arc-demo-20261105-100000 Failed after*SkuNotAvailable*'
            (Get-DemoAllocationGuidance -ErrorText $thrown -Location australiaeast -VmSize Standard_B2as_v2) | Should -BeLike '*(SkuNotAvailable; size Standard_B2as_v2*'
        }
        It 'names the modules still running when they change' {
            foreach ($s in '{"state":"Running"}', '{"state":"Running"}', '{"state":"Running"}', '{"state":"Succeeded"}') { $script:states.Enqueue($s) }
            foreach ($o in '["vm-win-sql-01","vm-lnx-app-01"]', '["vm-win-sql-01","vm-lnx-app-01"]', '["vm-lnx-app-01"]') { $script:operations.Enqueue($o) }
            Invoke-Fixture
            Should -Invoke Write-Step -Times 1 -Exactly -ParameterFilter { $Message -like '*still running: vm-lnx-app-01, vm-win-sql-01*' }
            Should -Invoke Write-Step -Times 1 -Exactly -ParameterFilter { $Message -like '*still running: vm-lnx-app-01' -and $Message -notlike '*vm-win-sql-01*' }
        }
        It 'follows the accepted deployment after a client error during the submit, without submitting twice' {
            $script:submitFailures.Enqueue('Azure CLI deployment sub failed (exit 1): ERROR: (ConnectionResetError(10054, An existing connection was forcibly closed))')
            foreach ($s in '{"state":"Running"}', '{"state":"Running"}', '{"state":"Succeeded"}') { $script:states.Enqueue($s) }
            Invoke-Fixture
            $script:created.Count | Should -Be 1
            Should -Invoke Write-Warn -Times 1 -Exactly -ParameterFilter { $Message -like '*after Azure had accepted it*' }
        }
        It 'resubmits a transient submit failure only while Azure has no record, at most three attempts' {
            $script:submitFailures.Enqueue('ERROR: Connection reset by peer'); $script:submitFailures.Enqueue('ERROR: Connection aborted')
            foreach ($s in 'missing', 'missing', '{"state":"Accepted"}', '{"state":"Succeeded"}') { $script:states.Enqueue($s) }
            Invoke-Fixture
            $script:created.Count | Should -Be 3
            Should -Invoke Write-Warn -Times 2 -Exactly -ParameterFilter { $Message -like '*Azure has no record of it, so nothing was created*' }
        }
        It 'does not retry a submit error that will not clear, and gives up after three transient ones' {
            $script:submitFailures.Enqueue('ERROR: {"code":"InvalidTemplateDeployment","message":"fixture"}'); $script:states.Enqueue('missing')
            { Invoke-Fixture } | Should -Throw '*InvalidTemplateDeployment*'
            $script:created.Count | Should -Be 1
            $script:created.Clear()
            1..3 | ForEach-Object { $script:submitFailures.Enqueue('ERROR: timed out'); $script:states.Enqueue('missing') }
            { Invoke-Fixture } | Should -Throw '*timed out*'
            $script:created.Count | Should -Be 3
        }
        It 'tolerates a few failed reads while polling but not five in a row' {
            $script:states.Enqueue('{"state":"Accepted"}')
            1..4 | ForEach-Object { $script:states.Enqueue('throw:ERROR: Connection reset') }
            $script:states.Enqueue('{"state":"Succeeded"}')
            { Invoke-Fixture } | Should -Not -Throw
            $script:states.Enqueue('{"state":"Accepted"}')
            1..5 | ForEach-Object { $script:states.Enqueue('throw:ERROR: Connection reset') }
            { Invoke-Fixture } | Should -Throw '*Could not read deployment arc-demo-20261105-100000 after 5 attempts*Azure keeps running it*'
        }
        It 'stops waiting at the timeout and leaves the deployment running in Azure' {
            $script:lastState = '{"state":"Running"}'
            $thrown = $null
            try { Invoke-Fixture -TimeoutMinutes 2 } catch { $thrown = $_.Exception.Message }
            $thrown | Should -BeLike '*still Running after 2 minutes*Azure keeps running it*Do not start another*'
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'cancel' -in $Arguments -or 'delete' -in $Arguments }
        }
    }
}

Describe 'Allocation failure guidance' {
    It 'explains a <Code> failure without switching size or region' -ForEach @(
        @{ Code = 'SkuNotAvailable'; Text = "Azure CLI deployment sub failed (exit 1): ERROR: {""code"": ""SkuNotAvailable"", ""message"": ""The requested VM size for resource 'Following SKUs have failed for Capacity Restrictions: Standard_B2as_v2' is currently not available in location 'australiaeast'.""}" }
        @{ Code = 'ZonalAllocationFailed'; Text = 'ERROR: {"code":"ZonalAllocationFailed","message":"Allocation failed. We do not have sufficient capacity for the requested VM size in this zone."}' }
        @{ Code = 'AllocationFailed'; Text = 'ERROR: {"code":"AllocationFailed","message":"Allocation failed. Please try again later."}' }
        @{ Code = 'OverconstrainedAllocationRequest'; Text = 'ERROR: {"code":"OverconstrainedAllocationRequest","message":"Allocation failed. VM allocation failed because of overconstrained request."}' }
        @{ Code = 'capacity restriction'; Text = 'ERROR: Operation could not be completed as it results in exceeding approved Total Regional Cores quota.' }
    ) {
        $text = Get-DemoAllocationGuidance -ErrorText $Text -Location australiaeast -VmSize Standard_B2as_v2 -SubscriptionId 11111111-1111-1111-1111-111111111111
        $text | Should -BeLike "*($Code; size Standard_B2as_v2, region australiaeast)*"
        $text | Should -BeLike '*Deploy never switches VM size or region on its own*'
        $text | Should -BeLike '*az vm list-skus --subscription 11111111-1111-1111-1111-111111111111 -l australiaeast*'
        $text | Should -BeLike '*az vm list-usage --subscription 11111111-1111-1111-1111-111111111111 -l australiaeast*'
        $text | Should -BeLike '*Original error:*'
    }
    It 'leaves unrelated deployment errors alone' {
        Get-DemoAllocationGuidance -ErrorText 'ERROR: {"code":"InvalidTemplateDeployment","message":"The template is not valid."}' -Location australiaeast -VmSize Standard_B2as_v2 | Should -BeNullOrEmpty
        Get-DemoAllocationGuidance -ErrorText '' -Location australiaeast -VmSize Standard_B2as_v2 | Should -BeNullOrEmpty
    }
}

Describe 'Stale deployment manifest selection' {
    BeforeAll {
        $deployments = @'
[
 {"name":"arc-demo-20261009-181623","properties":{"provisioningState":"Succeeded","outputs":{"arcResourceGroup":{"value":"rg-fixture"},"keyVaultName":{"value":"kv-fixture-old"}}}},
 {"name":"arc-demo-20261009-181139","properties":{"provisioningState":"Failed","parameters":{"arcResourceGroup":{"value":"rg-fixture"}}}},
 {"name":"arc-demo-20261009-164310","properties":{"provisioningState":"Canceled","parameters":{"arcResourceGroup":{"value":"rg-fixture"}}}},
 {"name":"arc-demo-20261009-190000","properties":{"provisioningState":"Running","parameters":{"arcResourceGroup":{"value":"rg-fixture"}}}},
 {"name":"arc-demo-20260518-170004","properties":{"provisioningState":"Succeeded","outputs":{"arcResourceGroup":{"value":"rg-other"}}}},
 {"name":"arc-demo-handmade","properties":{"provisioningState":"Succeeded","outputs":{"arcResourceGroup":{"value":"rg-fixture"}}}},
 {"name":"PolicyDeployment_10395098805976420115","properties":{"provisioningState":"Failed"}},
 {"name":"sre-agent-20261026233448","properties":{"provisioningState":"Succeeded","outputs":{"agentId":{"value":"fixture"}}}},
 {"name":"defender-deploy","properties":{"provisioningState":"Succeeded","outputs":{"pricingTier":{"value":"Standard"}}}},
 {"name":"policy-deploy","properties":{"provisioningState":"Succeeded"}},
 {"name":"budget-deploy","properties":{"provisioningState":"Succeeded"}}
]
'@ | ConvertFrom-Json
    }
    It 'returns only finished Deploy-ArcDemo records that name the removed Arc group' {
        $names = @(Get-DemoStaleManifestDeployments -Deployments $deployments -ArcResourceGroup rg-fixture).name
        $names | Should -Be @('arc-demo-20261009-181623', 'arc-demo-20261009-181139', 'arc-demo-20261009-164310')
    }
    It 'returns nothing for an empty history or another prefix' {
        @(Get-DemoStaleManifestDeployments -Deployments @() -ArcResourceGroup rg-fixture).Count | Should -Be 0
        @(Get-DemoStaleManifestDeployments -Deployments $null -ArcResourceGroup rg-fixture).Count | Should -Be 0
        @(Get-DemoStaleManifestDeployments -Deployments $deployments -ArcResourceGroup rg-unrelated).Count | Should -Be 0
    }
}

Describe 'Deploy against retained deployment manifests' {
    BeforeEach {
        Mock Import-Module {}
        Mock Write-Step {}
        Mock Write-Header {}
        Mock Test-Prerequisites { '33333333-3333-3333-3333-333333333333' }
        Mock Test-DemoComputeCapacity {}
        $state = @{
            groupExists = 'true'
            vaultList = '[{"name":"kv-fixture-stale"}]'
            manifests = '[{"name":"arc-demo-20261009-181623","properties":{"provisioningState":"Succeeded","timestamp":"2026-10-09T08:00:00Z","outputs":{"arcResourceGroup":{"value":"rg-fixture"},"keyVaultName":{"value":"kv-fixture-stale"}}}}]'
            preview = $null
        }
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'group' -and $Arguments[1] -eq 'exists') { return $state.groupExists }
            if ($Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'list') { return $state.vaultList }
            if ($Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'show') {
                return '{"id":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.KeyVault/vaults/kv-fixture-stale","properties":{"publicNetworkAccess":"Disabled"}}'
            }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'list') { return $state.manifests }
            # A missing resource group makes Invoke-DemoAz -AllowNotFound return $null, not an empty list.
            if ($Arguments[0] -eq 'vm') { return $(if ($state.groupExists -eq 'true') { '[]' }) }
            if ($Arguments[0] -in @('network', 'consumption')) { return $null }
            if ($Arguments[0] -eq 'security' -and $Arguments[2] -eq 'show') { return '{"name":"VirtualMachines","pricingTier":"Free","subPlan":null,"extensions":null}' }
            if ($Arguments[0] -eq 'bicep') { return '{"parameters":{"onPremFleet":{"defaultValue":[]}}}' }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if') {
                $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1].TrimStart('@')
                $state.preview = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                return
            }
            throw "Unexpected operation: $($Arguments -join ' ')"
        }
    }
    It 'ignores a manifest whose infra group is gone and builds a fresh, public vault' {
        $state.groupExists = 'false'
        $state.vaultList = $null
        & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf
        $state.preview.parameters.keyVaultName.value | Should -Match '^kv-fixture-[a-z0-9]{6}$'
        $state.preview.parameters.keyVaultName.value | Should -Not -Be 'kv-fixture-stale'
        $state.preview.parameters.keyVaultPublicNetworkAccess.value | Should -Be 'Enabled'
        Should -Invoke Write-Step -Times 1 -ParameterFilter { $Message -like '*Ignoring 1 retained deployment manifest(s) for rg-fixture: rg-fixture-infra no longer exists*' }
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'show' }
    }
    It 'keeps preserving the manifest vault when the infra group exists' {
        & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf
        $state.preview.parameters.keyVaultName.value | Should -Be 'kv-fixture-stale'
        $state.preview.parameters.keyVaultPublicNetworkAccess.value | Should -Be 'Disabled'
    }
    It 'still refuses when the infra group exists but the manifest vault is missing from it' {
        $state.vaultList = '[{"name":"kv-fixture-different"}]'
        { & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf } | Should -Throw '*absent/ambiguous*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if' }
    }
    It 'does not ask whether the group exists when there is no manifest' {
        $state.manifests = '[]'
        $state.vaultList = $null
        & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'group' }
        $state.preview.parameters.keyVaultName.value | Should -Match '^kv-fixture-[a-z0-9]{6}$'
    }
}

Describe 'Deploy hardening wiring' {
    BeforeEach {
        Mock Import-Module {}
        Mock Write-Step {}
        Mock Write-Header {}
        Mock Write-Ok {}
        Mock Test-Prerequisites { '33333333-3333-3333-3333-333333333333' }
        Mock Test-DemoComputeCapacity {}
        # A real vault write or ARM call must never happen here: stop right after the deployment step.
        Mock Set-DemoKeyVaultSecret { throw 'fixture: stop after the secret write' }
        Mock Invoke-AzRest { throw 'fixture: no ARM REST call expected' }
        $state = @{ createCalls = 0; createError = $null }
        # The deployment helper has its own tests; here only its call and failure text matter.
        Mock Invoke-DemoSubscriptionDeployment {
            $state.createCalls++
            if ($state.createError) { throw $state.createError }
        }
        Mock Invoke-DemoAz {
            param($Arguments)
            # On a clean subscription the infra group does not exist: every -AllowNotFound read returns $null.
            if ($Arguments[0] -in @('keyvault', 'network', 'consumption', 'aks', 'containerapp', 'vm')) { return $null }
            if ($Arguments[0] -eq 'security' -and $Arguments[2] -eq 'show') { return '{"name":"VirtualMachines","pricingTier":"Free","subPlan":null,"extensions":null}' }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'list') { return '[]' }
            if ($Arguments[0] -eq 'bicep') { return '{"parameters":{"onPremFleet":{"defaultValue":[]}}}' }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if') { return }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'show') { return '{"workspaceId":{"value":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.OperationalInsights/workspaces/law-fixture"}}' }
            throw "Unexpected operation: $($Arguments -join ' ')"
        }
    }
    It 'deploys to a clean subscription where the infra group does not exist yet, with new Container App and AKS' {
        { & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' -DeployContainerApps $true -DeployAks $true -WhatIf } | Should -Not -Throw
        Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if' }
    }
    It 'requires only the CLI extension and providers its workloads use' {
        & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf
        Should -Invoke Test-Prerequisites -Times 1 -Exactly -ParameterFilter {
            @($RequiredExtensions) -contains 'connectedmachine' -and @($RequiredExtensions) -notcontains 'containerapp' -and @($Providers) -notcontains 'Microsoft.App'
        }
        & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' -DeployContainerApps $true -WhatIf
        Should -Invoke Test-Prerequisites -Times 1 -Exactly -ParameterFilter {
            @($RequiredExtensions) -contains 'connectedmachine' -and @($RequiredExtensions) -contains 'containerapp' -and @($Providers) -contains 'Microsoft.App'
        }
        & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' -DeployAks $true -WhatIf
        Should -Invoke Test-Prerequisites -Times 1 -Exactly -ParameterFilter {
            @($Providers) -contains 'Microsoft.ContainerService' -and @($Providers) -notcontains 'Microsoft.App' -and @($RequiredExtensions) -notcontains 'containerapp'
        }
    }
    It 'saves the generated password through Azure Resource Manager right after the deployment' {
        { & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' -Confirm:$false } | Should -Throw '*stop after the secret write*'
        Should -Invoke Set-DemoKeyVaultSecret -Times 1 -Exactly -ParameterFilter {
            $ResourceGroup -eq 'rg-fixture-infra' -and $VaultName -match '^kv-fixture-[a-z0-9]{6}$' -and $Name -eq 'vm-admin-password' -and $Value.Length -eq 24
        }
        $state.createCalls | Should -Be 1
    }
    It 'turns an allocation failure into guidance and does not retry with another size or region' {
        $state.createError = 'Azure CLI deployment sub failed (exit 1): ERROR: {"code": "SkuNotAvailable", "message": "The requested VM size for resource ''Following SKUs have failed for Capacity Restrictions: Standard_B2as_v2'' is currently not available in location ''australiaeast''."}'
        $thrown = $null
        try { & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' -Confirm:$false }
        catch { $thrown = $_.Exception.Message }
        $thrown | Should -BeLike '*(SkuNotAvailable; size Standard_B2as_v2, region australiaeast)*'
        $thrown | Should -BeLike '*Deploy never switches VM size or region on its own*'
        $thrown | Should -BeLike '*az vm list-skus --subscription 11111111-1111-1111-1111-111111111111*'
        $state.createCalls | Should -Be 1
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'show' }
        Should -Invoke Set-DemoKeyVaultSecret -Times 0
    }
    It 'passes any other deployment failure through unchanged' {
        $state.createError = 'Azure CLI deployment sub failed (exit 1): ERROR: {"code":"InvalidTemplateDeployment","message":"fixture template problem"}'
        { & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' -Confirm:$false } | Should -Throw '*fixture template problem*'
    }
}

Describe 'Deploy admin password, saved copy and resume of an unfinished build' {
    BeforeEach {
        Mock Import-Module {}
        Mock Write-Step {}
        Mock Write-Header {}
        Mock Write-Ok {}
        Mock Write-Warn {}
        Mock Test-Prerequisites { '33333333-3333-3333-3333-333333333333' }
        Mock Test-DemoComputeCapacity {}
        Mock Set-DemoKeyVaultSecret { throw 'fixture: stop after the secret write' }
        Mock Invoke-AzRest { throw 'fixture: no ARM REST call expected' }
        $script:pwFile = Join-Path $TestDrive 'vm-admin-credential.clixml'
        Remove-Item -LiteralPath $script:pwFile -ErrorAction SilentlyContinue
        $vaultId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.KeyVault/vaults'
        $script:s = @{
            vaults = $null; vms = $null; secret = $null; liveAccess = $null; bicepPassword = $null; fileAtCreate = $false; createCalls = 0; secretReads = 0
            deployments = '[]'; vaultShow = $null; vaultId = $vaultId
            retainedManifest = '{"name":"arc-demo-20261009-181623","properties":{"provisioningState":"Succeeded","timestamp":"2026-10-09T08:00:00Z","outputs":{"arcResourceGroup":{"value":"rg-fixture"},"keyVaultName":{"value":"kv-fixture-stale"}}}}'
            failedBuild = '{"name":"arc-demo-20261105-100000","properties":{"provisioningState":"Failed","timestamp":"2026-11-05T00:00:00Z","parameters":{"arcResourceGroup":{"value":"rg-fixture"},"keyVaultName":{"value":"kv-fixture-abc123"}}}}'
            vm = '{"name":"keep-vm","location":"australiaeast","hardwareProfile":{"vmSize":"Standard_B2as_v2"}}'
        }
        # Mock bodies run outside the test file's script scope, so they share the state through globals (as FleetVmShape.Tests does).
        $global:ArcPw = $script:s
        $global:ArcPwFile = $script:pwFile
        Mock Invoke-DemoSubscriptionDeployment {
            $global:ArcPw.createCalls++
            $global:ArcPw.bicepPassword = (Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Json).parameters.adminPassword.value
            $global:ArcPw.fileAtCreate = Test-Path -LiteralPath $global:ArcPwFile
        }
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'list') { return $global:ArcPw.vaults }
            if ($Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'show') { return $(if ('--query' -in $Arguments) { $global:ArcPw.liveAccess } else { $global:ArcPw.vaultShow }) }
            if ($Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'secret') { $global:ArcPw.secretReads++; return $global:ArcPw.secret }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'list') { return $global:ArcPw.deployments }
            if ($Arguments[0] -eq 'group') { return 'true' }
            if ($Arguments[0] -eq 'vm') { return $global:ArcPw.vms }
            if ($Arguments[0] -in @('network', 'consumption', 'aks', 'containerapp')) { return $null }
            if ($Arguments[0] -eq 'security' -and $Arguments[2] -eq 'show') { return '{"name":"VirtualMachines","pricingTier":"Free","subPlan":null,"extensions":null}' }
            if ($Arguments[0] -eq 'bicep') { return '{"parameters":{"onPremFleet":{"defaultValue":[]}}}' }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if') { return }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'show') { return '{"workspaceId":{"value":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.OperationalInsights/workspaces/law-fixture"},"dcrCoreId":{"value":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.Insights/dataCollectionRules/dcr-fixture"},"dcrVmiId":{"value":"/x/dcr-vminsights"},"dcrCtId":{"value":"/x/dcr-changetracking"}}' }
            throw "Unexpected operation: $($Arguments -join ' ')"
        }
        function Invoke-FixtureDeploy {
            param([switch]$WithPath, [switch]$WhatIf, [string]$Path = $script:pwFile)
            $extra = @{}
            if ($WithPath) { $extra.AdminPasswordPath = $Path }
            if ($WhatIf) { $extra.WhatIf = $true } else { $extra.Confirm = $false }
            & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' @extra
        }
        function Set-RetainedEstate {
            param([string]$Access)
            $script:s.vaults = '[{"name":"kv-fixture-stale"}]'
            $script:s.deployments = "[$($script:s.retainedManifest)]"
            $script:s.vaultShow = '{"id":"' + $script:s.vaultId + '/kv-fixture-stale","properties":{"publicNetworkAccess":"' + $Access + '"}}'
            $script:s.vms = "[$($script:s.vm)]"
        }
    }

    AfterEach { Remove-Variable ArcPw, ArcPwFile -Scope Global -ErrorAction SilentlyContinue }

    It 'saves a fresh password before the deployment starts and passes the same value to Bicep and the vault' {
        { Invoke-FixtureDeploy -WithPath } | Should -Throw '*stop after the secret write*'
        $script:s.fileAtCreate | Should -BeTrue
        $script:s.bicepPassword.Length | Should -Be 24
        [System.Net.NetworkCredential]::new('', (Read-DemoSecretFile -Path $script:pwFile)).Password | Should -Be $script:s.bicepPassword
        Should -Invoke Set-DemoKeyVaultSecret -Times 1 -Exactly -ParameterFilter { $Value -eq $global:ArcPw.bicepPassword }
    }
    It 'saves nothing during a preview, and nothing when no path is given' {
        Invoke-FixtureDeploy -WithPath -WhatIf
        Test-Path -LiteralPath $script:pwFile | Should -BeFalse
        { Invoke-FixtureDeploy } | Should -Throw '*stop after the secret write*'
        Test-Path -LiteralPath $script:pwFile | Should -BeFalse
    }
    It 'refuses a password file inside the git worktree' {
        { Invoke-FixtureDeploy -WithPath -Path (Join-Path $repo '.local\vm-admin-credential.clixml') } | Should -Throw '*outside the git worktree*'
        Should -Invoke Invoke-DemoAz -Times 0
    }
    It 'warns that a policy made the vault private-only, and still writes the secret through ARM' {
        $script:s.liveAccess = 'Disabled'
        { Invoke-FixtureDeploy -WithPath } | Should -Throw '*stop after the secret write*'
        Should -Invoke Write-Warn -Times 1 -Exactly -ParameterFilter { $Message -like '*publicNetworkAccess=Disabled although this deployment asked for Enabled*not a role-propagation delay*' }
        Should -Invoke Set-DemoKeyVaultSecret -Times 1 -Exactly
    }
    It 'reuses the saved password for a retained estate whose vault is private-only, without reading the vault' {
        Set-RetainedEstate -Access 'Disabled'
        Save-DemoSecretFile -Path $script:pwFile -Value 'Saved-Value-1' 3>$null
        { Invoke-FixtureDeploy -WithPath } | Should -Throw '*no ARM REST call expected*'
        $script:s.bicepPassword | Should -Be 'Saved-Value-1'
        $script:s.secretReads | Should -Be 0
        Should -Invoke Set-DemoKeyVaultSecret -Times 0
    }
    It 'prefers the vault secret over the saved file when the vault is public, and the file when it holds no secret' {
        Set-RetainedEstate -Access 'Enabled'
        Save-DemoSecretFile -Path $script:pwFile -Value 'Saved-Value-1' 3>$null
        $script:s.secret = 'Vault-Value-1'
        { Invoke-FixtureDeploy -WithPath } | Should -Throw '*no ARM REST call expected*'
        $script:s.bicepPassword | Should -Be 'Vault-Value-1'
        $script:s.secret = $null
        { Invoke-FixtureDeploy -WithPath } | Should -Throw '*no ARM REST call expected*'
        $script:s.bicepPassword | Should -Be 'Saved-Value-1'
        Should -Invoke Set-DemoKeyVaultSecret -Times 0
    }
    It 'lets an explicit -AdminPassword win over everything and refuses a private-only vault with no password at all' {
        Set-RetainedEstate -Access 'Disabled'
        { Invoke-FixtureDeploy } | Should -Throw '*private-only*AdminPasswordPath*'
        Save-DemoSecretFile -Path $script:pwFile -Value 'Saved-Value-1' 3>$null
        $explicit = ConvertTo-SecureString 'Explicit-Value-1' -AsPlainText -Force
        { & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' -AdminPasswordPath $script:pwFile -AdminPassword $explicit -Confirm:$false } |
            Should -Throw '*no ARM REST call expected*'
        $script:s.bicepPassword | Should -Be 'Explicit-Value-1'
    }
    It 'resumes an unfinished build: adopts the vault named by its own Failed deployment, reuses the saved password and stores the vault copy' {
        $script:s.vaults = '[{"name":"kv-fixture-abc123"}]'
        $script:s.deployments = "[$($script:s.failedBuild)]"
        $script:s.vaultShow = '{"id":"' + $script:s.vaultId + '/kv-fixture-abc123","properties":{"publicNetworkAccess":"Disabled"}}'
        $script:s.vms = "[$($script:s.vm)]"
        Save-DemoSecretFile -Path $script:pwFile -Value 'Saved-Value-1' 3>$null
        { Invoke-FixtureDeploy -WithPath } | Should -Throw '*stop after the secret write*'
        $script:s.bicepPassword | Should -Be 'Saved-Value-1'
        Should -Invoke Write-Step -ParameterFilter { $Message -like '*Resuming the unfinished build arc-demo-20261105-100000*kv-fixture-abc123*' }
        Should -Invoke Set-DemoKeyVaultSecret -Times 1 -Exactly -ParameterFilter { $VaultName -eq 'kv-fixture-abc123' -and $Value -eq 'Saved-Value-1' }
    }
    It 'resumes the same way when the failed build had not created a VM yet' {
        $script:s.vaults = '[{"name":"kv-fixture-abc123"}]'
        $script:s.deployments = "[$($script:s.failedBuild)]"
        $script:s.vaultShow = '{"id":"' + $script:s.vaultId + '/kv-fixture-abc123","properties":{"publicNetworkAccess":"Enabled"}}'
        Save-DemoSecretFile -Path $script:pwFile -Value 'Saved-Value-1' 3>$null
        { Invoke-FixtureDeploy -WithPath } | Should -Throw '*stop after the secret write*'
        $script:s.bicepPassword | Should -Be 'Saved-Value-1'
    }
    It 'never adopts a vault that no deployment of this demo names' {
        $script:s.vaults = '[{"name":"kv-fixture-unrelated"}]'
        $script:s.deployments = "[$($script:s.failedBuild)]"
        { Invoke-FixtureDeploy -WithPath } | Should -Throw '*no canonical retained deployment output*'
        $script:s.createCalls | Should -Be 0
    }
    It 'does not start a second deployment while this demo has one running' {
        $script:s.deployments = '[{"name":"arc-demo-20261105-110000","properties":{"provisioningState":"Running","timestamp":"2026-11-05T01:00:00Z","parameters":{"arcResourceGroup":{"value":"rg-fixture"}}}}]'
        { Invoke-FixtureDeploy -WithPath } | Should -Throw '*arc-demo-20261105-110000*is still Running*'
        $script:s.createCalls | Should -Be 0
        { Invoke-FixtureDeploy -WithPath -WhatIf } | Should -Not -Throw
    }
}

Describe 'Test-Prerequisites.ps1 checks what Deploy would check for the skin' {
    BeforeEach {
        Mock Import-Module {}
        Mock Write-Ok {}
        Mock Write-Host {}
        Mock Test-Prerequisites { '33333333-3333-3333-3333-333333333333' }
        $script:skinPath = Join-Path $TestDrive 'skin.json'
    }
    It 'adds the Container Apps prerequisites when the skin selects them' {
        Set-Content -LiteralPath $script:skinPath -Value '{"schemaVersion":1,"workloads":{"deployContainerApps":true}}'
        & (Join-Path $repo 'scripts\Test-Prerequisites.ps1') @target -SkinPath $script:skinPath
        Should -Invoke Test-Prerequisites -Times 1 -Exactly -ParameterFilter {
            @($RequiredExtensions) -contains 'containerapp' -and @($Providers) -contains 'Microsoft.App' -and @($Providers) -notcontains 'Microsoft.ContainerService'
        }
    }
    It 'adds the AKS providers when the skin selects AKS, and an explicit parameter overrides the skin' {
        Set-Content -LiteralPath $script:skinPath -Value '{"schemaVersion":1,"workloads":{"deployContainerApps":true,"deployAks":true}}'
        & (Join-Path $repo 'scripts\Test-Prerequisites.ps1') @target -SkinPath $script:skinPath -DeployContainerApps $false
        Should -Invoke Test-Prerequisites -Times 1 -Exactly -ParameterFilter {
            @($Providers) -contains 'Microsoft.ContainerService' -and @($Providers) -notcontains 'Microsoft.App' -and @($RequiredExtensions) -notcontains 'containerapp'
        }
    }
    It 'checks only the base set for a skin with no optional workloads' {
        Set-Content -LiteralPath $script:skinPath -Value '{"schemaVersion":1}'
        & (Join-Path $repo 'scripts\Test-Prerequisites.ps1') @target -SkinPath $script:skinPath
        Should -Invoke Test-Prerequisites -Times 1 -Exactly -ParameterFilter {
            @($RequiredExtensions).Count -eq 1 -and @($RequiredExtensions) -contains 'connectedmachine' -and @($Providers) -notcontains 'Microsoft.App' -and @($Features).Count -eq 0
        }
    }
    It 'adds the Standard security type feature when the skin declares the nested SQL parent' {
        Set-Content -LiteralPath $script:skinPath -Value '{"schemaVersion":1,"nestedSqlGuest":{"enabled":true,"parentVmName":"win-sql-02","guestVmName":"g","arcMachineName":"g"}}'
        & (Join-Path $repo 'scripts\Test-Prerequisites.ps1') @target -SkinPath $script:skinPath
        Should -Invoke Test-Prerequisites -Times 1 -Exactly -ParameterFilter { @($Features) -contains 'Microsoft.Compute/UseStandardSecurityType' }
    }
}

Describe 'Readiness polling bound for a fresh deployment' {
    It 'allows read-only polling for up to 30 minutes and nothing unbounded' {
        { & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') @target -TimeoutSeconds 1801 } | Should -Throw '*1800*'
    }
    It 'waits up to 20 minutes for Windows Heartbeats at the end of Deploy' {
        (Get-Content (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -Raw) | Should -Match 'Test-ArcDemoReadiness\.ps1''\) .* -TimeoutSeconds 1200'
    }
}

Describe 'Remove-ArcDemo workspace and deployment-history options' {
    BeforeEach {
        Mock Import-Module {}
        Mock Initialize-DemoContext {}
        Mock Write-Ok {}
        Mock Write-Step {}
        Mock Get-DemoRemovalChecks { New-DemoCheck 'owned' '/fixture' 'absent' 'absent' 'pass' }
        Mock Wait-Until {
            param($Condition)
            if (-not (& $Condition)) { throw 'Owned resources still present.' }
        }
        $state = @{
            events = [Collections.Generic.List[string]]::new()
            workspace = '{"name":"law-fixture","provisioningState":"Succeeded"}'
            history = @'
[
 {"name":"arc-demo-20261009-181623","properties":{"provisioningState":"Succeeded","outputs":{"arcResourceGroup":{"value":"rg-fixture"}}}},
 {"name":"arc-demo-20261009-181139","properties":{"provisioningState":"Failed","parameters":{"arcResourceGroup":{"value":"rg-fixture"}}}},
 {"name":"arc-demo-20261009-190000","properties":{"provisioningState":"Running","parameters":{"arcResourceGroup":{"value":"rg-fixture"}}}},
 {"name":"arc-demo-20260518-170004","properties":{"provisioningState":"Succeeded","outputs":{"arcResourceGroup":{"value":"rg-other"}}}},
 {"name":"PolicyDeployment_10395098805976420115","properties":{"provisioningState":"Failed"}},
 {"name":"sre-agent-20261026233448","properties":{"provisioningState":"Succeeded","outputs":{"agentId":{"value":"fixture"}}}},
 {"name":"defender-deploy","properties":{"provisioningState":"Succeeded"}}
]
'@
        }
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'group' -and $Arguments[1] -eq 'exists') { return 'true' }
            if ($Arguments[0] -eq 'group' -and $Arguments[1] -eq 'delete') { $state.events.Add("group-delete:$($Arguments[3])"); return }
            if ($Arguments[0] -eq 'monitor' -and $Arguments[3] -eq 'show') { $state.events.Add('workspace-show'); return $state.workspace }
            if ($Arguments[0] -eq 'monitor' -and $Arguments[3] -eq 'delete') {
                $state.events.Add("workspace-delete:$($Arguments[5]):$($Arguments[7]):force=$($Arguments[9])")
                return
            }
            if ($Arguments[0] -in @('policy', 'consumption')) { return $null }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'list') { return $state.history }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'delete') { $state.events.Add("deployment-delete:$($Arguments[4])"); return }
            if ($Arguments[0] -eq 'security' -and $Arguments[2] -eq 'create') { $state.events.Add("defender-pricing:$($Arguments[4]):$($Arguments[6])"); return }
            throw "Unexpected cleanup operation: $($Arguments -join ' ')"
        }
    }
    It 'leaves the workspace and the deployment history alone by default' {
        & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') @target -NamePrefix fixture -Confirm:$false
        $state.events | Should -Be @('group-delete:rg-fixture', 'group-delete:rg-fixture-infra')
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -in @('monitor', 'deployment') }
    }
    It 'leaves Defender pricing unchanged by default; only -DisableDefender sets the plan to Free' {
        & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') @target -NamePrefix fixture -Confirm:$false
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'security' }
        $state.events.Clear()
        & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') @target -NamePrefix fixture -DisableDefender -Confirm:$false
        $state.events | Should -Be @('group-delete:rg-fixture', 'group-delete:rg-fixture-infra', 'defender-pricing:VirtualMachines:Free')
    }
    It 'force-deletes the workspace before either group is deleted' {
        & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') @target -NamePrefix fixture -ForceDeleteWorkspace -Confirm:$false
        $state.events | Should -Be @('workspace-show', 'workspace-delete:rg-fixture:law-fixture:force=true', 'group-delete:rg-fixture', 'group-delete:rg-fixture-infra')
    }
    It 'skips a workspace that is already gone and still removes the groups' {
        $state.workspace = $null
        & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') @target -NamePrefix fixture -ForceDeleteWorkspace -Confirm:$false
        $state.events | Should -Be @('workspace-show', 'group-delete:rg-fixture', 'group-delete:rg-fixture-infra')
    }
    It 'prunes only this demo''s finished manifest records, after the groups are verified absent' {
        & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') @target -NamePrefix fixture -PruneDeploymentHistory -Confirm:$false
        $state.events | Should -Be @('group-delete:rg-fixture', 'group-delete:rg-fixture-infra', 'deployment-delete:arc-demo-20261009-181623', 'deployment-delete:arc-demo-20261009-181139')
    }
    It 'does not prune when removal verification fails' {
        Mock Get-DemoRemovalChecks { New-DemoCheck 'budget' '/budget' 'absent' 'exists' 'pending' }
        { & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') @target -NamePrefix fixture -PruneDeploymentHistory -Confirm:$false } | Should -Throw '*still present*'
        $state.events | Should -Not -Contain 'deployment-delete:arc-demo-20261009-181623'
    }
    It 'previews both options without any Azure call' {
        Mock Invoke-DemoAz { throw 'WhatIf must not call Azure' }
        & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') @target -NamePrefix fixture -ForceDeleteWorkspace -PruneDeploymentHistory -WhatIf
        Should -Invoke Invoke-DemoAz -Times 0
    }
}
