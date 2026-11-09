#Requires -Version 7.4
<#
.SYNOPSIS
    Builds the whole demo estate from main in one ordered path: plan only unless -Execute.
.DESCRIPTION
    A thin wrapper that calls the maintained scripts in order (P0-P11): preflight, base
    estate, Hyper-V parent, nested guest, real SQL, Monitor add-ons, readiness, SRE layer
    in the companion repo, presenter guide, inventory snapshot and parity check.

    The default is a read-only plan. -Execute runs the steps that are not already recorded
    as done in the private state file, so a failed or interrupted run resumes where it
    stopped. A workbook step (P6.2, P6.3) records a snapshot of the Arc roster and tags, so
    it runs again when P2 or P4 finished after it did. -Only takes a phase (P6) or one step
    (P6.2, P6.3), for example `-Only P6.2, P6.3 -Force` to republish just the two workbooks
    after a tag repair. Billable resources, licence terms and IAM changes each need an explicit switch, never implied.
    Pass -ApproveCostStart (P2) to confirm you want to start billable resources, -AcceptWindowsEvaluationTerms
    and -AcceptSqlDeveloperTerms (P3, P5) to accept those licence terms, -ApproveSreCreation (P9) to create the
    SRE parent and -ApproveSubscriptionGrant for the subscription-scope Azure Monitor alert-access grant that the
    SRE agent needs to read alerts (pass it on a first SRE build). The plan lists the other switches it needs.
    -Execute asks for confirmation: add -Confirm:$false in a shell that cannot answer a prompt.

    When the nested guest (P4) will run, the Administrator credential is resolved at
    the start, not about an hour in: -GuestCredential, else a DPAPI-protected export
    saved as nested-guest-credential.clixml in the private folder (docs/private-config.md
    has the recipe, and a [pscredential] cannot be passed to pwsh -File), else a prompt.
    The wrapper never writes it. The SRE preview and create steps (P9.1, P9.2) are skipped, not failed,
    when the SRE parent already exists, because Deploy-SreAgent.ps1 refuses an existing
    parent even with -WhatIf.

    The build config, state and evidence live in one private folder outside the git
    worktree. See docs/private-config.md. -WhatIf is the same as the default plan.
.EXAMPLE
    .\Invoke-ArcDemoBuild.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -BuildConfigPath <PRIVATE>\build.json
.EXAMPLE
    .\Invoke-ArcDemoBuild.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -BuildConfigPath <PRIVATE>\build.json `
        -Execute -From P2 -To P4 -ApproveCostStart -AcceptWindowsEvaluationTerms -AcceptSqlDeveloperTerms -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][string]$BuildConfigPath,
    [ValidateSet('P0', 'P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7', 'P8', 'P9', 'P10', 'P11')][string]$From,
    [ValidateSet('P0', 'P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7', 'P8', 'P9', 'P10', 'P11')][string]$To,
    [ValidateSet('P0', 'P1', 'P2', 'P3', 'P4', 'P5', 'P5.1', 'P5.2', 'P5.3', 'P5.4', 'P6', 'P6.1', 'P6.2', 'P6.3', 'P7', 'P8', 'P8.1', 'P8.2',
        'P9', 'P9.1', 'P9.2', 'P9.3', 'P10', 'P11', 'P11.1', 'P11.2')][string[]]$Only,
    [switch]$Execute,
    [switch]$Force,
    [switch]$Offline,
    [switch]$ApproveCostStart,
    [switch]$AcceptWindowsEvaluationTerms,
    [switch]$AcceptSqlDeveloperTerms,
    [switch]$ApproveSreCreation,
    [switch]$ApproveSubscriptionGrant,
    [pscredential]$GuestCredential,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/BuildPlan.psm1') -Force

$run = $Execute -and -not $WhatIfPreference
if ($Execute -and $Offline) { throw '-Offline only applies to the plan; execution needs Azure.' }
$approved = @{
    CostStart = [bool]$ApproveCostStart
    WindowsEvaluationTerms = [bool]$AcceptWindowsEvaluationTerms
    SqlDeveloperTerms = [bool]$AcceptSqlDeveloperTerms
    SreCreation = [bool]$ApproveSreCreation
}
$config = Read-ArcDemoBuildConfig -Path $BuildConfigPath -RepoRoot $repoRoot
$context = New-ArcDemoBuildContext -Config $config -SubscriptionId $SubscriptionId -TenantId $TenantId -RepoRoot $repoRoot `
    -GuestCredential $GuestCredential -Approved $approved -ApproveSubscriptionGrant:$ApproveSubscriptionGrant
