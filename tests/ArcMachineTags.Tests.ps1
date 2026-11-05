BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
    $script:deployScript = Join-Path $repo 'scripts\Deploy-ArcDemo.ps1'
    $script:machineId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.HybridCompute/machines/win-sql-01'
    $script:tagsUrl = "https://management.azure.com$($script:machineId)/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
    function Get-WantedTags {
        [ordered]@{ owner = 'demo'; purpose = 'arc-demo'; costcenter = 'demo'; env = 'demo'; role = 'sql'; osType = 'Windows'; osTier = 'WS2022'
            monitorTier = 'full-monitor'; esuEligible = 'false'; updateManager = 'assessment'; defender = 'plan2'; machineConfig = 'enabled'; inventory = 'arc' }
    }
}

Describe 'ConvertTo-DemoTagMap' {
    It 'reads $null, a dictionary and a JSON object as one case-insensitive map' {
        (ConvertTo-DemoTagMap $null).Count | Should -Be 0
        (ConvertTo-DemoTagMap ([pscustomobject]@{})).Count | Should -Be 0
        $fromJson = ConvertTo-DemoTagMap ('{"Role":"sql","osTier":"WS2022"}' | ConvertFrom-Json)
        $fromJson['role'] | Should -Be 'sql'
        $fromJson.ContainsKey('OSTIER') | Should -BeTrue
        (ConvertTo-DemoTagMap @{ a = 1 })['A'] | Should -Be '1'
    }
}

Describe 'Set-DemoResourceTags' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        # The state that the az shorthand defect left behind: every other tag folded into the value of the first one.
        $script:response = '{"properties":{"tags":{"owner":"demo purpose=arc-demo role=sql osType=Windows osTier=WS2022","env":"demo"}}}' | ConvertFrom-Json
        $script:mergeTakes = $true
        Mock Invoke-DemoAz { throw "az must not be used to set tags: $($Arguments -join ' ')" } -ModuleName Common
        Mock Invoke-AzRest {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Url = $Url; Body = $Body })
            if ($Method -eq 'Get') { return $script:response }
            $merged = [ordered]@{}
            if ($script:response -and $script:response.properties -and $script:response.properties.tags) {
                foreach ($property in $script:response.properties.tags.PSObject.Properties) { $merged[$property.Name] = $property.Value }
            }
            if ($script:mergeTakes) { foreach ($key in $Body.properties.tags.Keys) { $merged[$key] = $Body.properties.tags[$key] } }
            [pscustomobject]@{ properties = [pscustomobject]@{ tags = [pscustomobject]$merged } }
        } -ModuleName Common
    }

    It 'merges the tags through the ARM tags API, one value per key, and never through az' {
        Set-DemoResourceTags -ResourceId $script:machineId -Tags (Get-WantedTags) | Should -BeTrue
        $script:calls.Count | Should -Be 2
        $script:calls[0].Method | Should -Be 'Get'
        $script:calls[0].Url | Should -Be $script:tagsUrl
        $script:calls[1].Method | Should -Be 'Patch'
        $script:calls[1].Url | Should -Be $script:tagsUrl
        $script:calls[1].Body.operation | Should -Be 'Merge'
        $sent = $script:calls[1].Body.properties.tags
        $sent.Count | Should -Be 13
        $sent['owner'] | Should -Be 'demo'
        $sent['role'] | Should -Be 'sql'
        $sent['osTier'] | Should -Be 'WS2022'
        $sent['esuEligible'] | Should -Be 'false'
        Should -Invoke Invoke-DemoAz -ModuleName Common -Times 0
    }

    It 'writes nothing when every wanted tag is already in place, and ignores tags it does not name' {
        $tags = Get-WantedTags
        $json = @{ properties = @{ tags = ($tags + @{ somethingElse = 'kept' }) } } | ConvertTo-Json -Depth 4
        $script:response = $json | ConvertFrom-Json
        Set-DemoResourceTags -ResourceId $script:machineId -Tags $tags | Should -BeFalse
        $script:calls.Count | Should -Be 1
        $script:calls[0].Method | Should -Be 'Get'
    }

    It 'reads a tag name without regard to case but a value exactly' {
        $tags = Get-WantedTags
        $upperNames = [ordered]@{}
        foreach ($key in $tags.Keys) { $upperNames[$key.ToUpperInvariant()] = $tags[$key] }
        $script:response = ([pscustomobject]@{ properties = [pscustomobject]@{ tags = [pscustomobject]$upperNames } })
        Set-DemoResourceTags -ResourceId $script:machineId -Tags $tags | Should -BeFalse
        $script:calls.Clear()
        $upperNames['ROLE'] = 'SQL'
        $script:response = ([pscustomobject]@{ properties = [pscustomobject]@{ tags = [pscustomobject]$upperNames } })
        Set-DemoResourceTags -ResourceId $script:machineId -Tags $tags | Should -BeTrue
        $script:calls[1].Method | Should -Be 'Patch'
    }

    It 'adds the tags to a resource that has none, whatever shape ARM returns' {
        foreach ($empty in '{}', '{"properties":{}}', '{"properties":{"tags":{}}}', '{"properties":{"tags":null}}') {
            $script:calls.Clear()
            $script:response = $empty | ConvertFrom-Json
            Set-DemoResourceTags -ResourceId $script:machineId -Tags (Get-WantedTags) | Should -BeTrue
            $script:calls.Count | Should -Be 2
        }
    }

    It 'stops when the merge did not take the requested value, naming the tag' {
        $script:mergeTakes = $false
        { Set-DemoResourceTags -ResourceId $script:machineId -Tags (Get-WantedTags) } | Should -Throw '*did not take the requested value*role*'
    }

    It 'refuses anything that is not an ARM resource ID, before any call' {
        { Set-DemoResourceTags -ResourceId 'win-sql-01' -Tags (Get-WantedTags) } | Should -Throw
        { Set-DemoResourceTags -ResourceId '/subscriptions/11111111-1111-1111-1111-111111111111' -Tags (Get-WantedTags) } | Should -Throw
        $script:calls.Count | Should -Be 0
    }
}

