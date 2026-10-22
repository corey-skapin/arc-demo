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

Describe 'Explicit retained OS disk tiers' {
    InModuleScope Common {
        BeforeEach {
            $script:diskVm = [pscustomobject]@{
                name = 'retained-vm'
                storageProfile = @{ osDisk = @{ managedDisk = @{ id = '/fixture/disk' } } }
            }
        }
        It 'accepts an existing matching <Tier> disk without a write' -TestCases @(
            @{ Tier = 'Standard_LRS' }
            @{ Tier = 'StandardSSD_LRS' }
        ) {
            param($Tier)
            Mock Invoke-DemoAz { $Tier }
            Assert-DemoOsDiskStorageAccountType -Machines @($script:diskVm) -StorageAccountType $Tier
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter {
                $Arguments[0] -eq 'disk' -and $Arguments[1] -eq 'show' -and '/fixture/disk' -in $Arguments
            }
        }
        It 'blocks an incidental HDD to SSD conversion' {
            Mock Invoke-DemoAz { 'Standard_LRS' }
            { Assert-DemoOsDiskStorageAccountType -Machines @($script:diskVm) -StorageAccountType StandardSSD_LRS } | Should -Throw '*separately approved*'
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'update' -in $Arguments -or 'deallocate' -in $Arguments }
        }
        It 'blocks an incidental SSD to HDD conversion' {
            Mock Invoke-DemoAz { 'StandardSSD_LRS' }
            { Assert-DemoOsDiskStorageAccountType -Machines @($script:diskVm) -StorageAccountType Standard_LRS } | Should -Throw '*tier mismatch*'
        }
        It 'does not inspect a disk when no existing VM is targeted' {
            Mock Invoke-DemoAz { throw 'unexpected disk read' }
            Assert-DemoOsDiskStorageAccountType -Machines @() -StorageAccountType StandardSSD_LRS
            Should -Invoke Invoke-DemoAz -Times 0
        }
        It 'fails on missing disk identity instead of guessing a tier' {
            $script:diskVm.storageProfile.osDisk.managedDisk.id = ''
            { Assert-DemoOsDiskStorageAccountType -Machines @($script:diskVm) -StorageAccountType Standard_LRS } | Should -Throw '*Cannot verify*'
        }
        It 'propagates read failures' {
            Mock Invoke-DemoAz { throw 'disk access denied' }
            { Assert-DemoOsDiskStorageAccountType -Machines @($script:diskVm) -StorageAccountType Standard_LRS } | Should -Throw '*disk access denied*'
        }
        It 'fails on an unreadable tier' {
            Mock Invoke-DemoAz { '' }
            { Assert-DemoOsDiskStorageAccountType -Machines @($script:diskVm) -StorageAccountType Standard_LRS } | Should -Throw '*unreadable*'
        }
    }
}

