param(
    [string]$WorkspaceResourceId = '',
    [guid]$SubscriptionId,
    [guid]$TenantId
)

# Explicit opt-in, read-only KQL execution. Normal CI needs no Azure account.
Describe 'Operational queries executed against deterministic literal tables' -Skip:([string]::IsNullOrWhiteSpace($WorkspaceResourceId)) {
    BeforeAll {
        $ErrorActionPreference = 'Stop'
        $repo = Split-Path $PSScriptRoot
        Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
        Import-Module (Join-Path $repo 'scripts\lib\OperationalWorkbooks.psm1') -Force
        if ($WorkspaceResourceId -notmatch ('^/subscriptions/' + [regex]::Escape($SubscriptionId.ToString()) + '/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft.OperationalInsights/workspaces/[A-Za-z0-9._()-]+$')) {
            throw 'Test workspace must be an exact ID in the explicitly confirmed subscription.'
        }
        Initialize-DemoContext -SubscriptionId $SubscriptionId -TenantId $TenantId
        $workspace = Invoke-DemoAz -Arguments @('resource', 'show', '--ids', $WorkspaceResourceId, '-o', 'json') | ConvertFrom-Json
        if ($workspace.id -ne $WorkspaceResourceId -or -not $workspace.properties.customerId) { throw 'Test workspace identity/customerId unknown.' }
        $scope = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture'
        $ids = @{}
        foreach ($name in @('parent', 'guest', 'low', 'parked', 'short', 'pressure', 'invalid', 'missing', 'foreign')) {
            $ids[$name] = "$scope/providers/Microsoft.HybridCompute/machines/$name".ToLowerInvariant()
        }
        $machines = @($ids.Keys | Where-Object { $_ -ne 'foreign' } | ForEach-Object { @{ id = $ids[$_] } })
        $topology = @(
            @{ resourceId = $ids.parent; layer = 'parent' }
            @{ resourceId = $ids.guest; layer = 'guest'; parentResourceId = $ids.parent }
        )
        $book = (Get-DemoOperationalWorkbook -Purpose optimisation -WorkspaceResourceId "$scope/providers/Microsoft.OperationalInsights/workspaces/law-fixture" -Machines $machines -Topology $topology).SerializedData | ConvertFrom-Json -Depth 100
        $fixture = Get-Content (Join-Path $PSScriptRoot 'fixtures\operational-telemetry.kql') -Raw
        foreach ($key in $ids.Keys) { $fixture = $fixture.Replace("__$($key.ToUpperInvariant())__", $ids[$key]) }
        $query = $fixture + "`n" + ($book.items | Where-Object name -eq 'review-candidates').content.query
        $query = $query.Replace('{LookbackHours}', '168').Replace('let PerfRows = Perf', 'let PerfRows = FixturePerf').Replace('let InsightsRows = InsightsMetrics', 'let InsightsRows = FixtureInsights')
        $token = Get-LawQueryToken
        $response = Invoke-RestMethod -Method POST -Uri "https://api.loganalytics.io/v1/workspaces/$($workspace.properties.customerId)/query" `
            -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body (@{ query = $query } | ConvertTo-Json -Depth 5) -TimeoutSec 120
        if ($response.error -or @($response.tables).Count -ne 1) { throw 'Fixture query failed/partial; no deterministic result claim.' }
        $table = $response.tables[0]
        $rows = @(
            foreach ($row in $table.rows) {
                $record = [ordered]@{}
                for ($i = 0; $i -lt $table.columns.Count; $i++) { $record[$table.columns[$i].name] = $row[$i] }
                [pscustomobject]$record
            }
        )
        function Get-FixtureMetric([string]$Machine, [string]$Metric) {
            @($rows | Where-Object { $_.Machine -eq $Machine -and $_.Metric -eq $Metric })
        }
    }

    It 'keeps a spike visible with low mean/P95 and rejects duplicate/per-core CPU streams' {
        $row = Get-FixtureMetric parent 'CPU percent'
        $row.Mean | Should -BeLessThan 11
        $row.P95 | Should -Be 10
        $row.Maximum | Should -Be 100
        $row.Review | Should -Match 'spike'
    }

    It 'keeps parent and guest observations separate rather than adding capacity' {
        $parent = Get-FixtureMetric parent 'CPU percent'
        $guest = Get-FixtureMetric guest 'CPU percent'
        $parent.Layer | Should -Be parent
        $guest.Layer | Should -Be guest
        $guest.ParentResourceId | Should -Be $ids.parent
        $guest.Mean | Should -Be 40
    }

    It 'leaves missing memory/disk/host measurements null, never zero' {
        foreach ($row in @($rows | Where-Object { $_.Machine -eq 'missing' -or ($_.Machine -eq 'guest' -and $_.Metric -ne 'CPU percent') })) {
            $row.Mean | Should -BeNullOrEmpty
            $row.P95 | Should -BeNullOrEmpty
            $row.Evidence | Should -Match 'Missing data'
            $row.Review | Should -Not -Match 'Low sampled CPU'
        }
    }

    It 'reports parked gaps/staleness without turning low samples into an opportunity' {
        $row = Get-FixtureMetric parked 'CPU percent'
        $row.CoveragePercent | Should -BeLessThan 80
        $row.Evidence | Should -Match 'Stale'
        $row.Review | Should -Match 'Evidence first'
    }

    It 'rejects short histories as optimisation evidence' {
        (Get-FixtureMetric short 'CPU percent').Evidence | Should -Match 'Insufficient history'
    }

    It 'surfaces committed/available memory and per-volume disk pressure' {
        (Get-FixtureMetric pressure 'Committed percent').Review | Should -Match 'commitment pressure'
        (Get-FixtureMetric pressure 'Available MB').Review | Should -Match 'Low available memory'
        $disks = Get-FixtureMetric pressure 'Disk free percent'
        $disks.Count | Should -Be 2
        ($disks | Where-Object Instance -eq 'D:').Review | Should -Match 'free-space pressure'
        ($disks | Where-Object Instance -eq 'C:').FirstValue | Should -Be 80
        ($disks | Where-Object Instance -eq 'C:').LastValue | Should -Be 60
        ($disks | Where-Object Instance -eq 'C:').Delta | Should -Be -20
    }

    It 'retains a low-CPU conversation only for adequate fresh evidence, never a sizing instruction' {
        (Get-FixtureMetric low 'CPU percent').Review | Should -Match 'conversation only.*no sizing'
    }

    It 'does not treat invalid values or out-of-scope identities as capacity evidence' {
        (Get-FixtureMetric invalid 'CPU percent').Mean | Should -BeNullOrEmpty
        (Get-FixtureMetric invalid 'CPU percent').Evidence | Should -Match 'Invalid samples'
        @($rows | Where-Object ResourceId -eq $ids.foreign).Count | Should -Be 0
    }
}
