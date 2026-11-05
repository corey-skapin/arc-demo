#Requires -Version 7.4
# Ordered "build everything" wrapper helpers: plan, approvals, resume state and step runner.
# The wrapper only calls the maintained scripts; it owns no deployment logic and no second manifest.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

$script:Phases = @('P0', 'P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7', 'P8', 'P9', 'P10', 'P11')
$script:ConfigKeys = @('schemaVersion', 'arcSkinPath', 'deployerPrincipalId', 'autoShutdownTime', 'nestedSqlBuildInputPath',
    'mediaManifestPath', 'realSql', 'operationalWorkbooks', 'sre', 'presenter')
$script:ApprovalSwitch = [ordered]@{
    CostStart = 'ApproveCostStart'
    WindowsEvaluationTerms = 'AcceptWindowsEvaluationTerms'
    SqlDeveloperTerms = 'AcceptSqlDeveloperTerms'
    SreCreation = 'ApproveSreCreation'
}
$script:SqlMediaId = 'sql-server-2022-developer'
$script:NestedRequiredInputs = @('SwitchName', 'WindowsIsoPath', 'SqlIsoPath', 'GuestAddress', 'Gateway', 'DnsServer')
$script:OutputPathKeys = @('ResultPath', 'OutputPath', 'ConfigurationBackupPath', 'BuildInputPath', 'AcceptanceRecordPath')
$script:MachinePattern = '^[A-Za-z][A-Za-z0-9-]{0,13}[A-Za-z0-9]$'

function Read-BuildJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20 }
    catch { throw "Invalid JSON in $Path`: $($_.Exception.Message)" }
}

function Resolve-BuildPath {
    param([Parameter(Mandatory)][string]$Base, [AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    [IO.Path]::GetFullPath((Join-Path $Base $Path))
}

function Join-BuildPath {
    # Repo-relative paths are written with backslashes; join them segment by segment so they also work on Linux CI.
    param([Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][string]$Relative)
    $path = $Base
    foreach ($part in ($Relative -split '[\\/]')) { if ($part) { $path = Join-Path $path $part } }
    $path
}

function Test-BuildPathInside {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Container)
    $separator = [IO.Path]::DirectorySeparatorChar
    $child = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') + $separator
    $parent = [IO.Path]::GetFullPath($Container).TrimEnd('\', '/') + $separator
    $child.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-BuildKeys {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string[]]$Allowed, [Parameter(Mandatory)][string]$Label)
    if ($Value -isnot [System.Collections.IDictionary]) { throw "$Label must be a JSON object." }
    foreach ($key in $Value.Keys) {
        if ($key -cnotin $Allowed) { throw "Unsupported $Label field '$key'." }
    }
}

function ConvertTo-BuildSafeValue {
    <#
    .SYNOPSIS
        Copies a value for evidence files, replacing credentials and secret-named fields.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Value, [int]$Depth = 0)
    if ($null -eq $Value) { return $null }
    if ($Value -is [securestring] -or $Value -is [pscredential]) { return '<redacted>' }
    if ($Depth -ge 6) { return "$Value" }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $copy["$key"] = if ("$key" -match '(?i)secret|password|token|credential') { '<redacted>' } else { ConvertTo-BuildSafeValue $Value[$key] ($Depth + 1) }
        }
        return $copy
    }
    # A string that came through a pipeline is PSObject-wrapped and also answers -is [pscustomobject]; copied property by
    # property it would be written as {"Length":N}. Only a real custom object is copied that way.
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $copy[$property.Name] = if ($property.Name -match '(?i)secret|password|token|credential') { '<redacted>' } else { ConvertTo-BuildSafeValue $property.Value ($Depth + 1) }
        }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return , @($Value | ForEach-Object { ConvertTo-BuildSafeValue $_ ($Depth + 1) })
    }
    $Value
}

function ConvertFrom-BuildOutput {
    param([AllowNull()]$Output)
    $items = @($Output | Where-Object { $null -ne $_ })
    if ($items.Count -eq 1 -and $items[0] -is [string] -and $items[0].TrimStart().StartsWith('{')) {
        try { return ($items[0] | ConvertFrom-Json -AsHashtable -Depth 20) } catch { Write-Verbose 'Output is not JSON; keeping the text.' }
    }
    $items
}

function Read-ArcDemoBuildConfig {
    <#
    .SYNOPSIS
        Loads the private build config and applies only a basic validity check.
    .DESCRIPTION
        Relative paths resolve against the config's own folder, the single private
        folder. That folder must be outside the git worktree.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RepoRoot)
    $file = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $raw = Read-BuildJson $file
    $root = Split-Path -Parent $file
    if (Test-BuildPathInside -Path $root -Container $RepoRoot) {
        throw 'Keep the build config, state and evidence in the private folder, outside the git worktree.'
    }
    if ($raw -isnot [System.Collections.IDictionary] -or $raw['schemaVersion'] -ne 1) { throw 'Build config must be a JSON object with schemaVersion 1.' }
    Assert-BuildKeys $raw $script:ConfigKeys 'build config'
    $arcSkin = [string](Get-DemoSkinValue $raw 'arcSkinPath' '')
    if (-not $arcSkin) { throw 'Build config requires arcSkinPath (the private Arc skin).' }
    $shutdown = [string](Get-DemoSkinValue $raw 'autoShutdownTime' '')
    if ($shutdown -and $shutdown -notmatch '^([01][0-9]|2[0-3])[0-5][0-9]$') { throw 'autoShutdownTime must be HHmm.' }
    $deployer = [string](Get-DemoSkinValue $raw 'deployerPrincipalId' '')
    $parsed = [guid]::Empty
    if ($deployer -and -not [guid]::TryParse($deployer, [ref]$parsed)) { throw 'deployerPrincipalId must be an Entra object ID (GUID).' }
    $books = Get-DemoSkinValue $raw 'operationalWorkbooks' $true
    if ($books -isnot [bool]) { throw 'operationalWorkbooks must be a JSON boolean.' }

    $realSql = $null
    if ($raw.Contains('realSql')) {
        $section = $raw['realSql']
        Assert-BuildKeys $section @('machineName', 'isoPath', 'stageMedia') 'realSql'
        $machine = [string](Get-DemoSkinValue $section 'machineName' '')
        $iso = [string](Get-DemoSkinValue $section 'isoPath' '')
        $stage = Get-DemoSkinValue $section 'stageMedia' $true
        if ($machine -notmatch $script:MachinePattern) { throw 'realSql.machineName must be a valid Windows computer name.' }
        if ($iso -notmatch '^[A-Za-z]:\\[^"]+\\[^\\"]+\.iso$') { throw 'realSql.isoPath must be a guest-local .iso path inside a folder, such as C:\DemoMedia\SQLServer2022-x64-ENU-Dev.iso.' }
        if ($stage -isnot [bool]) { throw 'realSql.stageMedia must be a JSON boolean.' }
        $realSql = [pscustomobject]@{ MachineName = $machine; IsoPath = $iso; StageMedia = $stage }
    }
    $sre = $null
    if ($raw.Contains('sre')) {
        $section = $raw['sre']
        Assert-BuildKeys $section @('repoPath', 'skinPath', 'grantSwitch') 'sre'
        $repoPath = [string](Get-DemoSkinValue $section 'repoPath' '')
        $skinPath = [string](Get-DemoSkinValue $section 'skinPath' '')
        $grant = [string](Get-DemoSkinValue $section 'grantSwitch' 'GrantAzureMonitorAlertAccess')
        if (-not $repoPath -or -not $skinPath) { throw 'sre requires repoPath (the local clone) and skinPath (the private SRE skin).' }
        if ($grant -notmatch '^[A-Za-z][A-Za-z0-9]*$') { throw 'sre.grantSwitch must be a parameter name.' }
        $sre = [pscustomobject]@{ RepoPath = (Resolve-BuildPath $root $repoPath); SkinPath = (Resolve-BuildPath $root $skinPath); GrantSwitch = $grant }
    }
    $presenter = $null
    if ($raw.Contains('presenter')) {
        $section = $raw['presenter']
        Assert-BuildKeys $section @('windowsMachineName', 'linuxMachineName', 'lobMachineName') 'presenter'
        $names = @{}
        foreach ($key in 'windowsMachineName', 'linuxMachineName', 'lobMachineName') { $names[$key] = [string](Get-DemoSkinValue $section $key '') }
        foreach ($key in 'windowsMachineName', 'linuxMachineName') {
            if ($names[$key] -notmatch $script:MachinePattern) { throw "presenter.$key must be a valid machine name." }
        }
        if ($names.lobMachineName -and $names.lobMachineName -notmatch $script:MachinePattern) { throw 'presenter.lobMachineName must be a valid machine name.' }
        $presenter = [pscustomobject]@{ WindowsMachineName = $names.windowsMachineName; LinuxMachineName = $names.linuxMachineName; LobMachineName = $names.lobMachineName }
    }
    [pscustomobject]@{
        Path = $file
        Root = $root
        ArcSkinPath = (Resolve-BuildPath $root $arcSkin)
        DeployerPrincipalId = $deployer
        AutoShutdownTime = $shutdown
        NestedSqlBuildInputPath = (Resolve-BuildPath $root ([string](Get-DemoSkinValue $raw 'nestedSqlBuildInputPath' '')))
        MediaManifestPath = (Resolve-BuildPath $root ([string](Get-DemoSkinValue $raw 'mediaManifestPath' '')))
        RealSql = $realSql
        OperationalWorkbooks = $books
        Sre = $sre
        Presenter = $presenter
        StatePath = (Join-Path $root 'build-state.json')
        EvidenceDirectory = (Join-Path $root 'evidence')
        BackupDirectory = (Join-Path $root 'sre-backups')
    }
}

