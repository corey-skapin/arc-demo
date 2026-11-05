<#
.SYNOPSIS
    Read-only, machine-readable readiness for the retained Arc demo estate.
.DESCRIPTION
    JSON schemaVersion 1. Exit 0: required checks pass; 1: fail/error;
    2: eventual-consistency checks remain pending at the bounded deadline.
    extension/* rows are non-required soft diagnostics; the required heartbeat/* rows decide readiness.
    With -TimeoutSeconds, polling continues while any required row is still pending, even when an
    unrelated required row has already failed, so one bounded run ends with every row settled.
    -SkipNestedGuest leaves out the nested/arc row. Deploy's own validation uses it: the nested guest is
    built after Deploy (wrapper step P4), so its Arc machine cannot exist yet and must not fail the base estate.
    -OutputPath also writes the JSON (whatever -OutputFormat shows) to that file, creating its folder, so one run
    gives both the dated evidence and the exit code. The JSON names the subscription and tenant: keep it outside git.
    Never repairs, induces faults, changes context defaults or registers providers.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = '',
    [ValidateSet('Active', 'Ready', 'Hibernated', 'Removed')][string]$DesiredState = 'Ready',
    [ValidateSet('Json', 'Table')][string]$OutputFormat = 'Table',
    [ValidateRange(0, 1800)][int]$TimeoutSeconds = 0,
    [switch]$SkipNestedGuest,
    [string]$OutputPath = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
try {
    $skin = if ($DesiredState -ne 'Hibernated' -or -not $PSBoundParameters.ContainsKey('NamePrefix')) {
        Get-DemoSkin -Path $SkinPath -RepoRoot (Split-Path $PSScriptRoot)
    }
    if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
    Assert-DemoName $NamePrefix
    Initialize-DemoContext $SubscriptionId $TenantId
    $nestedSqlGuest = if ($DesiredState -notin @('Hibernated', 'Removed')) { Get-DemoNestedSqlGuestConfig -Skin $skin }
    do {
        $checks = if ($DesiredState -eq 'Removed') {
            @(Get-DemoRemovalChecks -NamePrefix $NamePrefix)
        } else {
            $inventory = Get-DemoInventory $NamePrefix -ForHibernation:($DesiredState -eq 'Hibernated') `
                -NestedSqlParentVmName $(if ($nestedSqlGuest) { $nestedSqlGuest.ParentVmName } else { '' }) `
                -KeepParkedVmNames @(Get-DemoSkinValue $skin 'operations.keepParkedVmNames' @())
            if ($DesiredState -ne 'Hibernated') { Assert-DemoSkinInventory $skin $inventory }
            @(Get-DemoReadinessChecks -Inventory $inventory -NamePrefix $NamePrefix -DesiredState $DesiredState)
            if ($nestedSqlGuest -and -not $SkipNestedGuest) {
                $id = "/subscriptions/$SubscriptionId/resourceGroups/rg-$NamePrefix/providers/Microsoft.HybridCompute/machines/$($nestedSqlGuest.ArcMachineName)"
                $raw = Invoke-DemoAz -Arguments @('connectedmachine', 'show', '--ids', $id, '-o', 'json') -AllowNotFound
                $machine = if ($raw) { $raw | ConvertFrom-Json }
                $state = if (-not $machine) { 'fail' } elseif ($machine.id -ne $id) { 'fail' } elseif ($machine.status -eq 'Connected') { 'pass' } else { 'pending' }
                New-DemoCheck 'nested/arc' $id 'Connected' $machine.status $state `
                    -Message 'Arc connection only; use Test-NestedSqlDemoGuest for actual SQL readiness. No guest login occurs here.'
            }
        }
        $status = if (@($checks | Where-Object { $_.required -and $_.status -eq 'fail' }).Count) { 'fail' }
            elseif (@($checks | Where-Object { $_.required -and $_.status -eq 'pending' }).Count) { 'pending' }
            else { 'pass' }
        # Keep polling while any required row is pending, even if an unrelated required row has already failed.
        if (-not @($checks | Where-Object { $_.required -and $_.status -eq 'pending' }).Count -or [DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds ([Math]::Min(15, [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalSeconds)))
    } while ([DateTime]::UtcNow -lt $deadline)
} catch {
    $status = 'fail'
    $checks = @($checks) + @(New-DemoCheck 'readiness/error' '' 'successful read-only inspection' $null 'fail' -Message $_.Exception.Message)
}
$softExtensions = @($checks | Where-Object { $_ -and $_.id -like 'extension/*' -and -not $_.required -and $_.status -ne 'pass' })
if ($softExtensions.Count) {
    Write-Warning "$($softExtensions.Count) extension row(s) are not Succeeded. Soft warning only: the required heartbeat rows decide readiness; see docs/troubleshooting.md."
}
$result = [ordered]@{
    schemaVersion = 1; workload = 'arc-demo'; checkedAtUtc = [DateTime]::UtcNow.ToString('o')
    subscriptionId = "$SubscriptionId"; tenantId = "$TenantId"
    resourceGroups = @("rg-$NamePrefix", "rg-$NamePrefix-infra")
    desiredState = $DesiredState; status = $status; checks = @($checks | Where-Object { $_ })
}
if ($OutputPath) {
    $evidenceFile = [IO.Path]::GetFullPath($OutputPath, (Get-Location).ProviderPath)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $evidenceFile)
    $result | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $evidenceFile -Encoding utf8
}
if ($OutputFormat -eq 'Json') { $result | ConvertTo-Json -Depth 15 }
else {
    Write-Output "$DesiredState status: $status (required checks determine lifecycle state; non-required checks are diagnostics/exceptions)"
    $result.checks | Format-Table id, required, status, expected, observed, message -AutoSize
}
if ($status -eq 'pass') { exit 0 }
if ($status -eq 'pending') { exit 2 }
exit 1
