BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $script:Repo 'scripts/lib/Common.psm1') -Force
    Import-Module (Join-Path $script:Repo 'scripts/lib/BuildPlan.psm1') -Force
    $script:Sub = '11111111-1111-1111-1111-111111111111'
    $script:Ten = '22222222-2222-2222-2222-222222222222'
    $script:Pin = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

    $nested = 'SubscriptionId', 'TenantId', 'ParentResourceGroup', 'ParentVmName', 'ParentVmId', 'ResourceGroup', 'Location', 'VmName', 'VmRoot', 'SwitchName',
        'WindowsIsoPath', 'SqlIsoPath', 'GuestCredential', 'GuestAddress', 'Gateway', 'DnsServer', 'OnboardingApplicationId', 'SkinPath'
    $target = 'SubscriptionId', 'TenantId', 'SkinPath'
    $exitSequence = @'
$codes = @(($env:BUILD_TEST_EXITS ?? '0') -split ',' | ForEach-Object { [int]$_ })
$counter = "$($env:BUILD_TEST_LOG).__NAME__.count"
$index = if (Test-Path -LiteralPath $counter) { [int](Get-Content -LiteralPath $counter -Raw) } else { 0 }
Set-Content -LiteralPath $counter -Value ($index + 1)
'{"status":"pass","checks":[]}'
exit $codes[[Math]::Min($index, $codes.Count - 1)]
'@
    # name -> parameters, whether it supports ShouldProcess (and so -Confirm), optional body
    $script:ArcStubs = [ordered]@{
        'Deploy-ArcDemo.ps1' = @{ Params = $target + 'AutoShutdownTime', 'DeployerPrincipalId', 'AdminPasswordPath'; Process = $true }
        'Prepare-NestedSqlParent.ps1' = @{ Params = $target + 'NamePrefix', 'Phase', 'MediaManifestPath', 'AcceptWindowsEvaluationTerms', 'AcceptSqlDeveloperTerms', 'AcceptanceRecordPath', 'ResultPath', 'BuildInputPath'; Process = $true }
        'New-NestedSqlDemo.ps1' = @{ Params = $nested; Process = $true }
        'Stage-DemoMedia.ps1' = @{ Params = $target + 'MachineName', 'Media', 'Destination', 'AcceptWindowsEvaluationTerms', 'AcceptSqlDeveloperTerms', 'ManifestPath', 'AcceptanceRecordPath', 'ResultPath'; Process = $true }
        'Invoke-SqlEngineOnArc.ps1' = @{ Params = $target + 'MachineName', 'Action', 'MediaIsoPath', 'MediaSha256', 'AcceptDeveloperLicenseTerms', 'ArcSqlAutoConnectOptOutConfirmed', 'ResultPath'; Process = $true }
        'Set-SqlIncidentAlert.ps1' = @{ Params = $target + 'MachineName', 'Action', 'WorkspaceResourceId', 'ActionGroupId'; Process = $true }
        'Set-OperationalWorkbook.ps1' = @{ Params = $target + 'Purpose', 'Action', 'WorkspaceResourceId'; Process = $true
            Body = '[pscustomobject]@{ status = ''published''; workbookResourceId = "/stub/workbooks/$Purpose"; published = $true }' }
        'Test-ArcDemoReadiness.ps1' = @{ Params = $target + 'NamePrefix', 'DesiredState', 'OutputFormat', 'TimeoutSeconds'; Process = $false; Body = $exitSequence }
        'Export-ArcDemoInventory.ps1' = @{ Params = $target + 'OutputPath'; Process = $false
            Body = 'if (-not (Test-Path -LiteralPath (Split-Path -Parent $OutputPath))) { throw ''output folder missing'' }; $OutputPath' }
        'Test-ArcDemoParity.ps1' = @{ Params = $target + 'SnapshotPath', 'Feature', 'OutputFormat'; Process = $false; Body = $exitSequence }
    }
    $script:SreStubs = [ordered]@{
        'New-LobArcAppMonitorAlert.ps1' = @{ Params = $target + 'Action'; Process = $true }
        'Invoke-LobArcAppOnArc.ps1' = @{ Params = $target + 'Action'; Process = $true }
        'Deploy-SreAgent.ps1' = @{ Params = $target + 'ConfigurationBackupPath', 'WhatIf', 'ApproveParentCreation', 'GrantAzureMonitorAlertAccess'; Process = $false }
        'Test-SreReadiness.ps1' = @{ Params = $target + 'DesiredState', 'OutputFormat', 'TimeoutSeconds'; Process = $false; Body = $exitSequence }
    }

    function New-BuildStub {
        param([string]$Folder, [string]$Name, [hashtable]$Spec, [string]$Override = '')
        $null = New-Item -ItemType Directory -Path $Folder -Force
        $binding = if ($Spec.Process) { '[CmdletBinding(SupportsShouldProcess)]' } else { '[CmdletBinding()]' }
        $parameters = ($Spec.Params | ForEach-Object { "`$$_" }) -join ', '
        $body = if ($Override) { $Override } elseif ($Spec.Body) { $Spec.Body.Replace('__NAME__', $Name) } else { '' }
        $lines = @(
            $binding
            "param($parameters)"
            '$entry = [ordered]@{ script = ''' + $Name + '''; keys = @($PSBoundParameters.Keys | Sort-Object) }'
            'foreach ($pair in $PSBoundParameters.GetEnumerator()) { $entry["v_$($pair.Key)"] = "$($pair.Value)" }'
            'Add-Content -LiteralPath $env:BUILD_TEST_LOG -Value ($entry | ConvertTo-Json -Compress)'
            $body
        )
        Set-Content -LiteralPath (Join-Path $Folder $Name) -Value $lines
    }

    function New-BuildFixture {
        param([string[]]$Without = @(), [scriptblock]$Mutate, [switch]$NoNested, [string[]]$MissingStub = @(), [hashtable]$StubBody = @{}, [switch]$RealPresenter, [string]$GrantParameter = 'GrantAzureMonitorAlertAccess')
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $fixture = @{ Root = $root; Repo = (Join-Path $root 'repo'); Private = (Join-Path $root 'private'); Sre = (Join-Path $root 'sre')
            Log = (Join-Path $root 'calls.log'); ConfigPath = (Join-Path $root 'private/build.json') }
        $null = New-Item -ItemType Directory -Path $fixture.Private, (Join-Path $fixture.Repo 'scripts'), (Join-Path $fixture.Sre 'scripts') -Force
        foreach ($name in $script:ArcStubs.Keys | Where-Object { $_ -notin $MissingStub }) {
            New-BuildStub (Join-Path $fixture.Repo 'scripts') $name $script:ArcStubs[$name] $StubBody[$name]
        }
        foreach ($name in $script:SreStubs.Keys | Where-Object { $_ -notin $MissingStub }) {
            $spec = $script:SreStubs[$name].Clone()
            if ($name -eq 'Deploy-SreAgent.ps1') { $spec.Params = @($spec.Params | Where-Object { $_ -ne 'GrantAzureMonitorAlertAccess' }) + $GrantParameter }
            New-BuildStub (Join-Path $fixture.Sre 'scripts') $name $spec $StubBody[$name]
        }
        if ($RealPresenter) {
            $null = New-Item -ItemType Directory -Path (Join-Path $fixture.Repo 'docs') -Force
            Copy-Item -LiteralPath (Join-Path $script:Repo 'scripts/New-PresenterRunsheet.ps1') -Destination (Join-Path $fixture.Repo 'scripts') -Force
            Copy-Item -LiteralPath (Join-Path $script:Repo 'docs/runsheet.md') -Destination (Join-Path $fixture.Repo 'docs') -Force
        } else {
            New-BuildStub (Join-Path $fixture.Repo 'scripts') 'New-PresenterRunsheet.ps1' @{ Params = @('ContextPath'); Process = $true }
        }
        $skin = [ordered]@{
            schemaVersion = 1; azure = @{ namePrefix = 'build-test'; location = 'australiaeast' }
            workloads = @{ deployContainerApps = $true }; labels = @{ demoTitle = 'Build Test' }
            nestedSqlGuest = @{ enabled = (-not $NoNested); parentVmName = 'parent-vm'; guestVmName = 'guest-vm'; arcMachineName = 'guest-vm' }
        }
        $skin | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $fixture.Private 'arc-skin.json')
        Set-Content (Join-Path $fixture.Private 'sre-skin.json') '{}'
        @{ schemaVersion = 1; media = @{ 'sql-server-2022-developer' = @{ fileName = 'sql.iso'; sha256 = $script:Pin } } } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $fixture.Private 'media.json')
        @{ SwitchName = 'switch'; WindowsIsoPath = 'D:\Media\w.iso'; SqlIsoPath = 'D:\Media\s.iso'; GuestAddress = '172.31.240.20'; Gateway = '172.31.240.1'; DnsServer = '168.63.129.16' } |
            ConvertTo-Json | Set-Content (Join-Path $fixture.Private 'nested-sql-build.json')
        $config = [ordered]@{
            schemaVersion = 1; arcSkinPath = 'arc-skin.json'; nestedSqlBuildInputPath = 'nested-sql-build.json'; mediaManifestPath = 'media.json'
            realSql = [ordered]@{ machineName = 'sql-host'; isoPath = 'D:\Media\sql.iso' }
            sre = [ordered]@{ repoPath = $fixture.Sre; skinPath = 'sre-skin.json' }
            presenter = [ordered]@{ windowsMachineName = 'win-host'; linuxMachineName = 'lnx-host'; lobMachineName = 'win-host' }
        }
        foreach ($key in $Without) { $config.Remove($key) }
        if ($Mutate) { & $Mutate $config }
        $config | ConvertTo-Json -Depth 6 | Set-Content $fixture.ConfigPath
        $fixture
    }

    function Get-BuildTest {
        param($Fixture, [hashtable]$Approved = @{}, $State, [switch]$Force, [switch]$Grant, [string]$From, [string]$To, [string[]]$Only, [pscredential]$Credential)
        $config = Read-ArcDemoBuildConfig -Path $Fixture.ConfigPath -RepoRoot $Fixture.Repo
        $context = New-ArcDemoBuildContext -Config $config -SubscriptionId $script:Sub -TenantId $script:Ten -RepoRoot $Fixture.Repo `
            -Approved $Approved -ApproveSubscriptionGrant:$Grant -GuestCredential $Credential
        if (-not $State) { $State = New-ArcDemoBuildState $script:Sub $script:Ten $context.Prefix }
        $selection = @{}
        if ($From) { $selection.From = $From }
        if ($To) { $selection.To = $To }
        if ($Only) { $selection.Only = $Only }
        $steps = Select-ArcDemoBuildStep -Steps (Get-ArcDemoBuildSteps -Context $context) @selection
        [pscustomobject]@{ Context = $context; State = $State; Plan = @(Get-ArcDemoBuildPlan -Context $context -Steps $steps -State $State -Force:$Force) }
    }

    function Get-BuildCall {
        param($Fixture)
        if (Test-Path -LiteralPath $Fixture.Log) { @(Get-Content -LiteralPath $Fixture.Log | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
    }
    function Get-BuildRow { param($Test, [string]$Step) $Test.Plan | Where-Object Step -eq $Step }
}

AfterAll {
    $env:BUILD_TEST_LOG = $null
    $env:BUILD_TEST_EXITS = $null
}

Describe 'Private build config' {
    It 'loads a minimal config, resolves paths against the private folder and applies defaults' {
        $f = New-BuildFixture -Without 'realSql', 'sre', 'presenter', 'nestedSqlBuildInputPath', 'mediaManifestPath'
        $config = Read-ArcDemoBuildConfig -Path $f.ConfigPath -RepoRoot $f.Repo
        $config.ArcSkinPath | Should -Be (Join-Path $f.Private 'arc-skin.json')
        $config.StatePath | Should -Be (Join-Path $f.Private 'build-state.json')
        $config.EvidenceDirectory | Should -Be (Join-Path $f.Private 'evidence')
        $config.BackupDirectory | Should -Be (Join-Path $f.Private 'sre-backups')
        $config.RealSql | Should -BeNullOrEmpty
        $config.Sre | Should -BeNullOrEmpty
        $config.Presenter | Should -BeNullOrEmpty
        $config.OperationalWorkbooks | Should -BeTrue
        $config.NestedSqlBuildInputPath | Should -Be ''
    }

    It 'loads the optional sections' {
        $f = New-BuildFixture
        $config = Read-ArcDemoBuildConfig -Path $f.ConfigPath -RepoRoot $f.Repo
        $config.RealSql.MachineName | Should -Be 'sql-host'
        $config.RealSql.StageMedia | Should -BeTrue
        $config.Sre.RepoPath | Should -Be $f.Sre
        $config.Sre.SkinPath | Should -Be (Join-Path $f.Private 'sre-skin.json')
        $config.Sre.GrantSwitch | Should -Be 'GrantAzureMonitorAlertAccess'
        $config.Presenter.LobMachineName | Should -Be 'win-host'
    }

    It 'rejects <Name>' -TestCases @(
        @{ Name = 'an unknown top-level field'; Mutate = { param($c) $c.extra = 1 }; Message = '*Unsupported build config field*' }
        @{ Name = 'an unknown nested field'; Mutate = { param($c) $c.sre.extra = 1 }; Message = '*Unsupported sre field*' }
        @{ Name = 'a missing skin'; Mutate = { param($c) $c.Remove('arcSkinPath') }; Message = '*requires arcSkinPath*' }
        @{ Name = 'a bad shutdown time'; Mutate = { param($c) $c.autoShutdownTime = '2460' }; Message = '*HHmm*' }
        @{ Name = 'a bad deployer ID'; Mutate = { param($c) $c.deployerPrincipalId = 'not-a-guid' }; Message = '*GUID*' }
        @{ Name = 'a string boolean'; Mutate = { param($c) $c.operationalWorkbooks = 'yes' }; Message = '*JSON boolean*' }
        @{ Name = 'a relative SQL ISO path'; Mutate = { param($c) $c.realSql.isoPath = 'sql.iso' }; Message = '*guest-local*' }
        @{ Name = 'a SQL ISO path with no folder'; Mutate = { param($c) $c.realSql.isoPath = 'D:\sql.iso' }; Message = '*inside a folder*' }
        @{ Name = 'an SRE section without a skin'; Mutate = { param($c) $c.sre.Remove('skinPath') }; Message = '*requires repoPath*' }
        @{ Name = 'a bad grant switch name'; Mutate = { param($c) $c.sre.grantSwitch = 'bad name' }; Message = '*parameter name*' }
        @{ Name = 'a bad presenter machine'; Mutate = { param($c) $c.presenter.linuxMachineName = 'bad name!' }; Message = '*valid machine name*' }
        @{ Name = 'a different schema version'; Mutate = { param($c) $c.schemaVersion = 2 }; Message = '*schemaVersion 1*' }
    ) {
        param($Mutate, $Message)
        $f = New-BuildFixture -Mutate $Mutate
        { Read-ArcDemoBuildConfig -Path $f.ConfigPath -RepoRoot $f.Repo } | Should -Throw $Message
    }

    It 'rejects a folder inside the git worktree, malformed JSON and a missing file' {
        $f = New-BuildFixture
        $inside = Join-Path $f.Repo 'private-copy'
        $null = New-Item -ItemType Directory -Path $inside
        Copy-Item $f.ConfigPath (Join-Path $inside 'build.json')
        { Read-ArcDemoBuildConfig -Path (Join-Path $inside 'build.json') -RepoRoot $f.Repo } | Should -Throw '*outside the git worktree*'
        Set-Content (Join-Path $f.Private 'broken.json') '{ nope'
        { Read-ArcDemoBuildConfig -Path (Join-Path $f.Private 'broken.json') -RepoRoot $f.Repo } | Should -Throw '*Invalid JSON*'
        { Read-ArcDemoBuildConfig -Path (Join-Path $f.Private 'missing.json') -RepoRoot $f.Repo } | Should -Throw '*not found*'
    }

    It 'validates the tracked example config shape' {
        $example = Join-Path $script:Repo 'config/build-plan.example.json'
        $private = Join-Path $TestDrive 'example-private'
        $null = New-Item -ItemType Directory -Path $private
        Copy-Item $example (Join-Path $private 'build.json')
        $config = Read-ArcDemoBuildConfig -Path (Join-Path $private 'build.json') -RepoRoot $script:Repo
        $config.RealSql.MachineName | Should -Not -BeNullOrEmpty
        $config.Sre.GrantSwitch | Should -Not -BeNullOrEmpty
        (Get-Content $example -Raw) | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|@|[A-Za-z]:\\Users'
    }
}

Describe 'Ordered plan' {
    It 'lists every phase in order for a full config' {
        $t = Get-BuildTest (New-BuildFixture)
        $t.Plan.Step | Should -Be @('P0', 'P1', 'P2', 'P3', 'P4', 'P5.1', 'P5.2', 'P5.3', 'P5.4', 'P6.1', 'P6.2', 'P6.3', 'P7', 'P8.1', 'P8.2', 'P9.1', 'P9.2', 'P9.3', 'P10', 'P11.1', 'P11.2')
        @($t.Plan | Where-Object Status -eq 'blocked') | Should -HaveCount 0
        @($t.Plan | Where-Object Status -eq 'skipped') | Should -HaveCount 0
    }

    It 'skips optional phases with a reason when the config or skin does not ask for them' {
        $t = Get-BuildTest (New-BuildFixture -Without 'realSql', 'sre', 'presenter' -NoNested -Mutate { param($c) $c.operationalWorkbooks = $false })
        $skipped = @($t.Plan | Where-Object Status -eq 'skipped')
        $skipped.Step | Should -Be @('P3', 'P4', 'P5.1', 'P5.2', 'P5.3', 'P5.4', 'P6.1', 'P6.2', 'P6.3', 'P8.1', 'P8.2', 'P9.1', 'P9.2', 'P9.3', 'P10')
        (Get-BuildRow $t 'P3').Reason | Should -Match 'nestedSqlGuest'
        (Get-BuildRow $t 'P6.2').Reason | Should -Match 'operationalWorkbooks'
        (Get-BuildRow $t 'P9.2').Reason | Should -Match 'sre'
    }

    It 'skips SQL media staging when the ISO is already staged' {
        $t = Get-BuildTest (New-BuildFixture -Mutate { param($c) $c.realSql.stageMedia = $false })
        (Get-BuildRow $t 'P5.1').Status | Should -Be 'skipped'
        (Get-BuildRow $t 'P5.2').Status | Should -Be 'ready'
    }

    It 'blocks steps whose script, parameter or input is missing instead of guessing' {
        $missing = Get-BuildTest (New-BuildFixture -MissingStub 'Prepare-NestedSqlParent.ps1', 'Stage-DemoMedia.ps1')
        (Get-BuildRow $missing 'P3').Blockers | Should -Match 'Script not available yet'
        (Get-BuildRow $missing 'P5.1').Status | Should -Be 'blocked'
        $drift = Get-BuildTest (New-BuildFixture) -Grant
        (Get-BuildRow $drift 'P9.2').Status | Should -Be 'ready'
        $other = Get-BuildTest (New-BuildFixture -GrantParameter 'SomethingElse') -Grant
        (Get-BuildRow $other 'P9.2').Blockers | Should -Match 'does not accept: GrantAzureMonitorAlertAccess'
        $noInput = Get-BuildTest (New-BuildFixture -Mutate { param($c) $c.mediaManifestPath = 'missing-media.json' })
        (Get-BuildRow $noInput 'P3').Blockers | Should -Match 'media manifest not found'
        (Get-BuildRow $noInput 'P5.1').Blockers | Should -Match 'media manifest not found'
        (Get-BuildRow $noInput 'P5.3').Blockers | Should -Match 'media manifest not found'
        $noPin = New-BuildFixture
        @{ schemaVersion = 1; media = @{ 'sql-server-2022-developer' = @{ fileName = 'sql.iso'; sha256 = 'short' } } } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $noPin.Private 'media.json')
        (Get-BuildRow (Get-BuildTest $noPin) 'P5.3').Blockers | Should -Match 'sha256 for sql-server-2022-developer'
        $noRepo = Get-BuildTest (New-BuildFixture -Mutate { param($c) $c.sre.repoPath = (Join-Path $c.sre.repoPath 'nowhere') })
        (Get-BuildRow $noRepo 'P8.1').Blockers | Should -Match 'sre.repoPath is not a folder'
    }

    It 'passes the real media-staging arguments and falls back to the tracked manifest when none is configured' {
        $f = New-BuildFixture
        $t = Get-BuildTest $f
        $stage = & (Get-BuildRow $t 'P5.1').Definition.Arguments $t.Context
        ($stage['Media'] -join ',') | Should -Be 'sql-server-2022-developer'
        $stage['Destination'] | Should -Be 'D:\Media'
        $stage['AcceptSqlDeveloperTerms'] | Should -BeTrue
        $stage['ManifestPath'] | Should -Be (Join-Path $f.Private 'media.json')
        $stage['AcceptanceRecordPath'] | Should -Be (Join-Path $t.Context.Config.EvidenceDirectory 'media-acceptance.json')
        $stage.Keys | Should -Not -Contain 'DestinationPath'

        $tracked = New-BuildFixture -Without 'mediaManifestPath'
        $null = New-Item -ItemType Directory -Path (Join-Path $tracked.Repo 'config') -Force
        @{ schemaVersion = 1; media = @{ 'sql-server-2022-developer' = @{ fileName = 'sql.iso'; sha256 = $script:Pin } } } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $tracked.Repo 'config/demo-media.json')
        $u = Get-BuildTest $tracked
        (Get-BuildRow $u 'P5.1').Status | Should -Be 'ready'
        (& (Get-BuildRow $u 'P5.1').Definition.Arguments $u.Context).Keys | Should -Not -Contain 'ManifestPath'
        (& (Get-BuildRow $u 'P3').Definition.Arguments $u.Context).Keys | Should -Not -Contain 'MediaManifestPath'
        (& (Get-BuildRow $t 'P3').Definition.Arguments $t.Context)['MediaManifestPath'] | Should -Be (Join-Path $f.Private 'media.json')
        (& (Get-BuildRow $t 'P3').Definition.Arguments $t.Context)['BuildInputPath'] | Should -Be (Join-Path $f.Private 'nested-sql-build.json')
        (& (Get-BuildRow $u 'P5.3').Definition.Arguments $u.Context)['MediaSha256'] | Should -Be $script:Pin
        $missing = Get-BuildTest (New-BuildFixture -Without 'mediaManifestPath')
        (Get-BuildRow $missing 'P5.1').Blockers | Should -Match 'media manifest not found.*demo-media\.json'
    }

    It 'blocks staging when the SQL ISO name would not match the manifest file name' {
        $t = Get-BuildTest (New-BuildFixture -Mutate { param($c) $c.realSql.isoPath = 'D:\Media\other.iso' })
        (Get-BuildRow $t 'P5.1').Blockers | Should -Match 'must end with \\sql\.iso'
        (Get-BuildRow $t 'P5.3').Status | Should -Be 'ready'
    }

    It 'accepts a nested build input that the parent step will create, but not one that is incomplete' {
        $f = New-BuildFixture
        Remove-Item (Join-Path $f.Private 'nested-sql-build.json')
        (Get-BuildRow (Get-BuildTest $f) 'P4').Status | Should -Be 'ready'
        (Get-BuildRow (Get-BuildTest $f -Only 'P4') 'P4').Blockers | Should -Match 'nestedSqlBuildInputPath not found'
        Set-Content (Join-Path $f.Private 'nested-sql-build.json') '{"SwitchName":"switch"}'
        (Get-BuildRow (Get-BuildTest $f -Only 'P4') 'P4').Blockers | Should -Match 'WindowsIsoPath, SqlIsoPath, GuestAddress, Gateway, DnsServer'
    }

    It 'asks for the explicit switches only for steps that would run' {
        $none = Get-BuildTest (New-BuildFixture)
        (Get-BuildRow $none 'P2').Needs | Should -Be @('CostStart')
        (Get-BuildRow $none 'P3').Needs | Should -Be @('WindowsEvaluationTerms', 'SqlDeveloperTerms')
        (Get-BuildRow $none 'P5.1').Needs | Should -Be @('SqlDeveloperTerms')
        (Get-BuildRow $none 'P5.3').Needs | Should -Be @('SqlDeveloperTerms')
        (Get-BuildRow $none 'P9.2').Needs | Should -Be @('SreCreation')
        (Get-BuildRow $none 'P4').Needs | Should -HaveCount 0
        $all = @{ CostStart = $true; WindowsEvaluationTerms = $true; SqlDeveloperTerms = $true; SreCreation = $true }
        @((Get-BuildTest (New-BuildFixture) -Approved $all).Plan | Where-Object { $_.Needs.Count }) | Should -HaveCount 0
        $state = New-ArcDemoBuildState $script:Sub $script:Ten 'build-test'
        $state.steps['P2'] = @{ status = 'done' }
        (Get-BuildRow (Get-BuildTest (New-BuildFixture) -State $state) 'P2').Needs | Should -HaveCount 0
    }

    It 'runs the two workbook steps again when P2 or P4 finished after they did, and says why' {
        $f = New-BuildFixture
        $state = New-ArcDemoBuildState $script:Sub $script:Ten 'build-test'
        $state.steps['P6.1'] = @{ status = 'done'; endedUtc = '2026-11-05T08:00:00.0000000Z' }
        foreach ($id in 'P6.2', 'P6.3') { $state.steps[$id] = @{ status = 'done'; endedUtc = '2026-11-05T08:00:00.0000000Z' } }
        $state.steps['P4'] = @{ status = 'done'; endedUtc = '2026-11-05T07:00:00.0000000Z' }
        $t = Get-BuildTest $f -State $state
        foreach ($id in 'P6.1', 'P6.2', 'P6.3') { (Get-BuildRow $t $id).Status | Should -Be 'done' }

        $state.steps['P4'].endedUtc = '2026-11-05T09:30:00.0000000Z'
        $t = Get-BuildTest $f -State $state
        (Get-BuildRow $t 'P6.1').Status | Should -Be 'done'
        foreach ($id in 'P6.2', 'P6.3') {
            (Get-BuildRow $t $id).Status | Should -Be 'ready'
            (Get-BuildRow $t $id).Notes | Should -Match 'P4 finished later'
            $id | Should -BeIn $t.Context.PlannedSteps
        }

        # A state file read back from JSON holds [datetime] values.
        $path = Join-Path $TestDrive 'stale-state.json'
        Save-ArcDemoBuildState -Path $path -State $state
        $again = Read-ArcDemoBuildState -Path $path -SubscriptionId $script:Sub -TenantId $script:Ten -Prefix 'build-test'
        $again.steps['P4']['endedUtc'] | Should -BeOfType [datetime]
        (Get-BuildRow (Get-BuildTest $f -State $again) 'P6.2').Status | Should -Be 'ready'

        # P2 counts too, and a step that did not finish does not make the roster stale.
        $state.steps['P4'].endedUtc = '2026-11-05T07:00:00.0000000Z'
        $state.steps['P2'] = @{ status = 'done'; endedUtc = '2026-11-05T08:30:00.0000000Z' }
        (Get-BuildRow (Get-BuildTest $f -State $state) 'P6.3').Status | Should -Be 'ready'
        $state.steps['P2'].status = 'failed'
        (Get-BuildRow (Get-BuildTest $f -State $state) 'P6.3').Status | Should -Be 'done'
        (Get-BuildRow (Get-BuildTest $f -State $state) 'P6.3').Notes | Should -HaveCount 0
    }

    It 'selects one step by its ID with -Only, as well as a whole phase' {
        $f = New-BuildFixture
        $t = Get-BuildTest $f
        $steps = @(Get-ArcDemoBuildSteps -Context $t.Context)
        (Select-ArcDemoBuildStep -Steps $steps -Only 'P6.2', 'P6.3').Id | Should -Be @('P6.2', 'P6.3')
        (Select-ArcDemoBuildStep -Steps $steps -Only 'P6').Id | Should -Be @('P6.1', 'P6.2', 'P6.3')
        (Select-ArcDemoBuildStep -Steps $steps -Only 'P7').Id | Should -Be @('P7')
        $only = (Get-Command (Join-Path $script:Repo 'scripts/Invoke-ArcDemoBuild.ps1')).Parameters['Only'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        foreach ($id in @($steps.Id) + @($steps.Phase | Select-Object -Unique)) { $id | Should -BeIn $only.ValidValues }
    }

    It 'skips done steps, always re-checks read-only steps and re-runs everything with -Force' {
        $f = New-BuildFixture
        $state = New-ArcDemoBuildState $script:Sub $script:Ten 'build-test'
        foreach ($id in 'P2', 'P5.3', 'P7') { $state.steps[$id] = @{ status = 'done' } }
        $t = Get-BuildTest $f -State $state
        (Get-BuildRow $t 'P2').Status | Should -Be 'done'
        (Get-BuildRow $t 'P5.3').Status | Should -Be 'done'
        (Get-BuildRow $t 'P7').Status | Should -Be 'ready'
        (Get-BuildRow (Get-BuildTest $f -State $state -Force) 'P2').Status | Should -Be 'ready'
    }

    It 'runs the SRE preview once: it is not re-checked after it is recorded done' {
        $f = New-BuildFixture
        $state = New-ArcDemoBuildState $script:Sub $script:Ten 'build-test'
        $state.steps['P9.1'] = @{ status = 'done' }
        (Get-BuildRow (Get-BuildTest $f -State $state) 'P9.1').Status | Should -Be 'done'
        (Get-BuildRow (Get-BuildTest $f -State $state -Force) 'P9.1').Status | Should -Be 'ready'
    }

    It 'skips the SRE preview and create steps, without asking for approval, when the SRE parent already exists' {
        $f = New-BuildFixture
        $state = New-ArcDemoBuildState $script:Sub $script:Ten 'build-test'
        $state.steps['P9.2'] = @{ status = 'failed'; attempts = 1 }
        $t = Get-BuildTest $f -State $state
        (Get-BuildRow $t 'P9.2').Status | Should -Be 'blocked'
        $script:AzCalls = [System.Collections.Generic.List[string]]::new()
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        Mock Invoke-DemoAz {
            $script:AzCalls.Add(($Arguments -join ' '))
            '[{"name":"sre-build-test","type":"Microsoft.App/agents"},{"name":"sre-build-test-uami","type":"Microsoft.ManagedIdentity/userAssignedIdentities"}]'
        } -ModuleName BuildPlan
        Resolve-ArcDemoPlanSkip -Plan $t.Plan -Context $t.Context
        foreach ($id in 'P9.1', 'P9.2') {
            (Get-BuildRow $t $id).Status | Should -Be 'skipped'
            (Get-BuildRow $t $id).Reason | Should -Match 'already exists.*refuses an existing parent'
            (Get-BuildRow $t $id).Needs | Should -HaveCount 0
            (Get-BuildRow $t $id).Blockers | Should -HaveCount 0
        }
        (Get-BuildRow $t 'P9.3').Status | Should -Be 'ready'
        @($t.Plan | Where-Object { $_.Status -eq 'ready' -and $_.Step -like 'P9*' }).Step | Should -Be @('P9.3')
        $script:AzCalls | Should -Not -BeNullOrEmpty
        $script:AzCalls | ForEach-Object { $_ | Should -Match '^resource list -g rg-build-test-sre ' }
    }

    It 'keeps the SRE steps when the parent is absent, and blocks them with the exact error when it cannot be read' {
        $f = New-BuildFixture
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        Mock Invoke-DemoAz { $null } -ModuleName BuildPlan
        $absent = Get-BuildTest $f
        Resolve-ArcDemoPlanSkip -Plan $absent.Plan -Context $absent.Context
        (Get-BuildRow $absent 'P9.1').Status | Should -Be 'ready' -Because ((Get-BuildRow $absent 'P9.1').Blockers -join '; ')
        (Get-BuildRow $absent 'P9.2').Status | Should -Be 'ready'
        (Get-BuildRow $absent 'P9.2').Needs | Should -Be @('SreCreation')
        Mock Invoke-DemoAz { '[{"name":"someone-else","type":"Microsoft.App/agents"}]' } -ModuleName BuildPlan
        $other = Get-BuildTest $f
        Resolve-ArcDemoPlanSkip -Plan $other.Plan -Context $other.Context
        (Get-BuildRow $other 'P9.2').Status | Should -Be 'ready'
        Mock Invoke-DemoAz { throw 'Azure CLI resource list failed (exit 1): (AuthorizationFailed) denied for the test' } -ModuleName BuildPlan
        $denied = Get-BuildTest $f
        Resolve-ArcDemoPlanSkip -Plan $denied.Plan -Context $denied.Context
        foreach ($id in 'P9.1', 'P9.2') {
            (Get-BuildRow $denied $id).Status | Should -Be 'blocked'
            (Get-BuildRow $denied $id).Blockers | Should -Match 'Cannot tell whether this step is needed.*AuthorizationFailed'
        }
    }

    It 'reads the agent name and group from the SRE skin' {
        $f = New-BuildFixture
        @{ azure = @{ namePrefix = 'other-prefix' }; labels = @{ agentName = 'custom-agent' } } | ConvertTo-Json | Set-Content (Join-Path $f.Private 'sre-skin.json')
        $t = Get-BuildTest $f
        $script:AzCalls = [System.Collections.Generic.List[string]]::new()
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        Mock Invoke-DemoAz { $script:AzCalls.Add(($Arguments -join ' ')); '[{"name":"custom-agent","type":"Microsoft.App/agents"}]' } -ModuleName BuildPlan
        Resolve-ArcDemoPlanSkip -Plan $t.Plan -Context $t.Context
        (Get-BuildRow $t 'P9.2').Status | Should -Be 'skipped'
        $script:AzCalls[0] | Should -Match '^resource list -g rg-other-prefix-sre '
    }

    It 'refuses to retry a failed step that is not safe to repeat until -Force' {
        $f = New-BuildFixture
        $state = New-ArcDemoBuildState $script:Sub $script:Ten 'build-test'
        $state.steps['P4'] = @{ status = 'failed' }
        $state.steps['P2'] = @{ status = 'failed' }
        $t = Get-BuildTest $f -State $state
        (Get-BuildRow $t 'P4').Status | Should -Be 'blocked'
        (Get-BuildRow $t 'P4').Blockers | Should -Match 'earlier attempt failed'
        (Get-BuildRow $t 'P2').Status | Should -Be 'ready'
        (Get-BuildRow (Get-BuildTest $f -State $state -Force) 'P4').Status | Should -Be 'ready'
    }

    It 'blocks a non-repeatable step whose earlier attempt was interrupted, but simply re-runs a repeatable one' {
        $f = New-BuildFixture
        $state = New-ArcDemoBuildState $script:Sub $script:Ten 'build-test'
        $state.steps['P9.2'] = @{ status = 'running'; attempts = 1 }
        $state.steps['P2'] = @{ status = 'running'; attempts = 1 }
        $t = Get-BuildTest $f -State $state
        (Get-BuildRow $t 'P9.2').Status | Should -Be 'blocked'
        (Get-BuildRow $t 'P9.2').Blockers | Should -Match 'interrupted'
        (Get-BuildRow $t 'P2').Status | Should -Be 'ready'
        (Get-BuildRow (Get-BuildTest $f -State $state -Force) 'P9.2').Status | Should -Be 'ready'
    }

    It 'omits the parity feature list when no optional feature is enabled' {
        $f = New-BuildFixture -Without 'realSql', 'sre', 'presenter' -NoNested -Mutate { param($c) $c.operationalWorkbooks = $false }
        $skinPath = Join-Path $f.Private 'arc-skin.json'
        $skin = Get-Content $skinPath -Raw | ConvertFrom-Json -AsHashtable
        $skin.workloads.deployContainerApps = $false
        $skin | ConvertTo-Json -Depth 5 | Set-Content $skinPath
        $t = Get-BuildTest $f
        $row = Get-BuildRow $t 'P11.2'
        $row.Status | Should -Be 'ready'
        (& $row.Definition.Arguments $t.Context).Keys | Should -Not -Contain 'Feature'
    }

    It 'adds the SRE grant switch only when the grant was approved and confirms the SQL opt-out only after it was blocked' {
        $f = New-BuildFixture
        $plain = Get-BuildTest $f
        $create = & (Get-BuildRow $plain 'P9.2').Definition.Arguments $plain.Context
        $create['ApproveParentCreation'] | Should -BeTrue
        $create.Keys | Should -Not -Contain 'WhatIf'
        $preview = & (Get-BuildRow $plain 'P9.1').Definition.Arguments $plain.Context
        $preview['WhatIf'] | Should -BeTrue
        $preview.Keys | Should -Not -Contain 'ApproveParentCreation'
        (& (Get-BuildRow $plain 'P9.2').Definition.Arguments $plain.Context).Keys | Should -Not -Contain 'GrantAzureMonitorAlertAccess'
        $granted = Get-BuildTest $f -Grant
        (& (Get-BuildRow $granted 'P9.2').Definition.Arguments $granted.Context).Keys | Should -Contain 'GrantAzureMonitorAlertAccess'
        (& (Get-BuildRow $plain 'P5.3').Definition.Arguments $plain.Context).Keys | Should -Not -Contain 'ArcSqlAutoConnectOptOutConfirmed'
        $state = New-ArcDemoBuildState $script:Sub $script:Ten 'build-test'
        $state.steps['P5.2'] = @{ status = 'done' }
        $protected = Get-BuildTest $f -State $state
        $arguments = & (Get-BuildRow $protected 'P5.3').Definition.Arguments $protected.Context
        $arguments['ArcSqlAutoConnectOptOutConfirmed'] | Should -BeTrue
        $arguments['MediaSha256'] | Should -Be $script:Pin
    }

    It 'selects phases with -From/-To and -Only' {
        $f = New-BuildFixture
        (Get-BuildTest $f -From P5 -To P6).Plan.Step | Should -Be @('P5.1', 'P5.2', 'P5.3', 'P5.4', 'P6.1', 'P6.2', 'P6.3')
        (Get-BuildTest $f -From p5 -To p6).Plan.Step | Should -Be @('P5.1', 'P5.2', 'P5.3', 'P5.4', 'P6.1', 'P6.2', 'P6.3')
        (Get-BuildTest $f -Only P7, P11).Plan.Step | Should -Be @('P7', 'P11.1', 'P11.2')
        (Get-BuildTest $f -From P10).Plan.Step | Should -Be @('P10', 'P11.1', 'P11.2')
        { Get-BuildTest $f -Only P7 -From P2 } | Should -Throw '*either -Only or -From/-To*'
        { Get-BuildTest $f -From P7 -To P2 } | Should -Throw '*comes after*'
    }
}

Describe 'Resume state' {
    It 'starts empty, round-trips atomically and rejects another target or a malformed file' {
        $path = Join-Path $TestDrive 'state/build-state.json'
        $state = Read-ArcDemoBuildState -Path $path -SubscriptionId $script:Sub -TenantId $script:Ten -Prefix 'build-test'
        $state.steps.Count | Should -Be 0
        $state.steps['P2'] = @{ status = 'done'; attempts = 1 }
        $state.values['snapshotPath'] = 'x.json'
        Save-ArcDemoBuildState -Path $path -State $state
        Test-Path "$path.tmp" | Should -BeFalse
        $again = Read-ArcDemoBuildState -Path $path -SubscriptionId $script:Sub -TenantId $script:Ten -Prefix 'build-test'
        $again.steps['P2'].status | Should -Be 'done'
        $again.values['snapshotPath'] | Should -Be 'x.json'
        { Read-ArcDemoBuildState -Path $path -SubscriptionId $script:Sub -TenantId $script:Ten -Prefix 'other-prefix' } | Should -Throw '*different target*'
        { Read-ArcDemoBuildState -Path $path -SubscriptionId $script:Ten -TenantId $script:Ten -Prefix 'build-test' } | Should -Throw '*different target*'
        Set-Content $path '{"schemaVersion":1}'
        { Read-ArcDemoBuildState -Path $path -SubscriptionId $script:Sub -TenantId $script:Ten -Prefix 'build-test' } | Should -Throw '*malformed*'
    }

    It 'detects a stale state after a teardown without touching anything else' {
        $t = Get-BuildTest (New-BuildFixture)
        $t.State.steps['P2'] = @{ status = 'done' }
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        Mock Invoke-DemoAz { 'false' } -ModuleName BuildPlan
        Test-ArcDemoBuildStateFresh -Context $t.Context -State $t.State | Should -Match 'teardown happened'
        Mock Invoke-DemoAz { 'true' } -ModuleName BuildPlan
        Test-ArcDemoBuildStateFresh -Context $t.Context -State $t.State | Should -BeNullOrEmpty
        $t.State.steps.Remove('P2')
        Mock Invoke-DemoAz { throw 'must not be called' } -ModuleName BuildPlan
        Test-ArcDemoBuildStateFresh -Context $t.Context -State $t.State | Should -BeNullOrEmpty
    }
}

Describe 'Step runner' {
    BeforeEach {
        $env:BUILD_TEST_EXITS = $null
        Mock Start-Sleep {} -ModuleName BuildPlan
    }

    It 'runs a script with its arguments, adds -Confirm:$false only where supported, and records state and evidence' {
        $f = New-BuildFixture
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f -Approved @{ CostStart = $true }
        Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P2').Definition -Context $t.Context -State $t.State
        Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P7').Definition -Context $t.Context -State $t.State
        $calls = Get-BuildCall $f
        $calls[0].script | Should -Be 'Deploy-ArcDemo.ps1'
        $calls[0].v_SkinPath | Should -Be $t.Context.Config.ArcSkinPath
        $calls[0].v_Confirm | Should -Be 'False'
        $calls[0].keys | Should -Not -Contain 'AutoShutdownTime'
        $calls[0].v_AdminPasswordPath | Should -Be (Join-Path $f.Private 'vm-admin-credential.clixml')
        $calls[1].script | Should -Be 'Test-ArcDemoReadiness.ps1'
        $calls[1].keys | Should -Not -Contain 'Confirm'
        $calls[1].v_DesiredState | Should -Be 'Active'
        $t.State.steps['P2'].status | Should -Be 'done'
        $saved = Get-Content $t.Context.Config.StatePath -Raw | ConvertFrom-Json
        $saved.steps.P2.status | Should -Be 'done'
        $saved.steps.P2.attempts | Should -Be 1
        @(Get-ChildItem $t.Context.Config.EvidenceDirectory -Filter 'P2-*.json') | Should -HaveCount 1
    }

    It 'passes the autoShutdownTime override and the deployer ID to the base deployment' {
        $f = New-BuildFixture -Mutate { param($c) $c.autoShutdownTime = '2330'; $c.deployerPrincipalId = '33333333-3333-3333-3333-333333333333' }
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f -Approved @{ CostStart = $true }
        Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P2').Definition -Context $t.Context -State $t.State
        $call = (Get-BuildCall $f)[0]
        $call.v_AutoShutdownTime | Should -Be '2330'
        $call.v_DeployerPrincipalId | Should -Be '33333333-3333-3333-3333-333333333333'
    }

    It 'records a failure, rethrows and keeps the message short' {
        $f = New-BuildFixture -StubBody @{ 'Deploy-ArcDemo.ps1' = "throw ('stub failure ' + ('x' * 600))" }
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f -Approved @{ CostStart = $true }
        { Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P2').Definition -Context $t.Context -State $t.State } | Should -Throw '*stub failure*'
        $t.State.steps['P2'].status | Should -Be 'failed'
        $t.State.steps['P2'].message.Length | Should -BeLessOrEqual 400
        $saved = Get-Content $t.Context.Config.StatePath -Raw | ConvertFrom-Json
        $saved.steps.P2.status | Should -Be 'failed'
        $saved.steps.P2.attempts | Should -Be 1
    }

    It 'treats exit 2 as pending and re-checks within the wait, exit 0 as done and exit 1 as failed' {
        $f = New-BuildFixture
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f
        $step = (Get-BuildRow $t 'P7').Definition
        $step.WaitMinutes = 1
        $env:BUILD_TEST_EXITS = '2,2,0'
        Invoke-ArcDemoBuildStep -Step $step -Context $t.Context -State $t.State
        @(Get-BuildCall $f | Where-Object script -eq 'Test-ArcDemoReadiness.ps1') | Should -HaveCount 3
        $t.State.steps['P7'].status | Should -Be 'done'
        Should -Invoke Start-Sleep -ModuleName BuildPlan -Times 2 -Exactly
        $env:BUILD_TEST_LOG = (Join-Path $f.Root 'second.log')
        $env:BUILD_TEST_EXITS = '1'
        { Invoke-ArcDemoBuildStep -Step $step -Context $t.Context -State $t.State } | Should -Throw '*reported failure (exit 1)*'
        $t.State.steps['P7'].status | Should -Be 'failed'
        $step.WaitMinutes = 0
        $env:BUILD_TEST_LOG = (Join-Path $f.Root 'third.log')
        $env:BUILD_TEST_EXITS = '2'
        { Invoke-ArcDemoBuildStep -Step $step -Context $t.Context -State $t.State } | Should -Throw '*still pending*nothing was repaired*'
        $t.State.steps['P7'].attempts | Should -Be 3
    }

    It 'captures workbook IDs and the snapshot path, and creates output folders first' {
        $f = New-BuildFixture
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f
        foreach ($id in 'P6.2', 'P6.3', 'P11.1') { Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t $id).Definition -Context $t.Context -State $t.State }
        $t.State.values['capacityWorkbookResourceId'] | Should -Be '/stub/workbooks/capacity'
        $t.State.values['optimisationWorkbookResourceId'] | Should -Be '/stub/workbooks/optimisation'
        $t.State.values['snapshotPath'] | Should -BeLike (Join-Path $t.Context.Config.EvidenceDirectory 'inventory-*.json')
        $parity = (& (Get-BuildRow $t 'P11.2').Definition.Arguments $t.Context)
        $parity['SnapshotPath'] | Should -Be $t.State.values['snapshotPath']
        $parity['Feature'] | Should -Be @('ContainerApps', 'NestedSql', 'RealSql', 'OperationalWorkbooks', 'Sre')
    }

    It 'runs a read-only step with -NoState without writing state or evidence' {
        $f = New-BuildFixture
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f
        Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P7').Definition -Context $t.Context -State $t.State -NoState
        Test-Path $t.Context.Config.StatePath | Should -BeFalse
        Test-Path $t.Context.Config.EvidenceDirectory | Should -BeFalse
        @(Get-BuildCall $f) | Should -HaveCount 1
    }

    It 'resolves the nested guest inputs at run time and keeps the credential out of the evidence' {
        $f = New-BuildFixture
        $env:BUILD_TEST_LOG = $f.Log
        $secret = 'fixture-credential-text'
        $credential = [pscredential]::new('Administrator', (ConvertTo-SecureString -String $secret -AsPlainText -Force))
        $t = Get-BuildTest $f -Credential $credential
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        Mock Invoke-DemoAz {
            if ($Arguments[0] -eq 'vm') { return 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
            if ($Arguments[0] -eq 'ad') { return '[{"displayName":"sp-build-test-onboard","appId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"},{"displayName":"sp-build-test-onboard-extra","appId":"cccccccc-cccc-cccc-cccc-cccccccccccc"}]' }
            throw "Unexpected az call: $($Arguments -join ' ')"
        } -ModuleName BuildPlan
        Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P4').Definition -Context $t.Context -State $t.State
        $call = (Get-BuildCall $f)[0]
        $call.script | Should -Be 'New-NestedSqlDemo.ps1'
        $call.v_ParentVmId | Should -Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $call.v_OnboardingApplicationId | Should -Be 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $call.v_ParentVmName | Should -Be 'parent-vm'
        $call.v_VmName | Should -Be 'guest-vm'
        $call.v_VmRoot | Should -Be 'D:\NestedSQL\VMs\guest-vm'
        $call.v_ParentResourceGroup | Should -Be 'rg-build-test-infra'
        $call.v_ResourceGroup | Should -Be 'rg-build-test'
        $call.keys | Should -Contain 'GuestCredential'
        $evidence = Get-Content (Get-ChildItem $t.Context.Config.EvidenceDirectory -Filter 'P4-*.json').FullName -Raw
        $evidence | Should -Not -Match $secret
        $evidence | Should -Match '<redacted>'
        (Get-Content $t.Context.Config.StatePath -Raw) | Should -Not -Match $secret
    }

    It 'resolves the nested guest Administrator credential from the argument, then the private folder file, then a prompt, and never writes one' {
        $f = New-BuildFixture
        $given = [pscredential]::new('Administrator', (ConvertTo-SecureString -String 'given-credential' -AsPlainText -Force))
        $t = Get-BuildTest $f -Credential $given
        Mock Get-Credential { throw 'prompt must not be used' } -ModuleName BuildPlan
        (Get-BuildGuestCredential -Context $t.Context).GetNetworkCredential().Password | Should -Be 'given-credential'

        $t = Get-BuildTest $f
        $file = Join-Path $f.Private 'nested-guest-credential.clixml'
        [pscredential]::new('Administrator', (ConvertTo-SecureString -String 'saved-credential' -AsPlainText -Force)) | Export-Clixml -LiteralPath $file
        (Get-BuildGuestCredential -Context $t.Context).GetNetworkCredential().Password | Should -Be 'saved-credential'
        Should -Invoke Get-Credential -ModuleName BuildPlan -Times 0

        Remove-Item -LiteralPath $file
        Mock Get-Credential { [pscredential]::new('Administrator', (ConvertTo-SecureString -String 'prompted-credential' -AsPlainText -Force)) } -ModuleName BuildPlan
        (Get-BuildGuestCredential -Context $t.Context).GetNetworkCredential().Password | Should -Be 'prompted-credential'
        Should -Invoke Get-Credential -ModuleName BuildPlan -Times 1 -Exactly
        Test-Path -LiteralPath $file | Should -BeFalse
    }
    It 'refuses a saved guest credential that is not a credential, and explains how to supply one when the session cannot prompt' {
        $f = New-BuildFixture
        $t = Get-BuildTest $f
        $file = Join-Path $f.Private 'nested-guest-credential.clixml'
        'not a credential' | Export-Clixml -LiteralPath $file
        { Get-BuildGuestCredential -Context $t.Context } | Should -Throw '*is not a credential export*'
        Remove-Item -LiteralPath $file
        Mock Get-Credential { throw 'A command that prompts the user failed because the host program does not support user interaction.' } -ModuleName BuildPlan
        { Get-BuildGuestCredential -Context $t.Context } | Should -Throw '*cannot prompt*Pass -GuestCredential, or save one with Export-Clixml to*nested-guest-credential.clixml*Nothing was started*'
    }
    It 'uses the saved guest credential at P4 without prompting and keeps it out of the evidence' {
        $f = New-BuildFixture
        $env:BUILD_TEST_LOG = $f.Log
        [pscredential]::new('Administrator', (ConvertTo-SecureString -String 'saved-credential-text' -AsPlainText -Force)) | Export-Clixml -LiteralPath (Join-Path $f.Private 'nested-guest-credential.clixml')
        $t = Get-BuildTest $f
        Mock Get-Credential { throw 'prompt must not be used' } -ModuleName BuildPlan
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        Mock Invoke-DemoAz {
            if ($Arguments[0] -eq 'vm') { return 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
            if ($Arguments[0] -eq 'ad') { return '[{"displayName":"sp-build-test-onboard","appId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}]' }
            throw "Unexpected az call: $($Arguments -join ' ')"
        } -ModuleName BuildPlan
        Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P4').Definition -Context $t.Context -State $t.State
        (Get-BuildCall $f)[0].keys | Should -Contain 'GuestCredential'
        (Get-Content (Get-ChildItem $t.Context.Config.EvidenceDirectory -Filter 'P4-*.json').FullName -Raw) | Should -Not -Match 'saved-credential-text'
    }

    It 'stops P4 when the parent VM ID or exactly one onboarding identity cannot be resolved' {
        $f = New-BuildFixture
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f -Credential ([pscredential]::new('Administrator', (ConvertTo-SecureString -String 'fixture' -AsPlainText -Force)))
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        Mock Invoke-DemoAz { if ($Arguments[0] -eq 'vm') { 'not-a-guid' } else { '[]' } } -ModuleName BuildPlan
        { Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P4').Definition -Context $t.Context -State $t.State } | Should -Throw '*parent VM ID*'
        Mock Invoke-DemoAz { if ($Arguments[0] -eq 'vm') { 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' } else { '[]' } } -ModuleName BuildPlan
        { Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P4').Definition -Context $t.Context -State $t.State } | Should -Throw '*was not found*'
        Mock Invoke-DemoAz {
            if ($Arguments[0] -eq 'vm') { return 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
            '[{"displayName":"sp-build-test-onboard","appId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"},{"displayName":"sp-build-test-onboard","appId":"cccccccc-cccc-cccc-cccc-cccccccccccc"}]'
        } -ModuleName BuildPlan
        { Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P4').Definition -Context $t.Context -State $t.State } | Should -Throw '*More than one onboarding identity*'
        @(Get-BuildCall $f) | Should -HaveCount 0
        $t.State.steps['P4'].status | Should -Be 'blocked'
        $t.State.steps['P4'].attempts | Should -Be 0
        (Get-BuildRow (Get-BuildTest $f -State $t.State -Credential $t.Context.GuestCredential) 'P4').Status | Should -Be 'ready'
    }

    It 'runs maintained scripts without inheriting strict mode, which they do not expect' {
        $body = @'
$null = $neverSet
$null = ([pscustomobject]@{}).missing
[pscustomobject]@{ status = 'published'; workbookResourceId = "/stub/workbooks/$Purpose"; published = $true }
'@
        $f = New-BuildFixture -StubBody @{ 'Set-OperationalWorkbook.ps1' = $body }
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f
        { Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P6.2').Definition -Context $t.Context -State $t.State } | Should -Not -Throw
        $t.State.steps['P6.2'].status | Should -Be 'done'
        $t.State.values['capacityWorkbookResourceId'] | Should -Be '/stub/workbooks/capacity'
    }

    It 'records a failed inventory snapshot instead of treating its exit 1 as done' {
        $f = New-BuildFixture -StubBody @{ 'Export-ArcDemoInventory.ps1' = '$OutputPath; exit 1' }
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f
        { Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P11.1').Definition -Context $t.Context -State $t.State } | Should -Throw '*reported failure (exit 1)*'
        $t.State.steps['P11.1'].status | Should -Be 'failed'
    }

    It 'creates the folder of the media acceptance record and leaves the file itself to the script' {
        $f = New-BuildFixture
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f
        Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P5.1').Definition -Context $t.Context -State $t.State
        $record = (Get-BuildCall $f)[0].v_AcceptanceRecordPath
        $record | Should -Be (Join-Path $t.Context.Config.EvidenceDirectory 'media-acceptance.json')
        Test-Path -LiteralPath (Split-Path -Parent $record) -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $record | Should -BeFalse
    }

    It 'does not record the parent preparation as done while it reports <Status>, and keeps it re-runnable' -TestCases @(
        @{ Status = 'pending'; Message = '*reports status pending*' }
        @{ Status = 'fail'; Message = '*reports status fail*' }
    ) {
        param($Status, $Message)
        $f = New-BuildFixture -StubBody @{ 'Prepare-NestedSqlParent.ps1' = "[pscustomobject]@{ status = '$Status'; phases = @() }" }
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f
        { Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P3').Definition -Context $t.Context -State $t.State } | Should -Throw $Message
        $t.State.steps['P3'].status | Should -Be 'failed'
        (Get-BuildRow (Get-BuildTest $f -State $t.State) 'P3').Status | Should -Be 'ready'
    }

    It 'records the parent preparation as done when it reports pass' {
        $f = New-BuildFixture -StubBody @{ 'Prepare-NestedSqlParent.ps1' = "[pscustomobject]@{ status = 'pass'; phases = @() }" }
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f
        Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P3').Definition -Context $t.Context -State $t.State
        $t.State.steps['P3'].status | Should -Be 'done'
    }
}

Describe 'Presenter handoff' {
    It 'writes a context the real generator accepts, using only verified exact IDs' {
        $f = New-BuildFixture -RealPresenter
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f
        $scope = "/subscriptions/$script:Sub/resourceGroups/rg-build-test/providers"
        $t.State.values['capacityWorkbookResourceId'] = "$scope/Microsoft.Insights/workbooks/dddddddd-dddd-dddd-dddd-dddddddddddd"
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        Mock Invoke-DemoAz {
            if ($Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'list') {
                return ('[{"id":"' + $scope + '/Microsoft.Insights/workbooks/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","tags":{"workbookTag":"build-test---estate-overview"}},{"id":"' + $scope + '/Microsoft.Insights/workbooks/ffffffff-ffff-ffff-ffff-ffffffffffff","tags":{"workbookTag":"other"}}]')
            }
            if ($Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'show') { return '{}' }
            throw "Unexpected az call: $($Arguments -join ' ')"
        } -ModuleName BuildPlan
        $result = Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P10').Definition -Context $t.Context -State $t.State
        $contextFile = Join-Path $f.Repo '.local/demo-context.json'
        $document = Get-Content $contextFile -Raw | ConvertFrom-Json
        $document.workspaceResourceId | Should -Be "$scope/Microsoft.OperationalInsights/workspaces/law-build-test"
        $document.windowsMachineResourceId | Should -Be "$scope/Microsoft.HybridCompute/machines/win-host"
        $document.workbookResourceId | Should -BeLike '*eeeeeeee*'
        $document.lobMachineName | Should -Be 'win-host'
        $document.capacityWorkbookResourceId | Should -BeLike '*dddddddd*'
        $document.PSObject.Properties.Name | Should -Not -Contain 'sqlMachineResourceId'
        Test-Path (Join-Path $f.Repo '.local/presenter-runsheet.md') | Should -BeTrue
        $t.State.steps['P10'].status | Should -Be 'done'
    }

    It 'writes pipeline strings and arrays of them as plain text, never as {"Length":N}' {
        $piped = @('Online', 'Offline') | ForEach-Object { $_ }
        $safe = ConvertTo-BuildSafeValue ([pscustomobject]@{ State = $piped[0]; Names = $piped; Nested = @([pscustomobject]@{ Name = ($piped | Select-Object -First 1) }) })
        $json = $safe | ConvertTo-Json -Depth 6 -Compress
        $json | Should -Not -Match 'Length'
        $json | Should -Be '{"State":"Online","Names":["Online","Offline"],"Nested":[{"Name":"Online"}]}'
    }

    It 'adds the optional chapters it can verify, and names the ones it cannot instead of failing' {
        $f = New-BuildFixture
        $t = Get-BuildTest $f
        $scope = "/subscriptions/$script:Sub/resourceGroups/rg-build-test/providers"
        $dash = [string][char]0x2014
        $tagOf = { param($name) ("Arc $dash $name" -replace '[^A-Za-z0-9]', '-').ToLowerInvariant() }
        $script:optionalList = @(
            @{ id = "$scope/Microsoft.Insights/workbooks/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"; tags = @{ workbookTag = 'build-test---estate-overview' } }
            @{ id = "$scope/Microsoft.Insights/workbooks/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"; tags = @{ workbookTag = (& $tagOf 'Machine Intelligence Center') } }
            @{ id = "$scope/Microsoft.Insights/workbooks/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"; tags = @{ workbookTag = (& $tagOf 'Compliance, Security & Governance') } }
            @{ id = "$scope/Microsoft.Insights/workbooks/cccccccc-cccc-cccc-cccc-cccccccccccc"; tags = @{ workbookTag = (& $tagOf 'Asset Inventory') } }
        ) | ConvertTo-Json -Depth 4 -AsArray
        $script:instanceMissing = "$scope/Microsoft.AzureArcData/sqlServerInstances/guest-vm"
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        Mock Invoke-DemoAz {
            if ($Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'list') { return $script:optionalList }
            if ($Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'show') { if ($Arguments[3] -eq $script:instanceMissing) { return $null } else { return '{}' } }
            throw "Unexpected az call: $($Arguments -join ' ')"
        } -ModuleName BuildPlan
        $left = [System.Collections.Generic.List[string]]::new()
        $document = New-ArcDemoPresenterContext -Context $t.Context -State $t.State -LeftOut $left
        $document['dataCollectionRuleResourceId'] | Should -Be "$scope/Microsoft.Insights/dataCollectionRules/dcr-arc-demo"
        $document['machineIntelligenceWorkbookResourceId'] | Should -BeLike '*aaaaaaaa-aaaa*'
        $document['complianceWorkbookResourceId'] | Should -BeLike '*bbbbbbbb-bbbb*'
        $document['assetInventoryWorkbookResourceId'] | Should -BeLike '*cccccccc-cccc*'
        $document.Keys | Should -Not -Contain 'sqlEstateWorkbookResourceId'
        $document['nestedSqlMachineResourceId'] | Should -Be "$scope/Microsoft.HybridCompute/machines/guest-vm"
        $document['nestedSqlParentMachineResourceId'] | Should -Be "$scope/Microsoft.HybridCompute/machines/parent-vm"
        $document.Keys | Should -Not -Contain 'nestedSqlInstanceResourceId'
        @($left) | Should -Be @('the SQL Estate workbook steps', "the nested guest's SQL Server instance link")
    }

    It 'leaves every nested chapter out, without failing, when the guest is not an Arc machine yet' {
        $f = New-BuildFixture
        $t = Get-BuildTest $f
        $scope = "/subscriptions/$script:Sub/resourceGroups/rg-build-test/providers"
        $script:onlyEstate = '[{"id":"' + $scope + '/Microsoft.Insights/workbooks/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","tags":{"workbookTag":"build-test---estate-overview"}}]'
        $script:guestMachine = "$scope/Microsoft.HybridCompute/machines/guest-vm"
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        Mock Invoke-DemoAz {
            if ($Arguments[1] -eq 'list') { return $script:onlyEstate }
            if ($Arguments[3] -eq $script:guestMachine) { return $null }
            '{}'
        } -ModuleName BuildPlan
        $left = [System.Collections.Generic.List[string]]::new()
        $document = New-ArcDemoPresenterContext -Context $t.Context -State $t.State -LeftOut $left
        @($document.Keys | Where-Object { $_ -like 'nestedSql*' }) | Should -HaveCount 0
        $left | Should -Contain 'the nested Arc SQL chapter'
        $left | Should -Not -Contain "the nested guest's SQL Server instance link"
    }

    It 'does not look for a nested guest when the skin has none, and refuses two workbooks with one tag' {
        $f = New-BuildFixture -NoNested
        $t = Get-BuildTest $f
        $scope = "/subscriptions/$script:Sub/resourceGroups/rg-build-test/providers"
        $script:onlyEstate = '[{"id":"' + $scope + '/Microsoft.Insights/workbooks/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","tags":{"workbookTag":"build-test---estate-overview"}}]'
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        Mock Invoke-DemoAz { if ($Arguments[1] -eq 'list') { return $script:onlyEstate }; '{}' } -ModuleName BuildPlan
        $left = [System.Collections.Generic.List[string]]::new()
        $null = New-ArcDemoPresenterContext -Context $t.Context -State $t.State -LeftOut $left
        ($left -join ';') | Should -Not -Match 'nested'
        Should -Invoke Invoke-DemoAz -ModuleName BuildPlan -Times 0 -ParameterFilter { $Arguments[0] -eq 'resource' -and $Arguments[3] -like '*/machines/guest-vm' }
        $dash = [string][char]0x2014
        $dupe = ("Arc $dash Asset Inventory" -replace '[^A-Za-z0-9]', '-').ToLowerInvariant()
        $script:onlyEstate = '[{"id":"' + $scope + '/Microsoft.Insights/workbooks/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","tags":{"workbookTag":"build-test---estate-overview"}},{"id":"' + $scope + '/Microsoft.Insights/workbooks/a1","tags":{"workbookTag":"' + $dupe + '"}},{"id":"' + $scope + '/Microsoft.Insights/workbooks/a2","tags":{"workbookTag":"' + $dupe + '"}}]'
        { New-ArcDemoPresenterContext -Context $t.Context -State $t.State -LeftOut $left } | Should -Throw '*at most one workbook tagged*'
    }

    It 'prints the chapters left out, records them in the step result, and the real generator links the chapters it was given' {
        $f = New-BuildFixture -RealPresenter
        $env:BUILD_TEST_LOG = $f.Log
        $t = Get-BuildTest $f
        $scope = "/subscriptions/$script:Sub/resourceGroups/rg-build-test/providers"
        $script:onlyEstate = '[{"id":"' + $scope + '/Microsoft.Insights/workbooks/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","tags":{"workbookTag":"build-test---estate-overview"}}]'
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        Mock Invoke-DemoAz { if ($Arguments[1] -eq 'list') { return $script:onlyEstate }; '{}' } -ModuleName BuildPlan
        Mock Write-Warn {} -ModuleName BuildPlan
        $result = Invoke-ArcDemoBuildStep -Step (Get-BuildRow $t 'P10').Definition -Context $t.Context -State $t.State
        Should -Invoke Write-Warn -ModuleName BuildPlan -Times 1 -ParameterFilter { $Message -like 'Optional chapters left out*Machine Intelligence Center*SQL Estate*' }
        $evidence = Get-Content (Get-ChildItem $t.Context.Config.EvidenceDirectory -Filter 'P10-*.json').FullName -Raw | ConvertFrom-Json
        @($evidence.result.chaptersLeftOut) | Should -Contain 'the compliance workbook steps'
        $guide = Get-Content (Join-Path $f.Repo '.local/presenter-runsheet.md') -Raw
        $guide | Should -Not -Match 'No nested Arc SQL guest is recorded'
        $guide | Should -Not -Match 'No data collection rule is recorded'
        $guide | Should -Match 'The Machine Intelligence Center workbook is not recorded'
    }

    It 'adds the SQL presenter fields only when the saved status proof says pass' {
        $f = New-BuildFixture
        $t = Get-BuildTest $f
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        $scope = "/subscriptions/$script:Sub/resourceGroups/rg-build-test/providers"
        Mock Invoke-DemoAz {
            if ($Arguments[1] -eq 'list') { return ('[{"id":"' + $scope + '/Microsoft.Insights/workbooks/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","tags":{"workbookTag":"build-test---estate-overview"}}]') }
            '{}'
        } -ModuleName BuildPlan
        $null = New-Item -ItemType Directory -Path (Join-Path $f.Repo '.local') -Force
        $proof = Join-Path $f.Repo '.local/sql-engine-status.json'
        (New-ArcDemoPresenterContext -Context $t.Context -State $t.State).Keys | Should -Not -Contain 'sqlMachineResourceId'
        Set-Content $proof '{"evidence":{"status":"pending"}}'
        (New-ArcDemoPresenterContext -Context $t.Context -State $t.State).Keys | Should -Not -Contain 'sqlMachineResourceId'
        Set-Content $proof '{"evidence":{"status":"pass"}}'
        $document = New-ArcDemoPresenterContext -Context $t.Context -State $t.State
        $document['sqlMachineResourceId'] | Should -Be "$scope/Microsoft.HybridCompute/machines/sql-host"
        $document['sqlIncidentAlertResourceId'] | Should -Be "$scope/Microsoft.Insights/scheduledQueryRules/al-build-test-sql-lock-timeout"
    }

    It 'writes nothing when an expected resource or the Estate Overview workbook is missing' {
        $f = New-BuildFixture -RealPresenter
        $t = Get-BuildTest $f
        Mock Initialize-DemoContext {} -ModuleName BuildPlan
        Mock Invoke-DemoAz { if ($Arguments[1] -eq 'list') { '[]' } else { '{}' } } -ModuleName BuildPlan
        { New-ArcDemoPresenterContext -Context $t.Context -State $t.State } | Should -Throw '*exactly one Estate Overview workbook*'
        $scope = "/subscriptions/$script:Sub/resourceGroups/rg-build-test/providers"
        Mock Invoke-DemoAz {
            if ($Arguments[1] -eq 'list') { return ('[{"id":"' + $scope + '/Microsoft.Insights/workbooks/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee","tags":{"workbookTag":"build-test---estate-overview"}}]') }
            $null
        } -ModuleName BuildPlan
        { New-ArcDemoPresenterContext -Context $t.Context -State $t.State } | Should -Throw '*Expected resource is missing*'
        Test-Path (Join-Path $f.Repo '.local/demo-context.json') | Should -BeFalse
    }
}

Describe 'Build window' {
    It 'warns only when the remaining work crosses the auto-shutdown time' {
        $now = [datetime]::Parse('2026-11-02T16:00:00Z').ToUniversalTime()
        Get-ArcDemoBuildWindowWarning -Minutes 240 -ShutdownTime '1900' -TimeZoneId 'UTC' -Now $now | Should -Match 'cross the 19:00 auto-shutdown'
        Get-ArcDemoBuildWindowWarning -Minutes 120 -ShutdownTime '1900' -TimeZoneId 'UTC' -Now $now | Should -BeNullOrEmpty
        Get-ArcDemoBuildWindowWarning -Minutes 600 -ShutdownTime '2330' -TimeZoneId 'UTC' -Now $now | Should -Match 'cross the 23:30'
        Get-ArcDemoBuildWindowWarning -Minutes 60 -ShutdownTime '1900' -TimeZoneId 'UTC' -Now ([datetime]::Parse('2026-11-02T20:00:00Z').ToUniversalTime()) | Should -BeNullOrEmpty
        Get-ArcDemoBuildWindowWarning -Minutes 60 -TimeZoneId 'No Such Zone' -Now $now | Should -Match 'Cannot evaluate'
    }

    It 'applies an allowance for slow platform operations, says so, and tells the reader how to keep a later shutdown' {
        $now = [datetime]::Parse('2026-11-02T16:00:00Z').ToUniversalTime()
        # 150 typical minutes end at 18:30, inside the window; with a 50% allowance they would end at 19:45.
        Get-ArcDemoBuildWindowWarning -Minutes 150 -ShutdownTime '1900' -TimeZoneId 'UTC' -Now $now | Should -BeNullOrEmpty
        $warning = Get-ArcDemoBuildWindowWarning -Minutes 150 -ShutdownTime '1900' -TimeZoneId 'UTC' -Now $now -Allowance 1.5
        $warning | Should -Match 'About 150 minutes of VM-dependent steps, plus a 50% allowance for slow or repeated platform operations \(225 minutes\), would cross the 19:00 auto-shutdown'
        $warning | Should -Match 'Deploy sets this schedule again on every run, so a time changed by hand is reverted'
        $warning | Should -Match 'autoShutdownTime in the build config \(or operations\.autoShutdownTime in the skin\)'
        Get-ArcDemoBuildWindowWarning -Minutes 100 -ShutdownTime '1900' -TimeZoneId 'UTC' -Now $now -Allowance 1.5 | Should -BeNullOrEmpty
    }

    It 'plans the preflight window with that allowance' {
        $text = Get-Content -LiteralPath (Join-Path $script:Repo 'scripts/lib/BuildPlan.psm1') -Raw
        $text | Should -Match 'Get-ArcDemoBuildWindowWarning -Minutes \$Context\.RemainingMinutes -ShutdownTime \$time -TimeZoneId \$zone -Allowance 1\.5'
    }
}

Describe 'Build preflight' {
    BeforeEach {
        Mock Test-Prerequisites { '33333333-3333-3333-3333-333333333333' } -ModuleName BuildPlan
        Mock Invoke-AzRest { [pscustomobject]@{ value = @() } } -ModuleName BuildPlan
        Mock Invoke-DemoAz { 'false' } -ModuleName BuildPlan
        Mock Write-Step {} -ModuleName BuildPlan
    }
    It 'checks the providers and CLI extension the skin workloads need, not only the defaults' {
        $f = New-BuildFixture
        $t = Get-BuildTest $f
        (Invoke-ArcDemoBuildPreflight -Context $t.Context).status | Should -Be 'pass'
        Should -Invoke Test-Prerequisites -ModuleName BuildPlan -Times 1 -Exactly -ParameterFilter {
            'containerapp' -in $RequiredExtensions -and 'Microsoft.App' -in $Providers -and 'Microsoft.ContainerService' -notin $Providers
        }
    }
    It 'checks the Standard security type feature only when the skin declares a nested parent' {
        $f = New-BuildFixture
        $null = Invoke-ArcDemoBuildPreflight -Context (Get-BuildTest $f).Context
        Should -Invoke Test-Prerequisites -ModuleName BuildPlan -Times 1 -Exactly -ParameterFilter { 'Microsoft.Compute/UseStandardSecurityType' -in $Features }
        $f = New-BuildFixture -NoNested
        $null = Invoke-ArcDemoBuildPreflight -Context (Get-BuildTest $f).Context
        Should -Invoke Test-Prerequisites -ModuleName BuildPlan -Times 1 -Exactly -ParameterFilter { @($Features).Count -eq 0 }
    }
    It 'checks the AKS providers, and no Container Apps prerequisite, when the skin deploys only AKS' {
        $f = New-BuildFixture
        $skinPath = Join-Path $f.Private 'arc-skin.json'
        $skin = Get-Content $skinPath -Raw | ConvertFrom-Json -AsHashtable
        $skin.workloads = @{ deployContainerApps = $false; deployAks = $true }
        $skin | ConvertTo-Json -Depth 5 | Set-Content $skinPath
        $t = Get-BuildTest $f
        $null = Invoke-ArcDemoBuildPreflight -Context $t.Context
        Should -Invoke Test-Prerequisites -ModuleName BuildPlan -Times 1 -Exactly -ParameterFilter {
            'containerapp' -notin $RequiredExtensions -and 'Microsoft.App' -notin $Providers -and 'Microsoft.ContainerService' -in $Providers
        }
    }
}

Describe 'Evidence safety' {
    It 'redacts credentials and secret-named fields at every depth' {
        $credential = [pscredential]::new('user', (ConvertTo-SecureString -String 'fixture' -AsPlainText -Force))
        $safe = ConvertTo-BuildSafeValue ([ordered]@{
                GuestCredential = $credential; Nested = @{ clientSecret = 'fixture-value'; Password = 'fixture-value'; Keep = 'value' }
                List = @([pscustomobject]@{ token = 'fixture-value'; Name = 'ok' }); Secure = (ConvertTo-SecureString -String 'fixture' -AsPlainText -Force)
            })
        $json = $safe | ConvertTo-Json -Depth 8
        $json | Should -Not -Match 'fixture-value'
        $safe.GuestCredential | Should -Be '<redacted>'
        $safe.Secure | Should -Be '<redacted>'
        $safe.Nested.Keep | Should -Be 'value'
        $safe.List[0].Name | Should -Be 'ok'
    }
}

Describe 'Invoke-ArcDemoBuild.ps1' {
    BeforeAll {
        $script:Wrapper = Join-Path $script:Repo 'scripts/Invoke-ArcDemoBuild.ps1'
    }

    It 'prints an offline plan, returns the rows and runs nothing' {
        $f = New-BuildFixture
        $rows = & $script:Wrapper -SubscriptionId $script:Sub -TenantId $script:Ten -BuildConfigPath $f.ConfigPath -Offline -PassThru 6>$null
        $rows.Step | Should -Be @('P0', 'P1', 'P2', 'P3', 'P4', 'P5.1', 'P5.2', 'P5.3', 'P5.4', 'P6.1', 'P6.2', 'P6.3', 'P7', 'P8.1', 'P8.2', 'P9.1', 'P9.2', 'P9.3', 'P10', 'P11.1', 'P11.2')
        ($rows | Where-Object Step -eq 'P2').Needs | Should -Contain 'CostStart'
        $rows[0].PSObject.Properties.Name | Should -Not -Contain 'Definition'
        Test-Path (Join-Path $f.Private 'build-state.json') | Should -BeFalse
        Test-Path (Join-Path $f.Private 'evidence') | Should -BeFalse
    }

    It 'refuses to execute offline or without the explicit approval switches, before starting anything' {
        $f = New-BuildFixture -Without 'realSql', 'sre', 'presenter' -NoNested
        { & $script:Wrapper -SubscriptionId $script:Sub -TenantId $script:Ten -BuildConfigPath $f.ConfigPath -Execute -Offline } | Should -Throw '*-Offline only applies*'
        { & $script:Wrapper -SubscriptionId $script:Sub -TenantId $script:Ten -BuildConfigPath $f.ConfigPath -Execute -Only P2 -Confirm:$false 6>$null } |
            Should -Throw '*Approval switch(es) missing*-ApproveCostStart (P2)*'
        Test-Path (Join-Path $f.Private 'build-state.json') | Should -BeFalse
    }
}
