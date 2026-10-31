#Requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$ActorPath,
    [Parameter(Mandatory)][ValidateSet('Inspector', 'Marker')][string]$ActorKind,
    [Parameter(Mandatory)][string]$Payload,
    [ValidateSet('Base64', 'Json')][string]$Encoding = 'Base64',
    [ValidateSet('DnsFailure', 'NameMismatch', 'MetadataFailure', 'MetadataShape', 'VmMismatch')][string]$Case = 'DnsFailure'
)
$ErrorActionPreference = 'Stop'
$global:ArcPrivatePs5Case = $Case
$global:ArcPrivatePs5ImdsCalls = 0
$global:ArcPrivatePs5DnsCalls = 0
$env:COMPUTERNAME = if ($Case -eq 'NameMismatch') { 'other-parent' } else { 'fixture-parent' }
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $TimeoutSec)
    if ($Uri -cne 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01') {
        throw 'Unexpected network request prohibited by synthetic PS5 harness.'
    }
    $global:ArcPrivatePs5ImdsCalls++
    if ($global:ArcPrivatePs5Case -eq 'MetadataFailure') { throw 'SENSITIVE_SENTINEL' }
    if ($global:ArcPrivatePs5Case -eq 'MetadataShape') { return @{ vmId = @('SENSITIVE_SENTINEL') } }
    if ($global:ArcPrivatePs5Case -eq 'VmMismatch') { return @{ vmId = '88888888-8888-8888-8888-888888888888' } }
    @{ vmId = '33333333-3333-3333-3333-333333333333' }
}
function Resolve-DnsName {
    param($Name, $Type, $ErrorAction, [switch]$DnsOnly, [switch]$QuickTimeout)
    $global:ArcPrivatePs5DnsCalls++
    throw 'SENSITIVE_SENTINEL'
}
$parameters = @{ ExpectedComputerName = 'fixture-parent'; VaultName = 'kv-fixture' }
if ($Encoding -eq 'Base64') { $parameters.PrivateAddressesBase64 = $Payload }
else { $parameters.PrivateAddressesJson = $Payload }
if ($ActorKind -eq 'Inspector') { $parameters.ExpectedParentVmId = '33333333-3333-3333-3333-333333333333' }
else { $parameters.SecretName = 'arc-onboarding-client-secret'; $parameters.Operation = 'Marker' }
$script:failed = $false
$output = @(& {
    try { & $ActorPath @parameters }
    catch { $script:failed = $true }
})
$failure = $null
foreach ($line in $output) {
    if ($line -match '^ARC_PRIVATE_VAULT_FAILURE:(\{.*\})$') { $failure = $Matches[1] | ConvertFrom-Json }
}
if (-not $script:failed -or -not $failure) { throw 'Expected bounded synthetic failure proof absent.' }
$json = '["10.50.1.10"]'
$old = @($json | ConvertFrom-Json)
$decoded = $json | ConvertFrom-Json
$normalized = @($decoded)
[ordered]@{
    psVersion = "$($PSVersionTable.PSVersion)"
    failure = $failure
    imdsCalls = $global:ArcPrivatePs5ImdsCalls
    dnsCalls = $global:ArcPrivatePs5DnsCalls
    oldElementType = $old[0].GetType().FullName
    normalizedElementType = $normalized[0].GetType().FullName
    oldMarkerRejectCount = @('10.50.1.10' | Where-Object { $_ -notin $old }).Count
    normalizedMarkerRejectCount = @('10.50.1.10' | Where-Object { $_ -notin $normalized }).Count
} | ConvertTo-Json -Depth 8 -Compress
