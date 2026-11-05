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
    It 'does not let a JSON Keys property hide invalid workload booleans' {
        Set-Content (Join-Path $TestDrive 'collision.json') '{"schemaVersion":1,"workloads":{"Keys":"ignored","deployAks":"false"}}'
        { Get-DemoSkin -Path 'collision.json' -RepoRoot $TestDrive } | Should -Throw '*JSON boolean*'
    }
    It 'loads a non-default skin' {
        Set-Content (Join-Path $TestDrive 'retail.json') '{"schemaVersion":1,"azure":{"namePrefix":"retail-demo"},"workloads":{"deployAks":false}}'
        $skin = Get-DemoSkin -Path 'retail.json' -RepoRoot $TestDrive
        Get-DemoSkinValue $skin 'azure.namePrefix' '' | Should -Be 'retail-demo'
        Get-DemoSkinValue $skin 'workloads.deployAks' $true | Should -BeFalse
    }
    It 'rejects malformed or duplicate keep-parked names' -TestCases @(
        @{ Names = '"image-parent"' }, @{ Names = '["image-parent","IMAGE-parent"]' },
        @{ Names = '[null]' }, @{ Names = '["../foreign"]' }
    ) {
        param($Names)
        Set-Content (Join-Path $TestDrive 'parked.json') ('{"schemaVersion":1,"operations":{"keepParkedVmNames":' + $Names + '}}')
        { Get-DemoSkin -Path 'parked.json' -RepoRoot $TestDrive } | Should -Throw '*keepParkedVmNames*'
    }
    It 'preserves native JSON dictionaries, arrays and false overrides' {
        Set-Content (Join-Path $TestDrive 'nested.json') '{"schemaVersion":1,"workloads":{"deployAks":false},"compute":{"sizes":["first","second"]},"tags":{"role":"fixture"}}'
        $skin = Get-DemoSkin -Path 'nested.json' -RepoRoot $TestDrive
        $skin | Should -BeOfType ([System.Collections.IDictionary])
        Get-DemoSkinValue $skin 'compute.sizes' @() | Should -Be @('first', 'second')
        Get-DemoSkinValue $skin 'workloads.deployAks' $true | Should -BeFalse
        Get-DemoSkinValue $skin 'missing.child' 'fallback' | Should -Be 'fallback'
        (Merge-DemoHashtable -Defaults @{ role = 'default'; retained = 'yes' } -Overrides $skin.tags).retained | Should -Be 'yes'
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
        It 'tells a stranger exactly what to declare when a governance automation has converted the disks to HDD' {
            Mock Invoke-DemoAz { 'Standard_LRS' }
            $message = try { Assert-DemoOsDiskStorageAccountType -Machines @($script:diskVm) -StorageAccountType StandardSSD_LRS } catch { $_.Exception.Message }
            $message | Should -Match 'the disk is Standard_LRS and this run requests StandardSSD_LRS'
            $message | Should -Match 'Deploy never converts a disk'
            $message | Should -Match 'compute\.osDiskStorageAccountType to Standard_LRS in the private skin \(or pass -OsDiskStorageAccountType Standard_LRS\)'
            $message | Should -Match 'nestedSqlGuest\.parentDataDiskStorageAccountType'
            $message | Should -Match 'governance automation can convert a parked estate''s disks to Standard HDD on its own'
            $message | Should -Match 'The OS disk tier changed by itself'
            $message | Should -Match 'separately approved stop/deallocate/restart window'
        }
        It 'does not advise declaring a tier that Deploy cannot declare' {
            Mock Invoke-DemoAz { 'Premium_LRS' }
            $message = try { Assert-DemoOsDiskStorageAccountType -Machines @($script:diskVm) -StorageAccountType StandardSSD_LRS } catch { $_.Exception.Message }
            $message | Should -Match 'the disk is Premium_LRS'
            $message | Should -Match 'Deploy can only declare Standard_LRS or StandardSSD_LRS'
            $message | Should -Not -Match 'osDiskStorageAccountType to Premium_LRS'
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

Describe 'Result file of an Activate or Hibernate run' {
    It 'keeps a finished <Status> result as it is' -TestCases @(
        @{ Status = 'pass' }, @{ Status = 'fail' }, @{ Status = 'pending' }
    ) {
        param($Status)
        $path = Join-Path $TestDrive "result-$Status.json"
        Write-DemoResultFile -Result ([ordered]@{ status = $Status; error = 'kept' }) -Path $path
        $written = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $written.status | Should -Be $Status
        $written.error | Should -Be 'kept'
    }
    It 'records a run that was stopped before it finished as interrupted, not as running' {
        $path = Join-Path $TestDrive 'result-stopped.json'
        Write-DemoResultFile -Result ([ordered]@{ status = 'running'; error = $null }) -Path $path
        $written = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $written.status | Should -Be 'interrupted'
        $written.error | Should -Match 'stopped before it finished'
    }
    It 'only warns when the file cannot be written, so it never replaces the error in flight' {
        $path = Join-Path $TestDrive 'result-is-a-folder.json'
        New-Item -ItemType Directory -Path $path | Out-Null
        $warned = $null
        Write-DemoResultFile -Result ([ordered]@{ status = 'fail'; error = 'real failure' }) -Path $path -WarningVariable warned -WarningAction SilentlyContinue
        "$warned" | Should -Match 'could not be written'
    }
}

Describe 'Narrow LOB heartbeat collection' {
    BeforeAll {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\Deploy-ArcDemo.ps1'), [ref]$null, [ref]$errors)
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CoreDcrBody'
        }, $true)
        if (-not $function -or $errors) { throw 'Core DCR definition could not be loaded for isolated tests.' }
        . ([scriptblock]::Create($function.Extent.Text))
        $body = New-CoreDcrBody -Location 'australiaeast' -Tags @{ purpose = 'fixture' } -WorkspaceId '/fixture/workspace' -WorkspaceName 'law-fixture'
    }
    It 'collects only source-specific LOB and real SQL informational heartbeats alongside existing selectors' {
        $sources = @($body.properties.dataSources.windowsEventLogs)
        $sources.Count | Should -Be 1
        $sources[0].streams | Should -Be @('Microsoft-Event')
        $sources[0].xPathQueries.Count | Should -Be 6
        $sources[0].xPathQueries | Should -Contain "Application!*[System[Provider[@Name='ArcLobBridgeApp'] and (EventID=4000) and (Level=4)]]"
        $sources[0].xPathQueries | Should -Contain "Application!*[System[Provider[@Name='ArcSqlEngineDemo'] and (EventID=6000) and (Level=4)]]"
        $sources[0].xPathQueries | Should -Contain "Application!*[System[Provider[@Name='ArcSqlEngineDemo'] and (EventID=6001) and (Level=4)]]"
        $sources[0].xPathQueries | Should -Contain 'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
        $sources[0].xPathQueries | Should -Contain 'System!*[System[(Level=1 or Level=2 or Level=3)]]'
        $sources[0].xPathQueries | Should -Contain 'Security!*[System[(band(Keywords,4503599627370496))]]'
        $body.properties.destinations.logAnalytics[0].workspaceResourceId | Should -Be '/fixture/workspace'
        @($body.properties.dataFlows | Where-Object { 'Microsoft-Event' -in $_.streams })[0].destinations | Should -Be @('law-fixture')
    }
    It 'adds valid Linux AMA memory/disk counters to the existing Perf source without dropping the established selectors' {
        $perf = @($body.properties.dataSources.performanceCounters)
        $perf.Count | Should -Be 1
        $perf[0].streams | Should -Be @('Microsoft-Perf')
        $perf[0].samplingFrequencyInSeconds | Should -Be 60
        foreach ($counter in @('Memory(*)\Available MBytes Memory', 'Memory(*)\% Used Memory', 'Logical Disk(*)\% Free Space', 'Logical Disk(*)\Free Megabytes')) {
            $perf[0].counterSpecifiers | Should -Contain $counter
        }
        foreach ($counter in @('\Processor Information(_Total)\% Processor Time', '\Memory\% Committed Bytes In Use', '\Memory\Available MBytes',
                '\LogicalDisk(_Total)\% Free Space', '\Network Interface(*)\Bytes Total/sec', '\Processor(*)\% Processor Time')) {
            $perf[0].counterSpecifiers | Should -Contain $counter
        }
        # These were never valid AMA Linux counter names and produced no Linux samples.
        foreach ($counter in @('\Memory(*)\AvailableMemory', '\Memory(*)\PercentUsedMemory', '\Logical Disk(*)\FreeSpacePercentage')) {
            $perf[0].counterSpecifiers | Should -Not -Contain $counter
        }
        @($body.properties.dataSources.syslog).Count | Should -Be 1
        @($body.properties.dataFlows | Where-Object { 'Microsoft-Perf' -in $_.streams })[0].destinations | Should -Be @('law-fixture')
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
        It 'rejects unknown VMs for strict activation inventory' {
            $script:vmFixtures += @{ name = 'foreign-01'; id = "$script:infraRoot/Microsoft.Compute/virtualMachines/foreign-01" }
            { Get-DemoInventory 'retail-demo' } | Should -Throw '*ambiguous fleet*'
        }
        It 'keeps only an explicitly named deallocated extra VM out of the active fleet' {
            $script:vmFixtures += @{ name = 'image-parent'; id = "$script:infraRoot/Microsoft.Compute/virtualMachines/image-parent"; powerState = 'VM deallocated' }
            $inventory = Get-DemoInventory retail-demo -KeepParkedVmNames image-parent
            $inventory.Machines.Count | Should -Be 2
            $inventory.ParkedMachines.Name | Should -Be 'image-parent'
            $inventory.ParkedMachines.KeepParked | Should -BeTrue
        }
        It 'rejects a keep-parked VM that is <State>' -TestCases @(
            @{ State = 'VM running' }, @{ State = 'VM stopped' }, @{ State = '' }
        ) {
            param($State)
            $script:vmFixtures += @{ name = 'image-parent'; id = "$script:infraRoot/Microsoft.Compute/virtualMachines/image-parent"; powerState = $State }
            { Get-DemoInventory retail-demo -KeepParkedVmNames image-parent } | Should -Throw '*must exist*deallocated*'
        }
        It 'rejects missing keep-parked VMs, active-fleet conflicts and unsafe names' {
            { Get-DemoInventory retail-demo -KeepParkedVmNames missing } | Should -Throw '*must exist*'
            { Get-DemoInventory retail-demo -KeepParkedVmNames branch-01 } | Should -Throw '*outside the active*'
            { Get-DemoInventory retail-demo -KeepParkedVmNames '../foreign' } | Should -Throw '*valid*'
        }
        It 'does not let an explicit keep-parked VM hide another unknown VM' {
            $script:vmFixtures += @{ name = 'image-parent'; id = "$script:infraRoot/Microsoft.Compute/virtualMachines/image-parent"; powerState = 'VM deallocated' }
            $script:vmFixtures += @{ name = 'foreign'; id = "$script:infraRoot/Microsoft.Compute/virtualMachines/foreign" }
            { Get-DemoInventory retail-demo -KeepParkedVmNames image-parent } | Should -Throw '*ambiguous fleet*'
        }
        It 'rejects OS drift between the manifest and actual VM' {
            $script:vmFixtures[0].storageProfile.osDisk.osType = 'Linux'
            { Get-DemoInventory 'retail-demo' } | Should -Throw '*OS metadata*'
        }
        It 'rejects a foreign subscription workload ID' {
            $script:deploymentFixtures[0].properties.outputs.azureVmResourceIds.value = @('/subscriptions/other/resourceGroups/foreign/providers/Microsoft.Compute/virtualMachines/x')
            { Get-DemoInventory 'retail-demo' } | Should -Throw '*outside*'
        }
        It 'discovers every VM for parking despite <Drift>, without reading manifests' -TestCases @(
            @{ Drift = 'missing manifest' }
            @{ Drift = 'unlisted VM' }
            @{ Drift = 'OS mismatch' }
        ) {
            param($Drift)
            if ($Drift -eq 'unlisted VM') { $script:vmFixtures += @{ name = 'extra'; id = "$script:infraRoot/Microsoft.Compute/virtualMachines/extra" } }
            if ($Drift -eq 'OS mismatch') { $script:vmFixtures[0].storageProfile.osDisk.osType = 'Linux' }
            Mock Invoke-DemoAz { throw 'No deployment manifest' } -ParameterFilter { $Arguments[0] -eq 'deployment' }
            $inventory = Get-DemoInventory retail-demo -ForHibernation
            $inventory.Machines.Id | Should -Be @($script:vmFixtures.id)
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' }
        }
        It 'does not trust a foreign ID even in parking inventory' {
            $script:vmFixtures[0].id = '/foreign/vm'
            { Get-DemoInventory retail-demo -ForHibernation } | Should -Throw '*outside*'
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
        It 'removes the temporary script if asynchronous job creation fails' {
            Mock Start-DemoAzJob {
                param($Arguments)
                $global:ArcGuestTransportFixture.path = $Arguments[[array]::IndexOf($Arguments, '--scripts') + 1].TrimStart('@')
                throw 'Local job creation failed'
            }
            { Invoke-DemoGuestCommand -Machine $script:machine -Script 'valid' -AsJob } | Should -Throw '*job creation failed*'
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
        It 'accepts pending only when the activation caller explicitly permits it' {
            Mock Receive-DemoJobs { '{"value":[{"code":"ComponentStatus/StdOut/succeeded","message":"ARC_DEMO_PENDING"}]}' }
            { Invoke-DemoGuestCommand -Machine $script:machine -Script 'valid' } | Should -Throw
            (Invoke-DemoGuestCommand -Machine $script:machine -Script 'valid' -AllowPending -PassThru).status | Should -Be 'pending'
        }
        It 'keeps an asynchronous script file until its actual job is received' {
            Mock Receive-DemoJobs { '{"value":[{"code":"ComponentStatus/StdOut/succeeded","message":"ARC_DEMO_OK"}]}' }
            $job = Invoke-DemoGuestCommand -Machine $script:machine -Script 'valid' -AsJob
            [System.IO.File]::Exists($job.DemoScriptPath) | Should -BeTrue
            Should -Invoke Receive-DemoJobs -Times 0
            (Invoke-DemoGuestCommand -Machine $script:machine -Job $job -PassThru).status | Should -Be 'pass'
            [System.IO.File]::Exists($job.DemoScriptPath) | Should -BeFalse
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
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'list') { return '[]' }
            if ($Arguments[0] -eq 'bicep') { return '{"parameters":{"onPremFleet":{"defaultValue":[]}}}' }
            if ($Arguments[0] -in @('keyvault', 'network', 'consumption')) { return $null }
            if ($Arguments[0] -eq 'security' -and $Arguments[2] -eq 'show') { return '{"name":"VirtualMachines","pricingTier":"Free","subPlan":null,"extensions":null}' }
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
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if') {
                $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1].TrimStart('@')
                $global:ArcDiskPreview = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            }
            if ($Arguments[0] -eq 'security' -and $Arguments[2] -eq 'show') { return '{"name":"VirtualMachines","pricingTier":"Free","subPlan":null,"extensions":null}' }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'list') { return '[]' }
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
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'list') { return '[]' }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if') { throw 'must not reach template preview' }
        }
        { & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -AdminEmail 'test@example.com' -DeployAzureVMs $true -WhatIf } | Should -Throw '*tier mismatch*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if' }
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
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if') {
                $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1].TrimStart('@')
                $global:ArcPreviewParameters = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            }
            if ($Arguments[0] -eq 'security' -and $Arguments[2] -eq 'show') { return '{"name":"VirtualMachines","pricingTier":"Free","subPlan":null,"extensions":null}' }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'list') { return '[]' }
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