Describe 'Portable workbook workspace defaults' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\Deploy-ArcDemo.ps1'), [ref]$tokens, [ref]$errors)
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-WorkbookWorkspaceDefaults'
        }, $true)
        if (-not $function -or $errors) { throw 'Workbook binding function could not be loaded for isolated tests.' }
        . ([scriptblock]::Create($function.Extent.Text))
        $serialized = Get-Content (Join-Path $repo 'workbooks\nseilaz\Asset_Inventory_Workbook_Example.json') -Raw
    }
    It 'ships no upstream operator workspace selection' {
        $workbook = $serialized | ConvertFrom-Json -Depth 100
        $selector = @($workbook.items.content.parameters | Where-Object label -like '*Log Analytics Workspace*')
        $selector.Count | Should -Be 1
        [string]::IsNullOrEmpty($selector[0].defaultValue) | Should -BeTrue
        [string]::IsNullOrEmpty($selector[0].value) | Should -BeTrue
    }
    It 'binds the cleared selector to the supplied deployment workspace' {
        $workspace = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.OperationalInsights/workspaces/law-fixture'
        $bound = Set-WorkbookWorkspaceDefaults -SerializedData $serialized -DefaultWorkspaceId $workspace | ConvertFrom-Json -Depth 100
        $selector = @($bound.items.content.parameters | Where-Object label -like '*Log Analytics Workspace*')
        $selector[0].defaultValue | Should -Be $workspace
        $selector[0].value | Should -Be $workspace
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
        It 'accepts the observed stdout/stderr result without exposing guest output' {
            Mock Receive-DemoJobs {
                '{"value":[{"code":"ComponentStatus/StdOut/succeeded","level":"Info","message":"ARC_DIAGNOSTIC_SERVICES=[{\"Name\":\"himds\",\"State\":\"Running\",\"StartMode\":\"Auto\"}]\nARC_DEMO_OK"},{"code":"ComponentStatus/StdErr/succeeded","level":"Info","message":""}]}'
            }
            $result = Invoke-DemoGuestCommand -Machine $script:machine -Script 'valid' -PassThru
            $result.status | Should -Be 'pass'
            $result.statusCodes | Should -Contain 'ComponentStatus/StdOut/succeeded'
            $result.stderrPresent | Should -BeFalse
            $result | ConvertTo-Json | Should -Not -Match 'ARC_DIAGNOSTIC_SERVICES'
        }
        It 'rejects <Reason>' -TestCases @(
            @{ Reason = 'a marker only in stderr'; Json = '{"value":[{"code":"ComponentStatus/StdOut/succeeded","message":""},{"code":"ComponentStatus/StdErr/succeeded","message":"ARC_DEMO_OK"}]}' }
            @{ Reason = 'failed stderr despite a stdout marker'; Json = '{"value":[{"code":"ComponentStatus/StdOut/succeeded","message":"ARC_DEMO_OK"},{"code":"ComponentStatus/StdErr/failed","message":"private-fixture-output"}]}' }
            @{ Reason = 'an Error-level entry despite successful status codes'; Json = '{"value":[{"code":"ComponentStatus/StdOut/succeeded","message":"ARC_DEMO_OK"},{"code":"ComponentStatus/StdErr/succeeded","level":"Error","message":"private-fixture-output"}]}' }
            @{ Reason = 'an unknown result code with a marker'; Json = '{"value":[{"code":"Unknown","message":"ARC_DEMO_OK"}]}' }
            @{ Reason = 'an empty result'; Json = '{"value":[]}' }
        ) {
            param($Reason, $Json)
            $global:ArcGuestTransportFixture.responseJson = $Json
            Mock Receive-DemoJobs { $global:ArcGuestTransportFixture.responseJson }
            $errorRecord = { Invoke-DemoGuestCommand -Machine $script:machine -Script 'partial' } | Should -Throw -PassThru
            $errorRecord.Exception.Message | Should -Not -Match 'private-fixture-output'
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
        Mock Get-DemoNetworkState {}
        Mock Get-DemoInventory {
            [pscustomobject]@{ Machines = @(); ArcRg = 'rg-retail-demo'; InfraRg = 'rg-retail-demo-infra'; ContainerAppIds = @(); AksClusterIds = @(); Resources = @() }
        }
        Mock Invoke-DemoAz { throw 'WhatIf must not execute mutation commands' }
    }
    It 'activation performs no mutations' {
        & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -WhatIf
        Should -Invoke Invoke-DemoAz -Times 0
    }
    It 'rejects the bundled <SkinFile> placeholder mailbox before any deployment work' -TestCases @(
        @{ SkinFile = 'demo-skin.json' }
        @{ SkinFile = 'dummy-customer.demo-skin.json' }
    ) {
        param($SkinFile)
        { & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -SkinPath (Join-Path $repo "config\$SkinFile") -WhatIf } | Should -Throw '*placeholder*'
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
    It 'forwards explicit HDD input over the SSD skin default in a preview' {
        Mock Test-Prerequisites { '33333333-3333-3333-3333-333333333333' }
        Mock Test-DemoComputeCapacity {}
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'vm') { return '[]' }
            if ($Arguments[0] -eq 'bicep') { return '{"parameters":{"onPremFleet":{"defaultValue":[]}}}' }
            if ($Arguments[0] -eq 'deployment') {
                $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1].TrimStart('@')
                $global:ArcDiskPreview = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            }
        }
        try {
            & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -AdminEmail 'test@example.com' -OsDiskStorageAccountType Standard_LRS -WhatIf
            $global:ArcDiskPreview.parameters.osDiskStorageAccountType.value | Should -Be 'Standard_LRS'
        } finally {
            Remove-Variable ArcDiskPreview -Scope Global -ErrorAction SilentlyContinue
        }
    }
    It 'rejects an invalid private skin disk tier before cloud inspection' {
        $path = Join-Path $TestDrive 'invalid-disk-tier.json'
        Set-Content $path '{"schemaVersion":1,"compute":{"osDiskStorageAccountType":"PremiumV2_LRS"}}'
        { & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -SkinPath $path -AdminEmail 'test@example.com' -WhatIf } | Should -Throw '*OsDiskStorageAccountType*'
        Should -Invoke Invoke-DemoAz -Times 0
    }
    It 'refuses a retained native disk mismatch even if workload tags are missing' {
        Mock Test-Prerequisites { '33333333-3333-3333-3333-333333333333' }
        Mock Test-DemoComputeCapacity {}
        Mock Invoke-DemoAz -ModuleName Common { 'Standard_LRS' }
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'vm') {
                return '[{"name":"az-arcdemo-01","storageProfile":{"osDisk":{"managedDisk":{"id":"/fixture/disk"}}}}]'
            }
            if ($Arguments[0] -eq 'disk') { return 'Standard_LRS' }
            if ($Arguments[0] -eq 'bicep') { return '{"parameters":{"onPremFleet":{"defaultValue":[]}}}' }
            if ($Arguments[0] -eq 'deployment') { throw 'must not reach template preview' }
        }
        { & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -AdminEmail 'test@example.com' -DeployAzureVMs $true -WhatIf } | Should -Throw '*tier mismatch*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' }
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

