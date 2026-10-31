param([string]$SourceRoot = '')

BeforeAll {
    $repo = if ($SourceRoot) { [IO.Path]::GetFullPath($SourceRoot) } else { Split-Path $PSScriptRoot }
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
    Import-Module (Join-Path $repo 'scripts\lib\PrivateOnboarding.psm1') -Force
}

Describe 'Private onboarding plan' {
    BeforeEach {
        $sub = '11111111-1111-1111-1111-111111111111'
        $tenant = '22222222-2222-2222-2222-222222222222'
        $scope = "/subscriptions/$sub/resourceGroups/rg-fixture-infra"
        $plan = @{
            schemaVersion = 1; subscriptionId = $sub; tenantId = $tenant; namePrefix = 'fixture'; location = 'australiaeast'
            vaultResourceId        = "$scope/providers/Microsoft.KeyVault/vaults/kv-fixture"
            vnetResourceId         = "$scope/providers/Microsoft.Network/virtualNetworks/vnet-fixture"
            subnetResourceId       = "$scope/providers/Microsoft.Network/virtualNetworks/vnet-fixture/subnets/snet-vms"
            subnetAddressPrefix = '10.50.1.0/24'
            applicationId = '33333333-3333-3333-3333-333333333333'; applicationObjectId = '44444444-4444-4444-4444-444444444444'
            servicePrincipalObjectId = '55555555-5555-5555-5555-555555555555'; deployerPrincipalId = '66666666-6666-6666-6666-666666666666'
            parents                = @(
                @{ resourceId = "$scope/providers/Microsoft.Compute/virtualMachines/parent-one"; vmId = '77777777-7777-7777-7777-777777777777'; principalId = '88888888-8888-8888-8888-888888888888' }
                @{ resourceId = "$scope/providers/Microsoft.Compute/virtualMachines/parent-two"; vmId = '99999999-9999-9999-9999-999999999999'; principalId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
            )
            writerParentResourceId = "$scope/providers/Microsoft.Compute/virtualMachines/parent-two"
        }
        $path = Join-Path $TestDrive 'plan.json'
    }
    It 'accepts an explicit non-default estate' {
        $plan | ConvertTo-Json -Depth 10 | Set-Content $path
        (Get-DemoPrivatePlan $path $sub $tenant).namePrefix | Should -Be 'fixture'
    }
    It 'rejects <case> before any cloud call' -ForEach @(
        @{ case = 'missing deployer'; change = { $plan.Remove('deployerPrincipalId') } }
        @{ case = 'empty parent VM identity'; change = { $plan.parents[0].vmId = [guid]::Empty.ToString() } }
        @{ case = 'duplicate parent'; change = { $plan.parents[1] = $plan.parents[0] } }
        @{ case = 'foreign writer'; change = { $plan.writerParentResourceId += '-other' } }
        @{ case = 'regex-like provider'; change = { $plan.vaultResourceId = $plan.vaultResourceId.Replace('Microsoft.KeyVault', 'MicrosoftXKeyVault') } }
        @{ case = 'foreign subnet'; change = { $plan.subnetResourceId += '-other' } }
        @{ case = 'unknown input'; change = { $plan.secretValue = 'not-accepted' } }
        @{ case = 'foreign tenant'; change = { $plan.tenantId = $sub } }
    ) {
        & $change
        $plan | ConvertTo-Json -Depth 10 | Set-Content $path
        { Get-DemoPrivatePlan $path $sub $tenant } | Should -Throw
    }
}

Describe 'Private onboarding REST boundaries' {
    It 'matches an independently generated ARM UUIDv5 reference' {
        Get-DemoRoleAssignmentName scope principal role | Should -Be '0f761181-d230-57d6-9a09-8d94e57723e2'
    }
    It 'does not turn a non-HTTP failure into absence or mask it under StrictMode' {
        Mock Invoke-AzRest -ModuleName PrivateOnboarding { throw 'transport-broken' }
        { Get-DemoArmResource /fixture 2024-01-01 -AllowNotFound } | Should -Throw '*transport-broken*'
        Should -Invoke Invoke-AzRest -ModuleName PrivateOnboarding -Times 1 -Exactly
    }
    It 'sanitizes a Graph failure without retrying its credential operation' {
        Mock Invoke-DemoAz -ModuleName PrivateOnboarding { 'synthetic-token' }
        Mock Invoke-RestMethod -ModuleName PrivateOnboarding { throw 'SENSITIVE_SENTINEL' }
        { Invoke-DemoGraph POST /v1.0/applications/44444444-4444-4444-4444-444444444444/addPassword -Body @{ passwordCredential = @{} } } |
            Should -Throw '*failed/unknown (HTTP 0)*'
        Should -Invoke Invoke-RestMethod -ModuleName PrivateOnboarding -Times 1 -Exactly
    }
    It 'rejects unsupported Graph paths before requesting a token' {
        Mock Invoke-DemoAz -ModuleName PrivateOnboarding { throw 'must not request token' }
        { Invoke-DemoGraph POST /v1.0/applications -Body @{} } | Should -Throw '*outside*'
        Should -Invoke Invoke-DemoAz -ModuleName PrivateOnboarding -Times 0
    }
}

Describe 'One-shot private onboarding orchestration' {
    AfterEach {
        Get-Variable -Name 'ArcPrivateTest*' -Scope Global | Remove-Variable -Scope Global
    }
    BeforeEach {
        $global:ArcPrivateTestsub = '11111111-1111-1111-1111-111111111111'
        $global:ArcPrivateTesttenant = '22222222-2222-2222-2222-222222222222'
        $global:ArcPrivateTestscope = "/subscriptions/$global:ArcPrivateTestsub/resourceGroups/rg-fixture-infra"
        $global:ArcPrivateTestplan = @{
            schemaVersion = 1; subscriptionId = $global:ArcPrivateTestsub; tenantId = $global:ArcPrivateTesttenant; namePrefix = 'fixture'; location = 'australiaeast'
            vaultResourceId        = "$global:ArcPrivateTestscope/providers/Microsoft.KeyVault/vaults/kv-fixture"
            vnetResourceId         = "$global:ArcPrivateTestscope/providers/Microsoft.Network/virtualNetworks/vnet-fixture"
            subnetResourceId       = "$global:ArcPrivateTestscope/providers/Microsoft.Network/virtualNetworks/vnet-fixture/subnets/snet-vms"
            subnetAddressPrefix = '10.50.1.0/24'
            applicationId = '33333333-3333-3333-3333-333333333333'; applicationObjectId = '44444444-4444-4444-4444-444444444444'
            servicePrincipalObjectId = '55555555-5555-5555-5555-555555555555'; deployerPrincipalId = '66666666-6666-6666-6666-666666666666'
            parents                = @(
                @{ resourceId = "$global:ArcPrivateTestscope/providers/Microsoft.Compute/virtualMachines/parent-one"; vmId = '77777777-7777-7777-7777-777777777777'; principalId = '88888888-8888-8888-8888-888888888888' }
                @{ resourceId = "$global:ArcPrivateTestscope/providers/Microsoft.Compute/virtualMachines/parent-two"; vmId = '99999999-9999-9999-9999-999999999999'; principalId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
            )
            writerParentResourceId = "$global:ArcPrivateTestscope/providers/Microsoft.Compute/virtualMachines/parent-two"
        }
        $global:ArcPrivateTestsecretId = "$($global:ArcPrivateTestplan.vaultResourceId)/secrets/arc-onboarding-client-secret"
        $global:ArcPrivateTestendpointId = "$global:ArcPrivateTestscope/providers/Microsoft.Network/privateEndpoints/pe-fixture-onboarding-kv"
        $global:ArcPrivateTestzoneId = "$global:ArcPrivateTestscope/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
        $global:ArcPrivateTestnicId = "$global:ArcPrivateTestscope/providers/Microsoft.Network/networkInterfaces/pe-fixture-onboarding-kv-nic"
        $global:ArcPrivateTestoldKey = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $global:ArcPrivateTestnewKey = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $global:ArcPrivateTestinfraCreated = $false; $global:ArcPrivateTestwriterExists = $false; $global:ArcPrivateTestkeyExists = $false
        $global:ArcPrivateTestvaultConnections = @()
        $global:ArcPrivateTestfailMarker = $false; $global:ArcPrivateTestfailStore = $false; $global:ArcPrivateTestunknownAdd = $false; $global:ArcPrivateTestfailCleanup = $false
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $root -ItemType Directory | Out-Null
        $planPath = Join-Path $root 'plan.json'
        $global:ArcPrivateTestplan | ConvertTo-Json -Depth 10 | Set-Content $planPath
        $call = @{ SubscriptionId = $global:ArcPrivateTestsub; TenantId = $global:ArcPrivateTesttenant; PlanPath = $planPath; ResultDirectory = $root; Confirm = $false }
        $entry = Join-Path $repo 'scripts\Initialize-PrivateOnboarding.ps1'
        Mock Import-Module {}
        Mock Test-Prerequisites { $global:ArcPrivateTestplan.deployerPrincipalId }
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'deployment' -and $Arguments[1] -eq 'sub') {
                return '{"properties":{"provisioningState":"Succeeded","timestamp":"2026-01-01","outputs":{"arcResourceGroup":{"value":"rg-fixture"},"keyVaultName":{"value":"kv-fixture"}}}}'
            }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[1] -eq 'group') {
                $global:ArcPrivateTestinfraCreated = $true
                $ids = @($global:ArcPrivateTestplan.parents | ForEach-Object {
                        $name = Get-DemoRoleAssignmentName $global:ArcPrivateTestsecretId $_.principalId '4633458b-17de-408a-b874-0445c86b69e6'
                        "$global:ArcPrivateTestsecretId/providers/Microsoft.Authorization/roleAssignments/$name"
                    })
                return (@{ properties = @{ provisioningState = 'Succeeded'; outputs = @{ readerAssignmentIds = @{ value = $ids } } } } | ConvertTo-Json -Depth 10)
            }
            if ($Arguments[0] -eq 'vm') { return '{"instanceView":{"statuses":[{"code":"PowerState/running"}]}}' }
            if ($Arguments[0] -eq 'network') { return '[]' }
            if ($Arguments[0] -eq 'role') {
                return (@{ scope = "/subscriptions/$($global:ArcPrivateTestplan.subscriptionId)/resourceGroups/rg-fixture"; roleDefinitionName = 'Azure Connected Machine Onboarding' } | ConvertTo-Json)
            }
            throw 'Unexpected mocked CLI operation.'
        }
        Mock Get-DemoArmResource {
            param($ResourceId)
            if ($ResourceId -eq $global:ArcPrivateTestsecretId -and $global:ArcPrivateTestkeyExists) {
                $journal = Get-Content (Join-Path $root 'private-onboarding.json') -Raw | ConvertFrom-Json
                return @{ id = $ResourceId; tags = @{ state = 'initialized'; keyId = $global:ArcPrivateTestnewKey; appId = $global:ArcPrivateTestplan.applicationId }; properties = @{
                    secretUriWithVersion = $journal.secretVersionUri; attributes = @{ enabled = $true; exp = ([datetimeoffset]$journal.expiresAtUtc).ToUnixTimeSeconds() }
                } }
            }
            if ($ResourceId -eq $global:ArcPrivateTestplan.vaultResourceId) {
                return @{ id = $ResourceId; location = 'australiaeast'; properties = @{ publicNetworkAccess = 'Disabled'; enableRbacAuthorization = $true; privateEndpointConnections = $global:ArcPrivateTestvaultConnections } }
            }
            if ($ResourceId -eq $global:ArcPrivateTestplan.vnetResourceId) {
                return @{ id = $ResourceId; location = 'australiaeast'; properties = @{ dhcpOptions = @{ dnsServers = @() } } }
            }
            if ($ResourceId -eq $global:ArcPrivateTestplan.subnetResourceId) {
                return @{ id = $ResourceId; properties = @{ privateEndpointNetworkPolicies = 'Disabled'; delegations = @(); addressPrefix = '10.50.1.0/24'; ipConfigurations = @() } }
            }
            $parent = @($global:ArcPrivateTestplan.parents | Where-Object resourceId -EQ $ResourceId)
            if ($parent.Count) {
                return @{ id = $ResourceId; location = 'australiaeast'; identity = @{ principalId = $parent[0].principalId }; properties = @{
                        vmId = $parent[0].vmId; provisioningState = 'Succeeded'; storageProfile = @{ osDisk = @{ osType = 'Windows' } }
                        osProfile = @{ computerName = ($parent[0].resourceId -split '/')[-1] }
                    }
                }
            }
            if ($ResourceId -eq $global:ArcPrivateTestendpointId -and $global:ArcPrivateTestinfraCreated) {
                return @{ id = $ResourceId; tags = @{ managedBy = 'arc-demo-private-onboarding' }; properties = @{
                        provisioningState = 'Succeeded'; subnet = @{ id = $global:ArcPrivateTestplan.subnetResourceId }; networkInterfaces = @(@{ id = $global:ArcPrivateTestnicId })
                        privateLinkServiceConnections = @(@{ properties = @{ privateLinkServiceId = $global:ArcPrivateTestplan.vaultResourceId; privateLinkServiceConnectionState = @{ status = 'Approved' } } })
                    }
                }
            }
            if ($ResourceId -eq $global:ArcPrivateTestzoneId -and $global:ArcPrivateTestinfraCreated) { return @{ id = $ResourceId; tags = @{ managedBy = 'arc-demo-private-onboarding' } } }
            if ($ResourceId -eq "$global:ArcPrivateTestzoneId/virtualNetworkLinks/link-fixture-onboarding-vnet") {
                return @{ id = $ResourceId; properties = @{ virtualNetwork = @{ id = $global:ArcPrivateTestplan.vnetResourceId }; registrationEnabled = $false } }
            }
            if ($ResourceId -eq "$global:ArcPrivateTestendpointId/privateDnsZoneGroups/default") {
                return @{ id = $ResourceId; properties = @{ privateDnsZoneConfigs = @(@{ properties = @{ privateDnsZoneId = $global:ArcPrivateTestzoneId } }) } }
            }
            if ($ResourceId -eq $global:ArcPrivateTestnicId) {
                return @{ id = $ResourceId; properties = @{ privateEndpoint = @{ id = $global:ArcPrivateTestendpointId }; ipConfigurations = @(
                            @{ properties = @{ subnet = @{ id = $global:ArcPrivateTestplan.subnetResourceId }; privateIPAllocationMethod = 'Dynamic'; privateIPAddress = '10.50.1.10' } }
                        )
                    }
                }
            }
            if ($ResourceId -match '/roleAssignments/') {
                foreach ($parent in $global:ArcPrivateTestplan.parents) {
                    foreach ($role in @('4633458b-17de-408a-b874-0445c86b69e6', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')) {
                        $name = Get-DemoRoleAssignmentName $global:ArcPrivateTestsecretId $parent.principalId $role
                        if ($ResourceId.EndsWith($name) -and (($role -like '463*' -and $global:ArcPrivateTestinfraCreated) -or ($role -like 'b86*' -and $global:ArcPrivateTestwriterExists))) {
                            return @{ id = $ResourceId; properties = @{ scope = $global:ArcPrivateTestsecretId; principalId = $parent.principalId; roleDefinitionId = "/subscriptions/$global:ArcPrivateTestsub/providers/Microsoft.Authorization/roleDefinitions/$role" } }
                        }
                    }
                }
            }
            return $null
        }
        Mock Invoke-AzRest {
            param($Method)
            if ($Method -eq 'PUT') { $global:ArcPrivateTestwriterExists = $true; return }
            if ($Method -eq 'DELETE') {
                if ($global:ArcPrivateTestfailCleanup) { throw 'Synthetic cleanup failed.' }
                $global:ArcPrivateTestwriterExists = $false; return
            }
            throw 'Unexpected mocked REST operation.'
        }
        Mock Invoke-DemoGraph {
            param($Method, $Path, $Body)
            if ($Method -eq 'GET' -and $Path -like '*servicePrincipals*') {
                return @{ id = $global:ArcPrivateTestplan.servicePrincipalObjectId; appId = $global:ArcPrivateTestplan.applicationId; accountEnabled = $true }
            }
            if ($Method -eq 'GET') {
                $keys = @(@{ keyId = $global:ArcPrivateTestoldKey })
                if ($global:ArcPrivateTestkeyExists) { $keys += @{ keyId = $global:ArcPrivateTestnewKey } }
                return @{ id = $global:ArcPrivateTestplan.applicationObjectId; appId = $global:ArcPrivateTestplan.applicationId; passwordCredentials = $keys; keyCredentials = @() }
            }
            if ($Path -like '*/addPassword') {
                $global:ArcPrivateTestkeyExists = $true
                if ($global:ArcPrivateTestunknownAdd) { throw 'Exact Graph POST failed/unknown (HTTP 0); no retry.' }
                return @{ keyId = $global:ArcPrivateTestnewKey; secretText = 'SENSITIVE_SENTINEL'; startDateTime = $Body.passwordCredential.startDateTime; endDateTime = $Body.passwordCredential.endDateTime }
            }
            if ($Path -like '*/removePassword' -and $Body.keyId -eq $global:ArcPrivateTestnewKey) { $global:ArcPrivateTestkeyExists = $false; return }
            throw 'Unexpected mocked Graph operation.'
        }
        Mock Invoke-DemoProtectedVaultCommand {
            param($Operation, $ExpiresAtUtc)
            if ($Operation -eq 'Marker' -and $global:ArcPrivateTestfailMarker) { throw 'Private marker denied.' }
            if ($Operation -eq 'Initialize' -and $global:ArcPrivateTestfailStore) { throw 'Private storage failed.' }
            @{ result = @{ enabled = ($Operation -eq 'Initialize'); expiresAtUtc = $ExpiresAtUtc; secretVersionUri = 'https://kv-fixture.vault.azure.net/secrets/arc-onboarding-client-secret/123456789012345678901234567890ab' } }
        }
    }
    It 'previews by default without a journal or credential/role/infrastructure writes' {
        (& $entry @call).state | Should -Be 'preview'
        Test-Path (Join-Path $root 'private-onboarding.json') | Should -BeFalse
        Should -Invoke Invoke-DemoGraph -Times 0 -ParameterFilter { $Method -eq 'POST' }
        Should -Invoke Invoke-AzRest -Times 0
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'create' -in $Arguments }
    }
    It 'honors Initialize WhatIf without mutation' {
        (& $entry @call -Action Initialize -WhatIf).state | Should -Be 'preview'
        Should -Invoke Invoke-DemoGraph -Times 0 -ParameterFilter { $Method -eq 'POST' }
        Should -Invoke Invoke-AzRest -Times 0
    }
    It 'accepts an actual null private endpoint connection collection without writes' {
        $global:ArcPrivateTestvaultConnections = $null
        (& $entry @call -Action Initialize -WhatIf).state | Should -Be 'preview'
        Test-Path (Join-Path $root 'private-onboarding.json') | Should -BeFalse
        Should -Invoke Invoke-DemoProtectedVaultCommand -Times 0
        Should -Invoke Invoke-AzRest -Times 0
        Should -Invoke Invoke-DemoGraph -Times 0 -ParameterFilter { $Method -eq 'POST' }
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'create' -in $Arguments }
    }
    It 'does not discard a foreign or malformed nonnull private endpoint connection' -ForEach @('foreign', 'malformed') {
        $global:ArcPrivateTestvaultConnections = if ($_ -eq 'foreign') {
            @(@{ properties = @{ privateEndpoint = @{ id = "$global:ArcPrivateTestendpointId-other" } } })
        } else { @(@{ properties = @{ privateEndpoint = @{} } }) }
        { & $entry @call -Action Initialize -WhatIf } | Should -Throw '*another private endpoint*'
        Should -Invoke Invoke-DemoProtectedVaultCommand -Times 0
        Should -Invoke Invoke-AzRest -Times 0
        Test-Path (Join-Path $root 'private-onboarding.json') | Should -BeFalse
    }
    It 'creates exactly one 30-day credential, retains originals and removes the writer before success' {
        $result = & $entry @call -Action Initialize
        $result.state | Should -Be 'initialized'
        $journal = Get-Content (Join-Path $root 'private-onboarding.json') -Raw
        $journal | Should -Not -Match 'SENSITIVE_SENTINEL'
        ($journal | ConvertFrom-Json).temporaryWriterRemoved | Should -BeTrue
        $global:ArcPrivateTestwriterExists | Should -BeFalse
        Should -Invoke Invoke-DemoGraph -Times 1 -Exactly -ParameterFilter {
            $Path -like '*/addPassword' -and ([datetimeoffset]$Body.passwordCredential.endDateTime - [datetimeoffset]$Body.passwordCredential.startDateTime).TotalDays -eq 30
        }
        Should -Invoke Invoke-DemoGraph -Times 0 -ParameterFilter { $Path -like '*/removePassword' }
    }
    It 'uses only the designated writer lane while reading and granting both pinned parent identities' {
        (& $entry @call -Action Initialize).state | Should -Be 'initialized'
        Should -Invoke Get-DemoArmResource -Times 1 -Exactly -ParameterFilter {
            $ResourceId -eq $global:ArcPrivateTestplan.parents[0].resourceId
        }
        Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'get-instance-view' -and
            $global:ArcPrivateTestplan.writerParentResourceId -in $Arguments
        }
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter {
            $Arguments[0] -eq 'vm' -and
            ($Arguments[1] -ne 'get-instance-view' -or $global:ArcPrivateTestplan.parents[0].resourceId -in $Arguments)
        }
        Should -Invoke Invoke-DemoProtectedVaultCommand -Times 2 -Exactly -ParameterFilter {
            $Parent.resourceId -eq $global:ArcPrivateTestplan.writerParentResourceId -and
            $Parent.vmId -eq $global:ArcPrivateTestplan.parents[1].vmId
        }
        Should -Invoke Invoke-DemoProtectedVaultCommand -Times 0 -ParameterFilter {
            $Parent.resourceId -ne $global:ArcPrivateTestplan.writerParentResourceId
        }
        Should -Invoke Invoke-AzRest -Times 0 -ParameterFilter {
            $Url -like "*$($global:ArcPrivateTestplan.parents[0].resourceId)*"
        }
        $journal = Get-Content (Join-Path $root 'private-onboarding.json') -Raw | ConvertFrom-Json
        @($journal.readerAssignmentIds).Count | Should -Be 2
        @($journal.protectedCommands).Count | Should -Be 2
        foreach ($id in $journal.protectedCommands) {
            $id | Should -BeLike "$($global:ArcPrivateTestplan.writerParentResourceId)/runCommands/*"
        }
    }
    It 'keeps the stable nonwriter ARM guard without requiring a guest command completion proof' {
        $result = & $entry @call -Action Initialize -WhatIf
        $result.state | Should -Be 'preview'
        $result.guestEnrollment | Should -BeFalse
        $result.parentPowerChanges | Should -BeFalse
        @($result.readerPrincipalIds).Count | Should -Be 2
        Should -Invoke Invoke-DemoProtectedVaultCommand -Times 0
        Should -Invoke Invoke-AzRest -Times 0
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter {
            $Arguments[0] -eq 'vm' -and $global:ArcPrivateTestplan.parents[0].resourceId -in $Arguments
        }
        Test-Path (Join-Path $root 'private-onboarding.json') | Should -BeFalse
    }
    It 'does not waive the nonwriter stable-identity guard when its provisioning state is Updating' {
        Mock Get-DemoArmResource -ParameterFilter { $ResourceId -eq $global:ArcPrivateTestplan.parents[0].resourceId } {
            $parent = $global:ArcPrivateTestplan.parents[0]
            @{
                id = $parent.resourceId; location = 'australiaeast'; identity = @{ principalId = $parent.principalId }
                properties = @{
                    vmId = $parent.vmId; provisioningState = 'Updating'; storageProfile = @{ osDisk = @{ osType = 'Windows' } }
                    osProfile = @{ computerName = 'parent-one' }
                }
            }
        }
        { & $entry @call -Action Initialize } | Should -Throw '*Pinned parent*'
        Should -Invoke Invoke-DemoProtectedVaultCommand -Times 0
        Should -Invoke Invoke-AzRest -Times 0
        Should -Invoke Invoke-DemoGraph -Times 0 -ParameterFilter { $Method -eq 'POST' }
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'create' -in $Arguments }
        Test-Path (Join-Path $root 'private-onboarding.json') | Should -BeFalse
    }
    It 'does not start a stopped writer or use the other parent as a fallback' {
        Mock Invoke-DemoAz -ParameterFilter { $Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'get-instance-view' } {
            '{"instanceView":{"statuses":[{"code":"PowerState/deallocated"}]}}'
        }
        { & $entry @call -Action Initialize } | Should -Throw '*writer parent is not running*'
        Should -Invoke Invoke-DemoProtectedVaultCommand -Times 0
        Should -Invoke Invoke-AzRest -Times 0
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'start' -in $Arguments -or 'create' -in $Arguments }
    }
    It 'stops before creating a credential after denied private marker proof' {
        $global:ArcPrivateTestfailMarker = $true
        { & $entry @call -Action Initialize } | Should -Throw '*marker denied*'
        $global:ArcPrivateTestwriterExists | Should -BeFalse
        Should -Invoke Invoke-DemoGraph -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }
    It 'rolls back only its returned new key when storage fails' {
        $global:ArcPrivateTestfailStore = $true
        { & $entry @call -Action Initialize } | Should -Throw '*storage failed*'
        $global:ArcPrivateTestkeyExists | Should -BeFalse
        $global:ArcPrivateTestwriterExists | Should -BeFalse
        (Get-Content (Join-Path $root 'private-onboarding.json') -Raw | ConvertFrom-Json).rollback | Should -Be 'only-new-key-removed'
        Should -Invoke Invoke-DemoGraph -Times 1 -Exactly -ParameterFilter { $Path -like '*/removePassword' -and $Body.keyId -eq $global:ArcPrivateTestnewKey }
    }
    It 'does not retry or guess a rollback key after unknown credential creation' {
        $global:ArcPrivateTestunknownAdd = $true
        { & $entry @call -Action Initialize } | Should -Throw '*failed/unknown*'
        $global:ArcPrivateTestwriterExists | Should -BeFalse
        Should -Invoke Invoke-DemoGraph -Times 1 -Exactly -ParameterFilter { $Path -like '*/addPassword' }
        Should -Invoke Invoke-DemoGraph -Times 0 -ParameterFilter { $Path -like '*/removePassword' }
        { & $entry @call -Action Initialize } | Should -Throw '*Incomplete/different*'
        Should -Invoke Invoke-DemoGraph -Times 1 -Exactly -ParameterFilter { $Path -like '*/addPassword' }
    }
    It 'does not claim initialization if writer cleanup fails after storage' {
        $global:ArcPrivateTestfailCleanup = $true
        { & $entry @call -Action Initialize } | Should -Throw '*Temporary writer cleanup*'
        (Get-Content (Join-Path $root 'private-onboarding.json') -Raw | ConvertFrom-Json).state | Should -Be 'writer-cleanup-failed'
        Should -Invoke Invoke-DemoGraph -Times 0 -ParameterFilter { $Path -like '*/removePassword' }
    }
    It 'reuses initialized reference without a new key, secret version or writer' {
        $first = & $entry @call -Action Initialize
        $second = & $entry @call -Action Initialize
        $second.changed | Should -BeFalse
        $second.secretVersionUri | Should -Be $first.secretVersionUri
        Should -Invoke Invoke-DemoGraph -Times 1 -Exactly -ParameterFilter { $Path -like '*/addPassword' }
        Should -Invoke Invoke-DemoProtectedVaultCommand -Times 1 -Exactly -ParameterFilter { $Operation -eq 'Initialize' }
    }
    It 'rejects expired retained material instead of rotating it' {
        & $entry @call -Action Initialize | Out-Null
        $journalPath = Join-Path $root 'private-onboarding.json'
        $journal = Get-Content $journalPath -Raw | ConvertFrom-Json
        $journal.expiresAtUtc = [datetimeoffset]::UtcNow.AddHours(-1).ToString('o')
        $journal | ConvertTo-Json -Depth 15 | Set-Content $journalPath
        { & $entry @call -Action Initialize } | Should -Throw '*invalid validity*'
        Should -Invoke Invoke-DemoGraph -Times 1 -Exactly -ParameterFilter { $Path -like '*/addPassword' }
    }
}
Describe 'Protected private writer transport' {
    BeforeEach {
        $script:commandBody = $null
        $script:commandId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.Compute/virtualMachines/parent-two/runCommands/arc-onboarding-test'
        $script:receiptData = @{
            status = 'pass'; operation = 'Initialize'; secretVersionUri = 'https://kv-fixture.vault.azure.net/secrets/arc-onboarding-client-secret/123456789012345678901234567890ab'
            privateAddresses = @('10.50.1.10'); tlsVerified = $true; valueVerified = $true; enabled = $true
            expiresAtUtc = [datetimeoffset]::UtcNow.AddDays(30).ToString('o'); checkedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        }
        $call = @{
            Parent = @{ resourceId = ($script:commandId -split '/runCommands/')[0]; vmId = '99999999-9999-9999-9999-999999999999'; location = 'australiaeast'; computerName = 'parent-two' }
            VaultName = 'kv-fixture'; PrivateAddresses = @('10.50.1.10'); Operation = 'Initialize'; CommandName = 'arc-onboarding-test'
            EvidencePath = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).json"; SecretValue = 'SENSITIVE_SENTINEL'; ExpiresAtUtc = $script:receiptData.expiresAtUtc
        }
        Mock Get-DemoArmResource -ModuleName PrivateOnboarding { $null }
        Mock Start-Sleep -ModuleName PrivateOnboarding {}
        Mock Invoke-AzRest -ModuleName PrivateOnboarding {
            param($Method, $Body)
            if ($Method -eq 'PUT') { $script:commandBody = $Body; return }
            if ($Method -eq 'DELETE') { return }
            [pscustomobject]@{
                id = $script:commandId; tags = @{ managedBy = 'arc-demo-private-onboarding' }
                properties = [pscustomobject]@{
                    source       = $script:commandBody.properties.source
                    instanceView = @{ executionState = 'Succeeded'; exitCode = 0; output = 'ARC_PRIVATE_VAULT_RESULT:' + ($script:receiptData | ConvertTo-Json -Depth 5 -Compress) }
                }
            }
        }
    }
    It 'uses protected in-memory input and persists only proof before terminal deletion' {
        $actual = Invoke-DemoProtectedVaultCommand @call
        $actual.deleted | Should -BeTrue
        $actual.status | Should -Be 'pass'
        $script:commandBody.properties.protectedParameters[0].value | Should -BeExactly 'SENSITIVE_SENTINEL'
        ($script:commandBody.properties.parameters | ConvertTo-Json) | Should -Not -Match 'SENSITIVE_SENTINEL'
        (Get-Content $call.EvidencePath -Raw) | Should -Not -Match 'SENSITIVE_SENTINEL'
        Should -Invoke Invoke-AzRest -ModuleName PrivateOnboarding -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        Should -Invoke Invoke-AzRest -ModuleName PrivateOnboarding -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }
    It 'rejects <case> and still removes the terminal owned command' -ForEach @(
        @{ case = 'unexpected address'; change = { $script:receiptData.privateAddresses = @('1.2.3.4') } }
        @{ case = 'wrong enabled state'; change = { $script:receiptData.enabled = $false } }
        @{ case = 'stale proof'; change = { $script:receiptData.checkedAtUtc = [datetimeoffset]::UtcNow.AddHours(-1).ToString('o') } }
        @{ case = 'secret-shaped extra output'; change = { $script:receiptData.secretValue = 'SENSITIVE_SENTINEL' } }
        @{ case = 'incorrect expiry'; change = { $script:receiptData.expiresAtUtc = [datetimeoffset]::UtcNow.AddDays(60).ToString('o') } }
    ) {
        & $change
        { Invoke-DemoProtectedVaultCommand @call } | Should -Throw '*completion-proof*'
        Should -Invoke Invoke-AzRest -ModuleName PrivateOnboarding -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        (Get-Content $call.EvidencePath -Raw) | Should -Not -Match 'SENSITIVE_SENTINEL'
        (Get-Content $call.EvidencePath -Raw | ConvertFrom-Json).status | Should -Be 'fail'
    }
    It 'does not replay, delete or cancel when submission delivery is unknown' {
        Mock Invoke-AzRest -ModuleName PrivateOnboarding { throw 'SENSITIVE_SENTINEL' }
        { Invoke-DemoProtectedVaultCommand @call } | Should -Throw '*submission (HTTP 0)*'
        Should -Invoke Invoke-AzRest -ModuleName PrivateOnboarding -Times 1 -Exactly
        (Get-Content $call.EvidencePath -Raw) | Should -Not -Match 'SENSITIVE_SENTINEL'
        (Get-Content $call.EvidencePath -Raw | ConvertFrom-Json).status | Should -Be 'unknown'
    }
    It 'preserves both execution and cleanup failures' {
        $script:receiptData.enabled = $false
        Mock Invoke-AzRest -ModuleName PrivateOnboarding { throw 'SENSITIVE_SENTINEL' } -ParameterFilter { $Method -eq 'DELETE' }
        { Invoke-DemoProtectedVaultCommand @call } | Should -Throw '*completion-proof*cleanup/evidence not verified*'
    }
    It 'saves the projected terminal diagnostic before deleting the command without copying raw error text' {
        Mock Invoke-AzRest -ModuleName PrivateOnboarding -ParameterFilter { $Method -eq 'GET' } {
            [pscustomobject]@{
                id = $script:commandId; tags = @{ managedBy = 'arc-demo-private-onboarding' }
                properties = [pscustomobject]@{
                    source = $script:commandBody.properties.source
                    instanceView = @{
                        executionState = 'Failed'; exitCode = 1
                        output = 'ARC_PRIVATE_VAULT_FAILURE:' + (@{
                            status = 'fail'; operation = 'Initialize'; stage = 'private-secret-write'; httpStatus = 403
                            checkedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
                        } | ConvertTo-Json -Compress)
                        error = 'SENSITIVE_SENTINEL'
                    }
                }
            }
        }
        Mock Invoke-AzRest -ModuleName PrivateOnboarding -ParameterFilter { $Method -eq 'DELETE' } {
            $beforeDelete = Get-Content $call.EvidencePath -Raw | ConvertFrom-Json
            $beforeDelete.failure.stage | Should -Be 'private-secret-write'
            $beforeDelete.failure.category | Should -Be 'authorization-denied'
            $beforeDelete.deleted | Should -BeFalse
        }
        { Invoke-DemoProtectedVaultCommand @call } | Should -Throw '*private-secret-write*authorization-denied*HTTP 403*'
        $saved = Get-Content $call.EvidencePath -Raw
        $saved | Should -Not -Match 'SENSITIVE_SENTINEL|propagation'
        ($saved | ConvertFrom-Json).deleted | Should -BeTrue
        Should -Invoke Invoke-AzRest -ModuleName PrivateOnboarding -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }
    It 'does not delete a terminal command when its first evidence save fails' {
        Mock Set-Content -ModuleName PrivateOnboarding { throw 'SENSITIVE_SENTINEL' }
        { Invoke-DemoProtectedVaultCommand @call } | Should -Throw '*retained because its diagnostic receipt was not saved*'
        Should -Invoke Invoke-AzRest -ModuleName PrivateOnboarding -Times 0 -ParameterFilter { $Method -eq 'DELETE' }
    }
    It 'does not overwrite an existing receipt or submit another command' {
        'preserved' | Set-Content $call.EvidencePath
        { Invoke-DemoProtectedVaultCommand @call } | Should -Throw '*receipt already exists*'
        Get-Content $call.EvidencePath -Raw | Should -BeLike 'preserved*'
        Should -Invoke Invoke-AzRest -ModuleName PrivateOnboarding -Times 0
    }
    It 'inspects the private path in <mode> with no credential parameters or secret operations' -ForEach @(
        @{ mode = 'RuntimeDefault'; selection = 'runtime-default' }
        @{ mode = 'Tls12'; selection = 'tls12' }
    ) {
        $call.Operation = 'InspectPath'; $call.SecretValue = ''; $call.ExpiresAtUtc = ''
        $call.TlsMode = $mode
        $script:receiptData = @{
            status = 'pass'; operation = 'InspectPath'; parentVmId = $call.Parent.vmId; tlsProtocolSelection = $selection
            privateAddresses = @('10.50.1.10'); tlsVerified = $true; checkedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        }
        Mock Invoke-AzRest -ModuleName PrivateOnboarding -ParameterFilter { $Method -eq 'GET' } {
            [pscustomobject]@{
                id = $script:commandId; tags = @{ managedBy = 'arc-demo-private-onboarding' }
                properties = [pscustomobject]@{
                    source = $script:commandBody.properties.source
                    instanceView = @{ executionState = 'Succeeded'; exitCode = 0; output = 'ARC_PRIVATE_PATH_RESULT:' + ($script:receiptData | ConvertTo-Json -Compress) }
                }
            }
        }
        $result = Invoke-DemoProtectedVaultCommand @call
        $result.status | Should -Be pass
        $result.tlsMode | Should -Be $mode
        ($script:commandBody.properties.parameters | Where-Object name -EQ TlsMode).value | Should -Be $mode
        $script:commandBody.properties.ContainsKey('protectedParameters') | Should -BeFalse
        $script:commandBody.properties.parameters.name | Should -Not -Contain SecretValue
        $script:commandBody.properties.parameters.name | Should -Not -Contain SecretName
        $script:commandBody.properties.parameters.name | Should -Not -Contain PrivateAddressesJson
        $encoded = ($script:commandBody.properties.parameters | Where-Object name -EQ PrivateAddressesBase64).value
        $encoded | Should -Match '^[A-Za-z0-9+/]+={0,2}$'
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | Should -Be '["10.50.1.10"]'
        $script:commandBody.properties.source.script | Should -Not -Match '/secrets/|oauth2|PSDirect|Invoke-Command|addPassword'
        $script:commandBody.properties.timeoutInSeconds | Should -Be 90
        $result.sourceHash | Should -Be (Get-FileHash (Join-Path $repo 'scripts\guest\Test-PrivateVaultPath.ps1')).Hash
    }
    It 'rejects credential input before submitting a network-only inspection' {
        $call.Operation = 'InspectPath'
        { Invoke-DemoProtectedVaultCommand @call } | Should -Throw '*cannot accept credential input*'
        Should -Invoke Invoke-AzRest -ModuleName PrivateOnboarding -Times 0
    }
    It 'binds explicit TLS1.2 to the protected writer without changing its credential route' {
        $call.TlsMode = 'Tls12'
        $result = Invoke-DemoProtectedVaultCommand @call
        $result.status | Should -Be pass
        $result.tlsMode | Should -Be Tls12
        ($script:commandBody.properties.parameters | Where-Object name -EQ TlsMode).value | Should -Be Tls12
        $script:commandBody.properties.protectedParameters[0].name | Should -Be SecretValue
    }
    It 'rejects network inspection <case> without storing raw output' -ForEach @(
        @{ case = 'array identity'; change = { $script:receiptData.parentVmId = @($call.Parent.vmId) } }
        @{ case = 'duplicate addresses'; change = { $script:receiptData.privateAddresses = @('10.50.1.10', '10.50.1.10') } }
        @{ case = 'secret-shaped extra field'; change = { $script:receiptData.secretValue = 'SENSITIVE_SENTINEL' } }
        @{ case = 'stale proof'; change = { $script:receiptData.checkedAtUtc = [datetimeoffset]::UtcNow.AddHours(-1).ToString('o') } }
        @{ case = 'different TLS selection'; change = { $script:receiptData.tlsProtocolSelection = 'tls12' } }
    ) {
        $call.Operation = 'InspectPath'; $call.SecretValue = ''; $call.ExpiresAtUtc = ''
        $script:receiptData = @{
            status = 'pass'; operation = 'InspectPath'; parentVmId = $call.Parent.vmId; tlsProtocolSelection = 'runtime-default'
            privateAddresses = @('10.50.1.10'); tlsVerified = $true; checkedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        }
        & $change
        Mock Invoke-AzRest -ModuleName PrivateOnboarding -ParameterFilter { $Method -eq 'GET' } {
            [pscustomobject]@{
                id = $script:commandId; tags = @{ managedBy = 'arc-demo-private-onboarding' }
                properties = [pscustomobject]@{
                    source = $script:commandBody.properties.source
                    instanceView = @{ executionState = 'Succeeded'; exitCode = 0; output = 'ARC_PRIVATE_PATH_RESULT:' + ($script:receiptData | ConvertTo-Json -Compress) }
                }
            }
        }
        { Invoke-DemoProtectedVaultCommand @call } | Should -Throw '*completion-proof*'
        (Get-Content $call.EvidencePath -Raw) | Should -Not -Match SENSITIVE_SENTINEL
        Should -Invoke Invoke-AzRest -ModuleName PrivateOnboarding -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }
}
