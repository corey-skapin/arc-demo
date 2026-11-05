BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $script:Repo 'scripts/lib/Common.psm1') -Force
    Import-Module (Join-Path $script:Repo 'scripts/lib/EstateSnapshot.psm1') -Force
    $script:Sub = '11111111-1111-1111-1111-111111111111'
    $script:Ten = '22222222-2222-2222-2222-222222222222'
    $script:Expected = Get-Content (Join-Path $script:Repo 'config/expected-inventory.json') -Raw | ConvertFrom-Json
    $script:AllFeatures = 'ContainerApps', 'NestedSql', 'RealSql', 'OperationalWorkbooks', 'Sre', 'SreAlertGrant'

    function New-Res { param($Name, $Type, $Tags = $null) [ordered]@{ name = $Name; type = $Type; location = 'australiaeast'; tags = $Tags } }
    function New-HealthySnapshot {
        $book = 'Microsoft.Insights/workbooks'
        $operational = @{ managedBy = 'arc-demo-operational-workbooks' }
        $arc = @(
            (New-Res 'law-par-test' 'Microsoft.OperationalInsights/workspaces')
            (New-Res 'dcr-arc-demo' 'Microsoft.Insights/dataCollectionRules')
            (New-Res 'dcr-vminsights' 'Microsoft.Insights/dataCollectionRules')
            (New-Res 'dcr-changetracking' 'Microsoft.Insights/dataCollectionRules')
            (New-Res 'ag-par-test' 'Microsoft.Insights/actionGroups')
            (New-Res 'alert-par-test-host-missing-heartbeat' 'Microsoft.Insights/scheduledQueryRules')
            (New-Res 'al-par-test-sql-lock-timeout' 'Microsoft.Insights/scheduledQueryRules')
            (New-Res 'alert-par-test-lob-arc-app-fault' 'Microsoft.Insights/scheduledQueryRules')
            (New-Res 'guest-vm' 'Microsoft.AzureArcData/sqlServerInstances')
        ) + @(1..6 | ForEach-Object { New-Res "estate-$_" $book @{ workbookTag = "w$_" } }) + @(1..2 | ForEach-Object { New-Res "operational-$_" $book $operational })
        $infra = @(
            (New-Res 'vnet-par-test' 'Microsoft.Network/virtualNetworks')
            (New-Res 'nsg-par-test' 'Microsoft.Network/networkSecurityGroups')
            (New-Res 'natgw-par-test' 'Microsoft.Network/natGateways')
            (New-Res 'pip-natgw-par-test' 'Microsoft.Network/publicIPAddresses')
            (New-Res 'kv-partest-abc123' 'Microsoft.KeyVault/vaults')
            (New-Res 'shutdown-computevm-win-a' 'Microsoft.DevTestLab/schedules')
            (New-Res 'ca-par-test-fault' 'Microsoft.App/containerApps')
            (New-Res 'alert-par-test-containerapp-restarts' 'Microsoft.Insights/metricAlerts')
        )
        $sre = @(
            (New-Res 'sre-par-test' 'Microsoft.App/agents')
            (New-Res 'sre-par-test-uami' 'Microsoft.ManagedIdentity/userAssignedIdentities')
            (New-Res 'sre-par-test-appi' 'Microsoft.Insights/components')
        )
        $ok = { param($data) [ordered]@{ status = 'ok'; data = $data } }
        $names = 'win-a', 'lnx-a', 'parent-vm'
        $snapshot = [ordered]@{
            schemaVersion = 1; workload = 'arc-demo-inventory'; capturedAtUtc = '2026-11-02T00:00:00.0000000Z'
            subscriptionId = $script:Sub; tenantId = $script:Ten; namePrefix = 'par-test'
            sections = [ordered]@{
                groups = & $ok ([ordered]@{
                    arc = [ordered]@{ name = 'rg-par-test'; exists = $true; resources = $arc }
                    infra = [ordered]@{ name = 'rg-par-test-infra'; exists = $true; resources = $infra }
                    sre = [ordered]@{ name = 'rg-par-test-sre'; exists = $true; resources = $sre } })
                vms = & $ok @($names | ForEach-Object { [ordered]@{ name = $_; size = 'Standard_B2as_v2'; powerState = 'VM running'; osType = 'Windows'; osDiskSku = 'StandardSSD_LRS'; dataDisks = @() } })
                arcMachines = & $ok @(@($names) + 'guest-vm' | ForEach-Object { [ordered]@{ name = $_; status = 'Connected'; osType = 'windows'; agentVersion = '1.0' } })
                dcrAssociations = & $ok @()
                alerts = & $ok ([ordered]@{ scheduledQueryRules = @(); metricAlerts = @() })
                workbooks = & $ok @()
                workspace = & $ok ([ordered]@{ found = $true })
                keyVaults = & $ok ([ordered]@{ vaults = @(); softDeleted = @() })
                subscription = & $ok ([ordered]@{
                    policyAssignments = @('mcsb-par-test', 'nist-par-test'); budgets = @('budget-par-test')
                    defender = @([ordered]@{ name = 'VirtualMachines'; tier = 'Standard'; subPlan = 'P2' }, [ordered]@{ name = 'Containers'; tier = 'Free'; subPlan = $null }) })
                onboardingApp = & $ok ([ordered]@{ found = $true; credentials = @([ordered]@{ displayName = 'rbac'; keyId = 'k1'; startDateTime = '2026-10-09T00:00:00Z'; endDateTime = '2027-10-09T00:00:00Z' }) })
                sre = & $ok ([ordered]@{ exists = $true; identities = @([ordered]@{ name = 'sre-par-test-uami'; roleAssignments = @(
                    [ordered]@{ role = 'Contributor'; scope = "/subscriptions/$script:Sub/resourceGroups/rg-par-test" }
                    [ordered]@{ role = 'Monitoring Contributor'; scope = "/subscriptions/$script:Sub" }) }) })
                fleet = & $ok ([ordered]@{ deployment = 'arc-demo-20261102'; machines = @($names | ForEach-Object { [ordered]@{ name = $_; osType = 'Windows' } }) })
            }
        }
        $snapshot | ConvertTo-Json -Depth 14 | ConvertFrom-Json
    }
    function Invoke-Parity {
        param($Snapshot, [string[]]$Feature = $script:AllFeatures, [string[]]$KeepParked = @())
        Test-DemoEstateParity -Snapshot $Snapshot -Expected $script:Expected -NamePrefix 'par-test' -Feature $Feature `
            -NestedParentVmName 'parent-vm' -NestedArcMachineName 'guest-vm' -KeepParkedVmNames $KeepParked
    }
    function Get-Failed { param($Result) @($Result.checks | Where-Object status -eq 'fail' | ForEach-Object id) }
}

Describe 'Expected-object list' {
    It 'has unique ids, known groups, kinds and features' {
        $ids = @($script:Expected.rules | ForEach-Object id)
        $ids | Should -HaveCount @($ids | Select-Object -Unique).Count
        foreach ($rule in $script:Expected.rules) {
            $kind = $rule.PSObject.Properties['kind']
            if ($kind) { $kind.Value | Should -BeIn @('policy', 'budget', 'defender', 'identityRole', 'onboardingApp', 'noOneDayCredentials') }
            else {
                $rule.group | Should -BeIn @('arc', 'infra', 'sre')
                $rule.type | Should -Match '^Microsoft\.[A-Za-z]+/[A-Za-z]+$'
                ($rule.PSObject.Properties.Name -contains 'name' -or $rule.PSObject.Properties.Name -contains 'count' -or $rule.PSObject.Properties.Name -contains 'min') | Should -BeTrue
            }
            $feature = $rule.PSObject.Properties['feature']
            if ($feature) { $feature.Value | Should -BeIn $script:AllFeatures }
        }
    }

    It 'holds only synthetic placeholders, no real identifiers' {
        (Get-Content (Join-Path $script:Repo 'config/expected-inventory.json') -Raw) | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|@'
    }
}

Describe 'Parity evaluation' {
    It 'passes a healthy Active estate with every feature enabled' {
        $result = Invoke-Parity (New-HealthySnapshot)
        Get-Failed $result | Should -HaveCount 0
        $result.status | Should -Be 'pass'
        ($result.checks | Where-Object id -eq 'infra/one-key-vault').expected | Should -Match 'exactly 1'
        ($result.checks | Where-Object id -eq 'fleet/parent-vm/arc') | Should -Not -BeNullOrEmpty
    }

    It 'fails when <Name>' -TestCases @(
        @{ Name = 'the workspace is missing'; Expect = 'arc/workspace'; Change = { param($s) $s.sections.groups.data.arc.resources = @($s.sections.groups.data.arc.resources | Where-Object name -ne 'law-par-test') } }
        @{ Name = 'a second Key Vault exists'; Expect = 'infra/one-key-vault'; Change = { param($s) $s.sections.groups.data.infra.resources += [pscustomobject]@{ name = 'kv-other'; type = 'Microsoft.KeyVault/vaults'; location = 'x'; tags = $null } } }
        @{ Name = 'a private endpoint was left behind'; Expect = 'infra/no-private-endpoints'; Change = { param($s) $s.sections.groups.data.infra.resources += [pscustomobject]@{ name = 'pe'; type = 'Microsoft.Network/privateEndpoints'; location = 'x'; tags = $null } } }
        @{ Name = 'a private DNS zone was left behind'; Expect = 'infra/no-private-dns-zones'; Change = { param($s) $s.sections.groups.data.infra.resources += [pscustomobject]@{ name = 'z'; type = 'Microsoft.Network/privateDnsZones'; location = 'x'; tags = $null } } }
        @{ Name = 'workbooks are missing'; Expect = 'arc/workbooks'; Change = { param($s) $s.sections.groups.data.arc.resources = @($s.sections.groups.data.arc.resources | Where-Object type -ne 'Microsoft.Insights/workbooks') } }
        @{ Name = 'an operational workbook is missing'; Expect = 'arc/operational-workbooks'; Change = { param($s) $s.sections.groups.data.arc.resources = @($s.sections.groups.data.arc.resources | Where-Object name -ne 'operational-2') } }
        @{ Name = 'the NAT gateway is gone (a parked estate)'; Expect = 'infra/nat-gateway'; Change = { param($s) $s.sections.groups.data.infra.resources = @($s.sections.groups.data.infra.resources | Where-Object type -ne 'Microsoft.Network/natGateways') } }
        @{ Name = 'the SQL alert is missing'; Expect = 'arc/sql-alert'; Change = { param($s) $s.sections.groups.data.arc.resources = @($s.sections.groups.data.arc.resources | Where-Object name -ne 'al-par-test-sql-lock-timeout') } }
        @{ Name = 'the SRE agent group is absent'; Expect = 'sre/agent'; Change = { param($s) $s.sections.groups.data.sre.exists = $false } }
        @{ Name = 'a manifest host has no VM'; Expect = 'fleet/win-a/vm'; Change = { param($s) $s.sections.vms.data = @($s.sections.vms.data | Where-Object name -ne 'win-a') } }
        @{ Name = 'a manifest host has no Arc machine'; Expect = 'fleet/lnx-a/arc'; Change = { param($s) $s.sections.arcMachines.data = @($s.sections.arcMachines.data | Where-Object name -ne 'lnx-a') } }
        @{ Name = 'the nested guest is not an Arc machine'; Expect = 'fleet/nested-guest'; Change = { param($s) $s.sections.arcMachines.data = @($s.sections.arcMachines.data | Where-Object name -ne 'guest-vm') } }
        @{ Name = 'an unexpected VM exists'; Expect = 'fleet/no-extra-vms'; Change = { param($s) $s.sections.vms.data += [pscustomobject]@{ name = 'stray-vm'; size = 'x' } } }
        @{ Name = 'no deployment manifest lists the fleet'; Expect = 'fleet/manifest'; Change = { param($s) $s.sections.fleet.data.machines = @() } }
        @{ Name = 'Defender for Servers is not Standard'; Expect = 'subscription/defender-servers'; Change = { param($s) $s.sections.subscription.data.defender[0].tier = 'Free' } }
        @{ Name = 'a policy assignment is missing'; Expect = 'subscription/policy-nist'; Change = { param($s) $s.sections.subscription.data.policyAssignments = @('mcsb-par-test') } }
        @{ Name = 'the budget is missing'; Expect = 'subscription/budget'; Change = { param($s) $s.sections.subscription.data.budgets = @() } }
        @{ Name = 'the onboarding application is missing'; Expect = 'tenant/onboarding-app'; Change = { param($s) $s.sections.onboardingApp.data.found = $false } }
        @{ Name = 'a one-day build credential was left behind'; Expect = 'tenant/no-residual-credentials'
            Change = { param($s) $s.sections.onboardingApp.data.credentials += [pscustomobject]@{ displayName = 'nested-guest-1'; keyId = 'k2'; startDateTime = '2026-11-02T00:00:00Z'; endDateTime = '2026-11-03T00:00:00Z' } } }
        @{ Name = 'the alert-access grant is missing'; Expect = 'subscription/alert-access-grant'; Change = { param($s) $s.sections.sre.data.identities[0].roleAssignments = @($s.sections.sre.data.identities[0].roleAssignments | Where-Object role -ne 'Monitoring Contributor') } }
        @{ Name = 'the alert-access grant is duplicated'; Expect = 'subscription/alert-access-grant'
            Change = { param($s) $s.sections.sre.data.identities[0].roleAssignments += [pscustomobject]@{ role = 'Monitoring Contributor'; scope = "/subscriptions/$($s.subscriptionId)" } } }
    ) {
        param($Expect, $Change)
        $snapshot = New-HealthySnapshot
        & $Change $snapshot
        $result = Invoke-Parity $snapshot
        Get-Failed $result | Should -Contain $Expect
        $result.status | Should -Be 'fail'
    }

    It 'allows the nested parent and explicitly kept-parked VMs, and ignores rules for features that are off' {
        $snapshot = New-HealthySnapshot
        $snapshot.sections.vms.data += [pscustomobject]@{ name = 'kept-parked'; size = 'x' }
        Get-Failed (Invoke-Parity $snapshot) | Should -Contain 'fleet/no-extra-vms'
        Get-Failed (Invoke-Parity $snapshot -KeepParked 'kept-parked') | Should -HaveCount 0
        $plain = New-HealthySnapshot
        $plain.sections.groups.data.sre.exists = $false
        $plain.sections.groups.data.infra.resources = @($plain.sections.groups.data.infra.resources | Where-Object { $_.type -notin 'Microsoft.App/containerApps', 'Microsoft.Insights/metricAlerts' })
        $plain.sections.groups.data.arc.resources = @($plain.sections.groups.data.arc.resources | Where-Object { $_.name -notlike 'al-*' -and $_.name -notlike '*lob*' -and $_.tags -eq $null -or $_.type -eq 'Microsoft.Insights/workbooks' -and $_.name -notlike 'operational-*' })
        Get-Failed (Invoke-Parity $plain -Feature @('NestedSql')) | Should -Not -Contain 'sre/agent'
    }

    It 'allows the Azure-native VMs the manifest names and fails when one is missing' {
        $snapshot = New-HealthySnapshot
        $snapshot.sections.vms.data += [pscustomobject]@{ name = 'az-par-01'; size = 'x' }
        $snapshot.sections.fleet.data | Add-Member -NotePropertyName azureVmNames -NotePropertyValue @('az-par-01')
        Get-Failed (Invoke-Parity $snapshot) | Should -HaveCount 0
        $snapshot.sections.vms.data = @($snapshot.sections.vms.data | Where-Object name -ne 'az-par-01')
        Get-Failed (Invoke-Parity $snapshot) | Should -Contain 'fleet/az-par-01/vm'
    }

    It 'expects the core data collection rule under the literal name Bicep gives it, whatever the prefix' {
        (Get-Content (Join-Path $script:Repo 'bicep/modules/dcrs.bicep') -Raw) | Should -Match "dcrCoreName = 'dcr-arc-demo'"
        $snapshot = New-HealthySnapshot
        $snapshot.sections.groups.data.arc.resources = @($snapshot.sections.groups.data.arc.resources | Where-Object name -ne 'dcr-arc-demo')
        Get-Failed (Invoke-Parity $snapshot) | Should -Contain 'arc/dcr-core'
    }

    It 'finds a leftover one-day credential on a snapshot read back from JSON, in <Culture>' -TestCases @(
        @{ Culture = 'en-US' }, @{ Culture = 'en-AU' }, @{ Culture = 'en-GB' }, @{ Culture = 'de-DE' }
    ) {
        param($Culture)
        try { $info = [cultureinfo]::GetCultureInfo($Culture) } catch { Set-ItResult -Skipped -Because "culture $Culture is not available on this machine"; return }
        $snapshot = New-HealthySnapshot
        $snapshot.sections.onboardingApp.data.credentials += [pscustomobject]@{ displayName = 'nested-guest-1'; keyId = 'k2'; startDateTime = '2026-11-02T00:00:00Z'; endDateTime = '2026-11-03T00:00:00Z' }
        $snapshot = $snapshot | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        $snapshot.sections.onboardingApp.data.credentials[1].startDateTime | Should -BeOfType [datetime]
        $previous = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $info
            Get-Failed (Invoke-Parity $snapshot) | Should -Contain 'tenant/no-residual-credentials'
            $healthy = New-HealthySnapshot
            Get-Failed (Invoke-Parity $healthy) | Should -Not -Contain 'tenant/no-residual-credentials'
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $previous }
    }

    Context 'Arc machine tags' {
        BeforeEach {
            $script:tagged = New-HealthySnapshot
            foreach ($machine in $script:tagged.sections.fleet.data.machines) {
                $machine | Add-Member -NotePropertyName role -NotePropertyValue 'app' -Force
                $machine | Add-Member -NotePropertyName osTier -NotePropertyValue 'WS2022' -Force
            }
            foreach ($arc in $script:tagged.sections.arcMachines.data) {
                $arc | Add-Member -NotePropertyName tags -NotePropertyValue ([pscustomobject]@{ role = 'app'; osTier = 'WS2022'; owner = 'demo' }) -Force
            }
        }
        It 'passes when every manifest host carries the manifest role and osTier' {
            $result = Invoke-Parity $script:tagged
            Get-Failed $result | Should -HaveCount 0
            @($result.checks | Where-Object id -like 'fleet/*/tags') | Should -HaveCount 3
            ($result.checks | Where-Object id -eq 'fleet/win-a/tags').observed | Should -Be 'role=app, osTier=WS2022'
        }
        It 'fails the host whose tags were folded into one value, and says what was found' {
            $script:tagged.sections.arcMachines.data[0].tags = [pscustomobject]@{ owner = 'demo purpose=arc-demo role=app osTier=WS2022' }
            $failed = Get-Failed (Invoke-Parity $script:tagged)
            $failed | Should -Be @('fleet/win-a/tags')
            (Invoke-Parity $script:tagged).checks | Where-Object id -eq 'fleet/win-a/tags' | ForEach-Object { $_.observed | Should -Be 'role=(missing), osTier=(missing)' }
        }
        It 'fails a wrong value, treating a tag name as case-insensitive and a value as exact' {
            $script:tagged.sections.arcMachines.data[1].tags = [pscustomobject]@{ ROLE = 'app'; ostier = 'ws2022' }
            Get-Failed (Invoke-Parity $script:tagged) | Should -Be @('fleet/lnx-a/tags')
        }
        It 'fails a host that has no tags at all' {
            $script:tagged.sections.arcMachines.data[0].tags = $null
            Get-Failed (Invoke-Parity $script:tagged) | Should -Be @('fleet/win-a/tags')
        }
        It 'cannot judge a snapshot that predates tag capture or a manifest without role and osTier' {
            foreach ($arc in $script:tagged.sections.arcMachines.data) { $arc.PSObject.Properties.Remove('tags') }
            @((Invoke-Parity $script:tagged).checks | Where-Object id -like 'fleet/*/tags') | Should -HaveCount 0
            $older = New-HealthySnapshot
            foreach ($arc in $older.sections.arcMachines.data) { $arc | Add-Member -NotePropertyName tags -NotePropertyValue ([pscustomobject]@{ owner = 'demo' }) -Force }
            @((Invoke-Parity $older).checks | Where-Object id -like 'fleet/*/tags') | Should -HaveCount 0
        }
    }

    It 'reports an unreadable snapshot section as failed checks with the exact error' {
        $snapshot = New-HealthySnapshot
        $snapshot.sections.subscription = [pscustomobject]@{ status = 'error'; error = '(AuthorizationFailed) denied for the test' }
        $result = Invoke-Parity $snapshot
        Get-Failed $result | Should -Contain 'snapshot/subscription'
        Get-Failed $result | Should -Contain 'subscription/budget'
        (($result.checks | Where-Object id -eq 'snapshot/subscription').message) | Should -Match 'AuthorizationFailed'
        $missing = New-HealthySnapshot
        $missing.sections.PSObject.Properties.Remove('fleet')
        Get-Failed (Invoke-Parity $missing) | Should -Contain 'snapshot/fleet'
    }
}

Describe 'Snapshot collection' {
    BeforeEach {
        $script:Az = [System.Collections.Generic.List[string]]::new()
        $script:Rest = [System.Collections.Generic.List[string]]::new()
        Mock Initialize-DemoContext {} -ModuleName EstateSnapshot
        Mock Invoke-AzRest {
            $script:Rest.Add("$Method $Url")
            if ($Url -like '*scheduledQueryRules*') { return [pscustomobject]@{ value = @([pscustomobject]@{ name = 'alert-par-test-host-missing-heartbeat'; properties = [pscustomobject]@{ enabled = $true; severity = 2; evaluationFrequency = 'PT5M'; windowSize = 'PT15M' } }) } }
            if ($Url -like '*metricAlerts*') { return [pscustomobject]@{ value = @() } }
            if ($Url -like '*workbooks*') { return [pscustomobject]@{ value = @([pscustomobject]@{ name = 'w1'; properties = [pscustomobject]@{ displayName = 'Estate' }; tags = [pscustomobject]@{ workbookTag = 'estate' } }) } }
            if ($Url -like '*deletedWorkspaces*') { return [pscustomobject]@{ value = @([pscustomobject]@{ name = 'law-par-test' }) } }
            if ($Url -like '*roleAssignments*') {
                return [pscustomobject]@{ value = @(
                    [pscustomobject]@{ properties = [pscustomobject]@{ roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/749f88d5-cbae-40b8-bcfc-e573ddc772fa'; scope = "/subscriptions/$script:Sub" } }
                    [pscustomobject]@{ properties = [pscustomobject]@{ roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-00000000abcd'; scope = '/x' } }) }
            }
            throw "Unexpected REST call: $Method $Url"
        } -ModuleName EstateSnapshot
        Mock Invoke-DemoAz {
            $script:Az.Add(($Arguments[0..2] -join ' '))
            switch -Wildcard (($Arguments[0..1] -join ' ')) {
                'group exists' { return $(if ($Arguments[3] -like '*-sre') { 'false' } else { 'true' }) }
                'resource list' { return '[{"name":"law-par-test","type":"Microsoft.OperationalInsights/workspaces","location":"australiaeast","tags":null}]' }
                'vm list' { return '[{"name":"win-a","hardwareProfile":{"vmSize":"Standard_B2as_v2"},"powerState":"VM running","storageProfile":{"osDisk":{"osType":"Windows","managedDisk":{"storageAccountType":"StandardSSD_LRS"}},"dataDisks":[{"lun":0,"diskSizeGb":128,"managedDisk":{"storageAccountType":"StandardSSD_LRS"}}]}}]' }
                'connectedmachine list' { return '[{"name":"win-a","status":"Connected","osType":"windows","agentVersion":"1.0","tags":{"role":"app","osTier":"WS2022","owner":"demo"}}]' }
                'monitor data-collection' { return '[{"dataCollectionRuleId":"/subscriptions/x/resourceGroups/rg/providers/Microsoft.Insights/dataCollectionRules/dcr-par-test"}]' }
                'monitor log-analytics' { return '{"retentionInDays":30,"sku":{"name":"PerGB2018"},"workspaceCapping":{"dailyQuotaGb":-1}}' }
                'keyvault list' { return '[{"name":"kv-partest-abc123","properties":{"publicNetworkAccess":"Enabled"}}]' }
                'keyvault list-deleted' { return '[{"name":"kv-partest-old","properties":{"scheduledPurgeDate":"2027-01-01"}},{"name":"kv-other-old","properties":{}}]' }
                'policy assignment' { return $(if ($Arguments[4] -like 'mcsb-*') { '{"name":"mcsb-par-test"}' } else { $null }) }
                'consumption budget' { return '{"name":"budget-par-test"}' }
                'security pricing' { return '{"value":[{"name":"VirtualMachines","pricingTier":"Standard","subPlan":"P2"}]}' }
                'ad app' { return '[{"displayName":"sp-par-test-onboard","passwordCredentials":[{"displayName":"rbac","keyId":"k1","startDateTime":"2026-10-09T00:00:00Z","endDateTime":"2027-10-09T00:00:00Z","secretText":"must-not-be-copied"}]},{"displayName":"sp-par-test-onboard-other","passwordCredentials":[]}]' }
                'identity list' { return '[{"name":"sre-par-test-uami","principalId":"44444444-4444-4444-4444-444444444444"}]' }
                'deployment sub' { return '[{"name":"old","properties":{"provisioningState":"Succeeded","timestamp":"2026-10-01T00:00:00Z","outputs":{"arcResourceGroup":{"value":"rg-par-test"},"vmFleet":{"value":[{"name":"old-host","deployed":true}]}}}},{"name":"new","properties":{"provisioningState":"Succeeded","timestamp":"2026-11-01T00:00:00Z","outputs":{"arcResourceGroup":{"value":"rg-par-test"},"azureVmNames":{"value":["az-par-01"]},"vmFleet":{"value":[{"name":"win-a","osType":"Windows","role":"app","osTier":"WS2022","deployed":true},{"name":"skipped","deployed":false}]}}}},{"name":"other","properties":{"provisioningState":"Succeeded","timestamp":"2026-11-02T00:00:00Z","outputs":{"arcResourceGroup":{"value":"rg-other"},"vmFleet":{"value":[{"name":"x","deployed":true}]}}}}]' }
                default { throw "Unexpected az call: $($Arguments -join ' ')" }
            }
        } -ModuleName EstateSnapshot
    }

    It 'reads the estate with list, show and get calls only, and keeps secrets out' {
        $snapshot = Get-DemoEstateSnapshot -SubscriptionId $script:Sub -TenantId $script:Ten -NamePrefix 'par-test'
        @($snapshot.sections.Values | Where-Object status -ne 'ok') | Should -HaveCount 0
        $script:Az | ForEach-Object { $_ | Should -Match '^(group exists|resource list|vm list|connectedmachine list|monitor data-collection|monitor log-analytics|keyvault list|policy assignment|consumption budget|security pricing|ad app|identity list|deployment sub)' }
        $script:Rest | ForEach-Object { $_ | Should -Match '^Get ' }
        $json = $snapshot | ConvertTo-Json -Depth 14
        $json | Should -Not -Match 'must-not-be-copied|secretText'
        $snapshot.subscriptionId | Should -Be $script:Sub
        $snapshot.sections.groups.data.arc.resources[0].name | Should -Be 'law-par-test'
        $snapshot.sections.vms.data[0].dataDisks[0].sizeGb | Should -Be 128
        $snapshot.sections.dcrAssociations.data[0].rules | Should -Be @('dcr-par-test')
        $snapshot.sections.workspace.data.softDeleted | Should -Be @('law-par-test')
        $snapshot.sections.keyVaults.data.softDeleted.name | Should -Be @('kv-partest-old')
        $snapshot.sections.subscription.data.policyAssignments | Should -Be @('mcsb-par-test')
        $snapshot.sections.subscription.data.defender[0].tier | Should -Be 'Standard'
        $snapshot.sections.onboardingApp.data.credentials[0].displayName | Should -Be 'rbac'
        $snapshot.sections.fleet.data.deployment | Should -Be 'new'
        $snapshot.sections.fleet.data.machines.name | Should -Be @('win-a')
        $snapshot.sections.fleet.data.machines[0].role | Should -Be 'app'
        $snapshot.sections.fleet.data.machines[0].osTier | Should -Be 'WS2022'
        $snapshot.sections.arcMachines.data[0].tags.role | Should -Be 'app'
        $snapshot.sections.arcMachines.data[0].tags.osTier | Should -Be 'WS2022'
        $snapshot.sections.fleet.data.azureVmNames | Should -Be @('az-par-01')
    }

    It 'does not list resources in a group that does not exist and records an absent SRE layer' {
        $snapshot = Get-DemoEstateSnapshot -SubscriptionId $script:Sub -TenantId $script:Ten -NamePrefix 'par-test'
        $snapshot.sections.groups.data.sre.exists | Should -BeFalse
        $snapshot.sections.sre.data.exists | Should -BeFalse
        @($script:Az | Where-Object { $_ -eq 'resource list -g' }) | Should -HaveCount 2
    }

    It 'maps SRE role assignments to names and keeps unknown roles as IDs' {
        Mock Invoke-DemoAz {
            if (($Arguments[0..1] -join ' ') -eq 'group exists') { return 'true' }
            if (($Arguments[0..1] -join ' ') -eq 'identity list') { return '[{"name":"sre-par-test-uami","principalId":"44444444-4444-4444-4444-444444444444"}]' }
            if (($Arguments[0..1] -join ' ') -eq 'resource list') { return '[]' }
            return '[]'
        } -ModuleName EstateSnapshot
        $snapshot = Get-DemoEstateSnapshot -SubscriptionId $script:Sub -TenantId $script:Ten -NamePrefix 'par-test'
        $assignments = $snapshot.sections.sre.data.identities[0].roleAssignments
        $assignments[0].role | Should -Be 'Monitoring Contributor'
        $assignments[0].scope | Should -Be "/subscriptions/$script:Sub"
        $assignments[1].role | Should -Be '00000000-0000-0000-0000-00000000abcd'
        @($script:Rest | Where-Object { $_ -like '*roleAssignments*' }) | Should -Not -BeNullOrEmpty
        $script:Rest | Where-Object { $_ -like '*roleAssignments*' } | Should -BeLike '*principalId%20eq%20*44444444-4444-4444-4444-444444444444*'
    }

    It 'records a denied read verbatim in its own section and keeps reading the rest' {
        Mock Invoke-DemoAz {
            if (($Arguments[0..1] -join ' ') -eq 'group exists') { return 'false' }
            if (($Arguments[0..1] -join ' ') -eq 'keyvault list-deleted') { throw 'Azure CLI keyvault list-deleted failed (exit 1): (AuthorizationFailed) denied for the test' }
            if (($Arguments[0..1] -join ' ') -eq 'policy assignment') { return $null }
            if (($Arguments[0..1] -join ' ') -eq 'consumption budget') { return $null }
            if (($Arguments[0..1] -join ' ') -eq 'security pricing') { return '[]' }
            if (($Arguments[0..1] -join ' ') -eq 'ad app') { return '[]' }
            return '[]'
        } -ModuleName EstateSnapshot
        $snapshot = Get-DemoEstateSnapshot -SubscriptionId $script:Sub -TenantId $script:Ten -NamePrefix 'par-test'
        $snapshot.sections.keyVaults.status | Should -Be 'error'
        $snapshot.sections.keyVaults.error | Should -Match 'AuthorizationFailed'
        $snapshot.sections.groups.status | Should -Be 'ok'
        $snapshot.sections.onboardingApp.data.found | Should -BeFalse
        $snapshot.sections.subscription.data.budgets | Should -HaveCount 0
    }
}

Describe 'Snapshot and parity scripts' {
    BeforeAll {
        $script:Export = Join-Path $script:Repo 'scripts/Export-ArcDemoInventory.ps1'
        $script:Parity = Join-Path $script:Repo 'scripts/Test-ArcDemoParity.ps1'
        $script:Skin = Join-Path $TestDrive 'skin.json'
        '{"schemaVersion":1,"azure":{"namePrefix":"par-test"},"workloads":{"deployContainerApps":true},"nestedSqlGuest":{"enabled":true,"parentVmName":"parent-vm","guestVmName":"guest-vm","arcMachineName":"guest-vm"}}' | Set-Content $script:Skin
    }

    It 'compares a saved snapshot offline, derives features from the skin and exits 0 or 1' {
        $snapshot = New-HealthySnapshot
        $file = Join-Path $TestDrive 'healthy.json'
        $snapshot | ConvertTo-Json -Depth 14 | Set-Content $file
        $json = & $script:Parity -SubscriptionId $script:Sub -TenantId $script:Ten -SkinPath $script:Skin -SnapshotPath $file -Feature RealSql, Sre, OperationalWorkbooks, SreAlertGrant, ContainerApps, NestedSql -OutputFormat Json | ConvertFrom-Json
        $LASTEXITCODE | Should -Be 0
        $json.status | Should -Be 'pass'
        $json.snapshotSource | Should -Be 'file'
        $json.checks.Count | Should -BeGreaterThan 20
        $derived = & $script:Parity -SubscriptionId $script:Sub -TenantId $script:Ten -SkinPath $script:Skin -SnapshotPath $file -OutputFormat Json | ConvertFrom-Json
        $derived.features | Should -Be @('ContainerApps', 'NestedSql')
        $broken = New-HealthySnapshot
        $broken.sections.groups.data.infra.resources = @($broken.sections.groups.data.infra.resources | Where-Object type -ne 'Microsoft.Network/natGateways')
        $brokenFile = Join-Path $TestDrive 'broken.json'
        $broken | ConvertTo-Json -Depth 14 | Set-Content $brokenFile
        $result = & $script:Parity -SubscriptionId $script:Sub -TenantId $script:Ten -SkinPath $script:Skin -SnapshotPath $brokenFile -OutputFormat Json | ConvertFrom-Json
        $LASTEXITCODE | Should -Be 1
        ($result.checks | Where-Object status -eq 'fail').id | Should -Contain 'infra/nat-gateway'
    }

    It 'refuses a snapshot of another subscription or prefix, and a file that is not a snapshot' {
        $file = Join-Path $TestDrive 'other.json'
        New-HealthySnapshot | ConvertTo-Json -Depth 14 | Set-Content $file
        { & $script:Parity -SubscriptionId $script:Ten -TenantId $script:Ten -SkinPath $script:Skin -SnapshotPath $file -OutputFormat Json } | Should -Throw '*different subscription*'
        Set-Content (Join-Path $TestDrive 'not.json') '{"schemaVersion":1}'
        { & $script:Parity -SubscriptionId $script:Sub -TenantId $script:Ten -SkinPath $script:Skin -SnapshotPath (Join-Path $TestDrive 'not.json') -OutputFormat Json } | Should -Throw '*not an arc-demo inventory*'
    }

    It 'writes a new private snapshot file, never overwrites one, and refuses repository paths' {
        Mock Import-Module {}
        Mock Get-DemoEstateSnapshot { [ordered]@{ schemaVersion = 1; workload = 'arc-demo-inventory'; sections = [ordered]@{ groups = [ordered]@{ status = 'ok'; data = @{} } } } }
        $file = Join-Path $TestDrive 'snapshot-new.json'
        $path = & $script:Export -SubscriptionId $script:Sub -TenantId $script:Ten -SkinPath $script:Skin -OutputPath $file 6>$null
        $path | Should -Be $file
        (Get-Content $file -Raw | ConvertFrom-Json).workload | Should -Be 'arc-demo-inventory'
        { & $script:Export -SubscriptionId $script:Sub -TenantId $script:Ten -SkinPath $script:Skin -OutputPath $file } | Should -Throw '*never overwritten*'
        { & $script:Export -SubscriptionId $script:Sub -TenantId $script:Ten -SkinPath $script:Skin -OutputPath (Join-Path $TestDrive 'missing-folder/x.json') } | Should -Throw '*folder must already exist*'
        { & $script:Export -SubscriptionId $script:Sub -TenantId $script:Ten -SkinPath $script:Skin -OutputPath (Join-Path $script:Repo 'docs/snapshot.json') } | Should -Throw '*outside the repository*'
    }

    It 'exits 1 but still writes the snapshot when a section could not be read' {
        Mock Import-Module {}
        Mock Get-DemoEstateSnapshot { [ordered]@{ schemaVersion = 1; workload = 'arc-demo-inventory'; sections = [ordered]@{ keyVaults = [ordered]@{ status = 'error'; error = 'denied for the test' } } } }
        $file = Join-Path $TestDrive 'snapshot-partial.json'
        & $script:Export -SubscriptionId $script:Sub -TenantId $script:Ten -SkinPath $script:Skin -OutputPath $file 6>$null 3>$null | Out-Null
        $LASTEXITCODE | Should -Be 1
        (Get-Content $file -Raw | ConvertFrom-Json).sections.keyVaults.status | Should -Be 'error'
    }
}
