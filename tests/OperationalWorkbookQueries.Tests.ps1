param(
    [string]$WorkspaceResourceId = '',
    [guid]$SubscriptionId,
    [guid]$TenantId
)

# Explicit opt-in, read-only KQL execution. Normal CI needs no Azure account.
# The production item queries run unchanged except that the two raw telemetry sources are swapped for literal fixture tables
# defined inside the query text, so nothing is ingested and no real machine, guest or workload is touched.
Describe 'Operational workbook queries executed against deterministic literal tables' -Skip:([string]::IsNullOrWhiteSpace($WorkspaceResourceId)) {
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
        $token = Get-LawQueryToken

        $scope = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture'
        $definitions = [ordered]@{
            spike = @{ os = 'windows'; tags = @{ env = 'prod'; application = 'crm'; owner = 'alice'; costcenter = 'cc-1' } }
            parent = @{ os = 'windows'; tags = @{ env = 'prod'; application = 'sql'; owner = 'bob'; costcenter = 'cc-2' } }
            guest = @{ os = 'windows'; tags = @{ env = 'prod'; application = 'sql'; owner = 'bob'; costcenter = 'cc-2' } }
            lowa = @{ os = 'windows'; tags = @{ env = 'prod'; application = 'web'; owner = 'carol'; costcenter = 'cc-3' } }
            lowb = @{ os = 'windows'; tags = @{ env = 'prod'; application = 'web'; owner = 'carol'; costcenter = 'cc-3' } }
            lowc = @{ os = 'windows'; tags = @{} }
            steady = @{ os = 'windows'; tags = @{ env = 'prod'; application = 'erp'; owner = 'dave'; costcenter = 'cc-4' } }
            pressure = @{ os = 'windows'; tags = @{ env = 'prod'; application = 'erp'; owner = 'dave'; costcenter = 'cc-4' } }
            devidle = @{ os = 'linux'; tags = @{ env = 'dev'; application = 'tools'; owner = 'erin'; costcenter = 'cc-5' } }
            short = @{ os = 'windows'; tags = @{ env = 'prod'; application = 'misc'; owner = 'frank'; costcenter = 'cc-6' } }
            parked = @{ os = 'windows'; tags = @{ env = 'prod'; application = 'misc'; owner = 'frank'; costcenter = 'cc-6' } }
            missing = @{ os = 'windows'; tags = @{ env = 'prod'; application = 'misc'; owner = 'frank'; costcenter = 'cc-6' } }
            invalid = @{ os = 'windows'; tags = @{ env = 'prod'; application = 'misc'; owner = 'frank'; costcenter = 'cc-6' } }
        }
        $ids = @{ foreign = "$scope/providers/Microsoft.HybridCompute/machines/foreign".ToLowerInvariant() }
        $machines = @(
            foreach ($name in $definitions.Keys) {
                $ids[$name] = "$scope/providers/Microsoft.HybridCompute/machines/$name".ToLowerInvariant()
                @{ id = $ids[$name]; osType = $definitions[$name].os; tags = $definitions[$name].tags }
            }
        )
        $topology = @(
            @{ resourceId = $ids.parent; layer = 'parent' }
            @{ resourceId = $ids.guest; layer = 'guest'; parentResourceId = $ids.parent }
        )
        $roster = @(Get-DemoOperationalRoster -WorkspaceResourceId "$scope/providers/Microsoft.OperationalInsights/workspaces/law-fixture" -Machines $machines -Topology $topology)

        $fixture = Get-Content (Join-Path $PSScriptRoot 'fixtures\operational-telemetry.kql') -Raw
        foreach ($key in $ids.Keys) { $fixture = $fixture.Replace("__$($key.ToUpperInvariant())__", $ids[$key]) }
        $now = [datetime]::UtcNow
        $anchor = [datetime]::SpecifyKind($now.Date.AddMinutes([math]::Floor($now.TimeOfDay.TotalMinutes / 5) * 5), [DateTimeKind]::Utc)
        $fixture = $fixture.Replace('__ANCHOR__', $anchor.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture))

        # The grids show a short selection of columns. The test-only wide projections (tests/fixtures/operational-queries) compose with the
        # production shared fragments from a scratch folder, so the classification logic under test is exactly the shipped logic.
        $wideRoot = Join-Path ([IO.Path]::GetTempPath()) ('operational-queries-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $wideRoot | Out-Null
        Copy-Item (Join-Path $repo 'workbooks\queries\operational-*.kql') $wideRoot
        Copy-Item (Join-Path $PSScriptRoot 'fixtures\operational-queries\*.kql') $wideRoot

        function New-FixtureRequest {
            param([string]$Name, [hashtable]$Parameters = @{}, [string[]]$Only = @(), [string]$QueryRoot = '')
            # The fixtures were designed against a 24-hour evidence rule; the workbook default is a deliberately modest 3 hours.
            $effective = @{ MinObservedHours = '24' }
            foreach ($key in $Parameters.Keys) { $effective[$key] = $Parameters[$key] }
            # -Only narrows the roster to named machines so the edge cases (nothing reporting, everything silent) can be exercised.
            $scoped = if ($Only.Count) { @($roster | Where-Object { $_.machine -in $Only }) } else { $roster }
            $text = if ($QueryRoot) { Get-DemoOperationalQuery -Name $Name -Roster $scoped -QueryRoot $QueryRoot } else { Get-DemoOperationalQuery -Name $Name -Roster $scoped }
            $text = Expand-DemoOperationalQuery -Query $text -Roster $scoped -Parameters $effective -Start $anchor.AddDays(-7) -End $anchor
            $readsSharedSamples = $text.Contains('let PerfRows = Perf')
            $text = $text.Replace('let PerfRows = Perf', 'let PerfRows = FixturePerf').Replace('let InsightsRows = InsightsMetrics', 'let InsightsRows = FixtureInsights')
            # Only the scenario arithmetic may skip the shared samples; every other item must run on the fixture tables.
            if (-not $readsSharedSamples -and $Name -notin 'opt-scenario', 'opt-scenario-result') {
                throw "Query '$Name' does not read the shared telemetry sources; refusing to claim fixture coverage."
            }
            @{ query = ($fixture + "`n" + $text) } | ConvertTo-Json -Depth 5
        }
        function Get-Fixture([object[]]$Rows, [string]$Machine) { @($Rows | Where-Object Machine -eq $Machine) }

        $scenarioInputs = @{ SelectedHost = 'lowa'; SchedStartHour = '19'; SchedEndHour = '7'; SchedWeekendsOff = 'Yes'; ScenarioBaseline = '1000'; ScenarioSharePct = '60' }
        $guestInputs = $scenarioInputs.Clone()
        $guestInputs.SelectedHost = 'guest'
        $requests = [ordered]@{
            hosts = New-FixtureRequest 'test-hosts' -QueryRoot $wideRoot
            hostsGrid = New-FixtureRequest 'cap-hosts'
            volumes = New-FixtureRequest 'cap-disk-volumes'
            memory = New-FixtureRequest 'cap-mem-grid'
            capTiles = New-FixtureRequest 'cap-tiles'
            capTilesGaps = New-FixtureRequest 'cap-tiles-gaps'
            scopeTiles = New-FixtureRequest 'cap-scope'
            scopeAllAbsent = New-FixtureRequest 'cap-scope' -Only @('missing')
            scopeAllSilent = New-FixtureRequest 'cap-scope' -Only @('parked')
            scopeMixed = New-FixtureRequest 'cap-scope' -Only @('parked', 'missing')
            # Every way a portal can expand the All choice of the three filter dropdowns; none of them may remove a machine.
            scopeAllMarker = New-FixtureRequest 'cap-scope' @{ OsFilter = "'value::all'"; EnvironmentFilter = "'value::all'"; ApplicationFilter = "'value::all'" }
            scopeAllEmpty = New-FixtureRequest 'cap-scope' @{ OsFilter = ''; EnvironmentFilter = ''; ApplicationFilter = '' }
            scopeAllStar = New-FixtureRequest 'cap-scope' @{ OsFilter = "'*'"; EnvironmentFilter = "'*'"; ApplicationFilter = "'*'" }
            scopeLinuxOnly = New-FixtureRequest 'cap-scope' @{ OsFilter = "'Linux'" }
            detailTiles = New-FixtureRequest 'cap-detail-tiles' @{ SelectedHost = 'devidle' }
            whyLines = New-FixtureRequest 'detail-why' @{ SelectedHost = 'parent' }
            candidates = New-FixtureRequest 'test-candidates' -QueryRoot $wideRoot
            candidatesGrid = New-FixtureRequest 'opt-candidates'
            optTiles = New-FixtureRequest 'opt-tiles'
            optTilesHygiene = New-FixtureRequest 'opt-tiles-hygiene'
            card = New-FixtureRequest 'opt-detail-card' @{ SelectedHost = 'devidle' }
            scenario = New-FixtureRequest 'opt-scenario' $scenarioInputs
            scenarioResult = New-FixtureRequest 'opt-scenario-result' $scenarioInputs
            guestScenario = New-FixtureRequest 'opt-scenario' $guestInputs
            guestScenarioResult = New-FixtureRequest 'opt-scenario-result' $guestInputs
            emptyScenario = New-FixtureRequest 'opt-scenario'
            emptyScenarioResult = New-FixtureRequest 'opt-scenario-result'
            methodMatrix = New-FixtureRequest 'cap-method-matrix'
            # The activity heat map and the independent per-hour counts it is checked against.
            heatmap = New-FixtureRequest 'opt-sched-heatmap'
            hourly = New-FixtureRequest 'test-hourly' -QueryRoot $wideRoot
        }
        # Read-only queries run a few at a time: the service allows only a handful of concurrent queries per user.
        $uri = "https://api.loganalytics.io/v1/workspaces/$($workspace.properties.customerId)/query"
        $responses = @($requests.GetEnumerator() | ForEach-Object -ThrottleLimit 4 -Parallel {
            try {
                $reply = Invoke-RestMethod -Method POST -Uri $using:uri -Headers @{ Authorization = "Bearer $using:token" } -ContentType 'application/json' -Body $_.Value -TimeoutSec 180
                [pscustomobject]@{ Key = $_.Key; Reply = $reply; Error = '' }
            } catch {
                [pscustomobject]@{ Key = $_.Key; Reply = $null; Error = [string]$_.ErrorDetails.Message }
            }
        })
        $results = @{}
        foreach ($response in $responses) {
            if ($response.Error -or $response.Reply.error -or @($response.Reply.tables).Count -ne 1) {
                throw "Fixture query '$($response.Key)' failed or was partial; no deterministic result claim. $($response.Error)"
            }
            $table = $response.Reply.tables[0]
            $results[$response.Key] = @(
                foreach ($row in $table.rows) {
                    $record = [ordered]@{}
                    for ($i = 0; $i -lt $table.columns.Count; $i++) { $record[$table.columns[$i].name] = $row[$i] }
                    [pscustomobject]$record
                }
            )
        }
        $hosts = $results.hosts
        $hostsGrid = $results.hostsGrid
        $capTilesGaps = $results.capTilesGaps
        $whyLines = $results.whyLines
        $candidatesGrid = $results.candidatesGrid
        $optTilesHygiene = $results.optTilesHygiene
        $volumes = $results.volumes
        $memory = $results.memory
        $capTiles = $results.capTiles
        $scopeTiles = $results.scopeTiles
        $scopeAllAbsent = $results.scopeAllAbsent
        $scopeAllSilent = $results.scopeAllSilent
        $scopeMixed = $results.scopeMixed
        $scopeAllMarker = $results.scopeAllMarker
        $scopeAllEmpty = $results.scopeAllEmpty
        $scopeAllStar = $results.scopeAllStar
        $scopeLinuxOnly = $results.scopeLinuxOnly
        $detailTiles = $results.detailTiles
        $candidates = $results.candidates
        $optTiles = $results.optTiles
        $card = $results.card
        # The scenario is two rows of tiles (the inputs, then the arithmetic); the assertions read them as one list.
        $scenario = @($results.scenario) + @($results.scenarioResult)
        $guestScenario = @($results.guestScenario) + @($results.guestScenarioResult)
        $emptyScenario = @($results.emptyScenario) + @($results.emptyScenarioResult)
        $methodMatrix = $results.methodMatrix
        $heatmap = $results.heatmap
        $hourly = $results.hourly
    }

    AfterAll {
        if ($wideRoot -and (Test-Path -LiteralPath $wideRoot)) { Remove-Item -LiteralPath $wideRoot -Recurse -Force }
    }

    Context 'Capacity status and evidence' {
        It 'returns one row per roster machine and ignores identities outside the roster' {
            $hosts.Count | Should -Be $definitions.Count
            @($hosts | Where-Object Machine -eq 'foreign').Count | Should -Be 0
            @($hosts.Machine | Sort-Object -Unique).Count | Should -Be $definitions.Count
        }

        It 'keeps a brief spike visible without calling it pressure, and rejects duplicate and per-core CPU streams' {
            $row = Get-Fixture $hosts 'spike'
            $row.CpuP95 | Should -Be 10
            $row.CpuPeak | Should -Be 100
            $row.Pattern | Should -Be 'Brief spike(s)'
            $row.Assessment | Should -Be 'Apparent headroom'
            $row.Reason | Should -Match 'Peak 100% was brief'
            $row.Reason | Should -Match 'not a sizing recommendation'
        }

        It 'separates sustained pressure from a spike and reports memory, low memory and a full volume' {
            $row = Get-Fixture $hosts 'pressure'
            $row.Pattern | Should -Be 'Sustained pressure'
            $row.Assessment | Should -Be 'Pressure observed'
            $row.Reason | Should -Match 'continuous minutes'
            $row.AvailMbMin | Should -Be 100
            $row.Volume | Should -Be 'D:'
            $row.FreePct | Should -Be 10
        }

        It 'keeps parent and guest as separate evidence rows, never adds them and does not read a parent as headroom' {
            $parent = Get-Fixture $hosts 'parent'
            $guest = Get-Fixture $hosts 'guest'
            $parent.Topology | Should -Be 'parent of guest'
            $guest.Topology | Should -Be 'guest of parent'
            $parent.CpuP95 | Should -Be 15
            $guest.CpuP95 | Should -Be 40
            $parent.Evidence | Should -Be 'Parent counters exclude guest load'
            $parent.Assessment | Should -Be 'Insufficient evidence'
            $parent.Reason | Should -Match 'do not reflect the guest'
            @($hosts | Where-Object { $_.Machine -match 'total|sum|combined' }).Count | Should -Be 0
        }

        It 'leaves missing measurements null, never zero or healthy' {
            $guest = Get-Fixture $hosts 'guest'
            $guest.MemP95 | Should -BeNullOrEmpty
            $guest.FreePct | Should -BeNullOrEmpty
            $guest.Evidence | Should -Be 'Memory or disk evidence missing'
            $guest.Assessment | Should -Be 'Insufficient evidence'
            $none = Get-Fixture $hosts 'missing'
            $none.State | Should -Be 'No telemetry'
            $none.Assessment | Should -Be 'No telemetry'
            $none.CpuP95 | Should -BeNullOrEmpty
            $none.MemP95 | Should -BeNullOrEmpty
            $none.FreePct | Should -BeNullOrEmpty
            $none.Reason | Should -Match 'unknown, not zero'
        }

        It 'treats a parked gap as evidence first, not as idle headroom' {
            $row = Get-Fixture $hosts 'parked'
            $row.State | Should -Be 'Not reporting'
            $row.AgeMinutes | Should -BeGreaterThan 2800
            $row.Assessment | Should -Be 'Insufficient evidence'
            $row.Assessment | Should -Not -Be 'Apparent headroom'
        }

        It 'rejects a short history as capacity evidence' {
            $row = Get-Fixture $hosts 'short'
            $row.Evidence | Should -Be 'Thin history'
            $row.Assessment | Should -Be 'Insufficient evidence'
        }

        It 'does not use invalid values as capacity evidence' {
            $row = Get-Fixture $hosts 'invalid'
            $row.Evidence | Should -Match 'Invalid samples'
            $row.CpuP95 | Should -BeNullOrEmpty
            $row.Assessment | Should -Be 'Insufficient evidence'
            $row.History | Should -Match 'invalid sample'
        }

        It 'prefers per-volume disk evidence over the aggregate stream' {
            $row = Get-Fixture $hosts 'spike'
            $row.Volume | Should -Be 'C:'
            $row.FreePct | Should -Be 60
        }

        It 'reads the Linux Perf counter names, including memory and the worst real mount' {
            $row = Get-Fixture $hosts 'devidle'
            $row.Os | Should -Be 'Linux'
            $row.CpuP95 | Should -Be 2
            $row.MemP95 | Should -Be 35
            $row.AvailMbMin | Should -Be 3000
            $row.Volume | Should -Be '/data'
            $row.FreePct | Should -Be 55
            $row.Assessment | Should -Be 'Apparent headroom'
        }
    }

    Context 'Disk and memory detail' {
        It 'excludes Linux pseudo mounts and the aggregate whenever per-volume evidence exists' {
            $names = @((Get-Fixture $volumes 'devidle').Volume | Sort-Object)
            $names | Should -Be @('/', '/data')
        }

        It 'derives a Linux volume size from free megabytes and free percent and labels the basis' {
            $row = Get-Fixture $volumes 'devidle' | Where-Object Volume -eq '/'
            $row.SizeBasis | Should -Be 'derived'
            $row.FreeGb | Should -Be 6.8
            $row.SizeGb | Should -Be 9.8
        }

        It 'labels an aggregate-only series as not per-volume' {
            $row = Get-Fixture $volumes 'steady'
            $row.Volume | Should -Be '_Total (aggregate)'
            $row.Level | Should -Be 'Aggregate only - not per-volume'
        }

        It 'reports free space now and the observed trend, not a forecast, and flags the low volume' {
            $rows = Get-Fixture $volumes 'pressure'
            $cDrive = $rows | Where-Object Volume -eq 'C:'
            $cDrive.FreeNowPct | Should -Be 60
            $trend = @($cDrive.FreeTrend | ConvertFrom-Json)
            $trend[0] | Should -Be 80
            $trend[-1] | Should -Be 60
            $cDrive.Level | Should -Be 'Within threshold'
            ($rows | Where-Object Volume -eq 'D:').Level | Should -Be 'Low free space'
        }

        It 'keeps each memory basis separate and never blends Windows and Linux counters' {
            (Get-Fixture $memory 'spike').Basis | Should -Be 'Committed bytes (Windows)'
            (Get-Fixture $memory 'devidle').Basis | Should -Be 'Used memory (Linux)'
            (Get-Fixture $memory 'pressure').State | Should -Be 'Sustained pressure'
            (Get-Fixture $memory 'guest').State | Should -Be 'Missing - not zero'
            (Get-Fixture $memory 'pressure').LowestAvailableMB | Should -Be 100
        }
    }

    Context 'Summary tiles' {
        It 'answers scope and evidence quality: machines, reporting, freshness and adequate evidence with its coverage' {
            $tile = { param($label) @($scopeTiles | Where-Object Label -like "*$label*")[0] }
            $total = & $tile 'Machines in scope'
            [int]$total.Value | Should -Be $definitions.Count
            $total.Note | Should -Be '1 guest, counted once'
            # The silent and absent machines are counted, and an invalid-only host still counts as reporting (it sent samples).
            $reporting = & $tile 'Reporting'
            $reporting.Label | Should -Match 'Reporting (now|at end)'
            [int]$reporting.Value | Should -Be 11
            $reporting.Note | Should -Be '2 not reporting'
            $latest = & $tile 'Latest sample'
            [int]$latest.Value | Should -Be 0
            $latest.Note | Should -Be 'min since newest sample'
            $adequate = & $tile 'Adequate evidence'
            [int]$adequate.Value | Should -Be 7
            # Median of the machines that have CPU samples only: the invalid-only host and the one without telemetry are not counted as zero.
            $adequate.Note | Should -Be 'median coverage 100%'
            @($scopeTiles).Count | Should -Be 4
            # Adequate evidence plus the two gap rows is every machine in scope; the names are in the wide status table.
            $gaps = @($hosts | Where-Object Assessment -in 'Insufficient evidence', 'No telemetry')
            ([int]$adequate.Value + $gaps.Count) | Should -Be $definitions.Count
            @(($hosts | Where-Object Assessment -eq 'Insufficient evidence').Machine | Sort-Object) | Should -Be @('guest', 'invalid', 'parent', 'parked', 'short')
        }

        It 'treats an empty list, the literal All marker and * as no filter, and still filters a real selection' {
            $inScope = { param($rows) [int]@($rows | Where-Object Label -like '*Machines in scope*')[0].Value }
            & $inScope $scopeTiles | Should -Be $definitions.Count
            & $inScope $scopeAllEmpty | Should -Be $definitions.Count
            & $inScope $scopeAllMarker | Should -Be $definitions.Count
            & $inScope $scopeAllStar | Should -Be $definitions.Count
            # A real selection still narrows the view: exactly one fixture machine is Linux.
            & $inScope $scopeLinuxOnly | Should -Be @($definitions.Values | Where-Object { $_.os -eq 'linux' }).Count
        }

        It 'tells unknown from parked when nothing is reporting' {
            $tile = { param($rows, $label) @($rows | Where-Object Label -like "*$label*")[0] }
            # Every machine without telemetry: nothing was observed, so there is no last observed data to describe and nothing is zero.
            (& $tile $scopeAllAbsent 'Reporting').Value | Should -Be 0
            (& $tile $scopeAllAbsent 'Reporting').Note | Should -Be 'no telemetry in window'
            (& $tile $scopeAllAbsent 'Latest sample').Value | Should -BeNullOrEmpty -Because 'no sample at all is unknown, never zero minutes'
            (& $tile $scopeAllAbsent 'Latest sample').Note | Should -Be 'no sample: unknown'
            (& $tile $scopeAllAbsent 'Adequate evidence').Value | Should -Be 0
            (& $tile $scopeAllAbsent 'Adequate evidence').Note | Should -Be 'no CPU samples'
            # Every machine silent: parked, and the figures describe the last observed data (48 hours old, 71% of the window observed).
            $silent = & $tile $scopeAllSilent 'Reporting'
            $silent.Value | Should -Be 0
            $silent.Note | Should -Be 'parked or silent'
            (& $tile $scopeAllSilent 'Latest sample').Value | Should -Be 2
            (& $tile $scopeAllSilent 'Latest sample').Note | Should -Be 'days since newest sample'
            (& $tile $scopeAllSilent 'Adequate evidence').Note | Should -Be 'median coverage 71%'
            # A mix: only the silent subset has observed data to describe.
            $mixed = & $tile $scopeMixed 'Reporting'
            $mixed.Value | Should -Be 0
            $mixed.Note | Should -Be '2 not reporting'
            (& $tile $scopeMixed 'Latest sample').Value | Should -Be 2
        }

        It 'counts mutually exclusive capacity assessments that add up to the machines in scope, on two rows of tiles' {
            $count = { param($label) [int](@(@($capTiles) + @($capTilesGaps) | Where-Object Label -like "*$label*")[0].Value) }
            @($capTiles | Where-Object Label -like '*Machines in scope*').Count | Should -Be 0
            @($capTiles).Count | Should -Be 3
            @($capTilesGaps).Count | Should -Be 2
            (& $count 'Pressure observed') | Should -Be 1
            (& $count 'Apparent headroom') | Should -Be 5
            (& $count 'Within thresholds') | Should -Be 1
            (& $count 'Insufficient evidence') | Should -Be 5
            (& $count 'No telemetry') | Should -Be 1
            ((& $count 'Pressure observed') + (& $count 'Apparent headroom') + (& $count 'Within thresholds') + (& $count 'Insufficient evidence') + (& $count 'No telemetry')) |
                Should -Be $definitions.Count
            # The tile caption names one machine and a count, so it never overflows the tile.
            (@($capTiles | Where-Object Label -like '*Apparent headroom*')[0]).Note | Should -Be 'devidle +4'
            (@($capTilesGaps | Where-Object Label -like '*No telemetry*')[0]).Note | Should -Be 'missing'
        }

        It 'adds the application context to the selected-machine tiles' {
            $context = @($detailTiles | Where-Object Label -eq 'Application')[0]
            $context.Value | Should -Be 'tools / dev'
            $context.Note | Should -Match 'owner erin \| cost centre cc-5 \| Linux'
            @($detailTiles).Count | Should -Be 7
            (@($detailTiles | Where-Object Label -eq 'Evidence')[0]).Value | Should -Be 'Adequate'
            (@($detailTiles | Where-Object Label -eq 'CPU P95 / peak')[0]).Value | Should -Be '2% / 2%'
        }

        It 'counts optimisation review reasons on two rows of tiles without implying a saving' {
            $count = { param($label) [int](@(@($optTiles) + @($optTilesHygiene) | Where-Object Label -like "*$label*")[0].Value) }
            @($optTiles).Count | Should -Be 4
            @($optTilesHygiene).Count | Should -Be 2
            (& $count 'Machines reviewed') | Should -Be $definitions.Count
            (& $count 'Low utilisation') | Should -Be 5
            (& $count 'Scheduling') | Should -Be 1
            (& $count 'Consolidation') | Should -Be 2
            (& $count 'Ownership gaps') | Should -Be 1
            (& $count 'Not reporting') | Should -Be 2
            (@($optTilesHygiene | Where-Object Label -like '*Not reporting*')[0]).Note | Should -Be 'missing, parked'
            (@($optTiles | Where-Object Label -like '*Machines reviewed*')[0]).Note | Should -Be '1 guest, counted once'
            (@($optTiles | Where-Object Label -like '*Low utilisation*')[0]).Note | Should -Be 'devidle +4'
            (@($optTiles) + @($optTilesHygiene) | ConvertTo-Json -Depth 4) | Should -Not -Match '(?i)saving'
        }
    }

    Context 'Grid columns' {
        It 'keeps the status grid to the columns an engineer reads first' {
            @($hostsGrid[0].PSObject.Properties.Name) | Should -Be @('Machine', 'Assessment', 'Evidence', 'CpuP95', 'CpuPeak', 'MemP95', 'FreePct')
            @($hostsGrid).Count | Should -Be $definitions.Count
        }

        It 'keeps the candidate grid short and shortens the guest-load gap without losing the full wording elsewhere' {
            @($candidatesGrid[0].PSObject.Properties.Name) | Should -Be @('Machine', 'Reasons', 'Evidence', 'Needs', 'CpuP95', 'MemP95')
            (Get-Fixture $candidatesGrid 'parent').Needs | Should -Be 'guest load'
            (Get-Fixture $candidatesGrid 'lowa').Needs | Should -Be 'nothing further'
            (Get-Fixture $candidates 'parent').Needs | Should -Be "guest load (not in the parent's own counters)"
        }

        It 'wraps the explanation of the selected machine into readable lines, never one long cell' {
            @($whyLines).Count | Should -BeGreaterThan 1
            $whyLines[0].Assessment | Should -Be 'Insufficient evidence'
            foreach ($row in $whyLines | Select-Object -Skip 1) { $row.Assessment | Should -BeNullOrEmpty }
            foreach ($row in $whyLines) { $row.Why.Length | Should -BeLessOrEqual 95 }
            (($whyLines.Why) -join ' ') | Should -Match "do not reflect the guest's load or physical CPU use"
        }

        It 'reads a silent machine as no telemetry in every counter and one absent counter as missing' {
            foreach ($column in 'CPU', 'Memory', 'AvailableMemory', 'DiskFree') {
                (Get-Fixture $methodMatrix 'missing').$column | Should -Be 'no telemetry'
            }
            # A machine that reports is never "no telemetry": its hours read as hours, and a counter it lacks reads as missing.
            (Get-Fixture $methodMatrix 'spike').CPU | Should -Match '^\d+(\.\d)? h$'
            (Get-Fixture $methodMatrix 'guest').CPU | Should -Match '^\d+(\.\d)? h$'
            (Get-Fixture $methodMatrix 'guest').Memory | Should -Be 'missing'
            (Get-Fixture $methodMatrix 'guest').DiskFree | Should -Be 'missing'
        }
    }

    Context 'Optimisation review reasons' {
        It 'flags low utilisation only on adequate evidence, worded as a conversation starter' {
            foreach ($name in 'spike', 'lowa', 'lowb', 'lowc', 'devidle') { (Get-Fixture $candidates $name).LowUtilisation | Should -Be 'Flagged' }
            foreach ($name in 'parent', 'short', 'parked', 'missing', 'invalid') { (Get-Fixture $candidates $name).LowUtilisation | Should -Be 'Needs evidence' }
            foreach ($name in 'guest', 'steady', 'pressure') { (Get-Fixture $candidates $name).LowUtilisation | Should -Be 'Not flagged' }
            (Get-Fixture $candidates 'lowa').Why | Should -Match 'sizing conversation starter'
            ($candidates.Why -join ' ') | Should -Not -Match '(?i)\b(resize to|downsize to|will save|safe to resize)\b'
            (Get-Fixture $candidates 'parent').Needs | Should -Match 'guest load'
        }

        It 'groups only similar non-guest low-utilisation machines for consolidation' {
            foreach ($name in 'lowa', 'lowb') { (Get-Fixture $candidates $name).Consolidation | Should -Be 'Flagged' }
            foreach ($name in 'spike', 'parent', 'guest', 'lowc', 'devidle', 'steady', 'pressure') { (Get-Fixture $candidates $name).Consolidation | Should -Be 'Not flagged' }
            (Get-Fixture $candidates 'lowa').Reasons | Should -Be 'Low utilisation, Consolidation'
        }

        It 'proposes scheduling only where an explicit non-production tag exists and never assumes an environment' {
            $dev = Get-Fixture $candidates 'devidle'
            $dev.Scheduling | Should -Be 'Flagged'
            $dev.IdleSharePct | Should -Be 100
            $dev.Reasons | Should -Be 'Low utilisation, Scheduling'
            (Get-Fixture $candidates 'lowc').Scheduling | Should -Be 'Needs evidence'
            (Get-Fixture $candidates 'lowc').Environment | Should -Be 'Unclassified'
            (Get-Fixture $candidates 'lowa').Scheduling | Should -Be 'Not flagged'
        }

        It 'explains every flagged reason in the review card and leaves each decision to a person' {
            # The card wraps long sentences into lines and names each aspect on its first line only.
            $text = {
                param($aspect)
                $collect = $false
                $lines = foreach ($row in $card) {
                    if ($row.Aspect) { $collect = ($row.Aspect -eq $aspect) }
                    if ($collect) { $row.Detail }
                }
                @($lines) -join ' '
            }
            foreach ($row in $card) { $row.Detail.Length | Should -BeLessOrEqual 90 }
            # Each reason starts on its own line and no line starts or ends on a separator character.
            foreach ($row in $card) { $row.Detail.Trim() | Should -Not -Match '^\||\|$' }
            @($card | Where-Object { $_.Detail -match '^Low utilisation: ' }).Count | Should -BeGreaterOrEqual 2 -Because 'one line in the reasons and one in the decisions'
            @($card | Where-Object { $_.Detail -match '^Scheduling: ' }).Count | Should -BeGreaterOrEqual 2
            $why = & $text 'Why'
            $why | Should -Match 'Low utilisation: .*sizing conversation starter'
            $why | Should -Match 'Scheduling: .*proposal for the owner to confirm'
            (& $text 'Next human decision') | Should -Match 'never stops or starts a machine'
            (& $text 'Not done here') | Should -Match 'No shutdown, resize, schedule, tag change or deletion'
            (& $text 'Evidence window') | Should -Not -Match 'UTC'
        }

        It 'reports ownership gaps as missing tags, not as proof that nobody owns the machine' {
            $row = Get-Fixture $candidates 'lowc'
            $row.Ownership | Should -Be 'Flagged'
            $row.Why | Should -Match 'owner'
            $row.Why | Should -Match 'not proof'
            (Get-Fixture $candidates 'lowa').Ownership | Should -Be 'Not flagged'
        }

        It 'flags silent and absent machines as not reporting without calling them safe to delete' {
            foreach ($name in 'parked', 'missing') { (Get-Fixture $candidates $name).NotReporting | Should -Be 'Flagged' }
            foreach ($name in 'invalid', 'pressure', 'spike') { (Get-Fixture $candidates $name).NotReporting | Should -Be 'Not flagged' }
            (Get-Fixture $candidates 'parked').Why | Should -Match 'stale does not mean safe to delete'
            (Get-Fixture $candidates 'missing').Why | Should -Match 'does not mean safe to delete'
        }
    }

    Context 'Activity heat map' {
        It 'shows twelve two-hour blocks and no hourly column' {
            $heatmap.Count | Should -BeGreaterThan 0
            @($heatmap[0].PSObject.Properties.Name) | Should -Be (@('Machine', 'IdleSharePct') + @(0..11 | ForEach-Object { 'B{0:00}' -f $_ }))
        }

        It 'fills each block with the average of every sample in its two local hours, blank only when neither hour has any' {
            $hourly.Count | Should -BeGreaterThan 0
            foreach ($row in $heatmap) {
                foreach ($block in 0..11) {
                    $cell = $row.('B{0:00}' -f $block)
                    $reporting = @($hourly | Where-Object { $_.Machine -eq $row.Machine -and $_.Hr -in @((2 * $block), (2 * $block + 1)) -and $_.N -gt 0 })
                    $because = "$($row.Machine) block $block covers hours $(2 * $block) and $(2 * $block + 1)"
                    if (-not $reporting.Count) {
                        $cell | Should -BeNullOrEmpty -Because "$because has no samples: unknown, never zero"
                        continue
                    }
                    $samples = ($reporting | Measure-Object -Property N -Sum).Sum
                    $expected = (($reporting | ForEach-Object { $_.N * $_.Avg } | Measure-Object -Sum).Sum) / $samples
                    $cell | Should -Not -BeNullOrEmpty -Because "$because has samples"
                    [math]::Abs([double]$cell - $expected) | Should -BeLessOrEqual 0.5000001 -Because "$because averages to $expected and the cell is rounded to a whole percent"
                }
            }
        }

        It 'shows a block with one reporting hour as that hour and leaves every other block of a short history blank' {
            # short has about an hour of samples: one or two local hours, so one or two blocks, whatever time the test runs.
            $blocks = @($hourly | Where-Object { $_.Machine -eq 'short' -and $_.N -gt 0 } | ForEach-Object { [math]::Floor($_.Hr / 2) } | Sort-Object -Unique)
            $blocks.Count | Should -BeIn 1, 2
            $row = Get-Fixture $heatmap 'short'
            foreach ($block in 0..11) {
                $cell = $row.('B{0:00}' -f $block)
                if ($block -in $blocks) { $cell | Should -Be 1 -Because "short reports a constant 1% in block $block" } else { $cell | Should -BeNullOrEmpty }
            }
        }

        It 'leaves a machine with no telemetry blank in every block and lets a busy hour show in its block' {
            $row = Get-Fixture $heatmap 'missing'
            foreach ($block in 0..11) { $row.('B{0:00}' -f $block) | Should -BeNullOrEmpty }
            $pressure = Get-Fixture $heatmap 'pressure'
            $cells = @(0..11 | ForEach-Object { $pressure.('B{0:00}' -f $_) })
            @($cells | Where-Object { $null -eq $_ }).Count | Should -Be 0 -Because 'pressure reports all day for a week'
            @($cells | Select-Object -Unique).Count | Should -BeGreaterThan 1 -Because 'one hour of sustained CPU raises its block above the rest'
        }
    }

    Context 'Optional cost scenario' {
        It 'matches the PowerShell reference arithmetic and states what it excludes' {
            $reference = Get-DemoOperationalScenario -MonthlyBaseline 1000 -EligibleSharePercent 60 -WeeklyHoursOff 108
            $text = { param($rows, $label) @($rows | Where-Object Label -eq $label)[0] }
            (& $text $scenario 'Illustrative reduction').Value | Should -Be ([math]::Round($reference.IllustrativeReduction, 2).ToString([cultureinfo]::InvariantCulture))
            (& $text $scenario 'Hours off per week').Value | Should -Be '108 of 168'
            (& $text $scenario 'Stays unchanged').Value | Should -Be ([math]::Round($reference.FixedBaseline, 2).ToString([cultureinfo]::InvariantCulture))
            (& $text $scenario 'Illustrative reduction').Note | Should -Match 'not billing'
        }

        It 'shows the scenario as two rows of three tiles: the inputs, then the arithmetic' {
            @($results.scenario).Count | Should -Be 3
            @($results.scenarioResult).Count | Should -Be 3
            @($results.scenario.Label) | Should -Be @('Workload', 'Your baseline', 'Eligible share')
            @($results.scenarioResult.Label) | Should -Be @('Hours off per week', 'Illustrative reduction', 'Stays unchanged')
            foreach ($row in $scenario) { $row.Note.Length | Should -BeLessOrEqual 46 -Because "'$($row.Note)' must fit a tile" }
        }

        It 'offers no scenario for a guest and stays unconfigured without inputs' {
            (@($guestScenario | Where-Object Label -eq 'Illustrative reduction')[0]).Value | Should -Be 'not configured'
            (@($guestScenario | Where-Object Label -eq 'Workload')[0]).Note | Should -Match 'guest'
            (@($emptyScenario | Where-Object Label -eq 'Illustrative reduction')[0]).Value | Should -Be 'not configured'
        }
    }
}