function New-ArcDemoBuildContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][guid]$SubscriptionId,
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][string]$RepoRoot,
        [pscredential]$GuestCredential,
        [hashtable]$Approved = @{},
        [switch]$ApproveSubscriptionGrant
    )
    $skin = Get-DemoSkin -Path $Config.ArcSkinPath -RepoRoot $RepoRoot
    $prefix = [string](Get-DemoSkinValue $skin 'azure.namePrefix' 'arc-demo')
    Assert-DemoName $prefix
    [pscustomobject]@{
        SubscriptionId = $SubscriptionId
        TenantId = $TenantId
        Config = $Config
        Skin = $skin
        Prefix = $prefix
        Location = [string](Get-DemoSkinValue $skin 'azure.location' 'australiaeast')
        Nested = (Get-DemoNestedSqlGuestConfig -Skin $skin)
        ContainerApps = [bool](Get-DemoSkinValue $skin 'workloads.deployContainerApps' $false)
        Aks = [bool](Get-DemoSkinValue $skin 'workloads.deployAks' $false)
        ArcGroup = "rg-$prefix"
        InfraGroup = "rg-$prefix-infra"
        ArcRoot = $RepoRoot
        SreRoot = if ($Config.Sre) { $Config.Sre.RepoPath } else { '' }
        GuestCredential = $GuestCredential
        Approved = $Approved
        GrantRequested = [bool]$ApproveSubscriptionGrant
        State = $null
        PlannedSteps = @()
        RemainingMinutes = 0
    }
}

function New-BuildArguments {
    param([Parameter(Mandatory)]$Context, [string]$SkinPath, [System.Collections.IDictionary]$Extra = @{})
    $arguments = [ordered]@{ SubscriptionId = "$($Context.SubscriptionId)"; TenantId = "$($Context.TenantId)" }
    if ($SkinPath) { $arguments['SkinPath'] = $SkinPath }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
    $arguments
}

function Get-BuildArcResourceId {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)][string]$Name)
    "/subscriptions/$($Context.SubscriptionId)/resourceGroups/$($Context.ArcGroup)/providers/$Type/$Name"
}

function New-BuildStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [ValidateSet('arc', 'sre', 'internal')][string]$Repo = 'arc',
        [string]$Script = '',
        [int]$Minutes = 1,
        [switch]$Mutating,
        [string[]]$Approvals = @(),
        [scriptblock]$Arguments = { [ordered]@{} },
        [string[]]$ResolvedArguments = @(),
        [scriptblock]$Resolve,
        [scriptblock]$Run,
        [scriptblock]$Inputs,
        [scriptblock]$Capture,
        [switch]$ExitCodes,
        [int]$WaitMinutes = 0,
        [switch]$AlwaysRun,
        [switch]$NoRetry,
        [string]$RetryHint = '',
        [string]$SkipReason = '',
        [scriptblock]$SkipWhen,
        [switch]$ResultStatus,
        [string[]]$StaleAfter = @()
    )
    [pscustomobject]@{
        Id = $Id; Phase = ($Id -split '\.')[0]; Title = $Title; Repo = $Repo; Script = $Script; Minutes = $Minutes
        Mutating = [bool]$Mutating; Approvals = $Approvals; Arguments = $Arguments; ResolvedArguments = $ResolvedArguments
        Resolve = $Resolve; Run = $Run; Inputs = $Inputs; Capture = $Capture; ExitCodes = [bool]$ExitCodes; WaitMinutes = $WaitMinutes
        AlwaysRun = [bool]$AlwaysRun; NoRetry = [bool]$NoRetry; RetryHint = $RetryHint; SkipReason = $SkipReason
        SkipWhen = $SkipWhen; ResultStatus = [bool]$ResultStatus; StaleAfter = @($StaleAfter)
        Kind = if ($Repo -eq 'internal') { 'internal' } else { 'script' }
    }
}

function Test-BuildFile {
    param([AllowEmptyString()][string]$Path, [Parameter(Mandatory)][string]$Label)
    if (-not $Path) { "$Label is not set in the build config." }
    elseif (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { "$Label not found: $Path" }
}

function Get-BuildMediaManifestPath {
    # The tracked config\demo-media.json unless the build config names another manifest.
    param([Parameter(Mandatory)]$Context)
    if ($Context.Config.MediaManifestPath) { $Context.Config.MediaManifestPath } else { Join-BuildPath $Context.ArcRoot 'config\demo-media.json' }
}

function Get-BuildSqlMediaValue {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Field)
    $path = Get-BuildMediaManifestPath $Context
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    [string](Get-DemoSkinValue (Read-BuildJson $path) "media.$($script:SqlMediaId).$Field" '')
}

function Get-BuildMediaPin {
    param([Parameter(Mandatory)]$Context)
    Get-BuildSqlMediaValue $Context 'sha256'
}

function Get-BuildSqlMediaDirectory {
    param([Parameter(Mandatory)]$Context)
    [regex]::Match($Context.Config.RealSql.IsoPath, '^(?<directory>[A-Za-z]:\\.+)\\[^\\]+$').Groups['directory'].Value
}

function Test-BuildMediaManifest {
    param([Parameter(Mandatory)]$Context)
    Test-BuildFile (Get-BuildMediaManifestPath $Context) 'media manifest'
}

function Test-BuildMediaStaging {
    param([Parameter(Mandatory)]$Context)
    $problem = Test-BuildMediaManifest $Context
    if ($problem) { return $problem }
    $fileName = Get-BuildSqlMediaValue $Context 'fileName'
    if (-not $fileName) { return "The media manifest has no '$($script:SqlMediaId)' entry with a fileName." }
    if (($Context.Config.RealSql.IsoPath -replace '^.*\\', '') -ne $fileName) {
        "realSql.isoPath must end with \$fileName, the file name Stage-DemoMedia.ps1 gives the SQL ISO."
    }
}

function Test-BuildMediaPin {
    param([Parameter(Mandatory)]$Context)
    $problem = Test-BuildMediaManifest $Context
    if ($problem) { return $problem }
    if ((Get-BuildMediaPin $Context) -notmatch '^[A-Fa-f0-9]{64}$') { "The media manifest has no 64-hex sha256 for $($script:SqlMediaId)." }
}

function Get-BuildNestedInput {
    param([Parameter(Mandatory)]$Context)
    $path = $Context.Config.NestedSqlBuildInputPath
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { Read-BuildJson $path } else { @{} }
}

function Get-BuildNestedBlocker {
    param([Parameter(Mandatory)]$Context)
    $path = $Context.Config.NestedSqlBuildInputPath
    if ($path -and -not (Test-Path -LiteralPath $path -PathType Leaf) -and 'P3' -in $Context.PlannedSteps) { return }
    $problem = Test-BuildFile $path 'nestedSqlBuildInputPath'
    if ($problem) { return $problem }
    $values = Get-BuildNestedInput $Context
    $missing = @($script:NestedRequiredInputs | Where-Object { -not (Get-DemoSkinValue $values $_ '') })
    if ($missing) { "The nested SQL build input file is missing: $($missing -join ', ')." }
}

function Get-BuildSqlEngineProblem {
    # The SQL lock-timeout alert watches the SQL engine, so it needs P5.4's saved proof that the engine answers.
    param([Parameter(Mandatory)]$Context)
    $proof = Join-BuildPath $Context.ArcRoot '.local/sql-engine-status.json'
    if ((Test-Path -LiteralPath $proof -PathType Leaf) -and (Get-DemoSkinValue (Read-BuildJson $proof) 'evidence.status' '') -eq 'pass') { return }
    'The real SQL engine is not confirmed yet (P5.4 saves .local/sql-engine-status.json with status pass), so the lock-timeout alert would watch nothing. Run P5 first; its Status step, P5.4, is read-only.'
}

