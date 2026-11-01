BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\OperationalWorkbooks.psm1') -Force
    $scope = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture'
    $workspaceId = "$scope/providers/Microsoft.OperationalInsights/workspaces/law-fixture"
    $parentId = "$scope/providers/Microsoft.HybridCompute/machines/parent"
    $guestId = "$scope/providers/Microsoft.HybridCompute/machines/guest"
    $machines = @(@{ id = $parentId }, @{ id = $guestId })
}

Describe 'Scoped operational workbook rendering' {
    It 'renders valid exact-ID queries with single-workspace scopes for <Purpose>' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $result = Get-DemoOperationalWorkbook -Purpose $Purpose -WorkspaceResourceId $workspaceId -Machines $machines
        $book = $result.SerializedData | ConvertFrom-Json -Depth 100
        $book.version | Should -Be 'Notebook/1.0'
        $result.SerializedData | Should -Not -Match '__[A-Z_]+__'
        $result.SerializedData | Should -Match 'unclassified'
        $book.fallbackResourceIds | Should -Be @($workspaceId.ToLowerInvariant())
        foreach ($item in @($book.items | Where-Object { $_.type -eq 3 -and $_.content.queryType -eq 0 })) {
            $item.content.crossComponentResources | Should -Be @($workspaceId.ToLowerInvariant())
            $item.content.timeContext.durationMs | Should -Be 2592000000
            $item.content.query | Should -Match 'ResourceId in \(Machines'
            $item.content.query | Should -Not -Match 'startswith|make-series.*default=0'
            $item.content.query | Should -Match '\{LookbackHours\}'
        }
    }

    It 'has stable per-workspace/purpose names, not random duplicates on retry' {
        $one = Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines
        $two = Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId.ToLowerInvariant() -Machines $machines
        $other = Get-DemoOperationalWorkbook -Purpose optimisation -WorkspaceResourceId $workspaceId -Machines $machines
        $one.Name | Should -Be $two.Name
        $one.Name | Should -Not -Be $other.Name
    }

    It 'rejects empty/foreign/duplicate Arc rosters' {
        { Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines @() } | Should -Throw
        { Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines @(@{ id = "$scope/providers/Microsoft.Compute/virtualMachines/parent" }) } | Should -Throw '*Foreign*'
        { Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines @($machines[0], $machines[0]) } | Should -Throw '*duplicate*'
    }

    It 'requires explicit valid topology without guessing host names' {
        $topology = @(@{ resourceId = $parentId; layer = 'parent' }, @{ resourceId = $guestId; layer = 'guest'; parentResourceId = $parentId })
        $book = Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines -Topology $topology
        ($book.Machines | Where-Object layer -eq 'guest').parentResourceId | Should -Be $parentId.ToLowerInvariant()
        { Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines -Topology @($topology[1]) } | Should -Throw '*explicitly classified*'
        { Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines -Topology @(@{ resourceId = $guestId; layer = 'guest'; parentResourceId = $guestId }) } | Should -Throw '*different selected*'
    }

    It 'leaves optional scenario unconfigured by default' {
        $book = (Get-DemoOperationalWorkbook -Purpose optimisation -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
        ($book.items | Where-Object name -eq 'hypothetical-scenario').content.json | Should -Match 'Not configured'
    }

    It 'computes a bounded four-week scenario in decimals without claiming monthly/billed savings' {
        $cost = Get-DemoOperationalScenario -HourlyRate 0.125 -WeeklyHoursOff 80
        $cost.HypotheticalAvoidedCompute | Should -Be 40
        $cost.HypotheticalAvoidedCompute | Should -BeOfType decimal
        (Get-DemoOperationalScenario -HourlyRate 0.1 -WeeklyHoursOff 168).HypotheticalAvoidedCompute | Should -Be 67.2
        (Get-DemoOperationalScenario).HypotheticalAvoidedCompute | Should -Be 0
        { Get-DemoOperationalScenario -HourlyRate -1 } | Should -Throw
        { Get-DemoOperationalScenario -WeeklyHoursOff 169 } | Should -Throw
        $book = (Get-DemoOperationalWorkbook -Purpose optimisation -WorkspaceResourceId $workspaceId -Machines $machines `
            -Topology @(@{ resourceId = $parentId; layer = 'parent' }) -HypotheticalHourlyRate 0.125 `
            -HypotheticalWeeklyHoursOff 80 -HypotheticalMachineResourceId $parentId).SerializedData | ConvertFrom-Json -Depth 100
        ($book.items | Where-Object name -eq 'hypothetical-scenario').content.json | Should -Match '40 hypothetical units.*not a calendar month'
    }

    It 'refuses a guest/unknown-layer/partial hypothetical scenario' {
        { Get-DemoOperationalWorkbook -Purpose optimisation -WorkspaceResourceId $workspaceId -Machines $machines -HypotheticalHourlyRate 1 } | Should -Throw '*Scenario requires*'
        { Get-DemoOperationalWorkbook -Purpose optimisation -WorkspaceResourceId $workspaceId -Machines $machines `
            -HypotheticalHourlyRate 1 -HypotheticalWeeklyHoursOff 40 -HypotheticalMachineResourceId $guestId } | Should -Throw '*Scenario requires*'
    }
}

Describe 'Workbook-only entry point' {
    BeforeAll {
        Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
        $scriptPath = Join-Path $repo 'scripts\Set-OperationalWorkbook.ps1'
    }
    BeforeEach {
        Mock Import-Module {}
        Mock Get-DemoSkin { @{} }
        Mock Initialize-DemoContext {}
        Mock Assert-DemoName {}
        $mockState = @{ existingWorkbook = $null; deploymentParameters = $null; expectedId = ''; deploymentState = 'Succeeded'; readbackDrift = $false }
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'connectedmachine') { return ($machines | ConvertTo-Json -Depth 5 -AsArray) }
            if ($Arguments[0] -eq 'deployment') {
                $mockState.deploymentParameters = Get-Content ($Arguments[10].TrimStart('@')) -Raw | ConvertFrom-Json -Depth 20
                return (@{ properties = @{ provisioningState = $mockState.deploymentState; outputs = @{ workbookResourceId = @{ value = $mockState.expectedId } } } } | ConvertTo-Json -Depth 8)
            }
            if ($Arguments[0] -eq 'resource' -and $Arguments[3] -eq $workspaceId) {
                return (@{ id = $workspaceId; location = 'australiaeast' } | ConvertTo-Json)
            }
            if ($Arguments[0] -eq 'resource') {
                return $mockState.existingWorkbook
            }
            throw "Unexpected CLI operation $($Arguments -join ' ')"
        }
        Mock Invoke-AzRest {
            [pscustomobject]@{ id = $mockState.expectedId; tags = @{ managedBy = 'arc-demo-operational-workbooks' }; properties = @{
                sourceId = $workspaceId; serializedData = if ($mockState.readbackDrift) { '{}' } else { $mockState.deploymentParameters.parameters.serializedData.value }
            } }
        }
        $argsForScript = @{
            SubscriptionId = '11111111-1111-1111-1111-111111111111'; TenantId = '22222222-2222-2222-2222-222222222222'
            Purpose = 'capacity'; WorkspaceResourceId = $workspaceId; NamePrefix = 'fixture'
        }
        $mockState.expectedId = (Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines).ResourceId
    }

    It 'defaults to a read-only preview without any deployment' {
        $result = & $scriptPath @argsForScript
        $result.status | Should -Be preview
        $result.published | Should -BeFalse
        Should -Invoke Initialize-DemoContext -Times 1
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' }
    }

    It 'keeps Deploy WhatIf read-only and never reports publication' {
        $result = & $scriptPath @argsForScript -Action Deploy -WhatIf
        $result.published | Should -BeFalse
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' }
    }

    It 'rejects a foreign existing workbook rather than taking ownership' {
        $mockState.existingWorkbook = @{ id = $mockState.expectedId; kind = 'shared'; tags = @{ managedBy = 'someone-else' }; properties = @{ sourceId = $workspaceId } } | ConvertTo-Json
        { & $scriptPath @argsForScript } | Should -Throw '*ownership/source*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' }
    }

    It 'surfaces denied reads and does not fall back to absent' {
        Mock Invoke-DemoAz { throw 'AuthorizationFailed' }
        { & $scriptPath @argsForScript } | Should -Throw '*AuthorizationFailed*'
    }

    It 'deploys only the workbook module and verifies exact serialized content when approved' {
        $result = & $scriptPath @argsForScript -Action Deploy -Confirm:$false
        $result.published | Should -BeTrue
        Should -Invoke Invoke-DemoAz -Times 1 -ParameterFilter {
            $Arguments[0] -eq 'deployment' -and $Arguments[8] -like '*operational-workbook.bicep'
        }
        Should -Invoke Invoke-AzRest -Times 1 -ParameterFilter {
            $Method -eq 'GET' -and $Url -eq "https://management.azure.com$($mockState.expectedId)?api-version=2023-06-01&canFetchContent=true"
        }
    }

    It 'rejects a metadata-only readback without reporting publication' {
        Mock Invoke-AzRest {
            [pscustomobject]@{ id = $mockState.expectedId; tags = @{ managedBy = 'arc-demo-operational-workbooks' }
                properties = @{ sourceId = $workspaceId; serializedData = $null } }
        }
        { & $scriptPath @argsForScript -Action Deploy -Confirm:$false } | Should -Throw '*readback differs*'
        Should -Invoke Invoke-DemoAz -Times 1 -ParameterFilter { $Arguments[0] -eq 'deployment' }
    }

    It 'updates an owned same-source workbook idempotently rather than duplicating it' {
        $mockState.existingWorkbook = @{
            id = $mockState.expectedId; kind = 'shared'
            tags = @{ managedBy = 'arc-demo-operational-workbooks'; purpose = 'capacity' }
            properties = @{ sourceId = $workspaceId }
        } | ConvertTo-Json -Depth 6
        $result = & $scriptPath @argsForScript -Action Deploy -Confirm:$false
        $result.workbookResourceId | Should -Be $mockState.expectedId
        Should -Invoke Invoke-DemoAz -Times 1 -ParameterFilter { $Arguments[0] -eq 'deployment' }
    }

    It 'fails unknown deployment or content readback without retry or success-shaped output' -ForEach @(
        @{ State = 'Running'; Drift = $false; ExpectedError = '*failed/unknown*' }
        @{ State = 'Succeeded'; Drift = $true; ExpectedError = '*readback differs*' }
    ) {
        $mockState.deploymentState = $State
        $mockState.readbackDrift = $Drift
        { & $scriptPath @argsForScript -Action Deploy -Confirm:$false } | Should -Throw $ExpectedError
        Should -Invoke Invoke-DemoAz -Times 1 -ParameterFilter { $Arguments[0] -eq 'deployment' }
    }

    It 'rejects malformed topology before any Azure operation' {
        $topologyFile = Join-Path $TestDrive 'bad-topology.json'
        '{"schemaVersion":"1","machines":[]}' | Set-Content $topologyFile
        { & $scriptPath @argsForScript -TopologyPath $topologyFile } | Should -Throw '*Topology must contain*'
        Should -Invoke Initialize-DemoContext -Times 0
        Should -Invoke Invoke-DemoAz -Times 0
    }
}
