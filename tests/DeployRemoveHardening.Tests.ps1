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
    }
}

Describe 'Key Vault secret write rides out RBAC propagation' {
    InModuleScope Common {
        BeforeEach {
            $script:attempts = 0
            Mock Write-Warn {}
            Mock Start-Sleep {}
        }
        It 'writes once with the checked CLI wrapper on the happy path' {
            Mock Invoke-DemoAz { $script:attempts++ }
            Set-DemoKeyVaultSecret -VaultName kv-fixture-abc123 -Name vm-admin-password -Value 'Synthetic-Value-1'
            $script:attempts | Should -Be 1
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter {
                $Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'secret' -and $Arguments[2] -eq 'set' -and
                $Arguments[[Array]::IndexOf($Arguments, '--vault-name') + 1] -eq 'kv-fixture-abc123'
            }
            Should -Invoke Start-Sleep -Times 0
        }
        It 'retries Forbidden while the new role assignment propagates, with increasing waits' {
            Mock Invoke-DemoAz {
                $script:attempts++
                if ($script:attempts -lt 3) { throw 'Azure CLI keyvault secret failed (exit 1): (Forbidden) Caller is not authorized to perform action on resource. If role assignments, deny assignments or role definitions were changed recently, please observe propagation time.' }
            }
            Set-DemoKeyVaultSecret -VaultName kv-fixture-abc123 -Name vm-admin-password -Value 'Synthetic-Value-1' -RetryDelaySeconds @(5, 7, 9)
            $script:attempts | Should -Be 3
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
            Should -Invoke Start-Sleep -Times 0 -ParameterFilter { $Seconds -eq 9 }
        }
        It 'does not retry an error that will not clear by itself' {
            Mock Invoke-DemoAz { $script:attempts++; throw 'Azure CLI keyvault secret failed (exit 1): (VaultNotFound) The Vault ''kv-fixture-abc123'' was not found.' }
            { Set-DemoKeyVaultSecret -VaultName kv-fixture-abc123 -Name vm-admin-password -Value 'Synthetic-Value-1' } | Should -Throw '*VaultNotFound*'
            $script:attempts | Should -Be 1
            Should -Invoke Start-Sleep -Times 0
        }
        It 'gives up after the bounded backoff and never prints the secret' {
            Mock Invoke-DemoAz { $script:attempts++; throw 'Azure CLI keyvault secret failed (exit 1): (Forbidden) Caller is not authorized to perform action on resource.' }
            $thrown = $null
            try { Set-DemoKeyVaultSecret -VaultName kv-fixture-abc123 -Name vm-admin-password -Value 'Synthetic-Value-1' -RetryDelaySeconds @(1, 2) }
            catch { $thrown = $_.Exception.Message }
            $thrown | Should -BeLike '*vm-admin-password could not be written to kv-fixture-abc123 after 3 attempts*'
            $thrown | Should -Not -BeLike '*Synthetic-Value-1*'
            $script:attempts | Should -Be 3
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
        Mock Invoke-DemoAz {
            param($Arguments)
            # On a clean subscription the infra group does not exist: every -AllowNotFound read returns $null.
            if ($Arguments[0] -in @('keyvault', 'network', 'consumption', 'aks', 'containerapp', 'vm')) { return $null }
            if ($Arguments[0] -eq 'security' -and $Arguments[2] -eq 'show') { return '{"name":"VirtualMachines","pricingTier":"Free","subPlan":null,"extensions":null}' }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'list') { return '[]' }
            if ($Arguments[0] -eq 'bicep') { return '{"parameters":{"onPremFleet":{"defaultValue":[]}}}' }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if') { return }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'create') {
                $state.createCalls++
                if ($state.createError) { throw $state.createError }
                return
            }
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
    }
    It 'saves the generated password through the retrying Key Vault helper right after the deployment' {
        { & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') @target -NamePrefix fixture -AdminEmail 'test@example.com' -Confirm:$false } | Should -Throw '*stop after the secret write*'
        Should -Invoke Set-DemoKeyVaultSecret -Times 1 -Exactly -ParameterFilter {
            $VaultName -match '^kv-fixture-[a-z0-9]{6}$' -and $Name -eq 'vm-admin-password' -and $Value.Length -eq 24
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
