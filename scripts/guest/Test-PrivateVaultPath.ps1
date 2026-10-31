#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Json')]
param(
    [Parameter(Mandatory)][string]$ExpectedComputerName,
    [Parameter(Mandatory)][guid]$ExpectedParentVmId,
    [Parameter(Mandatory)][string]$VaultName,
    [Parameter(Mandatory, ParameterSetName = 'Json')][string]$PrivateAddressesJson,
    [Parameter(Mandatory, ParameterSetName = 'Base64')][string]$PrivateAddressesBase64,
    [ValidateSet('RuntimeDefault', 'Tls12')][string]$TlsMode = 'RuntimeDefault'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$stage = 'identity-validation'
$reason = 'target-invalid'
$details = @{
    expectedComputerName = $null; observedComputerName = $null
    expectedParentVmId = "$ExpectedParentVmId"; observedParentVmId = $null
    addressEncoding = $PSCmdlet.ParameterSetName.ToLowerInvariant()
    addressPayloadLength = 0; addressHasQuotes = $false; addressCount = 0; addressElementKind = 'unparsed'
}
try {
    if ($ExpectedParentVmId -eq [guid]::Empty -or $VaultName -notmatch '^[a-zA-Z0-9-]{3,24}$') { throw 'Diagnostic parent/target mismatch.' }
    $stage = 'computer-name-validation'; $reason = 'computer-name-invalid'
    if ($ExpectedComputerName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$' -or
        $env:COMPUTERNAME -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$') { throw 'Diagnostic computer name malformed.' }
    $details.expectedComputerName = $ExpectedComputerName; $details.observedComputerName = $env:COMPUTERNAME
    $reason = 'computer-name-mismatch'
    if ($env:COMPUTERNAME -ne $ExpectedComputerName) { throw 'Diagnostic computer name mismatch.' }
    $stage = 'parent-metadata-request'; $reason = 'metadata-request-failed'
    $parent = Invoke-RestMethod -Method GET -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01' -Headers @{ Metadata = 'true' } -TimeoutSec 10
    $stage = 'parent-metadata-shape'; $reason = 'metadata-vm-id-invalid'
    $observedId = [guid]::Empty
    if (-not $parent -or $parent.vmId -isnot [string] -or -not [guid]::TryParseExact($parent.vmId, 'D', [ref]$observedId) -or
        $observedId -eq [guid]::Empty) { throw 'Diagnostic compute metadata lacks a valid VM identity.' }
    $details.observedParentVmId = "$observedId"
    $stage = 'parent-vm-id-validation'; $reason = 'parent-vm-id-mismatch'
    if ($parent.vmId -ne "$ExpectedParentVmId") { throw 'Diagnostic immutable parent identity mismatch.' }
    $stage = 'private-address-decode'; $reason = 'address-encoding-invalid'
    if ($PSCmdlet.ParameterSetName -eq 'Base64') {
        if ($PrivateAddressesBase64.Length -gt 4096 -or $PrivateAddressesBase64 -notmatch '^[A-Za-z0-9+/]+={0,2}$') { throw 'Invalid address encoding.' }
        $PrivateAddressesJson = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String($PrivateAddressesBase64))
    }
    $details.addressPayloadLength = $PrivateAddressesJson.Length
    $details.addressHasQuotes = $PrivateAddressesJson.Contains('"')
    $stage = 'private-address-json'; $reason = 'address-json-invalid'
    if ($PrivateAddressesJson.Length -gt 2048 -or $PrivateAddressesJson -notmatch '^\s*\[') { throw 'Address payload must be a bounded JSON array.' }
    $decoded = $PrivateAddressesJson | ConvertFrom-Json -ErrorAction Stop
    # PS5 emits the whole JSON array as one pipeline object; normalize after assignment.
    $expected = @($decoded)
    $stage = 'private-address-schema'; $reason = 'address-schema-invalid'
    $details.addressCount = $expected.Count
    if ($expected.Count -lt 1 -or $expected.Count -gt 4 -or @($expected | Sort-Object -Unique).Count -ne $expected.Count) { throw 'Invalid private endpoint address set.' }
    foreach ($address in $expected) {
        $details.addressElementKind = if ($address -is [string]) { 'string' } elseif ($address -is [array]) { 'array' } else { 'object' }
        $ip = $null
        if ($address -isnot [string] -or -not [Net.IPAddress]::TryParse($address, [ref]$ip) -or
            $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $ip.ToString() -cne $address) { throw 'Invalid private endpoint IPv4.' }
        $bytes = $ip.GetAddressBytes()
        if (-not ($bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
            ($bytes[0] -eq 192 -and $bytes[1] -eq 168))) { throw 'Diagnostic requires an approved private endpoint IPv4.' }
    }
    $stage = 'private-dns'; $reason = 'dns-request-failed'
    $dnsName = "$VaultName.vault.azure.net"
    $resolved = @(Resolve-DnsName -Name $dnsName -Type A -DnsOnly -QuickTimeout -ErrorAction Stop |
        Where-Object Type -eq 'A' | ForEach-Object IPAddress | Sort-Object -Unique)
    $stage = 'private-dns-answers'; $reason = 'dns-address-mismatch'
    if (-not $resolved.Count -or @(Compare-Object $resolved @($expected | Sort-Object)).Count) { throw 'Private DNS address set mismatch.' }
    $stage = 'private-tcp'; $reason = 'tcp-connect-failed'
    $tcp = [Net.Sockets.TcpClient]::new()
    try {
        $connection = $tcp.ConnectAsync([string]$resolved[0], 443)
        if (-not $connection.Wait(10000) -or -not $tcp.Connected) { throw 'Private endpoint TCP timeout/failure.' }
        $stage = 'private-tls'; $reason = 'tls-authentication-failed'
        $details.tlsPhase = 'stream-create'
        $ssl = [Net.Security.SslStream]::new($tcp.GetStream(), $false)
        try {
            $details.tlsPhase = 'authenticate-start'
            $authentication = if ($TlsMode -eq 'Tls12') {
                $ssl.AuthenticateAsClientAsync($dnsName, [Security.Cryptography.X509Certificates.X509CertificateCollection]::new(),
                    [Security.Authentication.SslProtocols]::Tls12, $false)
            } else { $ssl.AuthenticateAsClientAsync($dnsName) }
            $details.tlsPhase = 'authenticate-wait'
            if (-not $authentication.Wait(10000)) {
                $reason = 'tls-authentication-timeout'
                throw [TimeoutException]::new('Private endpoint TLS deadline exceeded.')
            }
            $details.tlsPhase = 'authenticate-verify'
            if (-not $ssl.IsAuthenticated -or -not $ssl.IsEncrypted) { throw 'Private endpoint TLS unverified.' }
        } finally { $ssl.Dispose() }
    } finally { $tcp.Dispose() }
    'ARC_PRIVATE_PATH_RESULT:' + (@{
        status = 'pass'; operation = 'InspectPath'; parentVmId = "$ExpectedParentVmId"
        privateAddresses = $resolved; tlsVerified = $true; checkedAtUtc = [datetime]::UtcNow.ToString('o')
        tlsProtocolSelection = $(if ($TlsMode -eq 'Tls12') { 'tls12' } else { 'runtime-default' })
    } | ConvertTo-Json -Compress)
} catch {
    $failureRecord = $_
    if ($stage -eq 'private-tls') {
        $details.tlsProtocolSelection = if ($TlsMode -eq 'Tls12') { 'tls12' } else { 'runtime-default' }
        $details.tlsTaskStatus = if ($authentication) { $authentication.Status.ToString() } else { 'not-created' }
        $details.tlsNativeErrorCode = $null
        $exceptions = [Collections.Generic.Queue[Exception]]::new()
        $exceptions.Enqueue($failureRecord.Exception)
        $kinds = [Collections.Generic.List[string]]::new()
        while ($exceptions.Count -and $kinds.Count -lt 6) {
            $exception = $exceptions.Dequeue()
            $kind = switch ($exception.GetType().FullName) {
                'System.Management.Automation.MethodInvocationException' { 'method-invocation' }
                'System.AggregateException' { 'aggregate' }
                'System.Security.Authentication.AuthenticationException' { 'authentication' }
                'System.ComponentModel.Win32Exception' { 'win32' }
                'System.IO.IOException' { 'io' }
                'System.Net.Sockets.SocketException' { 'socket' }
                'System.TimeoutException' { 'timeout' }
                'System.ArgumentException' { 'argument' }
                'System.InvalidOperationException' { 'invalid-operation' }
                'System.NotSupportedException' { 'unsupported' }
                default { 'other' }
            }
            $kinds.Add($kind)
            if ($exception -is [ComponentModel.Win32Exception] -and $null -eq $details.tlsNativeErrorCode) {
                $details.tlsNativeErrorCode = $exception.NativeErrorCode
            }
            if ($exception -is [AggregateException]) {
                foreach ($inner in $exception.InnerExceptions) {
                    if ($exceptions.Count -ge 6) { break }
                    $exceptions.Enqueue($inner)
                }
            } elseif ($exception.InnerException) { $exceptions.Enqueue($exception.InnerException) }
        }
        $details.tlsExceptionKinds = @($kinds.ToArray())
        $details.tlsExceptionTruncated = $exceptions.Count -gt 0
    }
    $code = if ($failureRecord.Exception.Response) { [int]$failureRecord.Exception.Response.StatusCode } else { 0 }
    $kind = $failureRecord.Exception.GetType().Name
    $errorType = if ($kind -in @('ArgumentException', 'FormatException')) { 'invalid-input' }
        elseif ($kind -in @('WebException', 'HttpResponseException')) { 'http-request' }
        elseif ($kind -eq 'CommandNotFoundException') { 'command-unavailable' }
        elseif ($kind -eq 'MethodInvocationException') { 'method-invocation' } else { 'runtime' }
    'ARC_PRIVATE_VAULT_FAILURE:' + (@{
        status = 'fail'; operation = 'InspectPath'; stage = $stage; httpStatus = $code
        checkedAtUtc = [datetime]::UtcNow.ToString('o'); reason = $reason; errorType = $errorType; details = $details
    } | ConvertTo-Json -Compress)
    throw "Private path inspection failed during $stage (HTTP $code). No retry, repair, role change or secret operation."
}