function Get-BuildNestedArguments {
    param([Parameter(Mandatory)]$Context)
    $values = Get-BuildNestedInput $Context
    $guest = $Context.Nested
    $arguments = New-BuildArguments $Context $null @{
        ParentResourceGroup = $Context.InfraGroup; ParentVmName = $guest.ParentVmName; ResourceGroup = $Context.ArcGroup
        Location = [string](Get-DemoSkinValue $values 'Location' $Context.Location); VmName = $guest.GuestVmName
        VmRoot = [string](Get-DemoSkinValue $values 'VmRoot' "D:\NestedSQL\VMs\$($guest.GuestVmName)")
    }
    foreach ($key in $script:NestedRequiredInputs) { $arguments[$key] = [string](Get-DemoSkinValue $values $key '') }
    $arguments['SkinPath'] = $Context.Config.ArcSkinPath
    $arguments
}

function Initialize-BuildContext {
    param([Parameter(Mandatory)]$Context)
    Initialize-DemoContext -SubscriptionId $Context.SubscriptionId -TenantId $Context.TenantId
}

function Get-BuildSreParentSkipReason {
    <#
    .SYNOPSIS
        Returns a reason when the SRE parent already exists, otherwise nothing. Read-only.
    .DESCRIPTION
        Deploy-SreAgent.ps1 refuses an existing parent before it changes anything, even with -WhatIf, so the
        preview and the create step are skipped, not failed, when the parent is already there.
    #>
    param([Parameter(Mandatory)]$Context)
    Initialize-BuildContext $Context
    $skin = Read-BuildJson $Context.Config.Sre.SkinPath
    $prefix = [string](Get-DemoSkinValue $skin 'azure.namePrefix' $Context.Prefix)
    $agent = [string](Get-DemoSkinValue $skin 'labels.agentName' "sre-$prefix")
    $group = "rg-$prefix-sre"
    $raw = Invoke-DemoAz -Arguments @('resource', 'list', '-g', $group, '-o', 'json') -AllowNotFound
    $text = (@($raw) -join "`n").Trim()
    $found = @(if ($text) { $text | ConvertFrom-Json | Where-Object { $_.type -eq 'Microsoft.App/agents' -and $_.name -eq $agent } })
    if ($found.Count) {
        "The SRE parent $agent already exists in $group. Deploy-SreAgent.ps1 refuses an existing parent, even with -WhatIf, so this step is skipped. Use Initialize-SreConfiguration for configuration-only changes."
    }
}

function Resolve-ArcDemoPlanSkip {
    <#
    .SYNOPSIS
        Marks the steps that would be skipped because their target already exists. Read-only; updates the plan rows in place.
    .DESCRIPTION
        A skip is not a failure and needs no approval. A check that cannot be read blocks the step with the exact error
        instead of guessing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Plan, [Parameter(Mandatory)]$Context)
    foreach ($row in @($Plan | Where-Object { $_.Definition.SkipWhen -and $_.Status -in @('ready', 'blocked') })) {
        try { $reason = [string](& $row.Definition.SkipWhen $Context) }
        catch {
            $row.Status = 'blocked'
            $row.Blockers = @($row.Blockers) + "Cannot tell whether this step is needed: $($_.Exception.Message)"
            continue
        }
        if ($reason) { $row.Status = 'skipped'; $row.Reason = $reason; $row.Blockers = @(); $row.Needs = @() }
    }
}

function Get-BuildOnboardingApplication {
    param([Parameter(Mandatory)]$Context)
    Initialize-BuildContext $Context
    $name = "sp-$($Context.Prefix)-onboard"
    $raw = Invoke-DemoAz -Arguments @('ad', 'sp', 'list', '--display-name', $name, '-o', 'json')
    $found = @((@($raw) -join "`n") | ConvertFrom-Json | Where-Object { $_.displayName -eq $name })
    if ($found.Count -gt 1) { throw "More than one onboarding identity is named $name; refusing to guess." }
    if ($found.Count -eq 1) { [guid]$found[0].appId }
}

function Get-BuildGuestCredential {
    <#
    .SYNOPSIS
        The nested guest Administrator credential: -GuestCredential, else the private folder's
        nested-guest-credential.clixml, else a prompt.
    .DESCRIPTION
        A [pscredential] cannot be passed to pwsh -File, so an unattended run reads the DPAPI-protected export from the
        private folder (see docs/private-config.md for the two-line recipe that creates it). Nothing here writes a
        credential. Only the nested guest build and its guest checks use it; Activate, Hibernate and Remove never do.
    #>
    param([Parameter(Mandatory)]$Context)
    if ($Context.GuestCredential) { return $Context.GuestCredential }
    $path = Join-Path $Context.Config.Root 'nested-guest-credential.clixml'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { $saved = Import-Clixml -LiteralPath $path }
        catch { throw "The saved guest credential $path could not be read (a Windows export only opens for the user and PC that wrote it): $($_.Exception.Message)" }
        if ($saved -isnot [pscredential]) { throw "The saved guest credential $path is not a credential export (Export-Clixml of a PSCredential)." }
        return $saved
    }
    try {
        Get-Credential -UserName Administrator -Message 'Approved Administrator credential for the nested guest (asked now so the build can run unattended; save one to nested-guest-credential.clixml in the private folder to skip this prompt)'
    } catch {
        throw "The nested guest (P4) needs an approved Administrator credential and this session cannot prompt for it ($($_.Exception.Message)). Pass -GuestCredential, or save one with Export-Clixml to $path (docs/private-config.md). Nothing was started."
    }
}

function Resolve-BuildNestedArguments {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    Initialize-BuildContext $Context
    $vmId = [guid]::Empty
    $raw = Invoke-DemoAz -Arguments @('vm', 'show', '-g', $Context.InfraGroup, '-n', $Context.Nested.ParentVmName, '--query', 'vmId', '-o', 'tsv')
    if (-not [guid]::TryParse((@($raw) -join '').Trim(), [ref]$vmId)) { throw 'Could not read the nested parent VM ID from Azure.' }
    $application = Get-BuildOnboardingApplication $Context
    if (-not $application) { throw "Onboarding identity sp-$($Context.Prefix)-onboard was not found; the base deployment creates it." }
    $credential = Get-BuildGuestCredential -Context $Context
    $Arguments['ParentVmId'] = $vmId
    $Arguments['OnboardingApplicationId'] = $application
    $Arguments['GuestCredential'] = $credential
}

function New-BuildWorkbookArguments {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][ValidateSet('capacity', 'optimisation')][string]$Purpose)
    New-BuildArguments $Context $Context.Config.ArcSkinPath @{
        Purpose = $Purpose; Action = 'Deploy'
        WorkspaceResourceId = (Get-BuildArcResourceId $Context 'Microsoft.OperationalInsights/workspaces' "law-$($Context.Prefix)")
    }
}

function Save-BuildWorkbookId {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values, [Parameter(Mandatory)][string]$Slot, [AllowNull()]$Output)
    $found = @($Output | Where-Object { $_ -and $_.PSObject.Properties['workbookResourceId'] } | Select-Object -Last 1)
    if ($found) { $Values[$Slot] = [string]$found[0].workbookResourceId }
}

function Get-BuildFeature {
    param([Parameter(Mandatory)]$Context)
    $features = [System.Collections.Generic.List[string]]::new()
    if ($Context.ContainerApps) { $features.Add('ContainerApps') }
    if ($Context.Nested) { $features.Add('NestedSql') }
    if ($Context.Config.RealSql) { $features.Add('RealSql') }
    if ($Context.Config.OperationalWorkbooks) { $features.Add('OperationalWorkbooks') }
    if ($Context.Config.Sre) { $features.Add('Sre') }
    if ($Context.Config.Sre -and $Context.GrantRequested) { $features.Add('SreAlertGrant') }
    $features.ToArray()
}

