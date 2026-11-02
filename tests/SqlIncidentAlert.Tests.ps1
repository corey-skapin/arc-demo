BeforeAll {
    $repo = Split-Path $PSScriptRoot
    $module = Get-Content (Join-Path $repo 'bicep\modules\sql-incident-alert.bicep') -Raw
    $helper = Join-Path $repo 'scripts\Set-SqlIncidentAlert.ps1'
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
}

Describe 'Optional real SQL incident alert contract' {
    It 'uses the distinct Sev2 title and explicit existing route with bounded event detection' {
        $module | Should -Match "name: 'al-\$\{namePrefix\}-sql-lock-timeout'"
        $module | Should -Match "displayName: 'Arc SQL lock timeout - "
        $module | Should -Match 'severity: 2'
        $module | Should -Match "evaluationFrequency: 'PT1M'"
        $module | Should -Match "windowSize: 'PT15M'"
        $module | Should -Match 'scopes: \[workspaceResourceId\]'
        $module | Should -Match 'actionGroups: \[actionGroupId\]'
        $module | Should -Match 'autoMitigate: true'
        $module | Should -Match "timeAggregation: 'Count'"
        $module | Should -Match "operator: 'GreaterThan'"
        $module | Should -Match 'threshold: 0'
        $module | Should -Match 'numberOfEvaluationPeriods: 1'
        $module | Should -Match 'minFailingPeriodsToAlert: 1'
    }

    It 'queries only exact-host structured actual SQL lock-timeout events' {
        $module | Should -Match ([regex]::Escape("| where tolower(_ResourceId) == '{0}'"))
        $module | Should -Match ([regex]::Escape("| where Source == 'ArcSqlEngineDemo' and EventID == 6201"))
        $module | Should -Match ([regex]::Escape('| extend Incident = parse_json(RenderedDescription)'))
        $module | Should -Match ([regex]::Escape('| where toint(Incident.schemaVersion) == 1'))
        $module | Should -Match ([regex]::Escape("| where tostring(Incident.scenario) == 'sql-lock-timeout' and tostring(Incident.state) == 'detected'"))
        $module | Should -Match ([regex]::Escape('| where toint(Incident.sqlErrorNumber) == 1222'))
        $module | Should -Match 'toLower\(machineResourceId\)'
        $module | Should -Not -Match '6200|EventID == 6001|actionGroups@|roleAssignments|extensions@'
    }

    It 'rejects foreign workspace or action group IDs before Azure access' -ForEach @(
        @{ Workspace = '/foreign/workspace'; Group = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-arc-demo/providers/Microsoft.Insights/actionGroups/ag-fixture' }
        @{ Workspace = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-arc-demo/providers/Microsoft.OperationalInsights/workspaces/law-fixture'; Group = '/foreign/group' }
    ) {
        { & $helper -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -MachineName 'sql-fixture' -WorkspaceResourceId $Workspace -ActionGroupId $Group -Action Deploy -WhatIf } |
            Should -Throw '*exact existing workspace and Action Group IDs*'
    }

    It 'previews with the same explicit nested parent and keep-parked selection as lifecycle' {
        Mock Import-Module {}
        Mock Initialize-DemoContext {}
        Mock Assert-DemoSkinInventory {}
        Mock Get-DemoSkin {
            @{ nestedSqlGuest = @{ enabled = $true; parentVmName = 'sql-parent'; guestVmName = 'sql-guest'; arcMachineName = 'sql-guest' }
               operations = @{ keepParkedVmNames = @('image-parent') } }
        }
        Mock Get-DemoInventory {
            [pscustomobject]@{ ArcRg = 'rg-arc-demo'; Machines = @(
                [pscustomobject]@{ Name = 'sql-fixture'; Native = $false; OsType = 'Windows'; ArcId = '/fixture/arc/sql-fixture'
                    Actual = @{ storageProfile = @{ osDisk = @{ osType = 'Windows' } } } }
            ) }
        }
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -ne 'resource' -or $Arguments[1] -ne 'show') { throw 'Preview attempted a mutation.' }
            $id = $Arguments[3]
            if ($id -like '*/scheduledQueryRules/*') { return $null }
            if ($id -like '*/actionGroups/*') {
                return (@{ id = $id; properties = @{ enabled = $true; emailReceivers = @(@{ useCommonAlertSchema = $true }) } } | ConvertTo-Json -Depth 6)
            }
            return (@{ id = $id; location = 'australiaeast' } | ConvertTo-Json)
        }
        $scope = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-arc-demo'
        & $helper -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' `
            -MachineName sql-fixture -WorkspaceResourceId "$scope/providers/Microsoft.OperationalInsights/workspaces/law-fixture" `
            -ActionGroupId "$scope/providers/Microsoft.Insights/actionGroups/ag-fixture" -Action Deploy -WhatIf
        Should -Invoke Get-DemoInventory -Times 1 -ParameterFilter {
            $NestedSqlParentVmName -eq 'sql-parent' -and @($KeepParkedVmNames).Count -eq 1 -and $KeepParkedVmNames[0] -eq 'image-parent'
        }
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -ne 'resource' -or $Arguments[1] -ne 'show' }
    }
}
