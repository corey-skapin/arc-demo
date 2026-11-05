#Requires -Version 7.4
<#
.SYNOPSIS
    Prepares the nested SQL Hyper-V parent so New-NestedSqlDemo.ps1 can build the guest.
.DESCRIPTION
    Turns the by-hand parent preparation into one idempotent run for the parent named by
    nestedSqlGuest in the skin (win-sql-02 by default). Phases run in this order:

      Preflight  read-only: context, exact inventory, VM facts, lab Active (explicit outbound)
      Size       resize to the declared nested-capable size (skipped when Deploy declared it)
      Disk       create and attach the declared data disk (skipped when Deploy declared it)
      Volume     initialise the data disk as D: (NTFS, label NestedSQL) with VMs and Media folders
      HyperV     install the Hyper-V role; the restart is issued from Azure, never from the guest
      Network    internal switch, host address and NAT for the nested guest
      Media      stage the pinned Windows Server and SQL Server ISOs (Stage-DemoMedia.ps1)
      Verify     read-only pass/fail and the build input New-NestedSqlDemo.ps1 needs

    Every phase is idempotent: a prepared parent is verified with no mutation and no restart.
    Mutating steps go through ShouldProcess and only an Active lab (NAT attached) is changed,
    because starting compute needs explicit outbound networking. -WhatIf performs Azure reads
    only and runs nothing in the guest. Both media terms switches are required for the Media
    phase and are recorded privately; this script never implies acceptance. Do not run it
    while Activate, Hibernate, Deploy or a nested build is using the parent's Run Command.