Describe 'Activation with the real optional-network preflight' {
    BeforeEach {
        Mock Import-Module {}
        Mock Initialize-DemoContext {}
        Mock Assert-DemoSkinInventory {}
        Mock Get-DemoInventory {
            [pscustomobject]@{ Machines = @(); ArcRg = 'rg-retail-demo'; InfraRg = 'rg-retail-demo-infra'; ContainerAppIds = @(); AksClusterIds = @(); Resources = @() }
        }
        & (Get-Module Common) { $script:DemoSubscription = '11111111-1111-1111-1111-111111111111' }
        Mock Invoke-DemoAz { throw 'Unexpected activation command' }
        Mock Invoke-DemoAz -ModuleName Common {
            param($Arguments)
            if ('subnet' -in $Arguments -and 'show' -in $Arguments) {
                return '{"id":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-retail-demo-infra/providers/Microsoft.Network/virtualNetworks/vnet-retail-demo/subnets/snet-vms"}'
            }
            if ('show' -in $Arguments -and ('gateway' -in $Arguments -or 'public-ip' -in $Arguments)) { return $null }
            throw 'Unexpected network preflight operation'
        }
    }
    It 'previews a parked network without parsing null or reaching a mutation' {
        $path = Join-Path $TestDrive 'preview-result.json'
        & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -WhatIf -ResultPath $path
        Should -Invoke Invoke-DemoAz -ModuleName Common -Times 3 -Exactly
        Should -Invoke Invoke-DemoAz -Times 0
        Test-Path $path | Should -BeFalse
    }
    It 'normal activation reaches the mocked first write after accepting absent NAT and PIP' {
        Mock Invoke-DemoAz { throw 'TEST_WRITE_BOUNDARY' } -ParameterFilter { $Arguments[0] -eq 'network' -and $Arguments[1] -eq 'public-ip' -and $Arguments[2] -eq 'create' }
        $path = Join-Path $TestDrive 'normal-result.json'
        { & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment -ResultPath $path } | Should -Throw '*TEST_WRITE_BOUNDARY*'
        Should -Invoke Invoke-DemoAz -ModuleName Common -Times 3 -Exactly
        Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[2] -eq 'create' }
        $result = Get-Content $path -Raw | ConvertFrom-Json
        $result.status | Should -Be 'fail'
        $result.error | Should -Be 'TEST_WRITE_BOUNDARY'
    }
    It 'a genuine read denial stops <Mode> before any mutation' -TestCases @(
        @{ Mode = 'WhatIf'; Preview = $true }
        @{ Mode = 'normal activation'; Preview = $false }
    ) {
        param($Preview)
        Mock Invoke-DemoAz -ModuleName Common { throw 'AuthorizationFailed' } -ParameterFilter { 'gateway' -in $Arguments }
        { & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -WhatIf:$Preview } | Should -Throw '*AuthorizationFailed*'
        Should -Invoke Invoke-DemoAz -Times 0
    }
}

    Describe 'Idempotent lifecycle state transitions' {
        BeforeAll {
            # These guest-only Windows cmdlets also need mockable names in Linux CI.
            function Get-Service {
                param([string[]]$Name)
                throw "Unmocked guest service check: $Name"
            }
            function Restart-Service {
                param([string[]]$Name, [switch]$Force)
                throw "Unmocked guest service restart: $Name"
            }
        }
        BeforeEach {
            Mock Import-Module {}
            Mock Initialize-DemoContext {}
            Mock Assert-DemoSkinInventory {}
            Mock Invoke-DemoGuestCommand {
                param($Machine, $Script)
                $global:ArcLifecycleFixture.guestScript = $Script
                if ($global:ArcLifecycleFixture.executeGuestScript) { & ([scriptblock]::Create($Script)) | Out-Null }
                [pscustomobject]@{ machineName = $Machine.Name; status = 'pass'; completionMarker = 'ARC_DEMO_OK' }
            }
            Mock Restart-Service { throw 'Already-correct guests must not be restarted' }
            Mock Get-Service { [pscustomobject]@{ Name = 'himds'; Status = 'Running' } } -ParameterFilter { $Name -eq 'himds' }
            Mock Get-Service { throw 'AzureMonitorAgent is not a Windows Arc AMA service' } -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
            Mock Get-Process { [pscustomobject]@{ ProcessName = 'MonAgentCore' } }
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
                    ContainerAppIds = @($f.appIds | Where-Object { $_ }); AksClusterIds = @("$($f.root)/Microsoft.ContainerService/managedClusters/retail-demo-aks"); Resources = $f.resources }
            }
            Mock Get-DemoReadinessChecks { New-DemoCheck 'fixture' '/id' 'parked' 'parked' 'pass' }
            Mock Get-DemoNetworkState {
                $f = $global:ArcLifecycleFixture
                if ($f.networkError) { throw $f.networkError }
                $natId = "$($f.root)/Microsoft.Network/natGateways/natgw-retail-demo"
                $pipId = "$($f.root)/Microsoft.Network/publicIPAddresses/pip-natgw-retail-demo"
                [pscustomobject]@{
                    NatId = $natId; PublicIpId = $pipId
                    Subnet = @{ id = "$($f.root)/Microsoft.Network/virtualNetworks/vnet-retail-demo/subnets/snet-vms"; natGateway = @{ id = $f.nat } }
                    Nat = if ($natId -in $f.resources.id) { @{ id = $natId; publicIpAddresses = @(@{ id = $pipId }) } }
                    PublicIp = $f.resources | Where-Object id -eq $pipId
                }
            }
            Mock Invoke-DemoAz {
                param($Arguments)
                $f = $global:ArcLifecycleFixture
                $command = $Arguments[0..1] -join ' '
                switch ($command) {
                    'network vnet' { return (@{ id = "$($f.root)/Microsoft.Network/virtualNetworks/vnet-retail-demo/subnets/snet-vms"; natGateway = @{ id = $f.nat } } | ConvertTo-Json -Depth 5) }
                    'vm list' { return (ConvertTo-Json -InputObject @($f.machine.Actual) -Depth 5) }
                    'connectedmachine list' {
                        if ($f.machine.Native) { return '[]' }
                        return (ConvertTo-Json -InputObject @(@{ id = $f.machine.ArcId; status = 'Connected' }))
                    }
                    'connectedmachine assess-patches' { return }
                    'aks show' { return (@{ name = 'retail-demo-aks'; powerState = @{ code = $f.clusterState }; provisioningState = 'Succeeded' } | ConvertTo-Json -Depth 5) }
                    'resource list' { return (ConvertTo-Json -InputObject $f.resources -Depth 5) }
                    default { throw "Unexpected mutation or inspection: $command" }
                }
                AfterEach { Remove-Variable -Name ArcLifecycleFixture -Scope Global -ErrorAction SilentlyContinue }
            }
        }
        It 'does not restart or update an already-running native Windows VM and AKS' {
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment
            Should -Invoke Invoke-DemoGuestCommand -Times 1 -ParameterFilter { $Script -match 'MonAgentCore' -and $Script -notmatch 'Restart-Service|AzureMonitorAgent' }
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'start' -in $Arguments -or 'create' -in $Arguments -or 'update' -in $Arguments }
            Should -Invoke Invoke-DemoAz -Times 2 -Exactly -ParameterFilter { $Arguments[0] -eq 'aks' -and '-g' -in $Arguments -and '-n' -in $Arguments -and '--ids' -notin $Arguments }
        }
        It 'validates a connected Windows Arc host without resubmitting assessments on an already-active retry' {
            $f = $global:ArcLifecycleFixture
            $f.machine.Native = $false
            $f.machine | Add-Member ArcId '/arc/machines/windows-fixture'
            $f.executeGuestScript = $true
            $path = Join-Path $TestDrive 'activation-retry.json'
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -ResultPath $path
            Should -Invoke Get-Service -Times 1 -ParameterFilter { $Name -eq 'himds' }
            Should -Invoke Get-Service -Times 0 -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
            Should -Invoke Restart-Service -Times 0
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[1] -eq 'assess-patches' }
            $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $report.status | Should -Be 'pass'
            $report.guestChecks.Count | Should -Be 1
            $report.guestChecks[0].restartedServices.Count | Should -Be 0
            $report.guestChecks[0].status | Should -Be 'pass'
            $report.patchAssessments.Count | Should -Be 0
            $report.patchAssessment | Should -Be 'not-required'
            $report.readiness | Should -Be 'skipped'
        }
        It 'reports an unhealthy Arc service and does not submit assessments after guest failure' {
            $f = $global:ArcLifecycleFixture
            $f.machine.Native = $false
            $f.machine | Add-Member ArcId '/arc/machines/windows-fixture'
            $f.executeGuestScript = $true
            Mock Get-Service { [pscustomobject]@{ Name = 'himds'; Status = 'Stopped' } } -ParameterFilter { $Name -eq 'himds' }
            $path = Join-Path $TestDrive 'activation-failure.json'
            { & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -ResultPath $path } | Should -Throw '*Required Arc service is not running*'
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[1] -eq 'assess-patches' }
            $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $report.status | Should -Be 'fail'
            $report.guestChecks[0].status | Should -Be 'fail'
        }
        It 'restarts only himds after starting a parked Windows Arc host' {
            $f = $global:ArcLifecycleFixture
            $f.machine.Native = $false
            $f.machine | Add-Member ArcId '/arc/machines/windows-fixture'
            $f.machine.Actual.powerState = 'VM deallocated'
            $f.executeGuestScript = $true
            Mock Invoke-DemoAz { $global:ArcLifecycleFixture.machine.Actual.powerState = 'VM running' } -ParameterFilter { $Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'start' }
            Mock Restart-Service {}
            $path = Join-Path $TestDrive 'activation-started.json'
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment -ResultPath $path
            Should -Invoke Restart-Service -Times 1 -ParameterFilter { $Name -eq 'himds' -and $Force }
            Should -Invoke Get-Service -Times 0 -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
            $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $report.guestChecks[0].restartedServices | Should -Be @('himds')
            $report.patchAssessments.Count | Should -Be 0
        }
        It 'fails a missing AMA process after a bounded startup wait without a service restart' {
            $global:ArcLifecycleFixture.executeGuestScript = $true
            Mock Get-Process { @() }
            Mock Start-Sleep { throw 'bounded AMA wait observed' }
            { & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment } | Should -Throw '*bounded AMA wait observed*'
            $global:ArcLifecycleFixture.guestScript | Should -Match 'AddMinutes\(3\)'
            $global:ArcLifecycleFixture.guestScript | Should -Match 'did not start within 180 seconds'
            Should -Invoke Restart-Service -Times 0
        }
        It 'checks each Linux service individually without restarting an already-connected host' {
            $f = $global:ArcLifecycleFixture
            $f.machine.Native = $false
            $f.machine.OsType = 'Linux'
            $f.machine | Add-Member ArcId '/arc/machines/linux-fixture'
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment
            $f.guestScript | Should -Match 'for service in himdsd azuremonitoragent; do sudo systemctl is-active --quiet "\$service"; done'
            $f.guestScript | Should -Not -Match 'systemctl restart'
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[1] -eq 'assess-patches' }
        }
        It 'records assessment submission failures instead of reporting completed activation' {
            $global:ArcLifecycleFixture.machine.Native = $false
            $global:ArcLifecycleFixture.machine | Add-Member ArcId '/arc/machines/windows-fixture'
            Mock Invoke-DemoAz { throw 'injected assessment failure' } -ParameterFilter { $Arguments[1] -eq 'assess-patches' }
            $path = Join-Path $TestDrive 'activation-assessment-failed.json'
            { & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -AssessPatches -ResultPath $path } | Should -Throw '*injected assessment failure*'
            $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $report.status | Should -Be 'fail'
            $report.guestChecks[0].status | Should -Be 'pass'
            $report.patchAssessments[0].status | Should -Be 'fail'
        }
        It 'allows explicitly requested assessment submission on an already-active retry' {
            $f = $global:ArcLifecycleFixture
            $f.machine.Native = $false
            $f.machine | Add-Member ArcId '/arc/machines/windows-fixture'
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -AssessPatches
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'assess-patches' -and '--no-wait' -in $Arguments }
        }
        It 'assesses a newly started Arc host by default' {
            $f = $global:ArcLifecycleFixture
            $f.machine.Native = $false
            $f.machine | Add-Member ArcId '/arc/machines/windows-fixture'
            $f.machine.Actual.powerState = 'VM deallocated'
            Mock Invoke-DemoAz { $global:ArcLifecycleFixture.machine.Actual.powerState = 'VM running' } -ParameterFilter { $Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'start' }
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'assess-patches' }
        }
        It 'rejects conflicting assessment switches before inspecting Azure' {
            { & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipPatchAssessment -AssessPatches } | Should -Throw '*cannot both*'
            Should -Invoke Initialize-DemoContext -Times 0
        }
        It 'repairs only the missing PIP binding on a retained exclusive NAT' {
            Mock Get-DemoNetworkState {
                $f = $global:ArcLifecycleFixture
                [pscustomobject]@{
                    NatId = $f.nat; PublicIpId = "$($f.root)/Microsoft.Network/publicIPAddresses/pip-natgw-retail-demo"
                    PublicIp = $null; Nat = @{ id = $f.nat; publicIpAddresses = @() }
                    Subnet = @{ id = "$($f.root)/Microsoft.Network/virtualNetworks/vnet-retail-demo/subnets/snet-vms"; natGateway = @{ id = $f.nat } }
                }
            }
            Mock Invoke-DemoAz {} -ParameterFilter { $Arguments[0] -eq 'network' -and $Arguments[1] -eq 'public-ip' -and $Arguments[2] -eq 'create' }
            Mock Invoke-DemoAz {} -ParameterFilter { $Arguments[0] -eq 'network' -and $Arguments[1] -eq 'nat' -and $Arguments[3] -eq 'update' }
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'public-ip' -and $Arguments[2] -eq 'create' }
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'nat' -and $Arguments[3] -eq 'update' -and '--public-ip-addresses' -in $Arguments }
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[1] -eq 'nat' -and $Arguments[3] -eq 'create' }
        }
        It 'rejects a sharing conflict before activation or hibernation mutates anything' -TestCases @(
            @{ ScriptName = 'Activate-ArcDemo.ps1' }
            @{ ScriptName = 'Hibernate-ArcDemo.ps1' }
        ) {
            param($ScriptName)
            $global:ArcLifecycleFixture.networkError = 'shared NAT'
            { & (Join-Path $repo "scripts\$ScriptName") -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo } | Should -Throw '*shared NAT*'
            Should -Invoke Invoke-DemoAz -Times 0
            Should -Invoke Invoke-DemoGuestCommand -Times 0
        }
        It 'recovers an interrupted NAT/PIP removal without restarting or redeallocating hosts' {
            $f = $global:ArcLifecycleFixture
            $f.machine.Actual.powerState = 'VM deallocated'
            $f.clusterState = 'Stopped'
            $f.failPublicIpDelete = $true
            Mock Invoke-DemoAz { $global:ArcLifecycleFixture.nat = '' } -ParameterFilter { $Arguments[0] -eq 'network' -and 'subnet' -in $Arguments -and 'update' -in $Arguments }
            Mock Invoke-DemoAz {
                $f = $global:ArcLifecycleFixture
                $f.resources = @($f.resources | Where-Object type -ne 'Microsoft.Network/natGateways')
            } -ParameterFilter { $Arguments[0] -eq 'network' -and 'gateway' -in $Arguments -and 'delete' -in $Arguments }
            Mock Invoke-DemoAz {
                $f = $global:ArcLifecycleFixture
                if ($f.failPublicIpDelete) { $f.failPublicIpDelete = $false; throw 'injected public IP delete failure' }
                $f.resources = @($f.resources | Where-Object type -ne 'Microsoft.Network/publicIPAddresses')
            } -ParameterFilter { $Arguments[0] -eq 'network' -and 'public-ip' -in $Arguments -and 'delete' -in $Arguments }
            { & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo } | Should -Throw '*public IP delete failure*'
            & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { 'gateway' -in $Arguments -and 'delete' -in $Arguments }
            Should -Invoke Invoke-DemoAz -Times 2 -Exactly -ParameterFilter { 'public-ip' -in $Arguments -and 'delete' -in $Arguments }
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'deallocate' -in $Arguments -or 'start' -in $Arguments -or 'create' -in $Arguments }
            $f.resources.Count | Should -Be 0
        }
        It 'does not repeat completed deallocation or delete absent NAT on a hibernation rerun' {
            $global:ArcLifecycleFixture.machine.Actual.powerState = 'VM deallocated'
            $global:ArcLifecycleFixture.clusterState = 'Stopped'
            $global:ArcLifecycleFixture.nat = ''
            $global:ArcLifecycleFixture.resources = @()
            & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'deallocate' -in $Arguments -or 'stop' -in $Arguments -or 'delete' -in $Arguments -or 'update' -in $Arguments }
        }
        It 'waits for an in-flight VM start without submitting start again' {
            $global:ArcLifecycleFixture.machine.Actual.powerState = 'VM starting'
            Mock Invoke-DemoAz {
                $global:ArcLifecycleFixture.machine.Actual.powerState = 'VM running'
                ConvertTo-Json -InputObject @($global:ArcLifecycleFixture.machine.Actual) -Depth 5
            } -ParameterFilter { $Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'list' }
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'start' }
        }
        It 'waits for an in-flight AKS start even when optional full readiness is skipped' {
            $global:ArcLifecycleFixture.clusterReads = 0
            Mock Invoke-DemoAz {
                $f = $global:ArcLifecycleFixture
                $f.clusterReads++
                @{ name = 'retail-demo-aks'; powerState = @{ code = 'Running' }; provisioningState = if ($f.clusterReads -eq 1) { 'Starting' } else { 'Succeeded' } } | ConvertTo-Json -Depth 5
            } -ParameterFilter { $Arguments[0] -eq 'aks' -and $Arguments[1] -eq 'show' }
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'aks' -and $Arguments[1] -eq 'start' }
            $global:ArcLifecycleFixture.clusterReads | Should -Be 2
        }
        It 'waits for in-flight deallocation without submitting deallocate again' {
            $f = $global:ArcLifecycleFixture
            $f.machine.Actual.powerState = 'VM deallocating'
            $f.clusterState = 'Stopped'; $f.nat = ''; $f.resources = @()
            Mock Invoke-DemoAz {
                $global:ArcLifecycleFixture.machine.Actual.powerState = 'VM deallocated'
                ConvertTo-Json -InputObject @($global:ArcLifecycleFixture.machine.Actual) -Depth 5
            } -ParameterFilter { $Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'list' }
            & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'deallocate' -in $Arguments -or 'start' -in $Arguments }
        }
        It 'deactivates only active app revisions and preserves them on a parked retry' {
            $f = $global:ArcLifecycleFixture
            $f.machine.Actual.powerState = 'VM deallocated'
            $f.clusterState = 'Stopped'; $f.nat = ''; $f.resources = @()
            $f.appIds = @("$($f.root)/Microsoft.App/containerApps/fixture")
            $f.revisions = @(
                @{ name = 'retained'; properties = @{ active = $false } }
                @{ name = 'active'; properties = @{ active = $true } }
            )
            Mock Invoke-DemoAz { ConvertTo-Json -InputObject $global:ArcLifecycleFixture.revisions -Depth 5 } -ParameterFilter { $Arguments[0] -eq 'containerapp' -and $Arguments[2] -eq 'list' }
            Mock Invoke-DemoAz {
                ($global:ArcLifecycleFixture.revisions | Where-Object name -eq 'active').properties.active = $false
            } -ParameterFilter { $Arguments[0] -eq 'containerapp' -and $Arguments[2] -eq 'deactivate' }
            1..2 | ForEach-Object {
                & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo
            }
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'containerapp' -and $Arguments[2] -eq 'deactivate' -and 'active' -in $Arguments }
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'update' -in $Arguments -or 'set' -in $Arguments -or 'start' -in $Arguments -or 'delete' -in $Arguments }
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
            It 'throws on a nonzero native exit even when stdout looks successful with preview=<Preview>' -TestCases @(
                @{ Preview = $false }
                @{ Preview = $true }
            ) {
                param($Preview)
                Mock Get-Command { [pscustomobject]@{ Source = $script:pwshPath } } -ParameterFilter { $Name -eq 'az' }
                $WhatIfPreference = $Preview
                { Invoke-DemoAz -Arguments @('-NoProfile', '-Command', 'Write-Output success; [Console]::Error.WriteLine("denied"); exit 7') } | Should -Throw '*exit 7*denied*'
                $WhatIfPreference | Should -Be $Preview
            }
            It 'never treats authentication failures as resource absence with preview=<Preview>' -TestCases @(
                @{ Preview = $false }
                @{ Preview = $true }
            ) {
                param($Preview)
                Mock Get-Command { [pscustomobject]@{ Source = $script:pwshPath } } -ParameterFilter { $Name -eq 'az' }
                $WhatIfPreference = $Preview
                { Invoke-DemoAz -Arguments @('-NoProfile', '-Command', '[Console]::Error.WriteLine("AuthorizationFailed"); exit 1') -AllowNotFound } | Should -Throw '*AuthorizationFailed*'
                $WhatIfPreference | Should -Be $Preview
            }
            It 'recognizes actual native not-found stderr with preview=<Preview>' -TestCases @(
                @{ Preview = $false }
                @{ Preview = $true }
            ) {
                param($Preview)
                Mock Get-Command { [pscustomobject]@{ Source = $script:pwshPath } } -ParameterFilter { $Name -eq 'az' }
                $WhatIfPreference = $Preview
                $result = Invoke-DemoAz -Arguments @('-NoProfile', '-Command', '[Console]::Error.WriteLine("(ResourceNotFound) expected parked resource"); exit 3') -AllowNotFound
                $result | Should -BeNullOrEmpty
                $WhatIfPreference | Should -Be $Preview
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
                Mock Get-DemoNetworkState { [pscustomobject]@{ NatId = '/nat'; PublicIpId = '/pip'; Nat = $null; PublicIp = $null; Subnet = @{ id = '/subnet' } } }
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
    It 'keeps schema and exits compatible for Active' {
        Mock Get-DemoReadinessChecks { New-DemoCheck 'fixture' '/expected/id' 'ready' 'ready' 'pass' }
        $output = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -DesiredState Active -OutputFormat Json
        $LASTEXITCODE | Should -Be 0
        ($output | ConvertFrom-Json).desiredState | Should -Be 'Active'
        Should -Invoke Get-DemoReadinessChecks -Times 1 -ParameterFilter { $DesiredState -eq 'Active' }
    }
    It 'passes parked cost state with explicit failed and pending wake diagnostics' {
        Mock Get-DemoReadinessChecks {
            New-DemoCheck 'vm/fixture/power' '/vm/fixture' 'VM deallocated' 'VM deallocated' 'pass'
            New-DemoCheck 'extension/fixture/ama' '/extension/ama' 'Succeeded' 'Failed' 'fail' $false 'Wake-readiness diagnostic'
            New-DemoCheck 'dcra/fixture/rule' '/fixture' 'rule' $null 'pending' $false 'Wake-readiness diagnostic'
        }
        $output = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -DesiredState Hibernated -OutputFormat Json
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json
        $result.status | Should -Be 'pass'
        $result.checks[1].status | Should -Be 'fail'
        $result.checks[1].required | Should -BeFalse
    }
    It 'inspects Removed without deployment history or live VM inventory' {
        Mock Get-DemoInventory { throw 'deployment history is absent' }
        Mock Get-DemoRemovalChecks { New-DemoCheck 'group/fixture' '/rg/fixture' 'absent' 'absent' 'pass' }
        $output = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -DesiredState Removed -OutputFormat Json
        $LASTEXITCODE | Should -Be 0
        ($output | ConvertFrom-Json).desiredState | Should -Be 'Removed'
        Should -Invoke Get-DemoInventory -Times 0
    }
    It 'returns an actionable error record and exit 1 on inspection failure' {
        Mock Get-DemoReadinessChecks { throw 'permission denied' }
        $output = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -OutputFormat Json
        $LASTEXITCODE | Should -Be 1
        ($output | ConvertFrom-Json).checks[-1].message | Should -Be 'permission denied'
    }
}

    Describe 'Narrow lifecycle network ownership checks' {
        InModuleScope Common {
            BeforeEach {
                $script:DemoSubscription = '11111111-1111-1111-1111-111111111111'
                $script:networkRoot = "/subscriptions/$script:DemoSubscription/resourceGroups/rg-retail-demo-infra/providers/Microsoft.Network"
                $script:networkFixture = @{
                    subnet = @{ id = "$script:networkRoot/virtualNetworks/vnet-retail-demo/subnets/snet-vms"; natGateway = @{ id = "$script:networkRoot/natGateways/natgw-retail-demo" } }
                    nat = @{ id = "$script:networkRoot/natGateways/natgw-retail-demo"; subnets = @(@{ id = "$script:networkRoot/virtualNetworks/vnet-retail-demo/subnets/snet-vms" }); publicIpAddresses = @(@{ id = "$script:networkRoot/publicIPAddresses/pip-natgw-retail-demo" }) }
                    pip = @{ id = "$script:networkRoot/publicIPAddresses/pip-natgw-retail-demo"; natGateway = @{ id = "$script:networkRoot/natGateways/natgw-retail-demo" } }
                }
                Mock Invoke-DemoAz {
                    param($Arguments)
                    switch ($Arguments[0..2] -join ' ') {
                        'network vnet subnet' { $script:networkFixture.subnet | ConvertTo-Json -Depth 10 }
                        'network nat gateway' { if ($script:networkFixture.nat) { $script:networkFixture.nat | ConvertTo-Json -Depth 10 } else { return $null } }
                        'network public-ip show' { if ($script:networkFixture.pip) { $script:networkFixture.pip | ConvertTo-Json -Depth 10 } else { return $null } }
                        default { throw 'Unexpected operation; network preflight must only inspect exact resources.' }
                    }
                }
            }
            It 'accepts the expected exclusively used resources' {
                $state = Get-DemoNetworkState -InfraRg rg-retail-demo-infra -NamePrefix retail-demo
                $state.Nat.id | Should -Be "$script:networkRoot/natGateways/natgw-retail-demo"
                Should -Invoke Invoke-DemoAz -Times 3 -Exactly -ParameterFilter { 'show' -in $Arguments -and '--ids' -in $Arguments }
            }
            It 'accepts already-absent ephemeral resources and detached subnet' {
                $ErrorActionPreference = 'Stop'
                $script:networkFixture.nat = $null
                $script:networkFixture.pip = $null
                $script:networkFixture.subnet.natGateway = $null
                $state = Get-DemoNetworkState -InfraRg rg-retail-demo-infra -NamePrefix retail-demo
                $state.Nat | Should -BeNullOrEmpty
                $state.PublicIp | Should -BeNullOrEmpty
            }
            It 'accepts a partially restored network with absent <Missing> under terminating errors' -TestCases @(
                @{ Missing = 'nat' }
                @{ Missing = 'pip' }
            ) {
                param($Missing)
                $ErrorActionPreference = 'Stop'
                $script:networkFixture[$Missing] = $null
                $state = Get-DemoNetworkState -InfraRg rg-retail-demo-infra -NamePrefix retail-demo
                if ($Missing -eq 'nat') {
                    $state.Nat | Should -BeNullOrEmpty
                    $state.PublicIp.id | Should -Be "$script:networkRoot/publicIPAddresses/pip-natgw-retail-demo"
                } else {
                    $state.PublicIp | Should -BeNullOrEmpty
                    $state.Nat.id | Should -Be "$script:networkRoot/natGateways/natgw-retail-demo"
                }
            }
            It 'does not conceal malformed optional resource JSON' {
                Mock Invoke-DemoAz { '{broken' } -ParameterFilter { 'gateway' -in $Arguments }
                { Get-DemoNetworkState -InfraRg rg-retail-demo-infra -NamePrefix retail-demo -ErrorAction Stop } | Should -Throw
            }
            It 'rejects a foreign subnet association' {
                $script:networkFixture.subnet.natGateway.id = '/foreign/nat'
                { Get-DemoNetworkState -InfraRg rg-retail-demo-infra -NamePrefix retail-demo } | Should -Throw '*unexpected NAT*'
            }
            It 'rejects a NAT shared with another subnet' {
                $script:networkFixture.nat.subnets += @{ id = '/foreign/subnet' }
                { Get-DemoNetworkState -InfraRg rg-retail-demo-infra -NamePrefix retail-demo } | Should -Throw '*shared*'
            }
            It 'rejects additional NAT public IPs' {
                $script:networkFixture.nat.publicIpAddresses += @{ id = '/foreign/pip' }
                { Get-DemoNetworkState -InfraRg rg-retail-demo-infra -NamePrefix retail-demo } | Should -Throw '*unexpected public IP*'
            }
            It 'rejects a PIP bound to another resource' {
                $script:networkFixture.pip.ipConfiguration = @{ id = '/foreign/nic/ipconfig' }
                { Get-DemoNetworkState -InfraRg rg-retail-demo-infra -NamePrefix retail-demo } | Should -Throw '*another resource*'
            }
            It 'propagates a genuine read denial instead of treating the NAT as absent' {
                Mock Invoke-DemoAz { throw 'AuthorizationFailed' } -ParameterFilter { 'gateway' -in $Arguments }
                { Get-DemoNetworkState -InfraRg rg-retail-demo-infra -NamePrefix retail-demo } | Should -Throw '*AuthorizationFailed*'
            }
            It 'propagates a public IP read denial even when the NAT is absent' {
                $script:networkFixture.nat = $null
                Mock Invoke-DemoAz { throw 'AuthorizationFailed' } -ParameterFilter { 'public-ip' -in $Arguments }
                { Get-DemoNetworkState -InfraRg rg-retail-demo-infra -NamePrefix retail-demo -ErrorAction Stop } | Should -Throw '*AuthorizationFailed*'
            }
        }
    }

    Describe 'Actual parked checks versus wake diagnostics' {
        InModuleScope Common {
            BeforeEach {
                $script:DemoSubscription = '11111111-1111-1111-1111-111111111111'
                $script:parkedInventory = [pscustomobject]@{
                    ArcRg = 'rg-retail-demo'; InfraRg = 'rg-retail-demo-infra'; Resources = @(); AksClusterIds = @(); ContainerAppIds = @()
                    Machines = @([pscustomobject]@{ Name = 'fixture'; Id = '/vm/fixture'; ArcId = '/arc/fixture'; Native = $false
                        Monitor = $true; VmInsights = $false; ChangeTracking = $false; OsType = 'Windows'; Actual = @{ powerState = 'VM deallocated' } })
                }
                Mock Get-DemoNetworkState { [pscustomobject]@{ NatId = '/nat'; PublicIpId = '/pip'; Nat = $null; PublicIp = $null; Subnet = @{ id = '/subnet' } } }
                Mock Get-DemoHeartbeatIds { throw 'No live telemetry query while parked' }
                Mock Invoke-DemoAz {
                    param($Arguments)
                    if ($Arguments[0] -eq 'group') { return '{"properties":{"provisioningState":"Succeeded"}}' }
                    if ($Arguments[0] -eq 'connectedmachine' -and $Arguments[1] -eq 'list') { return '[{"id":"/arc/fixture","status":"Disconnected"}]' }
                    if ($Arguments[0] -eq 'connectedmachine') { return '[{"name":"AzureMonitorWindowsAgent","properties":{"provisioningState":"Failed"}}]' }
                    return '[]'
                }
            }
            It 'keeps missing DCRAs and failed extensions visible without failing parked cost state' {
                $checks = @(Get-DemoReadinessChecks -Inventory $script:parkedInventory -NamePrefix retail-demo -DesiredState Hibernated)
                @($checks | Where-Object { $_.required -and $_.status -ne 'pass' }).Count | Should -Be 0
                $extension = $checks | Where-Object id -like 'extension/*'
                $extension.status | Should -Be 'fail'
                $extension.required | Should -BeFalse
                $extension.message | Should -Match 'Wake-readiness diagnostic'
                ($checks | Where-Object id -like 'dcra/*').required | Should -BeFalse
                Should -Invoke Get-DemoHeartbeatIds -Times 0
            }
            It 'still fails mandatory cost checks when expected VM or app state is not parked' {
                $script:parkedInventory.Machines[0].Actual.powerState = 'VM running'
                $script:parkedInventory.ContainerAppIds = @('/containerapps/fixture')
                Mock Invoke-DemoAz { '[{"name":"active","properties":{"active":true}}]' } -ParameterFilter { $Arguments[0] -eq 'containerapp' }
                $checks = @(Get-DemoReadinessChecks -Inventory $script:parkedInventory -NamePrefix retail-demo -DesiredState Hibernated)
                @($checks | Where-Object { $_.required -and $_.status -eq 'pending' }).Count | Should -Be 2
            }
            It 'keeps inspection errors terminating even for optional monitoring diagnostics' {
                Mock Invoke-DemoAz { throw 'monitoring access denied' } -ParameterFilter { $Arguments[0] -eq 'monitor' }
                { Get-DemoReadinessChecks -Inventory $script:parkedInventory -NamePrefix retail-demo -DesiredState Hibernated } | Should -Throw '*access denied*'
            }
        }
    }

