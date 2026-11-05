<#
.SYNOPSIS
    Parks retained demo workloads without deleting their data or resetting faults.
.DESCRIPTION
    Parks all compute in the explicitly targeted demo infra group, despite
    manifest/skin drift. Foreign/shared networking is warned about and untouched.
    Progress lines carry the time of day, so the seven-minute run is never silent. -WhatIf is read-only and lists what a
    real run would do: each VM with its power state, the nested guest, AKS, the Container App revisions, NAT and public IP.
    Optional -ResultPath (a folder that already exists, outside git) keeps a JSON result like Activate's: the steps with
    their times, each VM's power state before parking, the revisions deactivated, the network outcome and the closing
    Hibernated readiness rows.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = '',
    [string]$ResultPath = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
try { $skin = Get-DemoSkin -Path $SkinPath -RepoRoot (Split-Path $PSScriptRoot) }
catch {
    if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { throw 'Unreadable skin: supply the confirmed NamePrefix explicitly to park without it.' }
    Write-Warning "Skin ignored for parking: $($_.Exception.Message)"
}
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
Assert-DemoName $NamePrefix
Write-Step "Reading the inventory of rg-$NamePrefix-infra first (about a minute for eight VMs)..."
Initialize-DemoContext $SubscriptionId $TenantId
$inventory = Get-DemoInventory $NamePrefix -ForHibernation
$nestedSqlGuest = $null
try { $nestedSqlGuest = Get-DemoNestedSqlGuestConfig -Skin $skin }
catch { Write-Warning "Nested SQL configuration is unreadable: $($_.Exception.Message) Continuing compute parking without guest shutdown verification." }
try {
    $strict = Get-DemoInventory $NamePrefix -NestedSqlParentVmName $(if ($nestedSqlGuest) { $nestedSqlGuest.ParentVmName } else { '' }) `
        -KeepParkedVmNames @(Get-DemoSkinValue $skin 'operations.keepParkedVmNames' @())
    Assert-DemoSkinInventory $skin $strict
    if (@($strict.Machines | Where-Object { -not $_.Actual }).Count) { throw 'Expected VMs are missing.' }
} catch { Write-Warning "Deployment/skin drift inspection: $($_.Exception.Message) Parking all compute in $($inventory.InfraRg), not starting or deleting it." }
if ($WhatIfPreference) {
    $previewNetwork = try { Get-DemoNetworkState -InfraRg $inventory.InfraRg -NamePrefix $NamePrefix -ForHibernation }
        catch { Write-Warning "The network state could not be read for the preview: $($_.Exception.Message)" }
    foreach ($line in @(Get-DemoParkPreview -Inventory $inventory -NestedSqlGuest $nestedSqlGuest -Network $previewNetwork)) { Write-Step $line }
}
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId / $NamePrefix", 'Shut down the configured nested SQL guest, deallocate VMs, stop AKS, deactivate Container App revisions and remove demo NAT/public IP')) { return }
if ($ResultPath) {
    $ResultPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultPath)
    if (-not (Test-Path -LiteralPath (Split-Path $ResultPath) -PathType Container)) {
        throw 'ResultPath parent directory must already exist; use a private path outside git.'
    }
}
$infraRg = $inventory.InfraRg
$result = [ordered]@{
    schemaVersion = 1; workload = 'arc-demo-hibernation'
    startedAtUtc = [DateTime]::UtcNow.ToString('o'); completedAtUtc = $null
    subscriptionId = "$SubscriptionId"; tenantId = "$TenantId"; status = 'running'
    steps = [System.Collections.Generic.List[object]]::new(); nestedGuest = $null
    vms = [System.Collections.Generic.List[object]]::new(); aks = [System.Collections.Generic.List[object]]::new()
    containerApps = [System.Collections.Generic.List[object]]::new(); network = $null
    readiness = 'not-run'; readinessChecks = @(); warnings = [System.Collections.Generic.List[string]]::new(); error = $null
}
function Write-ParkStep {
    param([Parameter(Mandatory)][string]$Message)
    Write-Step ('{0:HH:mm:ss} {1}' -f (Get-Date), $Message)
    $result.steps.Add([ordered]@{ atUtc = [DateTime]::UtcNow.ToString('o'); message = $Message })
}
function Write-ParkWarning {
    param([Parameter(Mandatory)][string]$Message)
    Write-Warning $Message
    $result.warnings.Add($Message)
}
if ($ResultPath) { $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ResultPath -Encoding utf8 }
try {
    if ($nestedSqlGuest) {
        $parent = $inventory.Machines | Where-Object Name -ceq $nestedSqlGuest.ParentVmName | Select-Object -First 1
        $guestResult = [ordered]@{ guestVmName = $nestedSqlGuest.GuestVmName; parentVmName = $nestedSqlGuest.ParentVmName; status = 'skipped'; message = '' }
        $result.nestedGuest = $guestResult
        try {
            if (-not $parent -or -not $parent.Actual) { throw 'Configured nested SQL parent state is unreadable.' }
            if ($parent.Actual.powerState -eq 'VM running') {
                Write-ParkStep "Stopping the nested SQL guest $($nestedSqlGuest.GuestVmName) on $($parent.Name) (graceful, through Run Command; up to 15 minutes)."
                Invoke-DemoNestedSqlGuest -ParentMachine ([pscustomobject]@{ Name = $parent.Name; Id = $parent.Id
                    OsType = $parent.Actual.storageProfile.osDisk.osType }) -GuestVmName $nestedSqlGuest.GuestVmName -Action Stop
                $guestResult.status = 'stopped'
            } else { $guestResult.message = "The parent is $($parent.Actual.powerState), so no stop command was sent." }
        } catch {
            $guestResult.status = 'failed'
            $guestResult.message = $_.Exception.Message
            Write-ParkWarning "Nested SQL graceful shutdown failed: $($_.Exception.Message) Continuing compute parking; guest data consistency is unverified."
        }
    }
    $toPark = @($inventory.Machines | Where-Object { $_.Actual.powerState -notin @('VM deallocated', 'VM deallocating') })
    Write-ParkStep "Submitting the deallocation of $($toPark.Count) of $(@($inventory.Machines).Count) VM(s) without waiting for it$(if ($toPark.Count) { ': ' + (($toPark | ForEach-Object { $_.Name }) -join ', ') })."
    foreach ($machine in $inventory.Machines) {
        $vmResult = [ordered]@{ name = $machine.Name; powerStateBefore = $(if ($machine.Actual.powerState) { [string]$machine.Actual.powerState } else { 'unknown' }); action = 'already-parked' }
        $result.vms.Add($vmResult)
        try {
            if ($machine.Actual.powerState -notin @('VM deallocated', 'VM deallocating')) {
                $vmResult.action = 'deallocate-failed'
                Invoke-DemoAz -Arguments @('vm', 'deallocate', '--ids', $machine.Id, '--no-wait', '-o', 'none') | Out-Null
                $vmResult.action = 'deallocate-submitted'
            }
        } catch { Write-ParkWarning "VM parking failed: $($_.Exception.Message) Continuing other workloads; final power verification is mandatory." }
    }
    foreach ($id in $inventory.AksClusterIds) {
        $name = ($id -split '/')[-1]
        $aksResult = [ordered]@{ name = $name; action = 'none' }
        $result.aks.Add($aksResult)
        try {
            $cluster = Invoke-DemoAz -Arguments @('aks', 'show', '-g', $infraRg, '-n', $name, '-o', 'json') | ConvertFrom-Json
            if ($cluster.provisioningState -eq 'Stopping') { $aksResult.action = 'already-stopping'; continue }
            if ($cluster.provisioningState -ne 'Succeeded') { throw "AKS $($cluster.name) is $($cluster.provisioningState); cannot stop during another operation." }
            if ($cluster.powerState.code -ne 'Stopped') {
                Write-ParkStep "Stopping AKS $name (submitted without waiting)."
                $aksResult.action = 'stop-failed'
                Invoke-DemoAz -Arguments @('aks', 'stop', '-g', $infraRg, '-n', $name, '--no-wait', '-o', 'none') | Out-Null
                $aksResult.action = 'stop-submitted'
            } else { $aksResult.action = 'already-stopped' }
        } catch { Write-ParkWarning "AKS parking failed: $($_.Exception.Message) Continuing other workloads; final power verification is mandatory." }
    }
    foreach ($id in $inventory.ContainerAppIds) {
        $name = ($id -split '/')[-1]
        $appResult = [ordered]@{ name = $name; deactivatedRevisions = [System.Collections.Generic.List[string]]::new() }
        $result.containerApps.Add($appResult)
        try { $revisions = @(Invoke-DemoAz -Arguments @('containerapp', 'revision', 'list', '-g', $infraRg, '-n', $name, '-o', 'json') | ConvertFrom-Json) }
        catch { Write-ParkWarning "App inspection failed: $($_.Exception.Message)"; continue }
        foreach ($revision in $revisions | Where-Object { $_.properties.active }) {
            try {
                Write-ParkStep "Deactivating revision $($revision.name) of Container App $name."
                Invoke-DemoAz -Arguments @('containerapp', 'revision', 'deactivate', '-g', $infraRg, '--revision', $revision.name, '-o', 'none') | Out-Null
                $appResult.deactivatedRevisions.Add($revision.name)
            } catch { Write-ParkWarning "Revision parking failed: $($_.Exception.Message) Continuing other revisions; final verification is mandatory." }
        }
    }
    Write-ParkStep 'Waiting for every VM to read deallocated and AKS to read stopped (up to 20 minutes).'
    Wait-Until -Message 'all expected VMs deallocated and AKS stopped' -TimeoutSeconds 1200 -Condition {
        $current = Get-DemoInventory $NamePrefix -ForHibernation
        $checks = @(Get-DemoReadinessChecks -Inventory $current -NamePrefix $NamePrefix -DesiredState Hibernated | Where-Object required)
        if (@($checks | Where-Object status -eq 'fail').Count) { throw 'Compute state is unknown or unhealthy; inspect required cost-state checks.' }
        @($checks | Where-Object status -ne 'pass').Count -eq 0
    } | Out-Null
    $networkResult = [ordered]@{ status = 'not-run'; removed = [System.Collections.Generic.List[string]]::new(); message = '' }
    $result.network = $networkResult
    try {
        $network = Get-DemoNetworkState -InfraRg $infraRg -NamePrefix $NamePrefix -ForHibernation
        if ($network.SafeToRemove) {
            $attached = $network.Subnet.natGateway.id -eq $network.NatId
            if ($attached -or $network.Nat -or $network.PublicIp) {
                Write-ParkStep 'Compute has stopped: removing the NAT association, the NAT gateway and the public IP, in that order.'
            }
            if ($attached) {
                Invoke-DemoAz -Arguments @('network', 'vnet', 'subnet', 'update', '--ids', $network.Subnet.id, '--remove', 'natGateway', '-o', 'none') | Out-Null
                $networkResult.removed.Add('subnet association')
            }
            if ($network.Nat) { Invoke-DemoAz -Arguments @('network', 'nat', 'gateway', 'delete', '--ids', $network.NatId) | Out-Null; $networkResult.removed.Add('NAT gateway') }
            if ($network.PublicIp) { Invoke-DemoAz -Arguments @('network', 'public-ip', 'delete', '--ids', $network.PublicIpId) | Out-Null; $networkResult.removed.Add('public IP') }
            $networkResult.status = if ($networkResult.removed.Count) { 'removed' } else { 'already-absent' }
        } else {
            $networkResult.status = 'skipped'
            $networkResult.message = [string]$network.ConflictMessage
            Write-ParkWarning "NETWORK CLEANUP SKIPPED: $($network.ConflictMessage) NAT/PIP costs may remain; no foreign binding changed."
        }
    } catch {
        $networkResult.status = 'incomplete'
        $networkResult.message = $_.Exception.Message
        Write-ParkWarning "NETWORK CLEANUP INCOMPLETE: $($_.Exception.Message) Retained networking may still bill; retry cleanup separately."
    }
    Write-ParkStep 'Verifying the Hibernated state (every required cost-state check must pass; up to 5 minutes).'
    $readyText = & (Join-Path $PSScriptRoot 'Test-ArcDemoReadiness.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId -NamePrefix $NamePrefix -SkinPath $SkinPath -DesiredState Hibernated -TimeoutSeconds 300 -OutputFormat Json
    $readyExit = $LASTEXITCODE
    $ready = try { ($readyText | Out-String) | ConvertFrom-Json } catch { $null }
    if ($ready -and $null -ne $ready.status) {
        $result.readiness = [string]$ready.status
        $result.readinessChecks = @($ready.checks)
        Write-Step "Hibernated status: $($ready.status) (required checks determine lifecycle state; non-required checks are diagnostics/exceptions)"
        $ready.checks | Format-Table id, required, status, expected, observed, message -AutoSize | Out-Host
    } else { $readyText | Out-Host }
    if ($readyExit -ne 0) { throw 'Hibernated cost-state verification failed or inspection was denied; inspect required checks/errors above. Completed parking steps are preserved; retry remaining work without redeploying.' }
    $result.status = 'pass'
} catch {
    $result.status = 'fail'
    $result.error = $_.Exception.Message
    throw
} finally {
    $result.completedAtUtc = [DateTime]::UtcNow.ToString('o')
    if ($ResultPath) { Write-DemoResultFile -Result $result -Path $ResultPath }
}
Write-Ok 'Compute parked. Review network cleanup diagnostics: skipped/failed NAT/PIP removal may still bill, as do retained disks, logs and enabled alerts. No fault flags or credentials changed.'
