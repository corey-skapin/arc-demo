<#
.SYNOPSIS
    Restores outbound networking, starts retained workloads and validates the demo.
.DESCRIPTION
    Uses retained deployment manifests and actual VM OS metadata, not name prefixes.
    Does not reset workload faults or credentials. Every run verifies guest health
    without restarting already-connected/running hosts. Windows AMA is checked by
    its MonAgentCore process, not an assumed Windows service. Patch assessments
    are submitted for newly started Arc hosts unless skipped. -AssessPatches
    explicitly assesses all Arc hosts, including already-active retries.
    Submission is not completion.
    -WhatIf is read-only. Optional ResultPath preserves per-host outcomes.
#>
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
Initialize-DemoContext $SubscriptionId $TenantId
$inventory = Get-DemoInventory $NamePrefix -NestedSqlParentVmName $(if ($nestedSqlGuest) { $nestedSqlGuest.ParentVmName } else { '' })
Assert-DemoSkinInventory $skin $inventory
$missing = @($inventory.Machines | Where-Object { -not $_.Actual })
if ($missing) { throw "Missing expected VMs: $($missing.Name -join ', '). Reconcile deployment before activation." }
$network = Get-DemoNetworkState -InfraRg $inventory.InfraRg -NamePrefix $NamePrefix
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId / $NamePrefix", 'Restore NAT, start retained workloads, verify guests and assess newly started Arc hosts (AssessPatches explicitly includes already-active hosts; no fault reset)')) { return }