Describe 'Removed ownership boundary' {
    InModuleScope Common {
        BeforeEach {
            $script:DemoSubscription = '11111111-1111-1111-1111-111111111111'
            Mock Invoke-DemoAz {
                param($Arguments)
                if ($Arguments[0] -eq 'group') { return 'false' }
                if ($Arguments[0] -in @('policy', 'consumption')) { return $null }
                throw 'Removed verification must not use directory or deployment APIs.'
            }
        }
        It 'verifies owned group policy and budget absence with explicit retained exceptions' {
            $checks = @(Get-DemoRemovalChecks retail-demo)
            @($checks | Where-Object required).Count | Should -Be 5
            @($checks | Where-Object { $_.required -and $_.status -ne 'pass' }).Count | Should -Be 0
            @($checks | Where-Object { -not $_.required -and $_.status -eq 'skipped' }).Count | Should -Be 2
        }
        It 'does not claim Removed while a named policy remains' {
            Mock Invoke-DemoAz { '{"id":"/remaining-policy"}' } -ParameterFilter { $Arguments[0] -eq 'policy' -and 'mcsb-retail-demo' -in $Arguments }
            (Get-DemoRemovalChecks retail-demo | Where-Object id -eq 'policy/mcsb-retail-demo').status | Should -Be 'pending'
        }
        It 'does not claim Removed while its budget remains' {
            Mock Invoke-DemoAz { '{"name":"budget-retail-demo"}' } -ParameterFilter { $Arguments[0] -eq 'consumption' }
            (Get-DemoRemovalChecks retail-demo | Where-Object id -eq 'budget').status | Should -Be 'pending'
        }
    }
}

