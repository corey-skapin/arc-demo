#Requires -Version 5.1
param([string]$ActorPath, [string]$Case)
$ErrorActionPreference = 'Stop'
$env:COMPUTERNAME = 'FIXTUREHOST'
$version = 'https://kv-fixture.vault.azure.net/secrets/arc-onboarding-client-secret/123456789012345678901234567890ab'
$script:methods = [Collections.Generic.List[string]]::new()
$script:versionBound = $true; $script:disabled = $false
$expiry = [datetimeoffset]::UtcNow.AddDays(30)
function Resolve-DnsName { param($Name, $Type, $ErrorAction) @{ Type = 'A'; IPAddress = '10.50.1.10' } }
function Invoke-RestMethod { param($Method, $Uri, $Headers, $TimeoutSec) @{ access_token = 'SENSITIVE_SENTINEL' } }
$transport = @'
function Invoke-PrivateVaultRequest {
    param($Method, $Uri, $Headers, $Body)
    $script:methods.Add("$Method$(if ($Body -match '"enabled":false') { '-disable' } elseif ($Body -match '"enabled":true') { '-enable' })")
    $script:versionBound = $script:versionBound -and $Uri -ceq "${version}?api-version=7.4"
    if ($Method -eq 'PUT') { throw 'New marker version forbidden in this fixture.' }
    if ($Method -eq 'PATCH' -and $Body -match '"enabled":true' -and $Case -eq 'EnableUnknown') { throw 'SENSITIVE_SENTINEL' }
    if ($Method -eq 'GET' -and $Case -eq 'ReadDenied') { throw 'SENSITIVE_SENTINEL' }
    if ($Case -like 'Reader*') {
        if ($Method -ne 'GET') { throw 'Reader attempted a write.' }
        if ($Case -eq 'ReaderDenied') { throw 'SENSITIVE_SENTINEL' }
        return @{
            id = $(if ($Case -eq 'ReaderForeignVersion') { $version.Replace('123456789012345678901234567890ab', 'ffffffffffffffffffffffffffffffff') } else { $version })
            attributes = @{
                enabled = ($Case -ne 'ReaderDisabled')
                exp = $(if ($Case -eq 'ReaderStringExpiry') { [string]$expiry.ToUnixTimeSeconds() } else { $expiry.ToUnixTimeSeconds() })
            }
            tags = @{
                purpose = $(if ($Case -eq 'ReaderForeignPurpose') { 'arc-demo-fresh-admin' } else { 'arc-demo-private-onboarding' })
                state = 'initialized'; appId = '11111111-1111-1111-1111-111111111111'
                keyId = $(if ($Case -eq 'ReaderForeignKey') { '99999999-9999-9999-9999-999999999999' } else { '22222222-2222-2222-2222-222222222222' })
                expiry = $expiry.UtcDateTime.ToString('o')
            }
            value = $(if ($Case -eq 'ReaderEmpty') { '' } else { 'SENSITIVE_SENTINEL' })
        }
    }
    if ($Method -eq 'PATCH' -and $Body -match '"enabled":false' -and $Case -eq 'DisableDenied') { throw 'SENSITIVE_SENTINEL' }
    if ($Method -eq 'PATCH' -and $Body -match '"enabled":false') { $script:disabled = $true }
    return @{
        id = $version; attributes = @{ enabled = -not $script:disabled }
        tags = @{ purpose = 'arc-demo-private-onboarding'; state = 'private-writer-tested' }
        value = $(if ($Case -eq 'WrongValue') { 'SENSITIVE_SENTINEL' } else { 'NONSECRET_PRIVATE_WRITER_TEST' })
    }
}
'@
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($ActorPath, [ref]$tokens, [ref]$errors)
$helper = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-PrivateVaultRequest' }, $true))
$tcp = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text -eq '{ $tcp.Dispose() }' }, $true))
if ($errors -or $helper.Count -ne 1 -or $tcp.Count -ne 1) { throw 'Expected exact private writer transport seams.' }
$text = Get-Content -LiteralPath $ActorPath -Raw
$text = $text.Replace($helper[0].Extent.Text, $transport).Replace($tcp[0].Extent.Text, '')
$text = $text.Replace('$tcp = [Net.Sockets.TcpClient]::new()', '$tcp = $null')
$call = @{
    ExpectedComputerName = 'FIXTUREHOST'; VaultName = 'kv-fixture'; SecretName = 'arc-onboarding-client-secret'
    PrivateAddressesBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('["10.50.1.10"]'))
    Operation = 'VerifyMarker'; MarkerVersionUri = $version; TlsMode = 'Tls12'
}
if ($Case -like 'Reader*') {
    $call.Operation = 'Read'; $call.Remove('MarkerVersionUri')
    $call.OnboardingVersionUri = $version; $call.ApplicationId = '11111111-1111-1111-1111-111111111111'
    $call.CredentialKeyId = '22222222-2222-2222-2222-222222222222'; $call.ExpiresAtUtc = $expiry.ToString('o')
    if ($Case -eq 'ReaderExpiring') { $call.ExpiresAtUtc = [datetimeoffset]::UtcNow.AddHours(1).ToString('o') }
}
$failed = $false; $safeError = $true; $script:proofLine = $null; $script:failureLine = $null
$script:secureResult = $false
try {
    & ([scriptblock]::Create($text)) @call | ForEach-Object {
        if ($_ -is [string] -and $_ -like 'ARC_PRIVATE_VAULT_RESULT:*') { $script:proofLine = $_ }
        elseif ($_ -is [string] -and $_ -like 'ARC_PRIVATE_VAULT_FAILURE:*') { $script:failureLine = $_ }
        elseif ($Case -like 'Reader*' -and $_ -is [securestring]) { $script:secureResult = $_.Length -gt 0; $_.Dispose() }
        else { throw 'Unexpected synthetic writer output.' }
    }
} catch { $failed = $true; $safeError = $_.Exception.Message -notmatch 'SENSITIVE_SENTINEL' }
@{
    psVersion = "$($PSVersionTable.PSVersion)"; failed = $failed; safeError = $safeError
    methods = @($script:methods); versionBound = $script:versionBound; disabled = $script:disabled
    proofLine = $script:proofLine; failureLine = $script:failureLine
    secureResult = $script:secureResult
} | ConvertTo-Json -Compress