function Get-ArcDemoBuildSteps {
    <#
    .SYNOPSIS
        Returns the ordered build steps P0-P11 for the given context.
    .DESCRIPTION
        Argument names are checked against each script's real parameters in the plan,
        so a script whose CLI differs is reported as blocked rather than guessed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $cfg = $Context.Config
    $noNested = if ($Context.Nested) { '' } else { 'nestedSqlGuest is not enabled in the Arc skin.' }
    $noSql = if ($cfg.RealSql) { '' } else { 'No realSql section in the build config.' }
    $noStage = if ($noSql) { $noSql } elseif (-not $cfg.RealSql.StageMedia) { 'realSql.stageMedia is false (the ISO is already staged).' } else { '' }
    $noSre = if ($cfg.Sre) { '' } else { 'No sre section in the build config.' }
    $noBooks = if ($cfg.OperationalWorkbooks) { '' } else { 'operationalWorkbooks is false.' }
    $noPresenter = if ($cfg.Presenter) { '' } else { 'No presenter section in the build config.' }
    $sreSkin = { param($c) Test-BuildFile $c.Config.Sre.SkinPath 'sre.skinPath' }
    @(
        New-BuildStep -Id 'P0' -Title 'Preflight: tools, access, repos, names, build window (read-only)' -Repo internal -Minutes 2 -AlwaysRun `
            -Run { param($c) Invoke-ArcDemoBuildPreflight -Context $c }
        New-BuildStep -Id 'P1' -Title 'Onboarding identity check (read-only)' -Repo internal -Minutes 1 -AlwaysRun `
            -Run { param($c, $s) Invoke-ArcDemoBuildIdentityCheck -Context $c -State $s }
        New-BuildStep -Id 'P2' -Title 'Base estate: Bicep, Arc, Monitor, DCRs, workbooks' -Script 'scripts\Deploy-ArcDemo.ps1' -Minutes 70 -Mutating `
            -Approvals CostStart -Arguments {
                param($c)
                $extra = @{ AdminPasswordPath = (Join-Path $c.Config.Root 'vm-admin-credential.clixml') }
                if ($c.Config.AutoShutdownTime) { $extra['AutoShutdownTime'] = $c.Config.AutoShutdownTime }
                if ($c.Config.DeployerPrincipalId) { $extra['DeployerPrincipalId'] = $c.Config.DeployerPrincipalId }
                New-BuildArguments $c $c.Config.ArcSkinPath $extra
            }
        New-BuildStep -Id 'P3' -Title 'Hyper-V parent for the nested SQL guest' -Script 'scripts\Prepare-NestedSqlParent.ps1' -Minutes 20 -Mutating -ResultStatus `
            -Approvals WindowsEvaluationTerms, SqlDeveloperTerms -SkipReason $noNested `
            -Inputs { param($c) Test-BuildMediaManifest $c } -Arguments {
                param($c)
                $extra = @{
                    AcceptWindowsEvaluationTerms = $true; AcceptSqlDeveloperTerms = $true
                    AcceptanceRecordPath = (Join-Path $c.Config.EvidenceDirectory 'media-acceptance.json')
                    ResultPath = (Join-Path $c.Config.EvidenceDirectory 'P3-parent-result.json')
                }
                if ($c.Config.MediaManifestPath) { $extra['MediaManifestPath'] = $c.Config.MediaManifestPath }
                if ($c.Config.NestedSqlBuildInputPath) { $extra['BuildInputPath'] = $c.Config.NestedSqlBuildInputPath }
                New-BuildArguments $c $c.Config.ArcSkinPath $extra
            }
        New-BuildStep -Id 'P4' -Title 'Nested Windows/SQL/Arc guest (one-day onboarding credential)' -Script 'scripts\New-NestedSqlDemo.ps1' -Minutes 45 -Mutating `
            -SkipReason $noNested -NoRetry -RetryHint 'Inspect the guest; continue with the targeted steps in docs/nested-sql-demo.md or remove the guest first.' `
            -Inputs { param($c) Get-BuildNestedBlocker $c } -Arguments { param($c) Get-BuildNestedArguments $c } `
            -ResolvedArguments ParentVmId, OnboardingApplicationId, GuestCredential -Resolve { param($c, $a) Resolve-BuildNestedArguments -Context $c -Arguments $a }
        New-BuildStep -Id 'P5.1' -Title 'Stage the SQL Server 2022 Developer ISO on the SQL host' -Script 'scripts\Stage-DemoMedia.ps1' -Minutes 5 -Mutating `
            -Approvals SqlDeveloperTerms -SkipReason $noStage -Inputs { param($c) Test-BuildMediaStaging $c } -Arguments {
                param($c)
                $extra = @{
                    MachineName = $c.Config.RealSql.MachineName; Media = @($script:SqlMediaId); Destination = (Get-BuildSqlMediaDirectory $c)
                    AcceptSqlDeveloperTerms = $true
                    AcceptanceRecordPath = (Join-Path $c.Config.EvidenceDirectory 'media-acceptance.json')
                    ResultPath = (Join-Path $c.Config.EvidenceDirectory 'P5-media-result.json')
                }
                if ($c.Config.MediaManifestPath) { $extra['ManifestPath'] = $c.Config.MediaManifestPath }
                New-BuildArguments $c $c.Config.ArcSkinPath $extra
            }
        New-BuildStep -Id 'P5.2' -Title 'Block automatic Arc SQL connection on the SQL host (local blocklist only)' -Script 'scripts\Invoke-SqlEngineOnArc.ps1' -Minutes 2 -Mutating `
            -SkipReason $noSql -Arguments {
                param($c)
                New-BuildArguments $c $c.Config.ArcSkinPath @{ MachineName = $c.Config.RealSql.MachineName; Action = 'ProtectArcSql' }
            }
        New-BuildStep -Id 'P5.3' -Title 'Install SQL Server 2022 Developer on the SQL host' -Script 'scripts\Invoke-SqlEngineOnArc.ps1' -Minutes 25 -Mutating `
            -Approvals SqlDeveloperTerms -SkipReason $noSql `
            -Inputs { param($c) Test-BuildMediaPin $c } -Arguments {
                param($c)
                $extra = @{
                    MachineName = $c.Config.RealSql.MachineName; Action = 'Install'; MediaIsoPath = $c.Config.RealSql.IsoPath
                    MediaSha256 = (Get-BuildMediaPin $c); AcceptDeveloperLicenseTerms = $true
                    ResultPath = (Join-Path $c.Config.EvidenceDirectory 'P5-sql-install.json')
                }
                if ($c.State.steps.Contains('P5.2') -and $c.State.steps['P5.2'].status -eq 'done') { $extra['ArcSqlAutoConnectOptOutConfirmed'] = $true }
                New-BuildArguments $c $c.Config.ArcSkinPath $extra
            }
        New-BuildStep -Id 'P5.4' -Title 'Real SQL status (guest Run Command, read-only)' -Script 'scripts\Invoke-SqlEngineOnArc.ps1' -Minutes 2 -AlwaysRun `
            -SkipReason $noSql -Arguments {
                param($c)
                New-BuildArguments $c $c.Config.ArcSkinPath @{
                    MachineName = $c.Config.RealSql.MachineName; Action = 'Status'; ResultPath = (Join-BuildPath $c.ArcRoot '.local/sql-engine-status.json')
                }
            }
        New-BuildStep -Id 'P6.1' -Title 'SQL lock-timeout incident alert' -Script 'scripts\Set-SqlIncidentAlert.ps1' -Minutes 2 -Mutating -SkipReason $noSql `
            -Inputs { param($c) if ('P5.4' -notin $c.PlannedSteps) { Get-BuildSqlEngineProblem $c } } `
            -Resolve { param($c) $problem = Get-BuildSqlEngineProblem $c; if ($problem) { throw $problem } } -Arguments {
                param($c)
                New-BuildArguments $c $c.Config.ArcSkinPath @{
                    MachineName = $c.Config.RealSql.MachineName; Action = 'Deploy'
                    WorkspaceResourceId = (Get-BuildArcResourceId $c 'Microsoft.OperationalInsights/workspaces' "law-$($c.Prefix)")
                    ActionGroupId = (Get-BuildArcResourceId $c 'Microsoft.Insights/actionGroups' "ag-$($c.Prefix)")
                }
            }
        New-BuildStep -Id 'P6.2' -Title 'Operational workbook: capacity' -Script 'scripts\Set-OperationalWorkbook.ps1' -Minutes 1 -Mutating -SkipReason $noBooks -StaleAfter P2, P4 `
            -Arguments { param($c) New-BuildWorkbookArguments $c 'capacity' } -Capture { param($values, $output) Save-BuildWorkbookId $values 'capacityWorkbookResourceId' $output }
        New-BuildStep -Id 'P6.3' -Title 'Operational workbook: optimisation' -Script 'scripts\Set-OperationalWorkbook.ps1' -Minutes 1 -Mutating -SkipReason $noBooks -StaleAfter P2, P4 `
            -Arguments { param($c) New-BuildWorkbookArguments $c 'optimisation' } -Capture { param($values, $output) Save-BuildWorkbookId $values 'optimisationWorkbookResourceId' $output }
        New-BuildStep -Id 'P7' -Title 'Arc readiness gate (Active, read-only)' -Script 'scripts\Test-ArcDemoReadiness.ps1' -Minutes 5 -AlwaysRun -ExitCodes -WaitMinutes 20 `
            -Arguments {
                param($c)
                New-BuildArguments $c $c.Config.ArcSkinPath @{ NamePrefix = $c.Prefix; DesiredState = 'Active'; OutputFormat = 'Json'; TimeoutSeconds = 600 }
            }
        New-BuildStep -Id 'P8.1' -Title 'LOB alert rule (SRE repo)' -Repo sre -Script 'scripts\New-LobArcAppMonitorAlert.ps1' -Minutes 1 -Mutating `
            -SkipReason $noSre -Inputs $sreSkin -Arguments { param($c) New-BuildArguments $c $c.Config.Sre.SkinPath @{ Action = 'Create' } }
        New-BuildStep -Id 'P8.2' -Title 'LOB guest app (SRE repo)' -Repo sre -Script 'scripts\Invoke-LobArcAppOnArc.ps1' -Minutes 4 -Mutating `
            -SkipReason $noSre -Inputs $sreSkin -Arguments { param($c) New-BuildArguments $c $c.Config.Sre.SkinPath @{ Action = 'Deploy' } }
        New-BuildStep -Id 'P9.1' -Title 'SRE agent preview (read-only; skipped when the parent exists)' -Repo sre -Script 'scripts\Deploy-SreAgent.ps1' -Minutes 2 `
            -SkipReason $noSre -Inputs $sreSkin -SkipWhen { param($c) Get-BuildSreParentSkipReason $c } `
            -Arguments { param($c) New-BuildArguments $c $c.Config.Sre.SkinPath @{ WhatIf = $true } }
        New-BuildStep -Id 'P9.2' -Title 'SRE agent: create the paid parent (4 AAU per hour from creation) and configure it' -Repo sre -Script 'scripts\Deploy-SreAgent.ps1' `
            -Minutes 8 -Mutating -Approvals SreCreation -SkipReason $noSre -NoRetry `
            -RetryHint 'Deploy-SreAgent.ps1 refuses an existing parent. Inspect it with Initialize-SreConfiguration -Inspect, make configuration-only changes with Initialize-SreConfiguration, then continue with -From P9.' `
            -Inputs $sreSkin -SkipWhen { param($c) Get-BuildSreParentSkipReason $c } -Arguments {
                param($c)
                $extra = @{
                    ConfigurationBackupPath = (Join-Path $c.Config.BackupDirectory ('sre-config-{0}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')))
                    ApproveParentCreation = $true
                }
                if ($c.GrantRequested) { $extra[$c.Config.Sre.GrantSwitch] = $true }
                New-BuildArguments $c $c.Config.Sre.SkinPath $extra
            }
        New-BuildStep -Id 'P9.3' -Title 'SRE readiness gate (Active, read-only)' -Repo sre -Script 'scripts\Test-SreReadiness.ps1' -Minutes 5 -AlwaysRun -ExitCodes -WaitMinutes 10 `
            -SkipReason $noSre -Inputs $sreSkin -Arguments {
                param($c)
                New-BuildArguments $c $c.Config.Sre.SkinPath @{ DesiredState = 'Active'; OutputFormat = 'Json'; TimeoutSeconds = 180 }
            }
        New-BuildStep -Id 'P10' -Title 'Presenter context and guide for the Arc repo (local files only)' -Repo internal -Minutes 3 -SkipReason $noPresenter `
            -Run { param($c, $s) Invoke-ArcDemoPresenterHandoff -Context $c -State $s }
        New-BuildStep -Id 'P11.1' -Title 'Read-only inventory snapshot' -Script 'scripts\Export-ArcDemoInventory.ps1' -Minutes 6 -AlwaysRun -ExitCodes -Arguments {
                param($c)
                New-BuildArguments $c $c.Config.ArcSkinPath @{
                    OutputPath = (Join-Path $c.Config.EvidenceDirectory ('inventory-{0}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')))
                }
            } -Capture {
                param($values, $output)
                $path = @($output | Where-Object { $_ -is [string] -and $_ -like '*.json' } | Select-Object -Last 1)
                if ($path) { $values['snapshotPath'] = $path[0] }
            }
        New-BuildStep -Id 'P11.2' -Title 'Parity: expected objects versus the snapshot (read-only)' -Script 'scripts\Test-ArcDemoParity.ps1' -Minutes 1 -AlwaysRun -ExitCodes `
            -Arguments {
                param($c)
                $snapshot = if ($c.State.values.Contains('snapshotPath')) { $c.State.values['snapshotPath'] } else { '<from P11.1>' }
                $extra = @{ SnapshotPath = $snapshot; OutputFormat = 'Json' }
                $features = @(Get-BuildFeature $c)
                if ($features.Count) { $extra['Feature'] = $features }
                New-BuildArguments $c $c.Config.ArcSkinPath $extra
            }
    )
}