Describe 'Removal convergence without broad cleanup' {
    BeforeEach {
        Mock Import-Module {}
        Mock Initialize-DemoContext {}
        Mock Invoke-AzRest { throw 'Already-absent budget must not be deleted again.' }
        Mock Get-DemoRemovalChecks { New-DemoCheck 'owned' '/fixture' 'absent' 'absent' 'pass' }
        Mock Wait-Until {
            param($Condition)
            if (-not (& $Condition)) { throw 'Owned resources still present.' }
        }
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'group' -and $Arguments[1] -eq 'exists') { return 'false' }
            if ($Arguments[0] -in @('policy', 'consumption')) { return $null }
            throw 'Unexpected cleanup operation.'
        }
    }
    It 'does not write or use Graph when owned resources are already removed' {
        & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -Confirm:$false
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'delete' -in $Arguments -or 'create' -in $Arguments -or $Arguments[0] -eq 'ad' }
        Should -Invoke Invoke-AzRest -Times 0
        Should -Invoke Get-DemoRemovalChecks -Times 1
    }
    It 'does not declare success solely because both groups are gone' {
        Mock Get-DemoRemovalChecks { New-DemoCheck 'budget' '/budget' 'absent' 'exists' 'pending' }
        { & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -Confirm:$false } | Should -Throw '*still present*'
    }
    It 'checks optional identity sharing before deleting policies budget or groups' {
        Mock Invoke-DemoAz { '[{"id":"identity-fixture","displayName":"sp-retail-demo-onboard"}]' } -ParameterFilter { $Arguments[0] -eq 'ad' }
        Mock Invoke-DemoAz { '[{"scope":"/foreign"}]' } -ParameterFilter { $Arguments[0] -eq 'role' }
        { & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -RemoveOnboardingIdentity -Confirm:$false } | Should -Throw '*potentially shared*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'delete' -in $Arguments -or $Arguments[0] -in @('policy', 'consumption', 'group') }
        Should -Invoke Invoke-AzRest -Times 0
    }
}
