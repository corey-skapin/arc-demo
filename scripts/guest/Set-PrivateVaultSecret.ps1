#Requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The HTTPS Key Vault JSON value is converted immediately to SecureString in memory; no value is logged or persisted.')]
[CmdletBinding(DefaultParameterSetName = 'Json')]
param(
    [Parameter(Mandatory)][string]$ExpectedComputerName,
    [Parameter(Mandatory)][string]$VaultName,
    [Parameter(Mandatory)][string]$SecretName,
    [Parameter(Mandatory, ParameterSetName = 'Json')][string]$PrivateAddressesJson,
    [Parameter(Mandatory, ParameterSetName = 'Base64')][string]$PrivateAddressesBase64,
    [Parameter(Mandatory)][ValidateSet('Marker', 'VerifyMarker', 'Initialize', 'Read')][string]$Operation,
    [ValidateSet('RuntimeDefault', 'Tls12')][string]$TlsMode = 'RuntimeDefault',
    [string]$SecretValue = '',
    [string]$ApplicationId = '',
    [guid]$CredentialKeyId = [guid]::Empty,
    [string]$ExpiresAtUtc = '',
    [string]$MarkerVersionUri = '',
    [string]$OnboardingVersionUri = '',
    [ValidateSet('arc-demo-private-onboarding', 'arc-demo-fresh-admin')][string]$Purpose = 'arc-demo-private-onboarding'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$token = $null
$headers = $null
$body = $null
$readback = $null
$stage = 'identity-validation'
$reason = 'target-invalid'
$details = @{
    expectedComputerName = $null; observedComputerName = $null
    addressEncoding = $PSCmdlet.ParameterSetName.ToLowerInvariant()
    addressPayloadLength = 0; addressHasQuotes = $false; addressCount = 0; addressElementKind = 'unparsed'
}
function Invoke-PrivateVaultRequest {
    param([string]$Method, [string]$Uri, [object]$Headers, [string]$Body = '')
    if ($TlsMode -eq 'RuntimeDefault') {
        $options = @{ Method = $Method; Uri = $Uri; Headers = $Headers; TimeoutSec = 60 }
        if ($Operation -eq 'Read') { $options.MaximumRedirection = 0 }
        if ($Body) { $options.Body = $Body; $options.ContentType = 'application/json' }
        return Invoke-RestMethod @options
    }
    if ($Uri -notmatch ('^https://' + [regex]::Escape("$VaultName.vault.azure.net/secrets/$SecretName") + '(?:/[0-9a-f]{32})?\?api-version=7\.4$')) {
        throw 'Private TLS request is outside the pinned secret/version route.'
    }
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $client = $null; $request = $null; $response = $null
    try {
        $handler.SslProtocols = [Security.Authentication.SslProtocols]::Tls12
        $handler.AllowAutoRedirect = $false
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [timespan]::FromSeconds(60)
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Uri)
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::Parse($Headers.Authorization)
        if ($Body) { $request.Content = [Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, 'application/json') }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $rejected = [InvalidOperationException]::new('Private vault request rejected; no alternate route or retry.')
            $rejected.Data['ArcPrivateHttpStatus'] = [int]$response.StatusCode
            throw $rejected
        }
        $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -ErrorAction Stop
    } finally {
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        if ($client) { $client.Dispose() } else { $handler.Dispose() }
    }
}
try {
    if ($VaultName -notmatch '^[a-zA-Z0-9-]{3,24}$' -or
        $SecretName -notin @('arc-onboarding-client-secret', 'vm-admin-password')) { throw 'Private writer identity/target mismatch.' }
    if (($Purpose -eq 'arc-demo-private-onboarding') -ne ($SecretName -eq 'arc-onboarding-client-secret')) { throw 'Secret purpose mismatch.' }
    if ($Operation -eq 'Read') {
        $applicationGuid = [guid]::Empty
        if ($Purpose -ne 'arc-demo-private-onboarding' -or $SecretValue -or $MarkerVersionUri -or
            -not [guid]::TryParseExact($ApplicationId, 'D', [ref]$applicationGuid) -or $applicationGuid -eq [guid]::Empty -or
            $CredentialKeyId -eq [guid]::Empty -or $ExpiresAtUtc -notmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,7})?(?:Z|[+-]\d\d:\d\d)$' -or
            $OnboardingVersionUri -notmatch ('^https://' + [regex]::Escape("$VaultName.vault.azure.net/secrets/$SecretName/") + '[0-9a-f]{32}$')) {
            throw 'Reader requires an exact onboarding version and retained app/key/expiry metadata, never another credential route.'
        }
        $readExpiry = [datetimeoffset]::Parse($ExpiresAtUtc, [cultureinfo]::InvariantCulture)
        if ($readExpiry -le [datetimeoffset]::UtcNow.AddHours(24)) { throw 'Retained onboarding credential has less than 24 hours remaining; no renewal or fallback.' }
    } elseif ($OnboardingVersionUri) { throw 'Credential version is valid only for the in-memory read operation.' }
    if ($Operation -eq 'VerifyMarker') {
        if ($Purpose -ne 'arc-demo-private-onboarding' -or $SecretValue -or $ApplicationId -or
            $CredentialKeyId -ne [guid]::Empty -or $ExpiresAtUtc -or
            $MarkerVersionUri -notmatch ('^https://' + [regex]::Escape("$VaultName.vault.azure.net/secrets/$SecretName/") + '[0-9a-f]{32}$')) {
            throw 'Existing-marker verification requires only its exact pinned version, never credential inputs.'
        }
    } elseif ($MarkerVersionUri) { throw 'Pinned marker version is valid only for existing-marker verification.' }
    $stage = 'computer-name-validation'; $reason = 'computer-name-invalid'
    if ($ExpectedComputerName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$' -or
        $env:COMPUTERNAME -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$') { throw 'Writer computer name malformed.' }
    $details.expectedComputerName = $ExpectedComputerName; $details.observedComputerName = $env:COMPUTERNAME
    $reason = 'computer-name-mismatch'
    if ($env:COMPUTERNAME -ne $ExpectedComputerName) { throw 'Private writer computer name mismatch.' }
    $stage = 'private-address-decode'; $reason = 'address-encoding-invalid'
    if ($PSCmdlet.ParameterSetName -eq 'Base64') {
        if ($PrivateAddressesBase64.Length -gt 4096 -or $PrivateAddressesBase64 -notmatch '^[A-Za-z0-9+/]+={0,2}$') { throw 'Invalid address encoding.' }
        $PrivateAddressesJson = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String($PrivateAddressesBase64))
    }
    $details.addressPayloadLength = $PrivateAddressesJson.Length; $details.addressHasQuotes = $PrivateAddressesJson.Contains('"')
    $stage = 'private-address-json'; $reason = 'address-json-invalid'
    if ($PrivateAddressesJson.Length -gt 2048 -or $PrivateAddressesJson -notmatch '^\s*\[') { throw 'Address payload must be a bounded JSON array.' }
    $decoded = $PrivateAddressesJson | ConvertFrom-Json -ErrorAction Stop
    # Normalize after assignment: PS5 emits the whole JSON array as one pipeline object.
    $expectedAddresses = @($decoded)
    $stage = 'private-address-schema'; $reason = 'address-schema-invalid'
    $details.addressCount = $expectedAddresses.Count
    if ($expectedAddresses.Count -lt 1 -or $expectedAddresses.Count -gt 4 -or
        @($expectedAddresses | Sort-Object -Unique).Count -ne $expectedAddresses.Count) { throw 'Invalid endpoint address set.' }
    foreach ($address in $expectedAddresses) {
        $details.addressElementKind = if ($address -is [string]) { 'string' } elseif ($address -is [array]) { 'array' } else { 'object' }
        $ip = $null
        if ($address -isnot [string] -or -not [Net.IPAddress]::TryParse($address, [ref]$ip) -or
            $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $ip.ToString() -cne $address) { throw 'Invalid endpoint IPv4.' }
        $bytes = $ip.GetAddressBytes()
        if (-not ($bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
            ($bytes[0] -eq 192 -and $bytes[1] -eq 168))) { throw 'Writer requires an approved private endpoint IPv4.' }
    }
    $stage = 'private-dns'; $reason = 'dns-request-failed'
    $dnsName = "$VaultName.vault.azure.net"
    $resolved = @(Resolve-DnsName -Name $dnsName -Type A -ErrorAction Stop | Where-Object Type -eq 'A' | ForEach-Object IPAddress | Select-Object -Unique)
    $stage = 'private-dns-answers'; $reason = 'dns-address-mismatch'
    if (-not $resolved.Count -or @(Compare-Object @($resolved | Sort-Object) @($expectedAddresses | Sort-Object)).Count) { throw 'Vault DNS does not resolve exclusively to the approved private endpoint.' }
    $stage = 'private-tcp'; $reason = 'tcp-connect-failed'
    $tcp = [Net.Sockets.TcpClient]::new()
    try {
        $connection = $tcp.ConnectAsync([string]$resolved[0], 443)
        if (-not $connection.Wait(10000) -or -not $tcp.Connected) { throw 'Private vault TCP connection timed out/failure.' }
        $stage = 'private-tls'; $reason = 'tls-authentication-failed'
        $ssl = [Net.Security.SslStream]::new($tcp.GetStream(), $false)
        try {
            $authentication = if ($TlsMode -eq 'Tls12') {
                $ssl.AuthenticateAsClientAsync($dnsName, [Security.Cryptography.X509Certificates.X509CertificateCollection]::new(),
                    [Security.Authentication.SslProtocols]::Tls12, $false)
            } else { $ssl.AuthenticateAsClientAsync($dnsName) }
            if (-not $authentication.Wait(10000)) { $reason = 'tls-authentication-timeout'; throw 'Private vault TLS deadline exceeded.' }
            if (-not $ssl.IsAuthenticated -or -not $ssl.IsEncrypted) { throw 'Private vault TLS is unverified.' }
        } finally { $ssl.Dispose() }
    } finally { $tcp.Dispose() }
    $stage = 'parent-managed-identity'; $reason = 'managed-identity-token-failed'
    $token = Invoke-RestMethod -Method GET -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -Headers @{ Metadata = 'true' } -TimeoutSec 30
    if (-not $token.access_token) { throw 'Parent managed identity token unavailable.' }
    $headers = @{ Authorization = "Bearer $($token.access_token)" }
    if ($Operation -eq 'Read') {
        $stage = 'private-credential-read'; $reason = 'credential-read-failed'
        $readback = Invoke-PrivateVaultRequest -Method GET -Uri "${OnboardingVersionUri}?api-version=7.4" -Headers $headers
        if ($readback.id -cne $OnboardingVersionUri -or $readback.attributes.enabled -isnot [bool] -or
            $readback.attributes.enabled -ne $true -or
            ($readback.attributes.exp -isnot [int] -and $readback.attributes.exp -isnot [long]) -or $readback.attributes.exp -ne $readExpiry.ToUnixTimeSeconds() -or
            $readback.tags.purpose -cne $Purpose -or $readback.tags.state -cne 'initialized' -or
            $readback.tags.appId -cne $ApplicationId -or $readback.tags.keyId -cne "$CredentialKeyId" -or
            $readback.tags.expiry -cne $readExpiry.UtcDateTime.ToString('o') -or
            $readback.value -isnot [string] -or [string]::IsNullOrWhiteSpace($readback.value) -or $readback.value.Length -gt 4096) {
            $reason = 'credential-reference-mismatch'
            throw 'Pinned retained onboarding value/metadata is not verified; no other version or credential route.'
        }
        return (ConvertTo-SecureString -String $readback.value -AsPlainText -Force)
    }
    $attributes = @{ enabled = $true }
    $tags = @{ purpose = $Purpose; state = 'private-writer-tested' }
    $value = 'NONSECRET_PRIVATE_WRITER_TEST'
    if ($Operation -eq 'Initialize') {
        $stage = 'credential-metadata'; $reason = 'credential-metadata-invalid'
        if ([string]::IsNullOrWhiteSpace($SecretValue)) { throw 'Protected initialization input missing.' }
        $value = $SecretValue
        $tags.state = 'initialized'
        if ($Purpose -eq 'arc-demo-private-onboarding') {
            $expiry = [datetimeoffset]::Parse($ExpiresAtUtc, [cultureinfo]::InvariantCulture)
            if ($expiry -le [datetimeoffset]::UtcNow.AddHours(24) -or $ApplicationId -notmatch '^[0-9a-f-]{36}$' -or $CredentialKeyId -notmatch '^[0-9a-f-]{36}$') { throw 'New onboarding credential metadata invalid.' }
            $attributes.exp = $expiry.ToUnixTimeSeconds()
            $tags.appId = $ApplicationId
            $tags.keyId = $CredentialKeyId
            $tags.expiry = $expiry.UtcDateTime.ToString('o')
        }
    }
    $uri = "https://$dnsName/secrets/$SecretName"
    $versionToDisable = $null; $readVerified = $false
    try {
        if ($Operation -eq 'VerifyMarker') {
            $stored = @{ id = $MarkerVersionUri }; $versionToDisable = $MarkerVersionUri
            $stage = 'enable-existing-marker'; $reason = 'marker-enable-failed'
            $enabled = Invoke-PrivateVaultRequest -Method PATCH -Uri "${MarkerVersionUri}?api-version=7.4" -Headers $headers -Body '{"attributes":{"enabled":true}}'
            if ($enabled.id -ne $MarkerVersionUri -or $enabled.attributes.enabled -ne $true -or
                $enabled.tags.purpose -ne $Purpose -or $enabled.tags.state -ne 'private-writer-tested' -or
                $enabled.tags.appId -or $enabled.tags.keyId -or $enabled.tags.expiry) { throw 'Enabled marker version/metadata differs.' }
        } else {
            $body = @{ value = $value; attributes = $attributes; tags = $tags; contentType = $Purpose } | ConvertTo-Json -Depth 5 -Compress
            $stage = 'private-secret-write'; $reason = 'secret-write-failed'
            $stored = Invoke-PrivateVaultRequest -Method PUT -Uri "${uri}?api-version=7.4" -Headers $headers -Body $body
            if ($stored.id -notmatch ('^' + [regex]::Escape("$uri/") + '[0-9a-f]{32}$')) { throw 'Private secret write returned an unexpected version identity.' }
            if ($Operation -eq 'Marker') { $versionToDisable = $stored.id }
        }
        $stage = 'private-secret-readback'; $reason = 'secret-readback-failed'
        $readback = Invoke-PrivateVaultRequest -Method GET -Uri "$($stored.id)?api-version=7.4" -Headers $headers
        if ($readback.id -ne $stored.id -or $readback.value -cne $value -or $readback.attributes.enabled -ne $true -or
            $readback.tags.purpose -ne $Purpose -or $readback.tags.state -ne $tags.state -or
            ($Operation -eq 'VerifyMarker' -and ($readback.tags.appId -or $readback.tags.keyId -or $readback.tags.expiry)) -or
            ($attributes.ContainsKey('exp') -and ($readback.attributes.exp -ne $attributes.exp -or
            $readback.tags.appId -ne $ApplicationId -or $readback.tags.keyId -ne "$CredentialKeyId" -or $readback.tags.expiry -ne $tags.expiry))) {
            throw 'Private secret value/metadata readback mismatch.'
        }
        $readVerified = $true
    } finally {
        if ($versionToDisable) {
            $priorStage = $stage; $priorReason = $reason
            $stage = 'disable-bootstrap-marker'; $reason = 'marker-disable-failed'
            $disabled = Invoke-PrivateVaultRequest -Method PATCH -Uri "${versionToDisable}?api-version=7.4" -Headers $headers -Body '{"attributes":{"enabled":false}}'
            if ($disabled.id -ne $versionToDisable -or $disabled.attributes.enabled -ne $false) { throw 'Exact marker version disable was not verified.' }
            if (-not $readVerified) { $stage = $priorStage; $reason = $priorReason }
        }
    }
    $receipt = @{
        status = 'pass'; operation = $Operation; secretVersionUri = $stored.id
        privateAddresses = $resolved; tlsVerified = $true; valueVerified = $true
        enabled = ($Operation -eq 'Initialize'); expiresAtUtc = $ExpiresAtUtc
        checkedAtUtc = [datetime]::UtcNow.ToString('o')
    }
    'ARC_PRIVATE_VAULT_RESULT:' + ($receipt | ConvertTo-Json -Depth 4 -Compress)
} catch {
    $code = if ($_.Exception.Data.Contains('ArcPrivateHttpStatus')) { [int]$_.Exception.Data['ArcPrivateHttpStatus'] }
        elseif ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response -and
            $_.Exception.Response.PSObject.Properties['StatusCode']) { [int]$_.Exception.Response.StatusCode } else { 0 }
    $kind = $_.Exception.GetType().Name
    $errorType = if ($kind -in @('ArgumentException', 'FormatException')) { 'invalid-input' }
        elseif ($kind -in @('WebException', 'HttpResponseException')) { 'http-request' }
        elseif ($kind -eq 'CommandNotFoundException') { 'command-unavailable' }
        elseif ($kind -eq 'MethodInvocationException') { 'method-invocation' } else { 'runtime' }
    'ARC_PRIVATE_VAULT_FAILURE:' + (@{
        status = 'fail'; operation = $Operation; stage = $stage; httpStatus = $code
        checkedAtUtc = [datetime]::UtcNow.ToString('o'); reason = $reason; errorType = $errorType; details = $details
    } | ConvertTo-Json -Compress)
    throw "Private writer failed during $stage (HTTP $code). No fallback or retry; inspect sanitized stage evidence."
} finally {
    $SecretValue = $null; $value = $null; $body = $null; $readback = $null; $stored = $null
    $headers = $null; $token = $null
}