function Select-ArcDemoBuildStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Steps, [string]$From, [string]$To, [string[]]$Only)
    if ($Only -and ($From -or $To)) { throw 'Use either -Only or -From/-To, not both.' }
    if ($Only) { return @($Steps | Where-Object { $_.Phase -in $Only -or $_.Id -in $Only }) }
    # [array]::IndexOf is case-sensitive while the phase parameters are not.
    $first = if ($From) { [array]::IndexOf($script:Phases, $From.ToUpperInvariant()) } else { 0 }
    $last = if ($To) { [array]::IndexOf($script:Phases, $To.ToUpperInvariant()) } else { $script:Phases.Count - 1 }
    if ($first -gt $last) { throw "-From $From comes after -To $To." }
    @($Steps | Where-Object { $index = [array]::IndexOf($script:Phases, $_.Phase); $index -ge $first -and $index -le $last })
}

function Get-BuildScriptPath {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Step)
    $root = if ($Step.Repo -eq 'sre') { $Context.SreRoot } else { $Context.ArcRoot }
    if ($root) { Join-BuildPath $root $Step.Script } else { '' }
}

function Get-BuildScriptParameter {
    param([Parameter(Mandatory)][string]$Path)
    try { @((Get-Command -Name $Path -CommandType ExternalScript -ErrorAction Stop).Parameters.Keys) } catch { @() }
}

function Get-ArcDemoBuildPlan {
    <#
    .SYNOPSIS
        Adds status, blockers and missing approvals to each selected step. Makes no Azure call.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][object[]]$Steps, [Parameter(Mandatory)]$State, [switch]$Force)
    $Context.State = $State
    # A step that publishes a snapshot of what earlier steps built (the workbook roster) is out of date when one of
    # those steps finished after it did, so a recorded 'done' is not trusted then.
    $staleAfter = {
        param($step)
        if (-not $State.steps.Contains($step.Id)) { return $null }
        $own = ConvertTo-DemoUtc $State.steps[$step.Id]['endedUtc']
        foreach ($id in $step.StaleAfter) {
            if (-not $State.steps.Contains($id) -or $State.steps[$id]['status'] -ne 'done') { continue }
            $other = ConvertTo-DemoUtc $State.steps[$id]['endedUtc']
            if ($own -and $other -and $other -gt $own) { return $id }
        }
        $null
    }
    $isDone = { param($step) $State.steps.Contains($step.Id) -and $State.steps[$step.Id].status -eq 'done' -and -not $step.AlwaysRun -and -not $Force -and -not (& $staleAfter $step) }
    $Context.PlannedSteps = @($Steps | Where-Object { -not $_.SkipReason -and -not (& $isDone $_) } | ForEach-Object Id)
    foreach ($step in $Steps) {
        $blockers = [System.Collections.Generic.List[string]]::new()
        $notes = [System.Collections.Generic.List[string]]::new()
        $record = if ($State.steps.Contains($step.Id)) { $State.steps[$step.Id] } else { $null }
        $newer = if (-not $step.SkipReason -and -not $step.AlwaysRun -and $record -and $record.status -eq 'done') { & $staleAfter $step }
        if ($newer) { $notes.Add("recorded as done, but $newer finished later, so what it published is out of date; it runs again.") }
        $status = 'ready'
        if ($step.SkipReason) { $status = 'skipped' }
        elseif (& $isDone $step) { $status = 'done' }
        else {
            if ($record -and $record.status -in @('failed', 'running') -and $step.NoRetry -and -not $Force) {
                $earlier = if ($record.status -eq 'running') { 'An earlier attempt was interrupted before it finished.' } else { 'An earlier attempt failed.' }
                $blockers.Add("$earlier $($step.RetryHint) Use -Force only after inspecting it.")
            }
            if ($step.Kind -eq 'script') {
                $path = Get-BuildScriptPath $Context $step
                if ($step.Repo -eq 'sre' -and -not (Test-Path -LiteralPath $Context.SreRoot -PathType Container)) { $blockers.Add("sre.repoPath is not a folder: $($Context.SreRoot)") }
                elseif (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { $blockers.Add("Script not available yet: $($step.Script)") }
                else {
                    $accepted = Get-BuildScriptParameter $path
                    $wanted = @((& $step.Arguments $Context).Keys) + @($step.ResolvedArguments)
                    $unknown = @($wanted | Where-Object { $_ -notin $accepted })
                    if ($unknown) { $blockers.Add("$($step.Script) does not accept: $($unknown -join ', ').") }
                }
            }
            if ($step.Inputs) { foreach ($message in @(& $step.Inputs $Context)) { if ($message) { $blockers.Add([string]$message) } } }
            if ($blockers.Count) { $status = 'blocked' }
        }
        $needs = if ($status -in @('ready', 'blocked')) { @($step.Approvals | Where-Object { -not $Context.Approved[$_] }) } else { @() }
        [pscustomobject]@{
            Step = $step.Id; Phase = $step.Phase; Title = $step.Title; Status = $status; Minutes = $step.Minutes; Mutating = $step.Mutating
            Needs = $needs; Blockers = $blockers.ToArray(); Reason = $step.SkipReason; Notes = $notes.ToArray(); Definition = $step
        }
    }
}