Describe 'Deploy sets the Arc machine tags through the tags merge' {
    BeforeAll {
        $script:deployText = Get-Content -LiteralPath $script:deployScript -Raw
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:deployScript, [ref]$null, [ref]$null)
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ArcMachineTags' }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    It 'no longer calls az connectedmachine update with --tags, whose shorthand folds the pairs into one value' {
        $script:deployText | Should -Not -Match '(?m)^\s*az connectedmachine update[^\r\n]*--tags'
        $script:deployText | Should -Match 'Set-DemoResourceTags -ResourceId'
        $script:deployText | Should -Not -Match 'Get-ArcMachineTagArgs'
    }
    It 'builds one name to value map with the base tags first and the 9 control-plane tags after them' {
        $machine = [pscustomobject]@{ role = 'sql'; osType = 'Windows'; osTier = 'WS2022'; monitorTier = 'full-monitor'; esuEligible = $false }
        $base = [ordered]@{ owner = 'demo'; purpose = 'arc-demo'; costcenter = 'demo'; env = 'demo' }
        $tags = Get-ArcMachineTags -Machine $machine -BaseTags $base
        $tags | Should -BeOfType [System.Collections.IDictionary]
        @($tags.Keys) | Should -Be @('owner', 'purpose', 'costcenter', 'env', 'role', 'osType', 'osTier', 'monitorTier', 'esuEligible', 'updateManager', 'defender', 'machineConfig', 'inventory')
        $tags['esuEligible'] | Should -Be 'false'
        $tags['owner'] | Should -Be 'demo'
        foreach ($key in $tags.Keys) { $tags[$key] | Should -Not -Match '[= ]' }
    }
}

