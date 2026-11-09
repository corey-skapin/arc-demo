<#
.SYNOPSIS
    Restores outbound networking, starts retained workloads and validates the demo.
.DESCRIPTION
    Uses retained deployment manifests and actual VM OS metadata, not name prefixes.
    Does not reset workload faults or credentials. Once compute is running, one shared wait with a single
    global deadline (-GuestCheckMinutes, default 12) decides each host from ARM and telemetry: the VM is running,
    Arc is Connected and, for monitored hosts, a Heartbeat was generated after the VM start. Run Command is not
    used by default, so a queued VM extension update cannot stall the wake. A host without a Heartbeat at the
    deadline is pending, not failed. Extension provisioning state (AMA, Change Tracking, MDE) is only a warning.
    -GuestChecks WhenStalled|Always opts in to Run Command guest checks that share the same deadline;
    -RepairStalledAgents also restarts the Arc/AMA services they check. The nested SQL guest start keeps its
    Run Command, runs concurrently and has its own five-minute budget. Patch assessments are submitted for newly
    started Arc hosts unless skipped. -AssessPatches explicitly assesses all Arc hosts, including already-active
    retries. Submission is not completion.
    -WhatIf is read-only. Optional ResultPath preserves per-host outcomes.
#>
#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$NamePrefix = 'arc-demo',
    [string]$Location = 'australiaeast',
    [string]$SkinPath = '',
    [switch]$SkipValidate,
    [switch]$SkipPatchAssessment,
    [switch]$AssessPatches,
    [ValidateRange(1, 120)][int]$GuestCheckMinutes = 12,
    [ValidateSet('None', 'WhenStalled', 'Always')][string]$GuestChecks = 'None',
    [ValidateRange(1, 120)][int]$StallMinutes = 9,
    [switch]$RepairStalledAgents,
    [string]$ResultPath = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$skin = Get-DemoSkin -Path $SkinPath -RepoRoot (Split-Path $PSScriptRoot)
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
if (-not $PSBoundParameters.ContainsKey('Location')) { $Location = Get-DemoSkinValue $skin 'azure.location' $Location }
$nestedSqlGuest = Get-DemoNestedSqlGuestConfig -Skin $skin
Assert-DemoName $NamePrefix
if ($SkipPatchAssessment -and $AssessPatches) { throw 'AssessPatches and SkipPatchAssessment cannot both be supplied.' }
if ($RepairStalledAgents -and $GuestChecks -eq 'None') { throw 'RepairStalledAgents needs -GuestChecks WhenStalled or Always.' }
if ($GuestChecks -eq 'WhenStalled' -and $StallMinutes -ge $GuestCheckMinutes) { throw 'StallMinutes must be less than GuestCheckMinutes.' }
Initialize-DemoContext $SubscriptionId $TenantId
$inventory = Get-DemoInventory $NamePrefix -NestedSqlParentVmName $(if ($nestedSqlGuest) { $nestedSqlGuest.ParentVmName } else { '' }) `
    -KeepParkedVmNames @(Get-DemoSkinValue $skin 'operations.keepParkedVmNames' @())
Assert-DemoSkinInventory $skin $inventory
$missing = @($inventory.Machines | Where-Object { -not $_.Actual })
if ($missing) { throw "Missing expected VMs: $($missing.Name -join ', '). Reconcile deployment before activation." }
$network = Get-DemoNetworkState -InfraRg $inventory.InfraRg -NamePrefix $NamePrefix
if ($WhatIfPreference) {
    foreach ($line in @(Get-DemoWakePreview -Inventory $inventory -NestedSqlGuest $nestedSqlGuest -Network $network -GuestCheckMinutes $GuestCheckMinutes)) { Write-Step $line }
}
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId / $NamePrefix", 'Restore NAT, start retained workloads, verify guests and assess newly started Arc hosts (AssessPatches explicitly includes already-active hosts; no fault reset)')) { return }

$attemptStartedUtc = (Get-Date).ToUniversalTime()
$result = [ordered]@{
    schemaVersion = 1; workload = 'arc-demo-activation'
    startedAtUtc = [DateTime]::UtcNow.ToString('o'); completedAtUtc = $null
    subscriptionId = "$SubscriptionId"; tenantId = "$TenantId"; status = 'running'
    guestCheckMinutes = $GuestCheckMinutes; guestChecksMode = $GuestChecks
    guestChecks = @(); nestedGuest = $null; patchAssessments = @()
    patchAssessment = if ($SkipPatchAssessment) { 'skipped' } else { 'not-run' }
    readiness = 'not-run'; error = $null
}
if ($ResultPath) {
    if (-not (Test-Path -LiteralPath (Split-Path ([System.IO.Path]::GetFullPath($ResultPath))) -PathType Container)) {
        throw 'ResultPath parent directory must already exist; use a private path outside git.'
    }
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ResultPath -Encoding utf8
}
$jobs = @()
$assessment = $null
try {
    $infraRg = $inventory.InfraRg
    $natId = $network.NatId
    if (-not $network.PublicIp) {
        Invoke-DemoAz -Arguments @('network', 'public-ip', 'create', '-g', $infraRg, '-n', "pip-natgw-$NamePrefix", '-l', $Location, '--sku', 'Standard', '--allocation-method', 'Static', '-o', 'none') | Out-Null
    }
    if (-not $network.Nat) {
        Invoke-DemoAz -Arguments @('network', 'nat', 'gateway', 'create', '-g', $infraRg, '-n', "natgw-$NamePrefix", '-l', $Location, '--public-ip-addresses', "pip-natgw-$NamePrefix", '--idle-timeout', '10', '-o', 'none') | Out-Null
    } elseif (-not @($network.Nat.publicIpAddresses | Where-Object { $_.id -eq $network.PublicIpId }).Count) {
        Invoke-DemoAz -Arguments @('network', 'nat', 'gateway', 'update', '--ids', $natId, '--public-ip-addresses', $network.PublicIpId, '-o', 'none') | Out-Null
    }
    $subnet = Invoke-DemoAz -Arguments @('network', 'vnet', 'subnet', 'show', '-g', $infraRg, '--vnet-name', "vnet-$NamePrefix", '-n', 'snet-vms', '-o', 'json') | ConvertFrom-Json
    if ($subnet.natGateway.id -and $subnet.natGateway.id -ne $natId) { throw 'Demo subnet has an unexpected NAT Gateway; refusing to overwrite it.' }
    if ($subnet.natGateway.id -ne $natId) {
        Invoke-DemoAz -Arguments @('network', 'vnet', 'subnet', 'update', '--ids', $subnet.id, '--nat-gateway', $natId, '-o', 'none') | Out-Null
    }
    $startedVmIds = @()
    $startedAtUtc = @{}
    foreach ($machine in $inventory.Machines) {
        if ($machine.Actual.powerState -ne 'VM running') {
            if ($machine.Actual.powerState -ne 'VM starting') {
                Invoke-DemoAz -Arguments @('vm', 'start', '--ids', $machine.Id, '--no-wait', '-o', 'none') | Out-Null
                $startedAtUtc[$machine.Id] = (Get-Date).ToUniversalTime()
            } else { $startedAtUtc[$machine.Id] = $attemptStartedUtc }
            $startedVmIds += $machine.Id
        }
    }
    # The NAT gateway and public IP are created above, and Bicep no longer declares them once they exist, so a recreated pair
    # would keep no tags unless they are written here. Tags are cost-allocation metadata: a failure warns and never stops the wake.
    try {
        $labTags = Get-DemoResourceTags -Skin $skin
        foreach ($networkResourceId in @($network.PublicIpId, $network.NatId)) { $null = Set-DemoResourceTags -ResourceId $networkResourceId -Tags $labTags }
    } catch { Write-Warning "The NAT gateway and public IP could not be tagged ($($_.Exception.Message)). The wake continues; the tags are cost-allocation metadata only." }
    Wait-Until -Message 'expected VM identities running' -Condition {
        $vms = @(Invoke-DemoAz -Arguments @('vm', 'list', '-g', $infraRg, '--show-details', '-o', 'json') | ConvertFrom-Json)
        @($inventory.Machines | Where-Object { $_.Id -notin @($vms | Where-Object powerState -eq 'VM running' | ForEach-Object { $_.id }) }).Count -eq 0
    } | Out-Null

    $nestedStart = $null
    if ($nestedSqlGuest) {
        $parent = $inventory.Machines | Where-Object Name -ceq $nestedSqlGuest.ParentVmName | Select-Object -First 1
        if (-not $parent) { throw 'Configured nested SQL parent was not found in the retained inventory.' }
        # Submitted now, collected by the shared wait under its own five-minute budget.
        $nestedStart = [pscustomobject]@{
            Parent = $parent; GuestVmName = $nestedSqlGuest.GuestVmName; ArcMachineName = $nestedSqlGuest.ArcMachineName
            Job = Invoke-DemoNestedSqlGuest -ParentMachine $parent -GuestVmName $nestedSqlGuest.GuestVmName -Action Start -AsJob
            SubmittedUtc = (Get-Date).ToUniversalTime(); BudgetMinutes = 5
        }
        $jobs += @{ Job = $nestedStart.Job }
    }
    foreach ($id in $inventory.AksClusterIds) {
        $cluster = Invoke-DemoAz -Arguments @('aks', 'show', '-g', $infraRg, '-n', ($id -split '/')[-1], '-o', 'json') | ConvertFrom-Json
        if ($cluster.provisioningState -eq 'Starting') { continue }
        if ($cluster.provisioningState -ne 'Succeeded') { throw "AKS $($cluster.name) is $($cluster.provisioningState). Wait for the current operation to finish, then retry; do not start during stop." }
        if ($cluster.powerState.code -eq 'Stopped') { Invoke-DemoAz -Arguments @('aks', 'start', '-g', $infraRg, '-n', ($id -split '/')[-1], '--no-wait', '-o', 'none') | Out-Null }
        elseif ($cluster.powerState.code -ne 'Running') { throw "Unexpected AKS power state: $($cluster.powerState.code)" }
    }
    if ($inventory.AksClusterIds.Count) {
        Wait-Until -Message 'expected AKS clusters running' -TimeoutSeconds 1200 -Condition {
            foreach ($id in $inventory.AksClusterIds) {
                $cluster = Invoke-DemoAz -Arguments @('aks', 'show', '-g', $infraRg, '-n', ($id -split '/')[-1], '-o', 'json') | ConvertFrom-Json
                if ($cluster.provisioningState -ne 'Succeeded' -or $cluster.powerState.code -ne 'Running') { return $false }
            }
            return $true
        } | Out-Null
    }
    foreach ($id in $inventory.ContainerAppIds) {
        $app = Invoke-DemoAz -Arguments @('containerapp', 'show', '--ids', $id, '-o', 'json') | ConvertFrom-Json
        $revisions = @(Invoke-DemoAz -Arguments @('containerapp', 'revision', 'list', '-g', $infraRg, '-n', $app.name, '-o', 'json') | ConvertFrom-Json)
        if (@($revisions | Where-Object { $_.properties.active }).Count -eq 0) {
            Invoke-DemoAz -Arguments @('containerapp', 'revision', 'activate', '-g', $infraRg, '--revision', $app.properties.latestRevisionName, '-o', 'none') | Out-Null
        }
    }
    $wait = Wait-DemoHostsReady -Inventory $inventory -NamePrefix $NamePrefix -AttemptStartedUtc $attemptStartedUtc -StartedAtUtc $startedAtUtc `
        -DeadlineMinutes $GuestCheckMinutes -GuestChecks $GuestChecks -StallMinutes $StallMinutes -RepairStalledAgents:$RepairStalledAgents -NestedGuest $nestedStart
    $result.guestChecks = @($wait.Hosts)
    $result.nestedGuest = $wait.NestedGuest
    $failures = @($wait.Hosts | Where-Object { $_.status -eq 'fail' } | ForEach-Object { "$($_.machineName): $($_.message)" })
    if ($wait.NestedGuest.status -eq 'fail') { $failures += "nested guest $($wait.NestedGuest.guestVmName): $($wait.NestedGuest.message)" }
    if ($failures) { throw ($failures -join '; ') }
    if ($wait.Status -eq 'pending') { Write-Warning 'Compute is running; telemetry is pending for the hosts above. Poll Test-ArcDemoReadiness before presenting or offering an incident.' }
    if (-not $SkipPatchAssessment) {
        foreach ($machine in $inventory.Machines | Where-Object { -not $_.Native -and ($AssessPatches -or $_.Id -in $startedVmIds) }) {
            $assessment = [ordered]@{ machineName = $machine.Name; resourceId = $machine.ArcId; status = 'pending' }
            $result.patchAssessments += $assessment
            try {
                Invoke-DemoAz -Arguments @('connectedmachine', 'assess-patches', '--ids', $machine.ArcId, '--no-wait', '-o', 'none') | Out-Null
                $assessment.status = 'submitted'
                Write-Ok "Patch assessment submitted: $($machine.Name)"
            } catch {
                if ($_.Exception.Message -notmatch '\bERROR:\s*\(OperationConflict\)') { throw }
                $assessment.status = 'already-in-progress'
                $assessment['message'] = 'An assess/patch operation is already running; no retry or cancellation. Completion is not verified.'
                Write-Warning "$($machine.Name): $($assessment.message)"
            }
        }
        $result.patchAssessment = if (@($result.patchAssessments | Where-Object status -eq 'submitted').Count) { 'submitted' }
            elseif ($result.patchAssessments.Count) { 'already-in-progress' } else { 'not-required' }
    }
    if (-not $SkipValidate) {
        $ready = & (Join-Path $PSScriptRoot 'Test-ArcDemoReadiness.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId -NamePrefix $NamePrefix -SkinPath $SkinPath -OutputFormat Json | ConvertFrom-Json
        $result.readiness = $ready.status
        $result['readinessChecks'] = $ready.checks
        if ($LASTEXITCODE -notin @(0, 2) -or $ready.schemaVersion -ne 1 -or $ready.status -notin @('pass', 'pending') -or @($ready.checks | Where-Object { $_.required -and $_.status -ne 'pass' -and $_.id -notlike 'heartbeat/*' }).Count) {
            throw 'Activation readiness failed or non-telemetry checks remain pending. Inspect readinessChecks in ResultPath.'
        }
        if ($ready.status -eq 'pending') { Write-Warning 'Compute/services are active; telemetry is pending. Re-run Test-ArcDemoReadiness before presenting or offering an incident.' }
    } else { $result.readiness = 'skipped' }
    $result.status = if ($result.readiness -eq 'pending' -or $wait.Status -eq 'pending') { 'pending' } else { 'pass' }
} catch {
    $result.status = 'fail'
    $result.error = $_.Exception.Message
    if ($assessment -and $assessment.status -eq 'pending') { $assessment.status = 'fail' }
    throw
} finally {
    $result.completedAtUtc = [DateTime]::UtcNow.ToString('o')
    foreach ($item in $jobs) {
        if ($item.Job.Id) { Get-Job -Id $item.Job.Id -ErrorAction SilentlyContinue | Stop-Job -PassThru | Remove-Job -Force }
        if ($item.Job.DemoScriptPath) { [System.IO.File]::Delete($item.Job.DemoScriptPath) }
    }
    if ($ResultPath) { Write-DemoResultFile -Result $result -Path $ResultPath }
}
Write-Ok 'Activation finished. Existing fault flags were preserved; assessment submissions are not assessment completion.'
exit 0