function Get-ArcDemoBuildWindowWarning {
    <#
    .SYNOPSIS
        Warns when the build would run across the DevTest auto-shutdown time.
    .DESCRIPTION
        -Allowance multiplies the plan's typical minutes, because platform operations are often slower or repeated.
        Deploy owns the schedule and sets it again on every run, so a time changed by hand does not survive a rerun.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Minutes,
        [string]$ShutdownTime = '1900',
        [string]$TimeZoneId = 'Cen. Australia Standard Time',
        [datetime]$Now = [datetime]::UtcNow,
        [ValidateRange(1.0, 4.0)][double]$Allowance = 1.0
    )
    try { $zone = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId) }
    catch { return "Cannot evaluate the auto-shutdown window: time zone '$TimeZoneId' is unknown on this machine." }
    $start = [TimeZoneInfo]::ConvertTimeFromUtc($Now.ToUniversalTime(), $zone)
    $shutdown = $start.Date.AddHours([int]$ShutdownTime.Substring(0, 2)).AddMinutes([int]$ShutdownTime.Substring(2, 2))
    if ($shutdown -le $start) { $shutdown = $shutdown.AddDays(1) }
    $planned = [int][Math]::Ceiling($Minutes * $Allowance)
    if ($shutdown -lt $start.AddMinutes($planned)) {
        $basis = if ($Allowance -gt 1) { "About $Minutes minutes of VM-dependent steps, plus a $([int][Math]::Round(($Allowance - 1) * 100))% allowance for slow or repeated platform operations ($planned minutes)," } else { "About $Minutes minutes of VM-dependent steps" }
        "$basis would cross the $($shutdown.ToString('HH:mm')) auto-shutdown ($TimeZoneId) and deallocate the hosts mid-build. Deploy sets this schedule again on every run, so a time changed by hand is reverted: start earlier, or set autoShutdownTime in the build config (or operations.autoShutdownTime in the skin) before the build."
    }
}

function New-ArcDemoBuildState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$SubscriptionId, [Parameter(Mandatory)][guid]$TenantId, [Parameter(Mandatory)][string]$Prefix)
    @{ schemaVersion = 1; subscriptionId = "$SubscriptionId"; tenantId = "$TenantId"; namePrefix = $Prefix; steps = @{}; values = @{} }
}

function Read-ArcDemoBuildState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][guid]$SubscriptionId, [Parameter(Mandatory)][guid]$TenantId, [Parameter(Mandatory)][string]$Prefix)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (New-ArcDemoBuildState $SubscriptionId $TenantId $Prefix) }
    $state = Read-BuildJson $Path
    if ($state -isnot [System.Collections.IDictionary] -or $state['schemaVersion'] -ne 1 -or $state['steps'] -isnot [System.Collections.IDictionary] -or
        $state['values'] -isnot [System.Collections.IDictionary]) { throw "Build state is malformed: $Path" }
    if ($state['subscriptionId'] -ne "$SubscriptionId" -or $state['tenantId'] -ne "$TenantId" -or $state['namePrefix'] -ne $Prefix) {
        throw "Build state belongs to a different target ($($state['namePrefix'])). Use that target's own private folder, or delete $Path to start a new build."
    }
    $state
}

function Save-ArcDemoBuildState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$State)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    $temporary = "$Path.tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Test-ArcDemoBuildStateFresh {
    <#
    .SYNOPSIS
        Returns a message when the state records a base deployment whose groups are gone (after a teardown).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$State)
    if (-not ($State.steps.Contains('P2') -and $State.steps['P2'].status -eq 'done')) { return }
    Initialize-BuildContext $Context
    $exists = Invoke-DemoAz -Arguments @('group', 'exists', '-n', $Context.InfraGroup, '-o', 'json') | ConvertFrom-Json
    if (-not $exists) {
        "The state file records P2 as done but $($Context.InfraGroup) does not exist (a teardown happened). Delete $($Context.Config.StatePath) to start a new build."
    }
}

function Get-BuildRepoSummary {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return "${Label}: git summary unavailable." }
    try {
        $sha = (& $git.Source -C $Path rev-parse --short HEAD 2>$null) -join ''
        $dirty = @(& $git.Source -C $Path status --porcelain 2>$null).Count
        "${Label}: $sha$(if ($dirty) { " ($dirty uncommitted change(s))" } else { ' (clean)' })"
    } catch { "${Label}: git summary unavailable." }
}