$state = Read-ArcDemoBuildState -Path $config.StatePath -SubscriptionId $SubscriptionId -TenantId $TenantId -Prefix $context.Prefix
$steps = @(Select-ArcDemoBuildStep -Steps (Get-ArcDemoBuildSteps -Context $context) -From $From -To $To -Only $Only)
$plan = @(Get-ArcDemoBuildPlan -Context $context -Steps $steps -State $state -Force:$Force)
$context.RemainingMinutes = [int](($plan | Where-Object { $_.Status -in @('ready', 'blocked') -and $_.Phase -in @('P2', 'P3', 'P4', 'P5', 'P6', 'P7', 'P8', 'P9') } |
    Measure-Object -Property Minutes -Sum).Sum)

if (-not $run) {
    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($WhatIfPreference -and $Execute) { $warnings.Add('-WhatIf: showing the plan only; nothing was run.') }
    if (-not $Offline) {
        try {
            Initialize-DemoContext -SubscriptionId $SubscriptionId -TenantId $TenantId
            $stale = Test-ArcDemoBuildStateFresh -Context $context -State $state
            if ($stale) { $warnings.Add($stale) }
            foreach ($row in $plan | Where-Object { $_.Step -in @('P0', 'P1') -and $_.Status -ne 'skipped' }) {
                Invoke-ArcDemoBuildStep -Step $row.Definition -Context $context -State $state -NoState
            }
            Resolve-ArcDemoPlanSkip -Plan $plan -Context $context
        } catch { $warnings.Add("Read-only checks stopped: $($_.Exception.Message)") }
    }
    Write-ArcDemoBuildPlan -Plan $plan -Warnings $warnings
    $needed = @($plan | Where-Object { $_.Status -in @('ready', 'blocked') } | ForEach-Object { $_.Needs })
    $switches = @((Get-ArcDemoApprovalSwitch).GetEnumerator() | Where-Object { $_.Key -in $needed } | ForEach-Object { "-$($_.Value)" })
    Write-Step ('To run it: .\scripts\Invoke-ArcDemoBuild.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -BuildConfigPath <CONFIG> -Execute ' + (($switches + '-Confirm:$false') -join ' '))
    if (@($plan | Where-Object { $_.Step -eq 'P9.2' -and $_.Status -in @('ready', 'blocked') }).Count) {
        Write-Step "First SRE build? Also pass -ApproveSubscriptionGrant (the SRE agent can't read Azure Monitor alerts without the one subscription grant); leave it out only if its identity already has it."
    }
    if ($PassThru) { $plan | Select-Object -ExcludeProperty Definition -Property * }
    return
}

function Assert-PlanRunnable {
    param([object[]]$Rows)
    $blocked = @($Rows | Where-Object Status -eq 'blocked')
    if ($blocked) {
        Write-ArcDemoBuildPlan -Plan $plan
        throw "Blocked step(s): $($blocked.Step -join ', '). Nothing was started. Fix the blockers above, or select other phases with -From/-To/-Only."
    }
    $missing = @($Rows | Where-Object { $_.Needs.Count } | ForEach-Object { foreach ($need in $_.Needs) { "-$((Get-ArcDemoApprovalSwitch)[$need]) ($($_.Step))" } })
    if ($missing) { throw "Confirmation switch(es) missing: $($missing -join ', '). Nothing was started." }
}
# Steps that can never be skipped fail fast, before any Azure read; the others (the SRE parent steps) are
# checked after the read-only resolution, so a skipped step neither blocks nor needs a switch.
Assert-PlanRunnable @($plan | Where-Object { -not $_.Definition.SkipWhen })
Initialize-DemoContext -SubscriptionId $SubscriptionId -TenantId $TenantId
$stale = Test-ArcDemoBuildStateFresh -Context $context -State $state
if ($stale) { throw $stale }
Resolve-ArcDemoPlanSkip -Plan $plan -Context $context
Assert-PlanRunnable $plan
$todo = @($plan | Where-Object { $_.Status -eq 'ready' })
Write-ArcDemoBuildPlan -Plan $plan
if (-not $todo) { Write-Ok 'Nothing to do: every selected step is already recorded as done or skipped.'; return }
if (-not $PSCmdlet.ShouldProcess("$($context.Prefix): $($todo.Step -join ', ')", 'Run the ordered build (billable resources, credentials and IAM per the switches you passed)')) { return }
if ('P4' -in $todo.Step -and -not $context.GuestCredential) {
    # Ask now rather than about an hour in, so the long build can run unattended: -GuestCredential, else the private
    # folder's saved nested-guest-credential.clixml, else a prompt. This script never writes a credential.
    $context.GuestCredential = Get-BuildGuestCredential -Context $context
    if (-not $context.GuestCredential) { throw 'The nested guest (P4) needs an Administrator credential. Nothing was started.' }
}
foreach ($row in $todo) {
    Invoke-ArcDemoBuildStep -Step $row.Definition -Context $context -State $state
}
Write-Header 'Build steps finished'
Write-Ok "Steps run: $($todo.Step -join ', '). State: $($config.StatePath)"
if ($PassThru) { $todo | Select-Object -ExcludeProperty Definition -Property * }
