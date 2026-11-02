#Requires -Version 7.4
<#
.SYNOPSIS
    Writes a read-only JSON snapshot of the demo estate: names, types, sizes, states and credential metadata.
.DESCRIPTION
    Use it before a teardown and after a rebuild. It makes only list/show/get calls, never reads
    secret values, and records a denied or failed read in that section instead of working around
    it. The file is private evidence: write it outside the repository (or under .local) and never
    commit it. An existing file is never overwritten. Exit 0 when every section was read, else 1.
.PARAMETER OutputPath
    New file in an existing folder. Omit it to print the JSON.
.EXAMPLE
    .\Export-ArcDemoInventory.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath <PRIVATE>\arc-skin.json -OutputPath <PRIVATE>\evidence\inventory-before.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = '',
    [string]$OutputPath = ''
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/EstateSnapshot.psm1') -Force

$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
Assert-DemoName $NamePrefix
$file = ''
if ($OutputPath) {
    $file = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $local = [IO.Path]::GetFullPath((Join-Path $repoRoot '.local')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $inRepo = [IO.Path]::GetFullPath($file).StartsWith([IO.Path]::GetFullPath($repoRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    if ($inRepo -and -not [IO.Path]::GetFullPath($file).StartsWith($local, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Write the snapshot outside the repository (or under .local); it is private evidence.'
    }
    if (Test-Path -LiteralPath $file) { throw 'The output file already exists; snapshots are never overwritten.' }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $file) -PathType Container)) { throw 'The output folder must already exist.' }
}
$snapshot = Get-DemoEstateSnapshot -SubscriptionId $SubscriptionId -TenantId $TenantId -NamePrefix $NamePrefix
$failed = @($snapshot.sections.GetEnumerator() | Where-Object { $_.Value.status -ne 'ok' })
foreach ($section in $failed) { Write-Warn "Section $($section.Key) was not read: $($section.Value.error)" }
$json = $snapshot | ConvertTo-Json -Depth 14
if ($file) {
    Set-Content -LiteralPath $file -Value $json -Encoding utf8
    Write-Ok "Snapshot written: $file"
    $file
} else {
    $json
}
if ($failed) { exit 1 }
exit 0