function Invoke-ArcDemoBuildPreflight {
    <#
    .SYNOPSIS
        Read-only preflight. Surfaces denied or failed reads; never repairs, registers or changes anything.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $notes = [System.Collections.Generic.List[string]]::new()
    $standardSecurityType = [bool](Get-DemoSkinValue $Context.Skin 'workloads.deployArcOnPrem' $true) -and
        (Test-DemoStandardSecurityTypeRequired -Skin $Context.Skin -FleetPath (Get-DemoSkinValue $Context.Skin 'workloads.onPremFleetPath' '') -RepoRoot $Context.ArcRoot)
    $prerequisites = Get-DemoPrerequisiteSet -ContainerApps:$Context.ContainerApps -Aks:$Context.Aks -StandardSecurityType:$standardSecurityType
    $null = Test-Prerequisites -SubscriptionId "$($Context.SubscriptionId)" -TenantId "$($Context.TenantId)" -DeployerPrincipalId $Context.Config.DeployerPrincipalId `
        -Providers $prerequisites.Providers -RequiredExtensions $prerequisites.Extensions -Features $prerequisites.Features
    $notes.Add((Get-BuildRepoSummary $Context.ArcRoot 'Arc repo'))
    if ($Context.Config.Sre) { $notes.Add((Get-BuildRepoSummary $Context.Config.Sre.RepoPath 'SRE repo')) }
    $deleted = Invoke-AzRest -Method Get -Url "https://management.azure.com/subscriptions/$($Context.SubscriptionId)/providers/Microsoft.OperationalInsights/deletedWorkspaces?api-version=2020-08-01"
    if (@($deleted.value | Where-Object { $_.name -eq "law-$($Context.Prefix)" }).Count) {
        $notes.Add("A soft-deleted workspace named law-$($Context.Prefix) exists: creating it again recovers the old workspace and its data (14-day window). Permanently delete it first, with separate approval, if you want a clean workspace.")
    }
    $existing = @(@($Context.ArcGroup, $Context.InfraGroup) | Where-Object { Invoke-DemoAz -Arguments @('group', 'exists', '-n', $_, '-o', 'json') | ConvertFrom-Json })
    $notes.Add($(if ($existing) { "Existing groups: $($existing -join ', ') (a resume or re-run)." } else { 'No demo groups exist yet (a fresh build).' }))
    if ($Context.RemainingMinutes -gt 0) {
        $time = if ($Context.Config.AutoShutdownTime) { $Context.Config.AutoShutdownTime } else { [string](Get-DemoSkinValue $Context.Skin 'operations.autoShutdownTime' '1900') }
        $zone = [string](Get-DemoSkinValue $Context.Skin 'operations.autoShutdownTimezone' 'Cen. Australia Standard Time')
        $window = Get-ArcDemoBuildWindowWarning -Minutes $Context.RemainingMinutes -ShutdownTime $time -TimeZoneId $zone -Allowance 1.5
        if ($window) { $notes.Add($window) }
    }
    foreach ($note in $notes) { Write-Step $note }
    [pscustomobject]@{ status = 'pass'; notes = $notes.ToArray() }
}

function Invoke-ArcDemoBuildIdentityCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$State)
    $application = Get-BuildOnboardingApplication $Context
    if ($application) {
        $State.values['onboardingApplicationId'] = "$application"
        Write-Ok "Onboarding identity sp-$($Context.Prefix)-onboard exists; nothing here reads or changes its credentials."
        Write-Step 'Deploy and the nested build each mint a one-day credential on it and remove it again. That needs ownership of the application or an application-administrator role; otherwise pass -OnboardingSecret to Deploy.'
    } else {
        Write-Step "Onboarding identity sp-$($Context.Prefix)-onboard does not exist yet; the base deployment creates it."
    }
    [pscustomobject]@{ status = 'pass'; exists = [bool]$application }
}

function Test-BuildResourceExists {
    param([Parameter(Mandatory)][string]$Id)
    [bool](Invoke-DemoAz -Arguments @('resource', 'show', '--ids', $Id, '-o', 'json') -AllowNotFound)
}

function Assert-BuildResourceExists {
    param([Parameter(Mandatory)][string]$Id)
    if (-not (Test-BuildResourceExists $Id)) { throw "Expected resource is missing, so no presenter context is written: $Id" }
}

function Get-BuildContextTime {
    # The context describes what the last passing Active readiness (P7) saw, so it carries that check's time,
    # which is the time in the evidence file, not the later moment P10 happens to run.
    param([Parameter(Mandatory)]$State)
    if ($State.steps.Contains('P7') -and $State.steps['P7'].status -eq 'done' -and $State.steps['P7'].Contains('evidence')) {
        $evidence = [string]$State.steps['P7']['evidence']
        if ($evidence -and (Test-Path -LiteralPath $evidence -PathType Leaf)) {
            try {
                $checked = ConvertTo-DemoUtc (Get-DemoSkinValue (Read-BuildJson $evidence) 'output.checkedAtUtc' '')
                if ($checked -and $checked -le [DateTime]::UtcNow) { return $checked.ToString('o') }
            } catch { Write-Verbose "P7 evidence has no usable checkedAtUtc: $($_.Exception.Message)" }
        }
    }
    [DateTime]::UtcNow.ToString('o')
}

function New-ArcDemoPresenterContext {
    <#
    .SYNOPSIS
        Builds the nonsecret presenter context from exact Arc-group IDs, each verified to exist.
    .DESCRIPTION
        The required IDs and the capacity and optimisation workbooks must exist or nothing is written. The optional
        chapters the wrapper can verify itself (the data collection rule, the four original workbooks, the nested guest, its
        SQL instance and its parent) are added when their resource is found. One that is missing is added to -LeftOut instead,
        so the guide cannot tell a presenter to skip a chapter whose resources exist, and a chapter that is left out is named.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$State,
        [System.Collections.Generic.List[string]]$LeftOut = ([System.Collections.Generic.List[string]]::new())
    )
    Initialize-BuildContext $Context
    $presenter = $Context.Config.Presenter
    $title = [string](Get-DemoSkinValue $Context.Skin 'labels.workbookTitle' ("$(Get-DemoSkinValue $Context.Skin 'labels.demoTitle' 'Arc Demo') $([char]0x2014) Estate Overview"))
    $tag = ($title -replace '[^A-Za-z0-9]', '-').ToLowerInvariant()
    $workbooks = (@(Invoke-DemoAz -Arguments @('resource', 'list', '-g', $Context.ArcGroup, '--resource-type', 'Microsoft.Insights/workbooks', '-o', 'json')) -join "`n") | ConvertFrom-Json
    $estate = @($workbooks | Where-Object { $_.tags -and $_.tags.PSObject.Properties['workbookTag'] -and $_.tags.workbookTag -eq $tag })
    if ($estate.Count -ne 1) { throw "Expected exactly one Estate Overview workbook tagged $tag; found $($estate.Count)." }
    $document = [ordered]@{
        schemaVersion = 1
        subscriptionId = "$($Context.SubscriptionId)"
        tenantId = "$($Context.TenantId)"
        recordedAtUtc = (Get-BuildContextTime $State)
        resourceGroups = [ordered]@{ arc = $Context.ArcGroup; infra = $Context.InfraGroup }
        workspaceResourceId = (Get-BuildArcResourceId $Context 'Microsoft.OperationalInsights/workspaces' "law-$($Context.Prefix)")
        workbookResourceId = $estate[0].id
        windowsMachineResourceId = (Get-BuildArcResourceId $Context 'Microsoft.HybridCompute/machines' $presenter.WindowsMachineName)
        linuxMachineResourceId = (Get-BuildArcResourceId $Context 'Microsoft.HybridCompute/machines' $presenter.LinuxMachineName)
        heartbeatAlertResourceId = (Get-BuildArcResourceId $Context 'Microsoft.Insights/scheduledQueryRules' "alert-$($Context.Prefix)-host-missing-heartbeat")
        actionGroupResourceId = (Get-BuildArcResourceId $Context 'Microsoft.Insights/actionGroups' "ag-$($Context.Prefix)")
    }
    if ($presenter.LobMachineName) { $document['lobMachineName'] = $presenter.LobMachineName }
    $proof = Join-BuildPath $Context.ArcRoot '.local/sql-engine-status.json'
    if ($Context.Config.RealSql -and (Test-Path -LiteralPath $proof -PathType Leaf)) {
        if ((Get-DemoSkinValue (Read-BuildJson $proof) 'evidence.status' '') -eq 'pass') {
            $document['sqlMachineResourceId'] = Get-BuildArcResourceId $Context 'Microsoft.HybridCompute/machines' $Context.Config.RealSql.MachineName
            $document['sqlIncidentAlertResourceId'] = Get-BuildArcResourceId $Context 'Microsoft.Insights/scheduledQueryRules' "al-$($Context.Prefix)-sql-lock-timeout"
        } else {
            Write-Warn 'The saved SQL status is not "pass", so the SQL presenter fields are left out. Re-run P5 Status when the worker is active.'
        }
    }
    foreach ($slot in 'capacityWorkbookResourceId', 'optimisationWorkbookResourceId') {
        if ($State.values.Contains($slot)) { $document[$slot] = $State.values[$slot] }
    }
    foreach ($key in @($document.Keys | Where-Object { $_ -match 'ResourceId$' })) { Assert-BuildResourceExists $document[$key] }
    $offer = {
        param([string]$Key, [string]$Id, [string]$Chapter)
        if (Test-BuildResourceExists $Id) { $document[$Key] = $Id; return $true }
        $LeftOut.Add($Chapter)
        $false
    }
    $null = & $offer 'dataCollectionRuleResourceId' (Get-BuildArcResourceId $Context 'Microsoft.Insights/dataCollectionRules' 'dcr-arc-demo') 'the data collection rule beat'
    $dash = [string][char]0x2014
    foreach ($entry in @(
        @('machineIntelligenceWorkbookResourceId', 'Machine Intelligence Center', 'the Machine Intelligence Center steps'),
        @('complianceWorkbookResourceId', 'Compliance, Security & Governance', 'the compliance workbook steps'),
        @('assetInventoryWorkbookResourceId', 'Asset Inventory', 'the Asset Inventory step'),
        @('sqlEstateWorkbookResourceId', 'SQL Estate Dashboard', 'the SQL Estate workbook steps'))) {
        # Deploy tags each workbook with its display name; the list above already proves a match exists.
        $optionalTag = ("Arc $dash $($entry[1])" -replace '[^A-Za-z0-9]', '-').ToLowerInvariant()
        $match = @($workbooks | Where-Object { $_.tags -and $_.tags.PSObject.Properties['workbookTag'] -and $_.tags.workbookTag -eq $optionalTag })
        if ($match.Count -gt 1) { throw "Expected at most one workbook tagged $optionalTag; found $($match.Count)." }
        if ($match.Count) { $document[$entry[0]] = $match[0].id } else { $LeftOut.Add($entry[2]) }
    }
    if ($Context.Nested) {
        $guestMachine = Get-BuildArcResourceId $Context 'Microsoft.HybridCompute/machines' $Context.Nested.ArcMachineName
        if (& $offer 'nestedSqlMachineResourceId' $guestMachine 'the nested Arc SQL chapter') {
            $null = & $offer 'nestedSqlInstanceResourceId' (Get-BuildArcResourceId $Context 'Microsoft.AzureArcData/sqlServerInstances' $Context.Nested.GuestVmName) "the nested guest's SQL Server instance link"
            $null = & $offer 'nestedSqlParentMachineResourceId' (Get-BuildArcResourceId $Context 'Microsoft.HybridCompute/machines' $Context.Nested.ParentVmName) "the nested guest's parent host link"
        }
    }
    $guide = if ($Context.Config.Sre) { Join-BuildPath $Context.Config.Sre.RepoPath '.local/presenter-runsheet.md' } else { '' }
    if ($guide -and (Test-Path -LiteralPath $guide -PathType Leaf)) { $document['companionSreRunsheetPath'] = $guide }
    $document
}

function Invoke-ArcDemoPresenterHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$State)
    $leftOut = [System.Collections.Generic.List[string]]::new()
    $document = New-ArcDemoPresenterContext -Context $Context -State $State -LeftOut $leftOut
    if ($leftOut.Count) {
        Write-Warn "Optional chapters left out of the presenter guide because their resources were not found: $($leftOut -join '; '). Build them, then run P10 again."
    }
    $directory = Join-Path $Context.ArcRoot '.local'
    $null = New-Item -ItemType Directory -Path $directory -Force
    $file = Join-Path $directory 'demo-context.json'
    $document | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $file -Encoding utf8
    Invoke-BuildLooseScript -Path (Join-BuildPath $Context.ArcRoot 'scripts/New-PresenterRunsheet.ps1') -Arguments @{ ContextPath = $file; Confirm = $false } | Out-Host
    if ($Context.Config.Sre) {
        $sreGuide = Join-BuildPath $Context.Config.Sre.RepoPath 'scripts/New-PresenterRunsheet.ps1'
        if ((Test-Path -LiteralPath (Join-BuildPath $Context.Config.Sre.RepoPath '.local/demo-context.json') -PathType Leaf) -and (Test-Path -LiteralPath $sreGuide -PathType Leaf)) {
            $options = @{}
            if ('Confirm' -in (Get-BuildScriptParameter $sreGuide)) { $options['Confirm'] = $false }
            Invoke-BuildLooseScript -Path $sreGuide -Arguments $options | Out-Host
        } else {
            Write-Warn 'The SRE repo has no .local\demo-context.json yet; record it with the SRE handbook, then run its New-PresenterRunsheet.ps1.'
        }
    }
    [pscustomobject]@{ status = 'pass'; contextPath = $file; resourceIds = @($document.Keys | Where-Object { $_ -match 'ResourceId$' }).Count; chaptersLeftOut = $leftOut.ToArray() }
}