Describe 'Readiness asserts the role and osTier tags on Arc machines' {
    BeforeEach {
        InModuleScope Common { $script:DemoSubscription = '11111111-1111-1111-1111-111111111111' }
        $script:arcRoot = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.HybridCompute/machines'
        $script:infraRoot = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.Compute/virtualMachines'
        $script:arcTags = @{
            'win-sql-01' = @{ role = 'sql'; osTier = 'WS2022'; owner = 'demo' }
            'lnx-app-01' = @{ role = 'app'; osTier = 'Ubuntu22.04'; owner = 'demo' }
        }
        Mock Get-DemoNetworkState { [pscustomobject]@{ NatId = '/nat'; PublicIpId = '/pip'; Nat = $null; PublicIp = $null; Subnet = @{ id = '/subnet' } } } -ModuleName Common
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'group') { return '{"properties":{"provisioningState":"Succeeded"}}' }
            if (($Arguments[0..1] -join ' ') -eq 'connectedmachine list') {
                return (ConvertTo-Json -Depth 6 -InputObject @($script:arcTags.Keys | Sort-Object | ForEach-Object {
                    @{ id = "$($script:arcRoot)/$_"; name = $_; status = 'Connected'; tags = $script:arcTags[$_] } }))
            }
            return '[]'
        } -ModuleName Common
        function New-TagInventory {
            param([switch]$WithoutExpectedTags)
            $win = [pscustomobject]@{ Name = 'win-sql-01'; Id = "$($script:infraRoot)/win-sql-01"; ArcId = "$($script:arcRoot)/win-sql-01"; Native = $false; Monitor = $false
                VmInsights = $false; ChangeTracking = $false; OsType = 'Windows'; Actual = @{ powerState = 'VM running' } }
            $lnx = [pscustomobject]@{ Name = 'lnx-app-01'; Id = "$($script:infraRoot)/lnx-app-01"; ArcId = "$($script:arcRoot)/lnx-app-01"; Native = $false; Monitor = $false
                VmInsights = $false; ChangeTracking = $false; OsType = 'Linux'; Actual = @{ powerState = 'VM running' } }
            if (-not $WithoutExpectedTags) {
                $win | Add-Member -NotePropertyName Role -NotePropertyValue 'sql'; $win | Add-Member -NotePropertyName OsTier -NotePropertyValue 'WS2022'
                $lnx | Add-Member -NotePropertyName Role -NotePropertyValue 'app'; $lnx | Add-Member -NotePropertyName OsTier -NotePropertyValue 'Ubuntu22.04'
            }
            [pscustomobject]@{ ArcRg = 'rg-fixture'; InfraRg = 'rg-fixture-infra'; Resources = @(); AksClusterIds = @(); ContainerAppIds = @(); Machines = @($win, $lnx) }
        }
    }

    It 'passes a required row per Arc machine when role and osTier match the manifest' {
        $checks = @(Get-DemoReadinessChecks -Inventory (New-TagInventory) -NamePrefix fixture -DesiredState Active | Where-Object id -like 'tags/*')
        $checks.Count | Should -Be 2
        @($checks | Where-Object { $_.status -eq 'pass' -and $_.required }).Count | Should -Be 2
        ($checks | Where-Object id -eq 'tags/win-sql-01').observed | Should -Be 'role=sql, osTier=WS2022'
        ($checks | Where-Object id -eq 'tags/win-sql-01').resourceId | Should -Be "$($script:arcRoot)/win-sql-01"
    }

    It 'fails a connected host whose other tags were folded into owner, and points at the troubleshooting entry' {
        $script:arcTags['win-sql-01'] = @{ owner = 'demo purpose=arc-demo role=sql osType=Windows osTier=WS2022' }
        $checks = @(Get-DemoReadinessChecks -Inventory (New-TagInventory) -NamePrefix fixture -DesiredState Active | Where-Object id -like 'tags/*')
        $bad = $checks | Where-Object id -eq 'tags/win-sql-01'
        $bad.status | Should -Be 'fail'
        $bad.required | Should -BeTrue
        $bad.observed | Should -Be 'role=(missing), osTier=(missing)'
        $bad.message | Should -Match 'docs/troubleshooting.md'
        ($checks | Where-Object id -eq 'tags/lnx-app-01').status | Should -Be 'pass'
    }

    It 'fails a wrong value and a host with no tags at all' {
        $script:arcTags['win-sql-01'] = @{ role = 'app'; osTier = 'WS2022' }
        $script:arcTags['lnx-app-01'] = $null
        $checks = @(Get-DemoReadinessChecks -Inventory (New-TagInventory) -NamePrefix fixture -DesiredState Active | Where-Object id -like 'tags/*')
        ($checks | Where-Object id -eq 'tags/win-sql-01').observed | Should -Be 'role=app, osTier=WS2022'
        @($checks | Where-Object status -eq 'fail').Count | Should -Be 2
    }

    It 'asserts nothing when the manifest carries no role and osTier, when the host is not in Arc yet, or when parked' {
        @(Get-DemoReadinessChecks -Inventory (New-TagInventory -WithoutExpectedTags) -NamePrefix fixture -DesiredState Active | Where-Object id -like 'tags/*').Count | Should -Be 0
        $script:arcTags.Remove('lnx-app-01')
        $checks = @(Get-DemoReadinessChecks -Inventory (New-TagInventory) -NamePrefix fixture -DesiredState Active)
        @($checks | Where-Object id -eq 'tags/lnx-app-01').Count | Should -Be 0
        ($checks | Where-Object id -eq 'arc/lnx-app-01').status | Should -Be 'fail'
        @(Get-DemoReadinessChecks -Inventory (New-TagInventory) -NamePrefix fixture -DesiredState Hibernated | Where-Object id -like 'tags/*').Count | Should -Be 0
    }
}

Describe 'Get-DemoInventory keeps the manifest role and osTier for the readiness rows' {
    It 'reads them from the vmFleet output' {
        (Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'scripts\lib\Common.psm1') -Raw) | Should -Match 'Role = \$entry\.role; OsTier = \$entry\.osTier'
        (Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'bicep\main.bicep') -Raw) | Should -Match '(?s)output vmFleet.*?role: vm\.role.*?osTier: vm\.osTier'
    }
}