.EXAMPLE
    .\scripts\Prepare-NestedSqlParent.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath <PRIVATE_SKIN> `
        -AcceptWindowsEvaluationTerms -AcceptSqlDeveloperTerms -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = '',
    [ValidateSet('All', 'Preflight', 'Size', 'Disk', 'Volume', 'HyperV', 'Network', 'Media', 'Verify')][string[]]$Phase = @('All'),
    [switch]$AcceptWindowsEvaluationTerms,
    [switch]$AcceptSqlDeveloperTerms,
    [switch]$AllowUntestedSize,
    [string]$MediaManifestPath = '',
    [string]$AcceptanceRecordPath = '',
    [string]$BuildInputPath = '',
    [string]$OnboardingApplicationId = '',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9 _-]{0,62}$')][string]$SwitchName = 'NestedSqlSwitch',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9 _-]{0,62}$')][string]$NatName = 'NestedSqlNat',
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}/24$')][string]$GuestNetworkPrefix = '172.31.240.0/24',
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')][string]$GatewayAddress = '172.31.240.1',
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')][string]$GuestAddress = '172.31.240.20',
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')][string]$DnsServer = '168.63.129.16',
    [ValidateRange(60, 3600)][int]$TimeoutSeconds = 900,
    [string]$ResultPath = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$repoRoot = Split-Path $PSScriptRoot
$guestScript = Join-Path $PSScriptRoot 'guest\Initialize-NestedSqlParentHost.ps1'
# Only this size is evidenced for nested virtualization here (B-series cannot run Hyper-V guests).
$testedSizes = @('Standard_D4s_v5')
$allPhases = @('Preflight', 'Size', 'Disk', 'Volume', 'HyperV', 'Network', 'Media', 'Verify')
$requested = @($allPhases | Where-Object { $_ -eq 'Preflight' -or 'All' -in $Phase -or $_ -in $Phase })
$mutating = @($requested | Where-Object { $_ -notin @('Preflight', 'Verify') })
$dataRoot = 'D:\NestedSQL'
$mediaRoot = "$dataRoot\Media"

$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
Assert-DemoName $NamePrefix
$nested = Get-DemoNestedSqlGuestConfig -Skin $skin
if (-not $nested) { throw 'Enable nestedSqlGuest in the skin first: Prepare needs the configured parent VM name (see docs/nested-sql-demo.md).' }
if ($nested.ParentVmSize -notin $testedSizes -and -not $AllowUntestedSize) {
    throw "Only $($testedSizes -join ', ') is evidenced for nested virtualization here; $($nested.ParentVmSize) needs -AllowUntestedSize and a size without a temp disk (the data volume must be D:)."
}
if ($ResultPath -and -not (Test-Path -LiteralPath (Split-Path ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultPath))) -PathType Container)) {
    throw 'ResultPath parent must already exist; use a private evidence directory.'
}
$manifest = @(Get-DemoMediaManifest -Path $MediaManifestPath -RepoRoot $repoRoot)
$windowsIso = $manifest | Where-Object Id -eq 'windows-server-2022-eval'
$sqlIso = $manifest | Where-Object Id -eq 'sql-server-2022-developer'
if (-not $windowsIso -or -not $sqlIso) { throw 'The media manifest must pin windows-server-2022-eval and sql-server-2022-developer.' }
if ('Media' -in $requested -and -not $WhatIfPreference -and -not ($AcceptWindowsEvaluationTerms -and $AcceptSqlDeveloperTerms)) {
    throw "Media staging needs explicit acceptance of both licences: -AcceptWindowsEvaluationTerms ($($windowsIso.LicenseUrl)) and -AcceptSqlDeveloperTerms ($($sqlIso.LicenseUrl)). Acceptance is recorded, never implied."
}

Initialize-DemoContext $SubscriptionId $TenantId
$parentName = $nested.ParentVmName
$infraRg = "rg-$NamePrefix-infra"
$arcRg = "rg-$NamePrefix"
$target = (Get-DemoGuestTarget -NamePrefix $NamePrefix -Skin $skin -MachineName $parentName).Target
$isFleetMember = -not $target.Native
$diskName = "$parentName-nested-data"
$phaseResults = [System.Collections.Generic.List[object]]::new()
$state = @{ Inspect = $null }

function New-PhaseResult {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    [pscustomobject]@{ phase = $Name; status = $Status; detail = $Detail }
}

function Confirm-Step {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([string]$Action)
    if ($PSCmdlet.ShouldProcess($target.Id, $Action)) { return $true }
    if ($WhatIfPreference) { return $false }
    throw "Declined: $Action. Stopping here; partial progress is kept and a rerun resumes."
}

function Get-ParentVm {
    Invoke-DemoAz -Arguments @('vm', 'show', '-g', $infraRg, '-n', $parentName, '--show-details', '-o', 'json') | ConvertFrom-Json
}

function Wait-ParentReady {
    Wait-Until -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 15 -Message "$parentName running" -Condition {
        $current = Get-ParentVm
        if ($current.provisioningState -ne 'Succeeded' -or $current.powerState -ne 'VM running') { return $false }
        if (-not $isFleetMember) { return $true }
        $arc = Invoke-DemoAz -Arguments @('connectedmachine', 'show', '-g', $arcRg, '-n', $parentName, '-o', 'json') | ConvertFrom-Json
        $arc.status -eq 'Connected' -and $arc.provisioningState -eq 'Succeeded'
    } | Out-Null
}

function Start-ParentIfNeeded {
    $current = Get-ParentVm
    if ($current.powerState -eq 'VM running') { return }
    if ($current.powerState -notin @('VM deallocated', 'VM stopped')) { throw "The parent is $($current.powerState); wait for the transition instead of resubmitting." }
    if (-not (Confirm-Step 'Start the parent VM (the lab is Active, so explicit outbound networking exists)')) { return }
    Invoke-DemoAz -Arguments @('vm', 'start', '-g', $infraRg, '-n', $parentName, '--only-show-errors') | Out-Null
    Wait-ParentReady
}

function Invoke-HostAction {
    param([ValidateSet('Inspect', 'Volume', 'HyperV', 'Network')][string]$Action, [hashtable]$Extra = @{})
    $settings = @{
        driveLetter = 'D'; label = 'NestedSQL'; root = $dataRoot; lun = 0; sizeBytes = [int64]$nested.ParentDataDiskGb * 1GB
        switchName = $SwitchName; natName = $NatName; prefix = $GuestNetworkPrefix; gateway = $GatewayAddress
        azurePrefixes = @(); hashMedia = $false
        media = @(@($windowsIso, $sqlIso) | ForEach-Object { @{ id = $_.Id; fileName = $_.FileName; bytes = $_.Bytes; sha256 = $_.Sha256 } })
    }
    foreach ($key in $Extra.Keys) { $settings[$key] = $Extra[$key] }
    Invoke-DemoGuestAction -Machine $target -ScriptPath $guestScript -Action $Action -Settings $settings -TimeoutSeconds $TimeoutSeconds
}

function Get-GuestState {
    if (-not $state.Inspect) { $state.Inspect = Invoke-HostAction -Action Inspect }
    $state.Inspect
}

function Wait-GuestSettled {
    # After the Azure restart the parent can restart a second time on its own (servicing finishing after the role install)
    # while Arc already reads Connected, so the first Inspect lands in early boot or in that shutdown ("Cannot connect to
    # CIM server. A system shutdown is in progress."). Inspect again, tolerating a guest that is not answering, until two
    # inspections a minute apart both find Hyper-V ready. About 10 minutes at most; the caller judges the final state.
    $ready = 0
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $state.Inspect = $null
        try { $ready = if (Test-HyperVReady (Get-GuestState)) { $ready + 1 } else { 0 } }
        catch {
            $ready = 0
            Write-Step "The parent is not answering yet ($($_.Exception.Message)); checking again in 30 seconds."
        }
        if ($ready -ge 2) { return }
        Start-Sleep -Seconds $(if ($ready) { 60 } else { 30 })
    }
}

function Test-VolumeReady { param($Guest) $Guest.volume.present -and $Guest.volume.label -eq 'NestedSQL' -and $Guest.volume.fileSystem -eq 'NTFS' -and $Guest.volume.vmsFolder -and $Guest.volume.mediaFolder }
function Test-HyperVReady { param($Guest) $Guest.hyperV.installed -and $Guest.hyperV.vmms -eq 'Running' -and $Guest.hyperV.hypervisorPresent -and $Guest.hyperV.vmHostOk }
function Test-NetworkReady {
    param($Guest)
    $net = $Guest.network
    $length = [int]$GuestNetworkPrefix.Split('/')[1]
    $net.switchExists -and $net.switchType -eq 'Internal' -and "$GatewayAddress/$length" -in @($net.addresses) -and
        @($net.nats | Where-Object { $_.name -eq $NatName -and $_.prefix -eq $GuestNetworkPrefix }).Count -eq 1
}

function Invoke-SizePhase {
    $current = Get-ParentVm
    $size = $current.hardwareProfile.vmSize
    if ($size -eq $nested.ParentVmSize) { return New-PhaseResult 'Size' 'satisfied' "already $size" }
    if ($current.provisioningState -ne 'Succeeded') { throw 'Parent provisioning is not Succeeded; wait or inspect before changing its size.' }
    Test-DemoComputeCapacity -Location $current.location -VmSize $nested.ParentVmSize -AdditionalVmCount 1
    $wasRunning = $current.powerState -eq 'VM running'
    if ($wasRunning -and -not $WhatIfPreference -and (Get-GuestState).hyperV.runningGuests -gt 0) {
        throw 'A nested guest is running; stop it gracefully before the parent is resized.'
    }
    $action = "Deallocate $parentName, resize $size to $($nested.ParentVmSize) and restore its power state (Windows retail about AUD 0.60/h against 0.15/h while running; see docs/cost.md)"
    if (-not (Confirm-Step $action)) { return New-PhaseResult 'Size' 'skipped' 'preview' }
    if ($wasRunning) {
        Invoke-DemoAz -Arguments @('vm', 'deallocate', '-g', $infraRg, '-n', $parentName, '--only-show-errors') | Out-Null
        Wait-Until -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 10 -Message "$parentName deallocated" -Condition { (Get-ParentVm).powerState -eq 'VM deallocated' } | Out-Null
    }
    try {
        Invoke-DemoAz -Arguments @('vm', 'resize', '-g', $infraRg, '-n', $parentName, '--size', $nested.ParentVmSize, '--only-show-errors') | Out-Null
    } catch {
        throw "Resize to $($nested.ParentVmSize) failed: $($_.Exception.Message) The parent stays deallocated at $size; retry later or restore it with the approved lifecycle. No other size or region is tried for you."
    }
    $after = Get-ParentVm
    if ($after.hardwareProfile.vmSize -ne $nested.ParentVmSize -or $after.provisioningState -ne 'Succeeded') { throw "The parent is $($after.hardwareProfile.vmSize)/$($after.provisioningState) after the resize; inspect it before continuing." }
    if ($wasRunning) {
        Invoke-DemoAz -Arguments @('vm', 'start', '-g', $infraRg, '-n', $parentName, '--only-show-errors') | Out-Null
        Wait-ParentReady
    }
    $state.Inspect = $null
    New-PhaseResult 'Size' 'changed' "$size -> $($nested.ParentVmSize)"
}

function Test-DiskMatchesDeclaration {
    param($Disk)
    [int]$Disk.lun -eq 0 -and [string]$Disk.caching -eq 'None' -and [int64]$Disk.diskSizeGb -eq $nested.ParentDataDiskGb -and
        [string]$Disk.managedDisk.storageAccountType -eq $nested.ParentDataDiskStorageAccountType
}

function Invoke-DiskPhase {
    $current = Get-ParentVm
    $attached = @($current.storageProfile.dataDisks | Where-Object { $_ })
    $own = @($attached | Where-Object { $_.name -eq $diskName })
    if ($own.Count -eq 1) {
        if (-not (Test-DiskMatchesDeclaration $own[0])) { throw "Data disk $diskName differs from its declaration (lun $($own[0].lun), $($own[0].diskSizeGb) GiB, $($own[0].managedDisk.storageAccountType)); Prepare never resizes, converts or moves a retained disk." }
        return New-PhaseResult 'Disk' 'satisfied' "$diskName attached at LUN 0"
    }
    $atLun = @($attached | Where-Object { [int]$_.lun -eq 0 })
    if ($atLun.Count) { throw "LUN 0 already holds $($atLun[0].name); Prepare will not change it." }
    $existing = Invoke-DemoAz -Arguments @('disk', 'show', '-g', $infraRg, '-n', $diskName, '-o', 'json') -AllowNotFound
    $disk = if ($null -ne $existing) { $existing | ConvertFrom-Json }
    if ($disk -and ($disk.managedBy -or [int64]$disk.diskSizeGb -ne $nested.ParentDataDiskGb -or $disk.sku.name -ne $nested.ParentDataDiskStorageAccountType)) {
        throw "Disk $diskName already exists but is attached elsewhere or differs from its declaration; Prepare will not reuse or change it."
    }
    $action = "Create the $($nested.ParentDataDiskGb) GiB $($nested.ParentDataDiskStorageAccountType) data disk $diskName and attach it at LUN 0 (StandardSSD 128 GiB retail about AUD 18.60/month)"
    if (-not (Confirm-Step $action)) { return New-PhaseResult 'Disk' 'skipped' 'preview' }
    if (-not $disk) {
        $tags = @($current.tags.PSObject.Properties | Where-Object { $_.Value -match '^[A-Za-z0-9._-]+$' } | ForEach-Object { "$($_.Name)=$($_.Value)" })
        $create = @('disk', 'create', '-g', $infraRg, '-n', $diskName, '--location', $current.location, '--size-gb', "$($nested.ParentDataDiskGb)",
            '--sku', $nested.ParentDataDiskStorageAccountType, '-o', 'json', '--only-show-errors')
        if ($tags.Count) { $create += @('--tags') + $tags }
        Invoke-DemoAz -Arguments $create | Out-Null
    }
    Invoke-DemoAz -Arguments @('vm', 'disk', 'attach', '-g', $infraRg, '--vm-name', $parentName, '--name', $diskName, '--lun', '0', '--caching', 'None', '--only-show-errors') | Out-Null
    $after = Get-ParentVm
    $attachedNow = @($after.storageProfile.dataDisks | Where-Object { $_.name -eq $diskName })
    if ($attachedNow.Count -ne 1 -or -not (Test-DiskMatchesDeclaration $attachedNow[0])) { throw "Data disk $diskName is not attached as declared after the attach; inspect the VM before continuing." }
    $state.Inspect = $null
    New-PhaseResult 'Disk' 'changed' "$diskName attached at LUN 0"
}

function Invoke-VolumePhase {
    if ($WhatIfPreference) {
        Confirm-Step 'Initialise the Azure data disk as D: (NTFS, label NestedSQL) when it is still blank; guest state is not read under -WhatIf' | Out-Null
        return New-PhaseResult 'Volume' 'skipped' 'preview'
    }
    Start-ParentIfNeeded
    if (Test-VolumeReady (Get-GuestState)) { return New-PhaseResult 'Volume' 'satisfied' 'D: NestedSQL with VMs and Media' }
    if (-not (Confirm-Step 'Initialise the blank Azure data disk as D: (NTFS, label NestedSQL) and create the VMs and Media folders')) { return New-PhaseResult 'Volume' 'skipped' 'preview' }
    $initialised = Invoke-HostAction -Action Volume
    $state.Inspect = $null
    if (-not (Test-VolumeReady (Get-GuestState))) { throw 'The data volume is not ready after initialisation; inspect the VM before continuing.' }
    New-PhaseResult 'Volume' 'changed' $(if ($initialised.opticalDriveMovedTo) { "D: initialised; the empty virtual DVD-ROM moved to $($initialised.opticalDriveMovedTo):" } else { 'D: initialised' })
}

function Invoke-HyperVPhase {
    if ($WhatIfPreference) {
        Confirm-Step 'Install the Hyper-V role when missing and restart the parent from Azure (about 5 minutes); guest state is not read under -WhatIf' | Out-Null
        return New-PhaseResult 'HyperV' 'skipped' 'preview'
    }
    Start-ParentIfNeeded
    $guest = Get-GuestState
    if (Test-HyperVReady $guest) { return New-PhaseResult 'HyperV' 'satisfied' 'role installed, vmms running, hypervisor present' }
    if ($guest.hyperV.runningGuests -gt 0) { throw 'A nested guest is running; stop it gracefully before the parent is restarted.' }
    $current = Get-ParentVm
    if ($current.securityProfile.securityType -notin @($null, '', 'Standard') -or ($current.hardwareProfile.vmSize -notin $testedSizes -and -not $AllowUntestedSize)) {
        throw 'Hyper-V needs a nested-virtualization size and security type Standard (Trusted Launch blocks it); fix the parent shape first.'
    }
    $detail = 'role already installed; restarted to start the hypervisor'
    if (-not $guest.hyperV.installed) {
        if (-not (Confirm-Step 'Install the Hyper-V role with management tools (a restart follows)')) { return New-PhaseResult 'HyperV' 'skipped' 'preview' }
        Invoke-HostAction -Action HyperV | Out-Null
        $detail = 'role installed; restarted from Azure'
    }
    if (-not (Confirm-Step 'Restart the parent from Azure so the hypervisor starts (about 5 minutes; Arc reconnects by itself)')) { return New-PhaseResult 'HyperV' 'skipped' 'preview' }
    Invoke-DemoAz -Arguments @('vm', 'restart', '-g', $infraRg, '-n', $parentName, '--only-show-errors') | Out-Null
    Wait-ParentReady
    $state.Inspect = $null
    Wait-GuestSettled
    if (-not (Test-HyperVReady (Get-GuestState))) { throw 'Hyper-V is not running after the restart. Check that the size supports nested virtualization and that security type is Standard.' }
    New-PhaseResult 'HyperV' 'changed' $detail
}

function Invoke-NetworkPhase {
    if ($WhatIfPreference) {
        Confirm-Step "Create the internal switch $SwitchName, host address $GatewayAddress and NAT $NatName for $GuestNetworkPrefix when missing; guest state is not read under -WhatIf" | Out-Null
        return New-PhaseResult 'Network' 'skipped' 'preview'
    }
    Start-ParentIfNeeded
    if (Test-NetworkReady (Get-GuestState)) { return New-PhaseResult 'Network' 'satisfied' "$SwitchName, $GatewayAddress and $NatName in place" }
    if (-not (Confirm-Step "Create the internal switch $SwitchName, host address $GatewayAddress and NAT $NatName for $GuestNetworkPrefix")) { return New-PhaseResult 'Network' 'skipped' 'preview' }
    $prefixes = @(Invoke-DemoAz -Arguments @('network', 'vnet', 'show', '-g', $infraRg, '-n', "vnet-$NamePrefix", '--query', 'addressSpace.addressPrefixes', '-o', 'json') | ConvertFrom-Json)
    Invoke-HostAction -Action Network -Extra @{ azurePrefixes = $prefixes } | Out-Null
    $state.Inspect = $null
    if (-not (Test-NetworkReady (Get-GuestState))) { throw 'The nested network is not ready after creation; inspect the parent before continuing.' }
    New-PhaseResult 'Network' 'changed' "$SwitchName, $GatewayAddress, $NatName"
}

function Invoke-MediaPhase {
    $arguments = @{
        SubscriptionId = $SubscriptionId; TenantId = $TenantId; MachineName = $parentName; NamePrefix = $NamePrefix
        Media = @($windowsIso.Id, $sqlIso.Id); Destination = $mediaRoot; SkinPath = $SkinPath
        ManifestPath = $MediaManifestPath; AcceptanceRecordPath = $AcceptanceRecordPath
    }
    if ($AcceptWindowsEvaluationTerms) { $arguments.AcceptWindowsEvaluationTerms = $true }
    if ($AcceptSqlDeveloperTerms) { $arguments.AcceptSqlDeveloperTerms = $true }
    if ($WhatIfPreference) {
        & (Join-Path $PSScriptRoot 'Stage-DemoMedia.ps1') @arguments -WhatIf
        Initialize-DemoContext $SubscriptionId $TenantId
        return New-PhaseResult 'Media' 'skipped' 'preview'
    }
    Start-ParentIfNeeded
    $guest = Get-GuestState
    $ready = @($guest.media | Where-Object { $_.present }).Count -eq 2
    $staged = & (Join-Path $PSScriptRoot 'Stage-DemoMedia.ps1') @arguments -Confirm:$false
    Initialize-DemoContext $SubscriptionId $TenantId
    $state.Inspect = $null
    $states = @($staged.items | ForEach-Object { $_.state })
    New-PhaseResult 'Media' $(if ($ready -and @($states | Where-Object { $_ -ne 'present' }).Count -eq 0) { 'satisfied' } else { 'changed' }) ($states -join ', ')
}

function Resolve-OnboardingApplicationId {
    if ($OnboardingApplicationId) { return $OnboardingApplicationId }
    try {
        $name = "sp-$NamePrefix-onboard"
        $ids = @(Invoke-DemoAz -Arguments @('ad', 'sp', 'list', '--display-name', $name, '--query', "[?displayName=='$name'].appId", '-o', 'json') | ConvertFrom-Json)
        if ($ids.Count -eq 1) { return [string]$ids[0] }
    } catch { Write-Verbose "Onboarding application not resolved: $($_.Exception.Message)" }
    return ''
}

function Invoke-VerifyPhase {
    $checks = [System.Collections.Generic.List[object]]::new()
    $id = $target.Id
    function Add-Check {
        param([string]$Name, $Expected, $Observed, [bool]$Pass, [string]$Message = '')
        $checks.Add((New-DemoCheck $Name $id $Expected $Observed $(if ($Pass) { 'pass' } else { 'fail' }) -Message $Message))
    }
    $current = Get-ParentVm
    Add-Check 'size' $nested.ParentVmSize $current.hardwareProfile.vmSize ($current.hardwareProfile.vmSize -eq $nested.ParentVmSize)
    $securityType = [string]$current.securityProfile.securityType
    Add-Check 'security-type' 'Standard or unset' $securityType ($securityType -in @('', 'Standard'))
    $own = @($current.storageProfile.dataDisks | Where-Object { $_.name -eq $diskName })
    Add-Check 'data-disk' "$diskName LUN 0, $($nested.ParentDataDiskGb) GiB, caching None" $(if ($own.Count) { "LUN $($own[0].lun), $($own[0].diskSizeGb) GiB, $($own[0].caching)" } else { 'absent' }) ($own.Count -eq 1 -and (Test-DiskMatchesDeclaration $own[0]))
    Add-Check 'power' 'VM running' $current.powerState ($current.powerState -eq 'VM running') 'Verify never starts a VM; run the approved Activate or the Volume phase first.'
    if ($isFleetMember -and $current.powerState -eq 'VM running') {
        $arc = Invoke-DemoAz -Arguments @('connectedmachine', 'show', '-g', $arcRg, '-n', $parentName, '-o', 'json') | ConvertFrom-Json
        Add-Check 'arc' 'Connected' $arc.status ($arc.status -eq 'Connected')
    }
    $guestChecked = $false
    if ($current.powerState -eq 'VM running' -and -not $WhatIfPreference) {
        $guest = Invoke-HostAction -Action Inspect -Extra @{ hashMedia = $true }
        $guestChecked = $true
        $volume = $guest.volume
        Add-Check 'volume' 'D: NTFS NestedSQL on LUN 0 with VMs and Media' $(if ($volume.present) { "$($volume.fileSystem) $($volume.label) LUN $($volume.lun)" } else { 'absent' }) ((Test-VolumeReady $guest) -and $volume.lun -eq 0)
        Add-Check 'volume-free-space' 'at least 24 GiB free' ("{0:N1} GiB" -f ($volume.freeBytes / 1GB)) ($volume.freeBytes -ge 24GB) 'The guest build needs 24 GiB free after the media.'
        Add-Check 'hyper-v' 'role installed, vmms Running, hypervisor present, Get-VMHost ok' "installed=$($guest.hyperV.installed) vmms=$($guest.hyperV.vmms) hypervisor=$($guest.hyperV.hypervisorPresent) host=$($guest.hyperV.vmHostOk)" (Test-HyperVReady $guest)
        Add-Check 'network' "$SwitchName Internal, $GatewayAddress, $NatName $GuestNetworkPrefix" "switch=$($guest.network.switchType) addresses=$(@($guest.network.addresses) -join ',') nats=$(@($guest.network.nats | ForEach-Object { $_.name }) -join ',')" (Test-NetworkReady $guest)
        foreach ($item in @($windowsIso, $sqlIso)) {
            $media = @($guest.media | Where-Object { $_.id -eq $item.Id })
            Add-Check "media/$($item.Id)" 'present with the pinned size and SHA-256' $(if ($media.Count -and $media[0].present) { "$($media[0].bytes) bytes, hash match $($media[0].sha256Matches)" } else { 'absent' }) ($media.Count -eq 1 -and $media[0].present -and $media[0].bytes -eq $item.Bytes -and $media[0].sha256Matches -eq $true)
        }
    } elseif ($WhatIfPreference) {
        $checks.Add((New-DemoCheck 'guest' $id 'guest checks' $null 'skipped' $false 'Guest checks are skipped under -WhatIf.'))
    }
    $status = if ($WhatIfPreference) { 'pending' } elseif (@($checks | Where-Object { $_.required -and $_.status -eq 'fail' }).Count) { 'fail' } elseif ($guestChecked) { 'pass' } else { 'pending' }
    [pscustomobject]@{ Status = $status; Checks = @($checks); Parent = $current }
}

function Write-BuildInput {
    param($Parent)
    $path = if ($BuildInputPath) { $BuildInputPath } else { Join-Path $repoRoot '.local\nested-sql-build.json' }
    $content = [ordered]@{}
    if (Test-Path -LiteralPath $path) {
        $existing = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 6
        if ($existing -is [System.Collections.IDictionary]) { foreach ($key in $existing.Keys) { $content[$key] = $existing[$key] } }
    }
    $content.SubscriptionId = "$SubscriptionId"
    $content.TenantId = "$TenantId"
    $content.ParentVmId = [string]$Parent.vmId
    $content.Location = [string]$Parent.location
    $content.WindowsIsoPath = "$mediaRoot\$($windowsIso.FileName)"
    $content.SqlIsoPath = "$mediaRoot\$($sqlIso.FileName)"
    $content.SwitchName = $SwitchName
    $content.GuestAddress = $GuestAddress
    $content.Gateway = $GatewayAddress
    $content.DnsServer = $DnsServer
    $application = Resolve-OnboardingApplicationId
    if ($application) { $content.OnboardingApplicationId = $application }
    $null = New-Item -ItemType Directory -Path (Split-Path $path) -Force
    [System.IO.File]::WriteAllText($path, ($content | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Path = $path; HasOnboardingApplicationId = [bool]$application }
}

# Preflight: read-only facts and gates.
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$vm = $target.Actual
if ($vm.provisioningState -ne 'Succeeded') { throw "The parent is $($vm.provisioningState), not Succeeded; wait or inspect before preparing it." }
if ($vm.powerState -notin @('VM running', 'VM deallocated', 'VM stopped')) { throw "The parent is $($vm.powerState); wait for the transition instead of resubmitting." }
$labActive = $false
if ($mutating.Count) {
    $network = Get-DemoNetworkState -InfraRg $infraRg -NamePrefix $NamePrefix
    $labActive = [bool]($network.Subnet.natGateway.id -and $network.Subnet.natGateway.id -eq $network.NatId)
    if (-not $labActive) { throw 'The lab is not Active (no NAT gateway on snet-vms). Run the approved Activate first: Prepare never starts compute without explicit outbound networking.' }
}
Write-Step "Preparing $parentName ($($vm.hardwareProfile.vmSize), $($vm.powerState)) for the nested SQL guest; phases: $($requested -join ', ')"
$phaseResults.Add((New-PhaseResult 'Preflight' 'satisfied' "$parentName $($vm.hardwareProfile.vmSize), $($vm.powerState), lab Active: $(if ($mutating.Count) { $labActive } else { 'not checked (no phase changes anything)' })"))

$verification = $null
foreach ($name in $requested | Where-Object { $_ -ne 'Preflight' }) {
    $clock.Restart()
    Write-Step "Phase $name"
    $result = switch ($name) {
        'Size' { Invoke-SizePhase }
        'Disk' { Invoke-DiskPhase }
        'Volume' { Invoke-VolumePhase }
        'HyperV' { Invoke-HyperVPhase }
        'Network' { Invoke-NetworkPhase }
        'Media' { Invoke-MediaPhase }
        'Verify' { $verification = Invoke-VerifyPhase; New-PhaseResult 'Verify' $verification.Status "$(@($verification.Checks | Where-Object { $_.status -eq 'pass' }).Count) of $(@($verification.Checks).Count) checks pass" }
    }
    $result = @($result | Where-Object { $_ -and $_.PSObject.Properties['phase'] }) | Select-Object -Last 1
    $result | Add-Member -NotePropertyName seconds -NotePropertyValue ([Math]::Round($clock.Elapsed.TotalSeconds, 1)) -Force
    $phaseResults.Add($result)
}

$buildInput = $null
if ($verification -and $verification.Status -eq 'pass') { $buildInput = Write-BuildInput -Parent $verification.Parent }
$overall = if ($verification) { $verification.Status } elseif (@($phaseResults | Where-Object { $_.status -eq 'skipped' }).Count) { 'pending' } else { 'pass' }
$output = [pscustomobject]@{
    schemaVersion = 1; workload = 'nested-sql-parent'; status = $overall
    parent = [pscustomobject]@{ name = $parentName; resourceId = $target.Id; size = $nested.ParentVmSize; dataDiskGb = $nested.ParentDataDiskGb }
    phases = @($phaseResults); checks = @($(if ($verification) { $verification.Checks }))
    buildInputPath = $(if ($buildInput) { $buildInput.Path } else { $null })
    warnings = @($(if ($buildInput -and -not $buildInput.HasOnboardingApplicationId) { 'OnboardingApplicationId was not resolved; add it to the build input before New-NestedSqlDemo.ps1.' }))
}
if ($ResultPath) { $output | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultPath -Encoding utf8 }
$output
if ($verification -and $verification.Status -eq 'fail') {
    throw "Verify failed: $((@($verification.Checks | Where-Object { $_.status -eq 'fail' }) | ForEach-Object { $_.id }) -join ', ')."
}