function Invoke-BuildLooseScript {
    # The maintained scripts do not set strict mode and rely on unset variables and missing properties being $null,
    # so they must not inherit this module's strict mode (it would also hide their own JSON/exit-code error contract).
    param([Parameter(Mandatory)][string]$Path, [System.Collections.IDictionary]$Arguments = @{})
    & { param($File, $Splat) Set-StrictMode -Off; & $File @Splat } $Path $Arguments
}

function Invoke-BuildStepScript {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    # A script that does not call exit must not report a stale code from an earlier command.
    Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
    $output = @(Invoke-BuildLooseScript -Path $Path -Arguments $Arguments)
    [pscustomobject]@{ Output = $output; ExitCode = (Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue) }
}

function Initialize-BuildOutputPath {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    foreach ($key in $script:OutputPathKeys) {
        if ($Arguments.Contains($key) -and $Arguments[$key]) { $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Arguments[$key]) -Force }
    }
}

function Write-BuildCheckSummary {
    param([AllowNull()]$Output)
    try {
        $result = ConvertFrom-BuildOutput $Output
        if ($result -isnot [System.Collections.IDictionary] -or -not $result.Contains('checks')) { return }
        Write-Step "Readiness status: $($result['status'])"
        foreach ($check in @($result['checks'] | Where-Object { $_['required'] -and $_['status'] -ne 'pass' } | Select-Object -First 15)) {
            Write-Warn "$($check['id']): $($check['status']) (observed: $($check['observed']))"
        }
    } catch { Write-Verbose 'Readiness output could not be summarised.' }
}

function Write-BuildEvidence {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$StepId, [Parameter(Mandatory)]$Record)
    $null = New-Item -ItemType Directory -Path $Directory -Force
    $path = Join-Path $Directory ('{0}-{1}.json' -f $StepId, [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
    ConvertTo-BuildSafeValue $Record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
    $path
}

function Invoke-ArcDemoBuildStep {
    <#
    .SYNOPSIS
        Runs one step, records it in the private state file and writes per-step evidence.
    .DESCRIPTION
        A failure is recorded and rethrown, so the build stops at the failed step.
        -NoState runs a read-only step without touching the state file or evidence.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step, [Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$State, [switch]$NoState)
    $Context.State = $State
    $started = [DateTime]::UtcNow
    $record = if ($State.steps.Contains($Step.Id)) { $State.steps[$Step.Id] } else { @{ attempts = 0 } }
    $captured = [ordered]@{ step = $Step.Id; title = $Step.Title; startedUtc = $started.ToString('o') }
    $failure = $null
    $began = $false
    Write-Header "$($Step.Id) - $($Step.Title)"
    try {
        $path = ''
        $arguments = [ordered]@{}
        if ($Step.Kind -eq 'script') {
            $path = Get-BuildScriptPath $Context $Step
            foreach ($entry in (& $Step.Arguments $Context).GetEnumerator()) { $arguments[$entry.Key] = $entry.Value }
            if ($Step.Resolve) { & $Step.Resolve $Context $arguments }
            if ('Confirm' -in (Get-BuildScriptParameter $path)) { $arguments['Confirm'] = $false }
            Initialize-BuildOutputPath $arguments
        }
        # Only now has the step really started; a failure before this point leaves it retryable.
        $began = $true
        $record['attempts'] = [int]$record['attempts'] + 1
        $record['status'] = 'running'
        $record['startedUtc'] = $captured['startedUtc']
        if (-not $NoState) { $State.steps[$Step.Id] = $record; Save-ArcDemoBuildState -Path $Context.Config.StatePath -State $State }
        if ($Step.Kind -eq 'internal') {
            $captured['result'] = ConvertTo-BuildSafeValue (& $Step.Run $Context $State)
        } else {
            $captured['script'] = $Step.Script
            $captured['arguments'] = ConvertTo-BuildSafeValue $arguments
            $deadline = [DateTime]::UtcNow.AddMinutes($Step.WaitMinutes)
            while ($true) {
                $run = Invoke-BuildStepScript -Path $path -Arguments $arguments
                $exit = if ($Step.ExitCodes) { [int]$run.ExitCode } else { 0 }
                $captured['exitCode'] = $exit
                $captured['output'] = ConvertTo-BuildSafeValue (ConvertFrom-BuildOutput $run.Output)
                if ($Step.ExitCodes) { Write-BuildCheckSummary $run.Output }
                if ($exit -ne 2 -or [DateTime]::UtcNow -ge $deadline) { break }
                Write-Step "$($Step.Id) is still pending; checking again shortly."
                Start-Sleep -Seconds 15
            }
            if ($exit -eq 2) { throw "$($Step.Id) is still pending after $($Step.WaitMinutes) minutes. Re-run later; nothing was repaired." }
            if ($exit -ne 0) { throw "$($Step.Id) reported failure (exit $exit). See the evidence file." }
            if ($Step.ResultStatus) {
                $reported = @($run.Output | Where-Object { $_ -and $_.PSObject.Properties['status'] } | Select-Object -Last 1)
                if ($reported.Count -and "$($reported[0].status)" -eq 'pending') { throw "$($Step.Id) reports status pending, so it is not recorded as done. Re-run it; its phases are idempotent." }
                if ($reported.Count -and "$($reported[0].status)" -eq 'fail') { throw "$($Step.Id) reports status fail." }
            }
            if ($Step.Capture) { & $Step.Capture $State.values $run.Output }
        }
        $record['status'] = 'done'
        $record['message'] = ''
    } catch {
        $failure = $_
        $record['status'] = if ($began) { 'failed' } else { 'blocked' }
        $record['message'] = $_.Exception.Message.Substring(0, [Math]::Min(400, $_.Exception.Message.Length))
    }
    $ended = [DateTime]::UtcNow
    $record['endedUtc'] = $ended.ToString('o')
    if (-not $NoState) {
        $captured['status'] = $record['status']
        $captured['message'] = $record['message']
        $captured['endedUtc'] = $record['endedUtc']
        $record['evidence'] = Write-BuildEvidence -Directory $Context.Config.EvidenceDirectory -StepId $Step.Id -Record $captured
        $State.steps[$Step.Id] = $record
        Save-ArcDemoBuildState -Path $Context.Config.StatePath -State $State
    }
    $minutes = [math]::Round(($ended - $started).TotalMinutes, 1)
    if ($failure) { Write-Fail "$($Step.Id) failed after $minutes min: $($record['message'])"; throw $failure }
    Write-Ok "$($Step.Id) done in $minutes min"
}

function Write-ArcDemoBuildPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Plan, [string[]]$Warnings = @())
    Write-Header 'Build plan'
    $Plan | Select-Object Step, Status, @{ n = 'Min'; e = { $_.Minutes } },
        @{ n = 'Needs'; e = { (@($_.Needs | ForEach-Object { "-$($script:ApprovalSwitch[$_])" }) -join ' ') } }, Title | Format-Table -AutoSize | Out-Host
    foreach ($row in $Plan) {
        if ($row.Reason) { Write-Step "$($row.Step) skipped: $($row.Reason)" }
        foreach ($note in $row.Notes) { Write-Step "$($row.Step): $note" }
        foreach ($blocker in $row.Blockers) { Write-Warn "$($row.Step) blocked: $blocker" }
    }
    foreach ($warning in $Warnings) { Write-Warn $warning }
    $total = [int](($Plan | Where-Object { $_.Status -in @('ready', 'blocked') } | Measure-Object -Property Minutes -Sum).Sum)
    Write-Step "About $total minutes of work remain in this selection (typical, not a promise); billable resources start at P2."
}

function Get-ArcDemoApprovalSwitch { $script:ApprovalSwitch }

Export-ModuleMember -Function Read-ArcDemoBuildConfig, New-ArcDemoBuildContext, Get-ArcDemoBuildSteps, Select-ArcDemoBuildStep,
    Get-ArcDemoBuildPlan, Resolve-ArcDemoPlanSkip, Get-ArcDemoBuildWindowWarning, New-ArcDemoBuildState, Read-ArcDemoBuildState, Save-ArcDemoBuildState,
    Test-ArcDemoBuildStateFresh, Invoke-ArcDemoBuildPreflight, Invoke-ArcDemoBuildIdentityCheck, New-ArcDemoPresenterContext,
    Invoke-ArcDemoPresenterHandoff, Invoke-ArcDemoBuildStep, Write-ArcDemoBuildPlan, Get-ArcDemoApprovalSwitch, ConvertTo-BuildSafeValue,
    Get-BuildGuestCredential