$result = [ordered]@{
    schemaVersion = 1; workload = 'arc-demo-activation'
    startedAtUtc = [DateTime]::UtcNow.ToString('o'); completedAtUtc = $null
    subscriptionId = "$SubscriptionId"; tenantId = "$TenantId"; status = 'running'
    guestChecks = @(); patchAssessments = @()
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
    foreach ($machine in $inventory.Machines) {
        if ($machine.Actual.powerState -ne 'VM running') {
            if ($machine.Actual.powerState -ne 'VM starting') {
                Invoke-DemoAz -Arguments @('vm', 'start', '--ids', $machine.Id, '--no-wait', '-o', 'none') | Out-Null
            }
            $startedVmIds += $machine.Id
        }
    }
    Wait-Until -Message 'expected VM identities running' -Condition {
        $vms = @(Invoke-DemoAz -Arguments @('vm', 'list', '-g', $infraRg, '--show-details', '-o', 'json') | ConvertFrom-Json)
        @($inventory.Machines | Where-Object { $_.Id -notin @($vms | Where-Object powerState -eq 'VM running' | ForEach-Object id) }).Count -eq 0
    } | Out-Null

    if ($nestedSqlGuest) {
        $parent = $inventory.Machines | Where-Object Name -ceq $nestedSqlGuest.ParentVmName | Select-Object -First 1
        if (-not $parent) { throw 'Configured nested SQL parent was not found in the retained inventory.' }
        Invoke-DemoNestedSqlGuest -ParentMachine $parent -GuestVmName $nestedSqlGuest.GuestVmName -Action Start
        Wait-DemoNestedSqlArcConnected -ArcResourceGroup $inventory.ArcRg -ArcMachineName $nestedSqlGuest.ArcMachineName
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
    $arcBeforeRestart = @(Invoke-DemoAz -Arguments @('connectedmachine', 'list', '-g', $inventory.ArcRg, '-o', 'json') | ConvertFrom-Json)
    foreach ($machine in $inventory.Machines) {
        $wasConnected = $machine.ArcId -in @($arcBeforeRestart | Where-Object status -eq 'Connected' | ForEach-Object id)
        $restart = $machine.Id -in $startedVmIds -or (-not $machine.Native -and -not $wasConnected)
        $services = @()
        if (-not $machine.Native) { $services += if ($machine.OsType -eq 'Windows') { 'himds' } else { 'himdsd' } }
        if ($machine.Monitor -and $machine.OsType -eq 'Linux') { $services += 'azuremonitoragent' }
        if (-not $services -and -not $machine.Monitor) { continue }
        $script = if ($machine.OsType -eq 'Windows') {
            $commands = @("`$ErrorActionPreference='Stop'")
            if ($services) {
                if ($restart) { $commands += "Restart-Service $($services -join ',') -Force" }
                $commands += ('if (@(Get-Service -Name {0} | Where-Object {{ $_.Status -ne ''Running'' }}).Count) {{ throw ''Required Arc service is not running.'' }}' -f ($services -join ','))
            }
            if ($machine.Monitor) {
                $commands += @'
$deadline = (Get-Date).AddMinutes(10)
while (-not @(Get-Process -ErrorAction Stop | Where-Object ProcessName -eq 'MonAgentCore').Count) {
    if ((Get-Date) -ge $deadline) { Write-Warning 'AMA startup remains pending after 10 minutes; re-check exact-ID Heartbeat.'; 'ARC_DEMO_PENDING'; return }
    Write-Progress -Activity 'Waiting for AMA MonAgentCore' -Status 'Cold start; no repair or restart'
    Start-Sleep -Seconds 15
}
'@
            }
            $commands += "'ARC_DEMO_OK'"
            $commands -join "`n"
        } else {
            $restartCommand = if ($restart) { "sudo systemctl restart $($services -join ' ')" } else { '' }
            "set -e`n$restartCommand`nfor service in $($services -join ' '); do sudo systemctl is-active --quiet `"`$service`"; done`necho ARC_DEMO_OK"
        }
        $guest = [ordered]@{
            machineName = $machine.Name; resourceId = $machine.Id; status = 'pending'
            restartedServices = @(if ($restart) { $services })
            monitorCheck = if (-not $machine.Monitor) { 'not-required' } elseif ($machine.OsType -eq 'Windows') { 'MonAgentCore process' } else { 'azuremonitoragent service' }
            completion = $null
        }
        $result.guestChecks += $guest
        try { $jobs += @{ Job = Invoke-DemoGuestCommand -Machine $machine -Script $script -AsJob; Machine = $machine; Evidence = $guest } }
        catch { $guest.status = 'fail'; throw }
    }
    foreach ($item in $jobs) {
        $guest = $item.Evidence
        try {
            $guest.completion = Invoke-DemoGuestCommand -Machine $item.Machine -Job $item.Job -PassThru -AllowPending:($item.Machine.Monitor -and $item.Machine.OsType -eq 'Windows')
            $guest.status = $guest.completion.status
            if ($guest.status -eq 'pending') { Write-Warning "$($item.Machine.Name): AMA startup pending; poll readiness before presenting or offering an incident." }
            else { Write-Ok "Guest activation verified: $($item.Machine.Name)" }
        } catch { $guest.status = 'fail'; $guest['error'] = $_.Exception.Message; Write-Warning $_.Exception.Message }
    }
    if (@($result.guestChecks | Where-Object status -eq 'fail').Count) { throw (($result.guestChecks | Where-Object status -eq 'fail' | ForEach-Object error) -join '; ') }
    Wait-Until -Message 'expected Arc identities connected' -Condition {
        $arc = @(Invoke-DemoAz -Arguments @('connectedmachine', 'list', '-g', $inventory.ArcRg, '-o', 'json') | ConvertFrom-Json)
        @($inventory.Machines | Where-Object { -not $_.Native -and $_.ArcId -notin @($arc | Where-Object status -eq 'Connected' | ForEach-Object id) }).Count -eq 0
    } | Out-Null
    if (-not $SkipPatchAssessment) {
        foreach ($machine in $inventory.Machines | Where-Object { -not $_.Native -and ($AssessPatches -or $_.Id -in $startedVmIds) }) {
            $assessment = [ordered]@{ machineName = $machine.Name; resourceId = $machine.ArcId; status = 'pending' }
            $result.patchAssessments += $assessment
            Invoke-DemoAz -Arguments @('connectedmachine', 'assess-patches', '--ids', $machine.ArcId, '--no-wait', '-o', 'none') | Out-Null
            $assessment.status = 'submitted'
            Write-Ok "Patch assessment submitted: $($machine.Name)"
        }
        $result.patchAssessment = if ($result.patchAssessments.Count) { 'submitted' } else { 'not-required' }
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
    $result.status = if ($result.readiness -eq 'pending') { 'pending' } else { 'pass' }
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
    if ($ResultPath) { $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ResultPath -Encoding utf8 }
}
Write-Ok 'Activation finished. Existing fault flags were preserved; assessment submissions are not assessment completion.'
exit 0