Describe 'Retained vault deployment selection' {
    BeforeEach {
        Mock Import-Module {}
        Mock Test-Prerequisites { '33333333-3333-3333-3333-333333333333' }
        Mock Test-DemoComputeCapacity {}
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'group' -and $Arguments[1] -eq 'exists') { return 'true' }
            if ($Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'list') { return '[{"name":"kv-fixture-old"},{"name":"kv-fixture-current"}]' }
            if ($Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'show') {
                return '{"id":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.KeyVault/vaults/kv-fixture-current","properties":{"publicNetworkAccess":"Disabled"}}'
            }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'list') {
                return '[{"properties":{"provisioningState":"Succeeded","timestamp":"2026-01-02","outputs":{"arcResourceGroup":{"value":"rg-fixture"},"keyVaultName":{"value":"kv-fixture-current"}}}},{"properties":{"provisioningState":"Succeeded","timestamp":"2026-01-01","outputs":{"arcResourceGroup":{"value":"rg-fixture"},"keyVaultName":{"value":"kv-fixture-old"}}}}]'
            }
            if ($Arguments[0] -eq 'vm') { return '[]' }
            if ($Arguments[0] -eq 'network' -or $Arguments[0] -eq 'consumption') { return $null }
            if ($Arguments[0] -eq 'bicep') { return '{"parameters":{"onPremFleet":{"defaultValue":[]}}}' }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if') {
                $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1].TrimStart('@')
                $global:ArcVaultPreview = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                return
            }
            if ($Arguments[0] -eq 'security' -and $Arguments[2] -eq 'show') { return '{"name":"VirtualMachines","pricingTier":"Free","subPlan":null,"extensions":null}' }
            throw 'Unexpected operation in vault selection preview.'
        }
    }
    AfterEach { Remove-Variable ArcVaultPreview -Scope Global -ErrorAction SilentlyContinue }
    It 'preserves the latest exact-estate vault and its disabled public access, not first prefix match' {
        & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf
        $global:ArcVaultPreview.parameters.keyVaultName.value | Should -Be 'kv-fixture-current'
        $global:ArcVaultPreview.parameters.keyVaultPublicNetworkAccess.value | Should -Be 'Disabled'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'keyvault' -and $Arguments[1] -eq 'secret' }
    }
    It 'blocks ambiguous retained vaults instead of choosing one' {
        Mock Invoke-DemoAz { '[]' } -ParameterFilter { $Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'list' }
        { & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf } | Should -Throw '*no canonical*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if' }
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
    It 'lists what a real wake would do from the network it read, including the tags, under -WhatIf' {
        $global:ArcWakePreview = [System.Collections.Generic.List[string]]::new()
        Mock Write-Step { param($Message) $global:ArcWakePreview.Add($Message) }
        try {
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -WhatIf
            $plan = $global:ArcWakePreview -join "`n"
            $plan | Should -Match 'Public IP pip-natgw-retail-demo: absent -> created'
            $plan | Should -Match 'NAT gateway natgw-retail-demo: absent -> created with that public IP'
            $plan | Should -Match 'carry the lab tags'
            $plan | Should -Match 'one shared wait of up to 12 minutes'
            Should -Invoke Invoke-DemoAz -Times 0
        } finally { Remove-Variable ArcWakePreview -Scope Global -ErrorAction SilentlyContinue }
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
        BeforeEach {
            Mock Import-Module {}
            Mock Initialize-DemoContext {}
            Mock Assert-DemoSkinInventory {}
            Mock Invoke-DemoGuestCommand { throw 'Activate must not call Run Command directly' }
            Mock Invoke-DemoNestedSqlGuest { throw 'No nested guest is configured in this fixture' }
            # Tag writes go through the ARM REST helper; a test must never reach it (and so the real token call) by accident.
            Mock Set-DemoResourceTags { $true }
            # The shared wait has its own tests; here it reports a canned per-host outcome and records how it was called.
            Mock Wait-DemoHostsReady {
                param($Inventory, $NamePrefix, $AttemptStartedUtc, $StartedAtUtc, $DeadlineMinutes, $GuestChecks, $StallMinutes, $RepairStalledAgents, $NestedGuest)
                $f = $global:ArcLifecycleFixture
                $f.waitCalls++
                $f.waitStartedAtUtc = $StartedAtUtc
                $status = if ($f.hostStatus) { $f.hostStatus } else { 'pass' }
                $hosts = @(foreach ($m in $Inventory.Machines) {
                    [ordered]@{ machineName = $m.Name; resourceId = $m.Id; status = $status; method = 'arm+heartbeat'; message = $f.hostMessage; restartedServices = @(); warnings = @() }
                })
                [pscustomobject]@{ Status = $status; Hosts = $hosts; NestedGuest = $f.nestedResult; ElapsedSeconds = 1 }
            }
            Mock Wait-Until { param($Condition) if (-not (& $Condition)) { throw 'Fixture cost/connection check is still pending' } }
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
                    ContainerAppIds = @($f.appIds | Where-Object { $_ }); AksClusterIds = @("$($f.root)/Microsoft.ContainerService/managedClusters/retail-demo-aks"); Resources = $f.resources
                    ParkedMachines = @($f.parkedMachines | Where-Object { $_ }) }
            }
            Mock Get-DemoReadinessChecks { New-DemoCheck 'fixture' '/id' 'parked' 'parked' 'pass' }
            Mock Get-DemoNetworkState {
                $f = $global:ArcLifecycleFixture
                if ($f.networkError) { throw $f.networkError }
                $natId = "$($f.root)/Microsoft.Network/natGateways/natgw-retail-demo"
                $pipId = "$($f.root)/Microsoft.Network/publicIPAddresses/pip-natgw-retail-demo"
                [pscustomobject]@{
                    SafeToRemove = $true
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
            Should -Invoke Wait-DemoHostsReady -Times 1 -Exactly
            Should -Invoke Invoke-DemoGuestCommand -Times 0
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'start' -in $Arguments -or 'create' -in $Arguments -or 'update' -in $Arguments }
            Should -Invoke Invoke-DemoAz -Times 2 -Exactly -ParameterFilter { $Arguments[0] -eq 'aks' -and '-g' -in $Arguments -and '-n' -in $Arguments -and '--ids' -notin $Arguments }
        }
        It 'recreates an absent NAT gateway and public IP, then tags both with the lab tags and the skin overrides' {
            $f = $global:ArcLifecycleFixture
            $f.resources = @(); $f.nat = ''
            $f.events = [System.Collections.Generic.List[string]]::new()
            Mock Get-DemoSkin { @{ tags = @{ owner = 'platform-team'; extra = 'kept' } } }
            Mock Invoke-DemoAz { $global:ArcLifecycleFixture.events.Add("create $($Arguments[1])") } -ParameterFilter { $Arguments[0] -eq 'network' -and 'create' -in $Arguments }
            Mock Set-DemoResourceTags {
                $global:ArcLifecycleFixture.events.Add("tag $(($ResourceId -split '/')[-1])")
                $global:ArcLifecycleFixture.tags = $Tags
                $true
            }
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment
            @($f.events) | Should -Be @('create public-ip', 'create nat', 'tag pip-natgw-retail-demo', 'tag natgw-retail-demo')
            $f.tags.owner | Should -Be 'platform-team'
            $f.tags.extra | Should -Be 'kept'
            $f.tags.purpose | Should -Be 'arc-demo'
            $f.tags.costcenter | Should -Be 'demo'
            $f.tags.env | Should -Be 'demo'
            Should -Invoke Wait-DemoHostsReady -Times 1 -Exactly
        }
        It 'checks the lab tags on a NAT gateway and public IP that already exist without recreating them' {
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment
            Should -Invoke Set-DemoResourceTags -Times 1 -Exactly -ParameterFilter { $ResourceId -like '*/publicIPAddresses/pip-natgw-retail-demo' -and $Tags.purpose -eq 'arc-demo' }
            Should -Invoke Set-DemoResourceTags -Times 1 -Exactly -ParameterFilter { $ResourceId -like '*/natGateways/natgw-retail-demo' -and $Tags.owner -eq 'demo' }
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'create' -in $Arguments }
        }
        It 'warns and keeps waking the estate when the tags cannot be written' {
            Mock Set-DemoResourceTags { throw 'AuthorizationFailed: tags' }
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment -WarningVariable warnings
            ($warnings -join ' ') | Should -Match 'could not be tagged \(AuthorizationFailed: tags\).*cost-allocation metadata only'
            Should -Invoke Wait-DemoHostsReady -Times 1 -Exactly
        }
        It 'never starts or invokes a guest command on an explicit keep-parked VM' {
            $f = $global:ArcLifecycleFixture
            $f.parkedMachines = @([pscustomobject]@{ Name = 'image-parent'; Id = "$($f.root)/Microsoft.Compute/virtualMachines/image-parent"
                KeepParked = $true; Actual = @{ powerState = 'VM deallocated' } })
            Mock Get-DemoSkin { @{ operations = @{ keepParkedVmNames = @('image-parent') } } }
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment
            Should -Invoke Get-DemoInventory -Times 1 -ParameterFilter { $KeepParkedVmNames -contains 'image-parent' }
            Should -Invoke Invoke-DemoGuestCommand -Times 0
            Should -Invoke Wait-DemoHostsReady -Times 1 -Exactly -ParameterFilter { @($Inventory.Machines.Name) -notcontains 'image-parent' }
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { ($Arguments -join ' ') -match 'image-parent' }
        }
        It 'records the shared wait without resubmitting assessments on an already-active retry' {
            $f = $global:ArcLifecycleFixture
            $f.machine.Native = $false
            $f.machine | Add-Member ArcId '/arc/machines/windows-fixture'
            $path = Join-Path $TestDrive 'activation-retry.json'
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -ResultPath $path
            Should -Invoke Wait-DemoHostsReady -Times 1 -Exactly -ParameterFilter { $GuestChecks -eq 'None' -and $DeadlineMinutes -eq 12 -and $StallMinutes -eq 9 -and -not $RepairStalledAgents -and -not $NestedGuest }
            Should -Invoke Invoke-DemoGuestCommand -Times 0
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[1] -eq 'assess-patches' }
            $f.waitStartedAtUtc.Count | Should -Be 0
            $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $report.status | Should -Be 'pass'
            $report.guestCheckMinutes | Should -Be 12
            $report.guestChecksMode | Should -Be 'None'
            $report.nestedGuest | Should -BeNullOrEmpty
            $report.guestChecks.Count | Should -Be 1
            $report.guestChecks[0].restartedServices.Count | Should -Be 0
            $report.guestChecks[0].status | Should -Be 'pass'
            $report.patchAssessments.Count | Should -Be 0
            $report.patchAssessment | Should -Be 'not-required'
            $report.readiness | Should -Be 'skipped'
        }
        It 'reports a failed host and does not submit assessments after guest failure' {
            $f = $global:ArcLifecycleFixture
            $f.machine.Native = $false
            $f.machine | Add-Member ArcId '/arc/machines/windows-fixture'
            $f.hostStatus = 'fail'; $f.hostMessage = 'Required Arc service is not running.'
            $path = Join-Path $TestDrive 'activation-failure.json'
            { & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -ResultPath $path } | Should -Throw '*az-retail-01: Required Arc service is not running*'
            Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[1] -eq 'assess-patches' }
            $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $report.status | Should -Be 'fail'
            $report.guestChecks[0].status | Should -Be 'fail'
        }
        It 'fails activation, with evidence, when the nested guest fails' {
            $f = $global:ArcLifecycleFixture
            $f.nestedResult = [ordered]@{ guestVmName = 'guest'; status = 'fail'; startCommand = 'fail'; message = 'Guest start failed.' }
            $path = Join-Path $TestDrive 'activation-nested-failure.json'
            { & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -ResultPath $path } | Should -Throw '*nested guest guest: Guest start failed*'
            $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $report.status | Should -Be 'fail'
            $report.nestedGuest.startCommand | Should -Be 'fail'
        }
        It 'forwards the start time of a started VM and the opt-in Run Command switches to the shared wait' {
            $f = $global:ArcLifecycleFixture
            $f.machine.Native = $false
            $f.machine | Add-Member ArcId '/arc/machines/windows-fixture'
            $f.machine.Actual.powerState = 'VM deallocated'
            Mock Invoke-DemoAz { $global:ArcLifecycleFixture.machine.Actual.powerState = 'VM running' } -ParameterFilter { $Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'start' }
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment `
                -GuestChecks WhenStalled -GuestCheckMinutes 20 -StallMinutes 7 -RepairStalledAgents
            Should -Invoke Wait-DemoHostsReady -Times 1 -Exactly -ParameterFilter { $GuestChecks -eq 'WhenStalled' -and $DeadlineMinutes -eq 20 -and $StallMinutes -eq 7 -and $RepairStalledAgents }
            $f.waitStartedAtUtc.Count | Should -Be 1
            $f.waitStartedAtUtc[$f.machine.Id] | Should -BeOfType [datetime]
            $f.waitStartedAtUtc[$f.machine.Id].Kind | Should -Be 'Utc'
        }
        It 'records a pending host as a pending activation even without final validation' {
            $f = $global:ArcLifecycleFixture
            $f.hostStatus = 'pending'; $f.hostMessage = 'No Heartbeat generated after VM start within 12 minutes.'
            $path = Join-Path $TestDrive 'activation-host-pending.json'
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -SkipPatchAssessment -ResultPath $path -WarningVariable warnings
            $LASTEXITCODE | Should -Be 0
            $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $report.status | Should -Be 'pending'
            $report.guestChecks[0].status | Should -Be 'pending'
            ($warnings -join ' ') | Should -Match 'telemetry is pending'
        }
        It 'rejects <Case> before inspecting Azure' -TestCases @(
            @{ Case = 'RepairStalledAgents without a Run Command mode'; Arguments = @{ RepairStalledAgents = $true }; Message = '*RepairStalledAgents needs*' }
            @{ Case = 'a stall threshold at or beyond the deadline'; Arguments = @{ GuestChecks = 'WhenStalled'; StallMinutes = 12 }; Message = '*StallMinutes must be less than GuestCheckMinutes*' }
        ) {
            param($Case, $Arguments, $Message)
            { & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo @Arguments } | Should -Throw $Message
            Should -Invoke Initialize-DemoContext -Times 0
        }
        It 'exits zero with explicit telemetry pending instead of failing activation' {
            Mock Get-DemoReadinessChecks { New-DemoCheck 'heartbeat/fixture' '/fixture' 'recent Heartbeat' $false 'pending' }
            $path = Join-Path $TestDrive 'telemetry-pending.json'
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipPatchAssessment -ResultPath $path
            $LASTEXITCODE | Should -Be 0
            $report = Get-Content $path -Raw | ConvertFrom-Json
            $report.status | Should -Be 'pending'
            $report.readiness | Should -Be 'pending'
            $report.readinessChecks[0].id | Should -Be 'heartbeat/fixture'
        }
        It 'does not forgive <Problem> as telemetry lag' -TestCases @(
            @{ Problem = 'an unconnected Arc host'; Id = 'arc/fixture'; Status = 'pending' }
            @{ Problem = 'a missing DCR association'; Id = 'dcra/fixture'; Status = 'fail' }
            @{ Problem = 'a denied inspection'; Id = 'readiness/error'; Status = 'fail' }
        ) {
            param($Problem, $Id, $Status)
            $global:ArcLifecycleFixture.readyId = $Id; $global:ArcLifecycleFixture.readyStatus = $Status
            Mock Get-DemoReadinessChecks { New-DemoCheck $global:ArcLifecycleFixture.readyId '/fixture' 'healthy' $null $global:ArcLifecycleFixture.readyStatus }
            { & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipPatchAssessment } | Should -Throw '*readiness failed*'
        }
        It 'ignores soft extension rows that are not required' {
            Mock Get-DemoReadinessChecks {
                New-DemoCheck 'heartbeat/fixture' '/fixture' 'recent Heartbeat' $true 'pass'
                New-DemoCheck 'extension/fixture/AzureMonitorLinuxAgent' '/fixture/ext' 'Succeeded' 'Updating' 'pending' -Required $false
            }
            $path = Join-Path $TestDrive 'soft-extension.json'
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipPatchAssessment -ResultPath $path
            $LASTEXITCODE | Should -Be 0
            $report = Get-Content $path -Raw | ConvertFrom-Json
            $report.status | Should -Be 'pass'
            $report.readiness | Should -Be 'pass'
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
        It 'records an already-running assessment and continues a default wake without retrying' {
            $f = $global:ArcLifecycleFixture
            $f.machine.Native = $false
            $f.machine | Add-Member ArcId '/arc/machines/windows-fixture'
            $f.machine.Actual.powerState = 'VM deallocated'
            Mock Invoke-DemoAz { $global:ArcLifecycleFixture.machine.Actual.powerState = 'VM running' } -ParameterFilter { $Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'start' }
            Mock Invoke-DemoAz { throw "Azure CLI connectedmachine assess-patches failed (exit 1): WARNING: subscription ignored`nERROR: (OperationConflict) Assess or Patch operation is already running on this resource." } -ParameterFilter { $Arguments[1] -eq 'assess-patches' }
            $path = Join-Path $TestDrive 'assessment-already-running.json'
            & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkipValidate -ResultPath $path -WarningVariable warnings
            $report = Get-Content $path -Raw | ConvertFrom-Json
            $report.status | Should -Be pass
            $report.patchAssessment | Should -Be 'already-in-progress'
            $report.patchAssessments[0].status | Should -Be 'already-in-progress'
            $report.patchAssessments[0].message | Should -Match 'Completion is not verified'
            ($warnings -join ' ') | Should -Match 'already running'
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'assess-patches' }
        }
        It 'does not swallow assessment <Code> errors or an incidental conflict mention' -TestCases @(
            @{ Code = 'AuthorizationFailed' }, @{ Code = 'ResourceNotFound' }, @{ Code = 'InternalServerError' }
        ) {
            param($Code)
            $f = $global:ArcLifecycleFixture
            $f.machine.Native = $false
            $f.machine | Add-Member ArcId '/arc/machines/windows-fixture'
            Mock Invoke-DemoAz { throw "ERROR: ($Code) Real failure; diagnostic text mentions (OperationConflict)." } -ParameterFilter { $Arguments[1] -eq 'assess-patches' }
            $path = Join-Path $TestDrive 'assessment-real-error.json'
            { & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -AssessPatches -SkipValidate -ResultPath $path } | Should -Throw "*$Code*"
            $report = Get-Content $path -Raw | ConvertFrom-Json
            $report.status | Should -Be fail
            $report.patchAssessments[0].status | Should -Be fail
            Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'assess-patches' }
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
        It 'rejects a sharing conflict before activation mutates anything' {
            $global:ArcLifecycleFixture.networkError = 'shared NAT'
            { & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo } | Should -Throw '*shared NAT*'
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
            & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo
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

Describe 'Best-effort Hibernate with real inventory and cost checks' {
    BeforeEach {
        Mock Import-Module {}
        Mock Initialize-DemoContext {}
        InModuleScope Common { $script:DemoSubscription = '11111111-1111-1111-1111-111111111111' }
        $root = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-retail-demo-infra/providers'
        $global:ArcParkFixture = @{
            root = $root; drift = ''; ops = [System.Collections.Generic.List[string]]::new()
            vms = @('node-01', 'node-02' | ForEach-Object { @{ name = $_; id = "$root/Microsoft.Compute/virtualMachines/$_"; powerState = 'VM running'; storageProfile = @{ osDisk = @{ osType = 'Windows' } } } })
            aks = 'Running'; active = $true; nat = $true; pip = $true; attached = $true
        }
        $transport = {
            param($Arguments, $AllowNotFound)
            $f = $global:ArcParkFixture; $root = $f.root
            $f.ops.Add($Arguments -join ' ')
            switch ($Arguments[0..1] -join ' ') {
                'resource list' {
                    return (ConvertTo-Json -Depth 10 -InputObject @(
                        $f.vms | ForEach-Object { @{ id = $_.id; name = $_.name; type = 'Microsoft.Compute/virtualMachines' } }
                        @{ id = "$root/Microsoft.ContainerService/managedClusters/fixture"; type = 'Microsoft.ContainerService/managedClusters' }
                        @{ id = "$root/Microsoft.App/containerApps/fixture"; type = 'Microsoft.App/containerApps' }
                    ))
                }
                'deployment sub' {
                    if ($f.drift -eq 'no manifest') { return '[]' }
                    return (ConvertTo-Json -Depth 15 -InputObject @(@{ properties = @{ outputs = @{ vmFleet = @{ value = @(
                        $f.vms | Where-Object { $f.drift -ne 'unlisted VM' -or $_.name -ne 'node-02' } | ForEach-Object {
                            @{ name = $_.name; deployed = $true; osType = $(if ($f.drift -eq 'OS mismatch') { 'Linux' } else { 'Windows' }); supportsAzureMonitor = $true }
                        }
                    ) } } } }))
                }
                'vm list' {
                    if ($f.denyPower) { throw 'AuthorizationFailed: VM power read denied' }
                    return (ConvertTo-Json -Depth 10 -InputObject $f.vms)
                }
                'vm deallocate' {
                    $id = $Arguments[[array]::IndexOf($Arguments, '--ids') + 1]
                    # Swaps the result file for a folder, so that the write at the end of the run fails.
                    if ($f.sabotagePath -and (Test-Path -LiteralPath $f.sabotagePath -PathType Leaf)) {
                        Remove-Item -LiteralPath $f.sabotagePath -Force
                        New-Item -ItemType Directory -Path $f.sabotagePath | Out-Null
                    }
                    if ($f.failVm -and $id -eq $f.vms[0].id) { throw 'AuthorizationFailed: first VM deallocation denied' }
                    ($f.vms | Where-Object id -eq $id).powerState = 'VM deallocated'; return
                }
                'aks show' { return (@{ name = 'fixture'; provisioningState = 'Succeeded'; powerState = @{ code = $f.aks } } | ConvertTo-Json) }
                'aks stop' { $f.aks = 'Stopped'; return }
                'containerapp revision' {
                    if ($Arguments[2] -eq 'list') { return (ConvertTo-Json -InputObject @(@{ name = 'revision'; properties = @{ active = $f.active } }) -Depth 10) }
                    if ($Arguments[2] -eq 'deactivate') { $f.active = $false; return }
                }
                'network vnet' {
                    if ('update' -in $Arguments) { $f.attached = $false; return }
                    return (@{ id = "$root/Microsoft.Network/virtualNetworks/vnet-retail-demo/subnets/snet-vms"
                        natGateway = @{ id = $(if ($f.drift -eq 'foreign NAT') { '/foreign/nat' } elseif ($f.attached) { "$root/Microsoft.Network/natGateways/natgw-retail-demo" }) } } | ConvertTo-Json)
                }
                'network nat' {
                    if ('delete' -in $Arguments) { $f.nat = $false; return }
                    if ($f.nat) { return (@{ id = "$root/Microsoft.Network/natGateways/natgw-retail-demo" } | ConvertTo-Json) }
                    return $null
                }
                'network public-ip' {
                    if ('delete' -in $Arguments) { $f.pip = $false; return }
                    if ($f.pip) { return (@{ id = "$root/Microsoft.Network/publicIPAddresses/pip-natgw-retail-demo" } | ConvertTo-Json) }
                    return $null
                }
            }
            throw 'Unexpected fixture CLI operation'
        }
        Mock Invoke-DemoAz $transport
        Mock Invoke-DemoAz -ModuleName Common $transport
        Mock Wait-Until { param($Condition) if (-not (& $Condition)) { throw 'Compute remains running' } }
    }
    AfterEach { Remove-Variable ArcParkFixture -Scope Global }
    It 'parks every owned compute workload despite <Drift>' -TestCases @(
        @{ Drift = 'no manifest' }
        @{ Drift = 'unlisted VM' }
        @{ Drift = 'OS mismatch' }
        @{ Drift = 'skin mismatch' }
        @{ Drift = 'foreign NAT' }
    ) {
        param($Drift)
        $f = $global:ArcParkFixture; $f.drift = $Drift
        $skin = Join-Path $TestDrive 'skin.json'
        Set-Content $skin '{"schemaVersion":1,"workloads":{"deployAzureVMs":true}}'
        & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -SkinPath $skin -WarningVariable warnings
        if ($Drift -eq 'skin mismatch') { $warnings -join ' ' | Should -Match 'Skin requires' }
        @($f.vms | Where-Object powerState -ne 'VM deallocated').Count | Should -Be 0
        $f.aks | Should -Be 'Stopped'; $f.active | Should -BeFalse
        if ($Drift -eq 'foreign NAT') {
            $f.nat | Should -BeTrue; $f.pip | Should -BeTrue
            @($f.ops | Where-Object { $_ -match '^network .* (update|delete) ' }).Count | Should -Be 0
        } else {
            $f.nat | Should -BeFalse; $f.pip | Should -BeFalse
            $writes = @($f.ops | Where-Object { $_ -match '^network .* (update|delete) ' })
            $writes[0] | Should -Match 'subnet update'
            $writes[1] | Should -Match 'gateway delete'
            $writes[2] | Should -Match 'public-ip delete'
        }
    }
    It 'keeps preview read-only even when manifests drift' {
        $f = $global:ArcParkFixture; $f.drift = 'no manifest'
        & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -WhatIf
        @($f.ops | Where-Object { $_ -match ' (deallocate|stop|deactivate|delete|update) ' }).Count | Should -Be 0
    }
    It 'parks other compute after one failed deallocation without declaring success' {
        $f = $global:ArcParkFixture; $f.failVm = $true
        { & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo } | Should -Throw '*running*'
        $f.vms[0].powerState | Should -Be 'VM running'
        $f.vms[1].powerState | Should -Be 'VM deallocated'
        $f.aks | Should -Be 'Stopped'; $f.active | Should -BeFalse
        $f.nat | Should -BeTrue
    }
    It 'never calls denied power inspection verified Hibernated' {
        $global:ArcParkFixture.denyPower = $true
        { & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo } | Should -Throw '*AuthorizationFailed*'
    }
    It 'keeps the steps, each VM power state, the revisions, the network outcome and the closing readiness in -ResultPath' {
        $path = Join-Path $TestDrive 'hibernate-result.json'
        & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -ResultPath $path
        $r = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $r.workload | Should -Be 'arc-demo-hibernation'
        $r.status | Should -Be 'pass'
        $r.readiness | Should -Be 'pass'
        $r.error | Should -BeNullOrEmpty
        $r.completedAtUtc | Should -Not -BeNullOrEmpty
        @($r.vms.name) | Should -Be @('node-01', 'node-02')
        @($r.vms | Where-Object { $_.powerStateBefore -eq 'VM running' -and $_.action -eq 'deallocate-submitted' }).Count | Should -Be 2
        $r.aks[0].action | Should -Be 'stop-submitted'
        @($r.containerApps[0].deactivatedRevisions) | Should -Be @('revision')
        $r.network.status | Should -Be 'removed'
        @($r.network.removed) | Should -Be @('subnet association', 'NAT gateway', 'public IP')
        @($r.readinessChecks).Count | Should -BeGreaterThan 0
        ($r.steps.message -join "`n") | Should -Match 'Submitting the deallocation of 2 of 2 VM'
    }
    It 'records a failed deallocation and the closing error in -ResultPath, and still throws' {
        $global:ArcParkFixture.failVm = $true
        $path = Join-Path $TestDrive 'hibernate-failed.json'
        { & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -ResultPath $path } | Should -Throw '*running*'
        $r = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $r.status | Should -Be 'fail'
        $r.error | Should -Match 'running'
        $r.vms[0].action | Should -Be 'deallocate-failed'
        $r.vms[1].action | Should -Be 'deallocate-submitted'
        ($r.warnings -join ' ') | Should -Match 'VM parking failed'
        $r.completedAtUtc | Should -Not -BeNullOrEmpty
    }
    It 'keeps the real error when the result file cannot be written at the end of the run' {
        $f = $global:ArcParkFixture; $f.failVm = $true
        $path = Join-Path $TestDrive 'hibernate-unwritable.json'
        $f.sabotagePath = $path
        $warned = $null
        $thrown = try {
            & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -ResultPath $path -WarningVariable warned -WarningAction SilentlyContinue
        } catch { $_.Exception.Message }
        $thrown | Should -Match 'running'
        $thrown | Should -Not -Match 'could not be written'
        "$warned" | Should -Match 'result file .*hibernate-unwritable\.json could not be written'
    }
    It 'rejects a -ResultPath folder that does not exist before parking anything' {
        $f = $global:ArcParkFixture
        { & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -ResultPath (Join-Path $TestDrive 'missing\result.json') } | Should -Throw '*parent directory must already exist*'
        @($f.ops | Where-Object { $_ -match ' (deallocate|stop|deactivate|delete|update) ' }).Count | Should -Be 0
    }
    It 'prints a progress line before the first Azure read and a time-stamped line for each parking phase' {
        $f = $global:ArcParkFixture
        $f.steps = [System.Collections.Generic.List[string]]::new()
        Mock Write-Step { param($Message) $global:ArcParkFixture.steps.Add($Message) }
        & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo
        $f.steps[0] | Should -Match '^Reading the inventory of rg-retail-demo-infra first'
        $stamped = @($f.steps | Where-Object { $_ -match '^\d\d:\d\d:\d\d ' })
        ($stamped -join "`n") | Should -Match 'Submitting the deallocation of 2 of 2 VM\(s\)'
        ($stamped -join "`n") | Should -Match 'Stopping AKS fixture'
        ($stamped -join "`n") | Should -Match 'Deactivating revision revision of Container App fixture'
        ($stamped -join "`n") | Should -Match 'removing the NAT association, the NAT gateway and the public IP'
        ($stamped -join "`n") | Should -Match 'Verifying the Hibernated state'
    }
    It 'prints what each workload would do under -WhatIf, writes no result file and changes nothing' {
        $f = $global:ArcParkFixture
        $f.steps = [System.Collections.Generic.List[string]]::new()
        Mock Write-Step { param($Message) $global:ArcParkFixture.steps.Add($Message) }
        $path = Join-Path $TestDrive 'hibernate-preview.json'
        & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -WhatIf -ResultPath $path
        Test-Path -LiteralPath $path | Should -BeFalse
        @($f.ops | Where-Object { $_ -match ' (deallocate|stop|deactivate|delete|update) ' }).Count | Should -Be 0
        $plan = $f.steps -join "`n"
        $plan | Should -Match 'VM node-01: VM running -> deallocate'
        $plan | Should -Match 'VM node-02: VM running -> deallocate'
        $plan | Should -Match 'AKS fixture: stopped if it is running'
        $plan | Should -Match 'Container App fixture: active revision\(s\) revision -> deactivate'
        $plan | Should -Match 'Network: after compute has stopped, removed in this order: the subnet association, NAT gateway natgw-retail-demo, public IP pip-natgw-retail-demo'
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
    It 'writes the same JSON to -OutputPath, creating the folder, whatever the display format, and keeps the exit code' {
        Mock Get-DemoReadinessChecks { New-DemoCheck 'fixture' '/expected/id' 'ready' 'starting' 'pending' }
        $file = Join-Path $TestDrive 'evidence\nested\readiness-20260101T000000Z.json'
        $output = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -OutputPath $file
        $LASTEXITCODE | Should -Be 2
        $saved = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        $saved.schemaVersion | Should -Be 1
        $saved.status | Should -Be 'pending'
        $saved.checks[0].id | Should -Be 'fixture'
        ($output -join "`n") | Should -Not -Match 'schemaVersion'
        $jsonOutput = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -OutputFormat Json -OutputPath $file
        ((Get-Content -LiteralPath $file -Raw) | ConvertFrom-Json).status | Should -Be ($jsonOutput | ConvertFrom-Json).status
    }
    It 'writes no file when -OutputPath is not given' {
        Mock Get-DemoReadinessChecks { New-DemoCheck 'fixture' '/expected/id' 'ready' 'ready' 'pass' }
        $cwd = Join-Path $TestDrive 'no-output-path'
        $null = New-Item -ItemType Directory -Path $cwd
        Push-Location $cwd
        try { $null = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -OutputFormat Json }
        finally { Pop-Location }
        @(Get-ChildItem -LiteralPath $cwd -Recurse -File) | Should -HaveCount 0
    }
    It 'resolves a relative -OutputPath against the current location' {
        Mock Get-DemoReadinessChecks { New-DemoCheck 'fixture' '/expected/id' 'ready' 'ready' 'pass' }
        $cwd = Join-Path $TestDrive 'relative-output-path'
        $null = New-Item -ItemType Directory -Path $cwd
        Push-Location $cwd
        try { $null = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -OutputPath '.\out\readiness.json' }
        finally { Pop-Location }
        Test-Path -LiteralPath (Join-Path $cwd 'out\readiness.json') | Should -BeTrue
    }
    It 'returns exit 2 for pending at the zero-second deadline' {
        Mock Get-DemoReadinessChecks { New-DemoCheck 'fixture' '/expected/id' 'ready' 'starting' 'pending' }
        $output = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -OutputFormat Json -TimeoutSeconds 0
        $LASTEXITCODE | Should -Be 2
        ($output | ConvertFrom-Json).status | Should -Be 'pending'
    }
    It 'keeps polling while a required row is pending, even when an unrelated required row has already failed' {
        Mock Get-DemoReadinessChecks {
            New-DemoCheck 'resource/fixture' '/expected/id' 'exists' 'missing' 'fail'
            New-DemoCheck 'heartbeat/fixture' '/expected/id' 'recent Heartbeat' $false 'pending'
        }
        Mock Start-Sleep {}
        $output = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -OutputFormat Json -TimeoutSeconds 1
        $LASTEXITCODE | Should -Be 1
        ($output | ConvertFrom-Json).status | Should -Be 'fail'
        Should -Invoke Get-DemoReadinessChecks -Times 2
    }
    It 'stops at once when no required row is pending' {
        Mock Get-DemoReadinessChecks { New-DemoCheck 'resource/fixture' '/expected/id' 'exists' 'missing' 'fail' }
        Mock Start-Sleep {}
        $null = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -OutputFormat Json -TimeoutSeconds 30
        $LASTEXITCODE | Should -Be 1
        Should -Invoke Get-DemoReadinessChecks -Times 1 -Exactly
    }
    It 'keeps schema and exits compatible for Active' {
        Mock Get-DemoReadinessChecks { New-DemoCheck 'fixture' '/expected/id' 'ready' 'ready' 'pass' }
        $output = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -DesiredState Active -OutputFormat Json
        $LASTEXITCODE | Should -Be 0
        ($output | ConvertFrom-Json).desiredState | Should -Be 'Active'
        Should -Invoke Get-DemoReadinessChecks -Times 1 -ParameterFilter { $DesiredState -eq 'Active' }
    }
    It 'passes with a warning, not pending, when only non-required extension rows are Updating' {
        Mock Get-DemoReadinessChecks {
            New-DemoCheck 'heartbeat/fixture' '/expected/id' 'recent Heartbeat' $true 'pass'
            New-DemoCheck 'extension/fixture/AzureMonitorLinuxAgent' '/expected/id/extensions/x' 'Succeeded' 'Updating' 'pending' -Required $false -Message 'soft'
        }
        $output = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -DesiredState Active -OutputFormat Json -WarningVariable warnings
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json
        $result.status | Should -Be 'pass'
        ($result.checks | Where-Object id -like 'extension/*').required | Should -BeFalse
        ($warnings -join ' ') | Should -Match '1 extension row\(s\) are not Succeeded'
    }
    It 'passes parked compute with explicit incomplete network cost diagnostics' {
        Mock Get-DemoReadinessChecks {
            New-DemoCheck 'vm/fixture/power' '/vm/fixture' 'VM deallocated' 'VM deallocated' 'pass'
            New-DemoCheck 'network/natgw-fixture' '/nat' $false $true 'fail' $false 'Retained network may still bill'
            New-DemoCheck 'network/nat-association' '/subnet' '' '/foreign/nat' 'fail' $false 'Foreign binding untouched'
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
            It 'reports unsafe parked bindings as data without polluting standalone JSON with warnings' {
                $script:networkFixture.subnet.natGateway.id = '/foreign/nat'
                $state = Get-DemoNetworkState -InfraRg rg-retail-demo-infra -NamePrefix retail-demo -ForHibernation -WarningVariable warnings
                $state.SafeToRemove | Should -BeFalse
                $state.ConflictMessage | Should -Match 'unexpected NAT'
                @($warnings).Count | Should -Be 0
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
            It 'checks only parked cost facts, without querying retained monitoring' {
                $checks = @(Get-DemoReadinessChecks -Inventory $script:parkedInventory -NamePrefix retail-demo -DesiredState Hibernated)
                @($checks | Where-Object { $_.required -and $_.status -ne 'pass' }).Count | Should -Be 0
                @($checks | Where-Object id -match 'extension/|dcra/|group/|heartbeat/').Count | Should -Be 0
                Should -Invoke Get-DemoHeartbeatIds -Times 0
                Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -in @('monitor', 'connectedmachine', 'group') }
            }
            It 'still fails mandatory cost checks when expected VM or app state is not parked' {
                $script:parkedInventory.Machines[0].Actual.powerState = 'VM running'
                $script:parkedInventory.ContainerAppIds = @('/containerapps/fixture')
                Mock Invoke-DemoAz { '[{"name":"active","properties":{"active":true}}]' } -ParameterFilter { $Arguments[0] -eq 'containerapp' }
                $checks = @(Get-DemoReadinessChecks -Inventory $script:parkedInventory -NamePrefix retail-demo -DesiredState Hibernated)
                @($checks | Where-Object { $_.required -and $_.status -eq 'pending' }).Count | Should -Be 2
            }
            It 'does not report an unknown VM power state as stopped' {
                $script:parkedInventory.Machines[0].Actual.powerState = $null
                $check = Get-DemoReadinessChecks -Inventory $script:parkedInventory -NamePrefix retail-demo -DesiredState Hibernated | Where-Object id -like 'vm/*'
                $check.status | Should -Be 'fail'
                $check.message | Should -Match 'unknown'
            }
            It 'requires explicitly kept-parked machines to remain deallocated during Active readiness' {
                $script:parkedInventory.Machines = @()
                $script:parkedInventory | Add-Member ParkedMachines @([pscustomobject]@{
                    Name = 'image-parent'; Id = '/vm/image-parent'; KeepParked = $true; Actual = @{ powerState = 'VM deallocated' }
                })
                $check = Get-DemoReadinessChecks -Inventory $script:parkedInventory -NamePrefix retail-demo -DesiredState Active | Where-Object id -like 'vm/*'
                $check.expected | Should -Be 'VM deallocated'
                $check.status | Should -Be pass
                $script:parkedInventory.ParkedMachines[0].Actual.powerState = 'VM running'
                $check = Get-DemoReadinessChecks -Inventory $script:parkedInventory -NamePrefix retail-demo -DesiredState Active | Where-Object id -like 'vm/*'
                $check.status | Should -Be pending
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
            param($Condition, [switch]$AllowTimeout)
            if (& $Condition) { return $true }
            if ($AllowTimeout) { return $false }
            throw 'Owned resources still present.'
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
    It 'does not declare success solely because both groups are gone: it exits pending and says what is left' {
        Mock Get-DemoRemovalChecks { New-DemoCheck 'budget' '/budget' 'absent' 'exists' 'pending' }
        Mock Write-Ok {}
        Mock Write-Warn {}
        & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -Confirm:$false
        $LASTEXITCODE | Should -Be 2
        Should -Invoke Write-Warn -Times 1 -Exactly -ParameterFilter { $Message -like '*still in progress*still present: budget*' }
        Should -Invoke Write-Ok -Times 0 -ParameterFilter { $Message -like 'Removed:*' }
    }
    It 'checks optional identity sharing before deleting policies budget or groups' {
        Mock Invoke-DemoAz { '[{"id":"identity-fixture","displayName":"sp-retail-demo-onboard"}]' } -ParameterFilter { $Arguments[0] -eq 'ad' }
        Mock Invoke-DemoAz { '[{"scope":"/foreign"}]' } -ParameterFilter { $Arguments[0] -eq 'role' }
        { & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -NamePrefix retail-demo -RemoveOnboardingIdentity -Confirm:$false } | Should -Throw '*potentially shared*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'delete' -in $Arguments -or $Arguments[0] -in @('policy', 'consumption', 'group') }
        Should -Invoke Invoke-AzRest -Times 0
    }
}
