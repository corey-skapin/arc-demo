#Requires -Version 7.4
Set-StrictMode -Version Latest

function Get-DemoHttpFailureStatus {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$Record)
    if ($Record.Exception.PSObject.Properties['Response'] -and $Record.Exception.Response) { return [int]$Record.Exception.Response.StatusCode }
    return 0
}

function Get-DemoArmResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ResourceId, [Parameter(Mandatory)][string]$ApiVersion, [switch]$AllowNotFound)
    try { Invoke-AzRest -Method GET -Url "https://management.azure.com${ResourceId}?api-version=$ApiVersion" }
    catch {
        if ($AllowNotFound -and (Get-DemoHttpFailureStatus -Record $_) -eq 404) { return $null }
        throw
    }
}

function Get-DemoPrivatePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][guid]$SubscriptionId, [Parameter(Mandatory)][guid]$TenantId)
    $plan = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    $fields = @('schemaVersion', 'subscriptionId', 'tenantId', 'namePrefix', 'location', 'vaultResourceId', 'vnetResourceId',
        'subnetResourceId', 'subnetAddressPrefix', 'applicationId', 'applicationObjectId', 'servicePrincipalObjectId', 'deployerPrincipalId', 'parents', 'writerParentResourceId')
    if ($plan -isnot [System.Collections.IDictionary] -or $plan.schemaVersion -ne 1 -or
        @($plan.Keys | Where-Object { $_ -notin $fields }).Count -or
        @($fields | Where-Object { -not $plan.Contains($_) }).Count -or
        $plan.subscriptionId -ne "$SubscriptionId" -or $plan.tenantId -ne "$TenantId") { throw 'Private onboarding plan schema/explicit target mismatch.' }
    Assert-DemoName $plan.namePrefix
    if ($plan.subnetAddressPrefix -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$') { throw 'Private plan subnet prefix must be explicit IPv4 CIDR.' }
    $scope = "/subscriptions/$SubscriptionId/resourceGroups/rg-$($plan.namePrefix)-infra"
    $patterns = @{
        vaultResourceId = [regex]::Escape("$scope/providers/Microsoft.KeyVault/vaults/") + '[a-zA-Z0-9-]{3,24}'
        vnetResourceId = [regex]::Escape("$scope/providers/Microsoft.Network/virtualNetworks/vnet-$($plan.namePrefix)")
        subnetResourceId = [regex]::Escape("$scope/providers/Microsoft.Network/virtualNetworks/vnet-$($plan.namePrefix)/subnets/snet-vms")
    }
    foreach ($key in $patterns.Keys) {
        if ($plan[$key] -notmatch ('^' + $patterns[$key] + '$')) { throw "Private plan $key is outside the exact approved infra target." }
    }
    foreach ($key in @('applicationId', 'applicationObjectId', 'servicePrincipalObjectId', 'deployerPrincipalId')) {
        $id = [guid]::Empty
        if (-not [guid]::TryParse($plan[$key], [ref]$id) -or $id -eq [guid]::Empty) { throw "Private plan $key must be a nonempty GUID." }
    }
    if ($plan.parents -isnot [array] -or $plan.parents.Count -ne 2) { throw 'This onboarding contract requires exactly two existing parent identities.' }
    $seen = @{}
    foreach ($parent in $plan.parents) {
        if (@($parent.Keys | Where-Object { $_ -notin @('resourceId', 'principalId', 'vmId') }).Count -or
            $parent.resourceId -notmatch ('^' + [regex]::Escape("$scope/providers/Microsoft.Compute/virtualMachines/") + '[A-Za-z0-9._-]+$') -or
            $seen.ContainsKey([string]$parent.resourceId)) { throw 'Private plan parent is foreign, duplicate or malformed.' }
        foreach ($key in @('principalId', 'vmId')) {
            $id = [guid]::Empty
            if (-not [guid]::TryParse($parent[$key], [ref]$id) -or $id -eq [guid]::Empty) { throw 'Parent VM/managed identity must be pinned explicitly.' }
        }
        $seen[$parent.resourceId] = $true
    }
    if (-not $seen.ContainsKey([string]$plan.writerParentResourceId) -or $plan.location -notmatch '^[a-z0-9]+$') { throw 'Private plan writer/location is invalid.' }
    return $plan
}

function Invoke-DemoGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method, [Parameter(Mandatory)][string]$Path, [object]$Body)
    if ($Path -notmatch '^/v1\.0/(applications|servicePrincipals)/[0-9a-f-]{36}(?:/addPassword|/removePassword|\?.*)?$') { throw 'Graph operation outside the exact application/SP contract.' }
    $token = Invoke-DemoAz -Arguments @('account', 'get-access-token', '--resource-type', 'ms-graph', '--query', 'accessToken', '-o', 'tsv')
    try {
        $options = @{ Method = $Method; Uri = "https://graph.microsoft.com$Path"; Headers = @{ Authorization = "Bearer $token" }; TimeoutSec = 60 }
        if ($PSBoundParameters.ContainsKey('Body')) { $options.Body = $Body | ConvertTo-Json -Depth 8 -Compress; $options.ContentType = 'application/json' }
        Invoke-RestMethod @options
    } catch {
        $status = Get-DemoHttpFailureStatus -Record $_
        throw "Exact Graph $Method failed/unknown (HTTP $status); no retry or credential reset."
    } finally { $token = $null; $options = $null }
}

function Get-DemoRoleAssignmentName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Scope, [Parameter(Mandatory)][string]$PrincipalId, [Parameter(Mandatory)][string]$RoleId)
    # ARM guid() is UUIDv5 over hyphen-joined arguments with this published namespace.
    $namespace = ([guid]'11fb06fb-712d-4ddd-98c7-e71bbd588830').ToByteArray()
    [array]::Reverse($namespace, 0, 4); [array]::Reverse($namespace, 4, 2); [array]::Reverse($namespace, 6, 2)
    $hash = [Security.Cryptography.SHA1]::HashData([byte[]]($namespace + [text.encoding]::UTF8.GetBytes("$Scope-$PrincipalId-$RoleId")))
    $bytes = [byte[]]$hash[0..15]
    $bytes[6] = ($bytes[6] -band 0x0f) -bor 0x50
    $bytes[8] = ($bytes[8] -band 0x3f) -bor 0x80
    [array]::Reverse($bytes, 0, 4); [array]::Reverse($bytes, 4, 2); [array]::Reverse($bytes, 6, 2)
    ([guid]::new($bytes)).ToString()
}

function Get-DemoPrivateFailureProof {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$View, [Parameter(Mandatory)][string]$Operation, [datetimeoffset]$NotBeforeUtc = [datetimeoffset]::MinValue)
    $stages = @('identity-validation', 'private-dns', 'private-tcp-tls', 'private-tcp', 'private-tls',
        'parent-managed-identity', 'credential-metadata', 'private-secret-write', 'private-secret-readback', 'enable-existing-marker', 'disable-bootstrap-marker',
        'computer-name-validation', 'parent-metadata-request', 'parent-metadata-shape', 'parent-vm-id-validation',
        'private-address-decode', 'private-address-json', 'private-address-schema', 'private-dns-answers')
    $proof = [ordered]@{
        stage = 'unreported'; httpStatus = 0; category = 'execution-unreported'; evidence = 'missing'; checkedAtUtc = $null
        reason = 'unreported'; errorType = 'unknown'; details = $null
    }
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($field in @('output', 'error')) {
        if (($View -is [System.Collections.IDictionary] -and $View.Contains($field)) -or $View.PSObject.Properties[$field]) {
            $value = $View.$field
            if ($null -ne $value -and ($value -isnot [string] -or $value.Length -gt 8192)) {
                $proof.evidence = 'malformed'
                return [pscustomobject]$proof
            }
            if ($null -ne $value) { $parts.Add($value) }
        }
    }
    $text = $parts -join "`n"
    $failureMatches = [regex]::Matches($text, '(?m)^ARC_PRIVATE_VAULT_FAILURE:(\{[^\r\n]{1,2048}\})\s*$')
    if ($failureMatches.Count) {
        $proof.evidence = 'malformed'
        if ($failureMatches.Count -ne 1) { return [pscustomobject]$proof }
        try { $data = $failureMatches[0].Groups[1].Value | ConvertFrom-Json -AsHashtable -Depth 5 -ErrorAction Stop }
        catch { return [pscustomobject]$proof }
        $fields = @('status', 'operation', 'stage', 'httpStatus', 'checkedAtUtc')
        $extended = @('reason', 'errorType', 'details')
        if ($data -isnot [System.Collections.IDictionary] -or
            @($data.Keys | Where-Object { $_ -notin ($fields + $extended) }).Count -or @($fields | Where-Object { -not $data.Contains($_) }).Count) {
            return [pscustomobject]$proof
        }
        if ($data.status -isnot [string] -or $data.operation -isnot [string] -or $data.stage -isnot [string] -or
            $data.status -cne 'fail' -or $data.operation -cne $Operation -or $data.stage -notin $stages -or
            ($data.httpStatus -isnot [int] -and $data.httpStatus -isnot [long]) -or $data.httpStatus -lt 0 -or $data.httpStatus -gt 599) {
            return [pscustomobject]$proof
        }
        $time = [datetimeoffset]::MinValue
        # Newer ConvertFrom-Json versions convert ISO strings to DateTime automatically.
        if ($data.checkedAtUtc -is [datetime] -or $data.checkedAtUtc -is [datetimeoffset]) { $time = [datetimeoffset]$data.checkedAtUtc }
        elseif ($data.checkedAtUtc -isnot [string] -or -not [datetimeoffset]::TryParse($data.checkedAtUtc, [ref]$time)) { return [pscustomobject]$proof }
        if ($time -lt $NotBeforeUtc -or $time -gt [datetimeoffset]::UtcNow.AddSeconds(30)) { return [pscustomobject]$proof }
        if (@($extended | Where-Object { $data.Contains($_) }).Count) {
            $reasons = @('target-invalid', 'computer-name-invalid', 'computer-name-mismatch', 'metadata-request-failed',
                'metadata-vm-id-invalid', 'parent-vm-id-mismatch', 'address-encoding-invalid', 'address-json-invalid',
                'address-schema-invalid', 'dns-request-failed', 'dns-address-mismatch', 'tcp-connect-failed',
                'tls-authentication-failed', 'tls-authentication-timeout', 'managed-identity-token-failed', 'credential-metadata-invalid',
                'secret-write-failed', 'secret-readback-failed', 'marker-disable-failed')
            if (@($extended | Where-Object { -not $data.Contains($_) }).Count -or
                $data.reason -isnot [string] -or $data.reason -notin $reasons -or
                $data.errorType -isnot [string] -or $data.errorType -notin @('invalid-input', 'http-request', 'command-unavailable', 'method-invocation', 'runtime') -or
                $data.details -isnot [System.Collections.IDictionary]) { return [pscustomobject]$proof }
            $detailFields = @('expectedComputerName', 'observedComputerName', 'expectedParentVmId', 'observedParentVmId',
                'addressEncoding', 'addressPayloadLength', 'addressHasQuotes', 'addressCount', 'addressElementKind',
                'tlsPhase', 'tlsProtocolSelection', 'tlsTaskStatus', 'tlsNativeErrorCode', 'tlsExceptionKinds', 'tlsExceptionTruncated')
            if (@($data.details.Keys | Where-Object { $_ -notin $detailFields }).Count) { return [pscustomobject]$proof }
            foreach ($key in $data.details.Keys) {
                $value = $data.details[$key]
                if ($key -in @('expectedComputerName', 'observedComputerName')) {
                    if ($null -ne $value -and ($value -isnot [string] -or $value -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')) { return [pscustomobject]$proof }
                } elseif ($key -in @('expectedParentVmId', 'observedParentVmId')) {
                    $id = [guid]::Empty
                    if ($null -ne $value -and ($value -isnot [string] -or -not [guid]::TryParseExact($value, 'D', [ref]$id))) { return [pscustomobject]$proof }
                } elseif ($key -in @('addressPayloadLength', 'addressCount')) {
                    if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt [int]::MaxValue) { return [pscustomobject]$proof }
                } elseif ($key -eq 'addressHasQuotes') {
                    if ($value -isnot [bool]) { return [pscustomobject]$proof }
                } elseif ($key -eq 'addressEncoding') {
                    if ($value -isnot [string] -or $value -notin @('json', 'base64')) { return [pscustomobject]$proof }
                } elseif ($key -eq 'addressElementKind') {
                    if ($value -isnot [string] -or $value -notin @('unparsed', 'string', 'array', 'object')) { return [pscustomobject]$proof }
                } elseif ($key -eq 'tlsPhase') {
                    if ($value -isnot [string] -or $value -notin @('stream-create', 'authenticate-start', 'authenticate-wait', 'authenticate-verify')) { return [pscustomobject]$proof }
                } elseif ($key -eq 'tlsProtocolSelection') {
                    if ($value -isnot [string] -or $value -cnotin @('runtime-default', 'tls12')) { return [pscustomobject]$proof }
                } elseif ($key -eq 'tlsTaskStatus') {
                    if ($value -isnot [string] -or $value -notin @('not-created', 'Created', 'WaitingForActivation', 'WaitingToRun',
                        'Running', 'WaitingForChildrenToComplete', 'RanToCompletion', 'Canceled', 'Faulted')) { return [pscustomobject]$proof }
                } elseif ($key -eq 'tlsNativeErrorCode') {
                    if ($null -ne $value -and (($value -isnot [int] -and $value -isnot [long]) -or $value -lt [int]::MinValue -or $value -gt [int]::MaxValue)) { return [pscustomobject]$proof }
                } elseif ($key -eq 'tlsExceptionTruncated') {
                    if ($value -isnot [bool]) { return [pscustomobject]$proof }
                } elseif ($key -eq 'tlsExceptionKinds') {
                    if ($value -isnot [array] -or $value.Count -lt 1 -or $value.Count -gt 6 -or
                        @($value | Where-Object { $_ -isnot [string] -or $_ -notin @('method-invocation', 'aggregate',
                            'authentication', 'win32', 'io', 'socket', 'timeout', 'argument', 'invalid-operation', 'unsupported', 'other') }).Count) {
                        return [pscustomobject]$proof
                    }
                }
            }
            $proof.reason = $data.reason; $proof.errorType = $data.errorType; $proof.details = $data.details
        }
        $proof.stage = $data.stage; $proof.httpStatus = $data.httpStatus; $proof.checkedAtUtc = $time.UtcDateTime.ToString('o')
        $proof.evidence = 'structured'
    } elseif ($text -match '(?m)^ARC_PRIVATE_VAULT_FAILURE:') {
        $proof.evidence = 'malformed'
    } elseif ($text -match 'Private writer failed during ([a-z-]+) \(HTTP ([0-9]{1,3})\)\. No fallback or retry; inspect sanitized stage evidence\.') {
        if ($Matches[1] -in $stages -and [int]$Matches[2] -le 599) {
            $proof.stage = $Matches[1]; $proof.httpStatus = [int]$Matches[2]; $proof.evidence = 'legacy-sanitized-stage'
        }
    } elseif ($text -match 'FullyQualifiedErrorId\s*:\s*ParserError|System\.Management\.Automation\.ParseException') {
        $proof.stage = 'script-parse'; $proof.evidence = 'parser-signature'
    }
    $proof.category = if ($proof.httpStatus -in @(401, 403)) { 'authorization-denied' }
        elseif ($proof.stage -in @('private-dns', 'private-dns-answers')) { 'dns' }
        elseif ($proof.stage -eq 'private-tcp') { 'tcp' }
        elseif ($proof.stage -eq 'private-tls') { 'tls' }
        elseif ($proof.stage -eq 'private-tcp-tls') { 'network-tls-unseparated' }
        elseif ($proof.stage -eq 'parent-managed-identity') { 'managed-identity' }
        elseif ($proof.stage -eq 'script-parse') { 'script-parse' }
        elseif ($proof.stage -in @('identity-validation', 'computer-name-validation', 'parent-vm-id-validation')) { 'identity' }
        elseif ($proof.stage -in @('parent-metadata-request', 'parent-metadata-shape')) { 'parent-metadata' }
        elseif ($proof.stage -in @('private-address-decode', 'private-address-json', 'private-address-schema')) { 'address-input' }
        elseif ($proof.stage -in @('private-secret-write', 'private-secret-readback', 'enable-existing-marker', 'disable-bootstrap-marker')) { 'secret-operation' }
        elseif ($proof.stage -eq 'credential-metadata') { 'credential-metadata' }
        else { 'execution-unreported' }
    [pscustomobject]$proof
}

function ConvertTo-DemoPrivateProofTime {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [datetimeoffset]) { return $Value }
    if ($Value -is [datetime] -and $Value.Kind -ne [DateTimeKind]::Unspecified) { return [datetimeoffset]$Value }
    if ($Value -is [string] -and $Value -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}(?:Z|[+-]\d\d:\d\d)$') {
        return [datetimeoffset]::ParseExact($Value, 'o', [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
    }
    throw 'Private proof timestamp is not an explicit round-trip instant.'
}

function Get-DemoPrivateWriterProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][ValidateSet('Marker', 'VerifyMarker', 'Initialize')][string]$Operation,
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string[]]$PrivateAddresses,
        [Parameter(Mandatory)][datetimeoffset]$NotBeforeUtc,
        [string]$ExpiresAtUtc = ''
    )
    $reason = 'writer-envelope'
    try {
        if ($Output.Length -gt 8192) { throw 'Output is oversized.' }
        $proofMatches = [regex]::Matches($Output, '(?m)^ARC_PRIVATE_VAULT_RESULT:(\{[^\r\n]{1,4096}\})\s*$')
        if ($proofMatches.Count -ne 1) { throw 'Unique bounded writer result required.' }
        $reason = 'writer-json'
        $data = $proofMatches[0].Groups[1].Value | ConvertFrom-Json -AsHashtable -Depth 10 -ErrorAction Stop
        $reason = 'writer-schema'
        $fields = @('status', 'operation', 'secretVersionUri', 'privateAddresses', 'tlsVerified', 'valueVerified', 'enabled', 'expiresAtUtc', 'checkedAtUtc')
        if ($data -isnot [Collections.IDictionary] -or @($data.Keys | Where-Object { $_ -notin $fields }).Count -or
            @($fields | Where-Object { -not $data.Contains($_) }).Count -or
            $data.status -isnot [string] -or $data.status -cne 'pass' -or
            $data.operation -isnot [string] -or $data.operation -cne $Operation -or
            $data.tlsVerified -isnot [bool] -or -not $data.tlsVerified -or
            $data.valueVerified -isnot [bool] -or -not $data.valueVerified -or
            $data.enabled -isnot [bool] -or $data.enabled -ne ($Operation -eq 'Initialize') -or
            $data.privateAddresses -isnot [array] -or -not $data.privateAddresses.Count -or
            @($data.privateAddresses | Where-Object { $_ -isnot [string] }).Count -or
            @($data.privateAddresses | Sort-Object -Unique).Count -ne $data.privateAddresses.Count -or
            @(Compare-Object @($data.privateAddresses | Sort-Object) @($PrivateAddresses | Sort-Object)).Count -or
            $data.secretVersionUri -isnot [string] -or
            $data.secretVersionUri -notmatch ('^https://' + [regex]::Escape("$VaultName.vault.azure.net/secrets/arc-onboarding-client-secret/") + '[0-9a-f]{32}$')) {
            throw 'Writer fields do not match exact nonsecret contract.'
        }
        $reason = 'writer-timestamp'
        $checked = ConvertTo-DemoPrivateProofTime -Value $data.checkedAtUtc
        $reason = 'writer-freshness'
        if ($checked -lt $NotBeforeUtc -or $checked -gt [datetimeoffset]::UtcNow.AddSeconds(30)) { throw 'Writer proof is outside its execution window.' }
        $reason = 'writer-expiry'
        if ($Operation -ne 'Initialize') {
            if ($data.expiresAtUtc -isnot [string] -or $data.expiresAtUtc -cne '') { throw 'Marker cannot carry credential expiry.' }
        } else {
            $expiry = ConvertTo-DemoPrivateProofTime -Value $data.expiresAtUtc
            if ($expiry -ne (ConvertTo-DemoPrivateProofTime -Value $ExpiresAtUtc)) { throw 'Writer expiry differs.' }
            $data.expiresAtUtc = $expiry.UtcDateTime.ToString('o')
        }
        $data.checkedAtUtc = $checked.UtcDateTime.ToString('o')
        return $data
    } catch {
        $rejection = [InvalidOperationException]::new("Protected writer completion proof rejected: $reason; no semantic success or retry.")
        $rejection.Data['ArcPrivateProofReason'] = $reason
        throw $rejection
    }
}

function Invoke-DemoProtectedVaultCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parent,
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string[]]$PrivateAddresses,
        [Parameter(Mandatory)][ValidateSet('Marker', 'VerifyMarker', 'Initialize', 'InspectPath')][string]$Operation,
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][string]$EvidencePath,
        [ValidateSet('RuntimeDefault', 'Tls12')][string]$TlsMode = 'RuntimeDefault',
        [string]$SecretValue = '',
        [string]$ApplicationId = '',
        [guid]$CredentialKeyId = [guid]::Empty,
        [string]$ExpiresAtUtc = '',
        [string]$MarkerVersionUri = ''
    )
    $commandId = "$($Parent.resourceId)/runCommands/$CommandName"
    if ($CommandName -notmatch '^arc-onboarding-[a-z0-9-]{1,45}$') { throw 'Invalid protected command ownership name.' }
    if (Test-Path -LiteralPath $EvidencePath) { throw 'Protected-command receipt already exists; preserve evidence, never overwrite or replay.' }
    $sourcePath = Join-Path $PSScriptRoot '..\guest\Set-PrivateVaultSecret.ps1'
    if ($Operation -eq 'InspectPath') {
        if ($SecretValue -or $ApplicationId -or $CredentialKeyId -ne [guid]::Empty -or $ExpiresAtUtc) { throw 'Network inspection cannot accept credential input.' }
        $sourcePath = Join-Path $PSScriptRoot '..\guest\Test-PrivateVaultPath.ps1'
    }
    if ($Operation -eq 'VerifyMarker') {
        if ($SecretValue -or $ApplicationId -or $CredentialKeyId -ne [guid]::Empty -or $ExpiresAtUtc -or
            $MarkerVersionUri -notmatch ('^https://' + [regex]::Escape("$VaultName.vault.azure.net/secrets/arc-onboarding-client-secret/") + '[0-9a-f]{32}$')) {
            throw 'Existing marker verification requires one exact version and no credential input.'
        }
    } elseif ($MarkerVersionUri) { throw 'Marker version is valid only for existing-marker verification.' }
    $addressesBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($PrivateAddresses) -Compress)))
    if (Get-DemoArmResource -ResourceId $commandId -ApiVersion '2025-11-01' -AllowNotFound) { throw 'Protected command already exists. Inspect it; never replay an owned operation.' }
    $parameters = @{
        ExpectedComputerName = $Parent.computerName; VaultName = $VaultName; SecretName = 'arc-onboarding-client-secret'
        PrivateAddressesBase64 = $addressesBase64; Operation = $Operation; TlsMode = $TlsMode
        ApplicationId = $ApplicationId; CredentialKeyId = $CredentialKeyId; ExpiresAtUtc = $ExpiresAtUtc
    }
    if ($Operation -eq 'VerifyMarker') { $parameters.MarkerVersionUri = $MarkerVersionUri }
    if ($Operation -eq 'InspectPath') {
        $parameters = @{
            ExpectedComputerName = $Parent.computerName; ExpectedParentVmId = $Parent.vmId
            VaultName = $VaultName; PrivateAddressesBase64 = $addressesBase64; TlsMode = $TlsMode
        }
    }
    $body = @{
        location = $Parent.location
        tags = @{ managedBy = 'arc-demo-private-onboarding' }
        properties = @{
            source = @{ script = Get-Content -LiteralPath $sourcePath -Raw }
            timeoutInSeconds = $(if ($Operation -eq 'InspectPath') { 90 } else { 180 }); asyncExecution = $false; treatFailureAsDeploymentFailure = $true
            parameters = @($parameters.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = [string]$_.Value } })
            protectedParameters = @(@{ name = 'SecretValue'; value = $SecretValue })
        }
    }
    if ($Operation -in @('InspectPath', 'VerifyMarker')) { $body.properties.Remove('protectedParameters') }
    $receipt = [ordered]@{
        resourceId = $commandId; parentVmId = $Parent.vmId
        sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        state = 'submission-unknown'; status = 'unknown'; exitCode = $null; result = $null; failure = $null; deleted = $false; errors = @()
        tlsMode = $TlsMode; completionProofFailure = $null
    }
    $terminal = $false
    $submitted = [datetimeoffset]::UtcNow
    $stage = 'submission'
    $failures = [Collections.Generic.List[string]]::new()
    try {
        Invoke-AzRest -Method PUT -Url "https://management.azure.com${commandId}?api-version=2025-11-01" -Body $body | Out-Null
        $deadline = [datetime]::UtcNow.AddMinutes(5)
        do {
            $stage = 'execution-poll'
            $actual = Invoke-AzRest -Method GET -Url "https://management.azure.com${commandId}?api-version=2025-11-01&`$expand=instanceView"
            if ($actual.id -ne $commandId -or $actual.tags.managedBy -ne 'arc-demo-private-onboarding' -or
                $actual.properties.source.script -cne $body.properties.source.script) { throw 'Owned protected command identity/source drift.' }
            $view = if ($actual.properties.PSObject.Properties['instanceView']) { $actual.properties.instanceView } else { $null }
            if ($view -and $view.executionState -notin @('Unknown', 'Pending', 'Running', 'Succeeded', 'Failed', 'Canceled', 'TimedOut')) { throw 'Unrecognized command state.' }
            $receipt.state = if ($view) { $view.executionState } else { 'Pending' }
            if ($view -and $view.executionState -in @('Succeeded', 'Failed', 'Canceled', 'TimedOut')) {
                $terminal = $true
                $receipt.exitCode = $view.exitCode
                if ($view.executionState -ne 'Succeeded' -or $view.exitCode -ne 0) {
                    $receipt.failure = Get-DemoPrivateFailureProof -View $view -Operation $Operation -NotBeforeUtc $submitted.AddSeconds(-5)
                    throw 'Protected private writer failed; no alternate route or retry.'
                }
                $stage = 'completion-proof'
                $output = [string]$view.output
                if ($Operation -eq 'InspectPath') {
                    $pathMatches = [regex]::Matches($output, '(?m)^ARC_PRIVATE_PATH_RESULT:(\{[^\r\n]{1,2048}\})\s*$')
                    if ($pathMatches.Count -ne 1) { throw 'Private path completion proof missing/malformed.' }
                    $data = $pathMatches[0].Groups[1].Value | ConvertFrom-Json -AsHashtable -Depth 5
                    $allowed = @('status', 'operation', 'parentVmId', 'privateAddresses', 'tlsVerified', 'checkedAtUtc', 'tlsProtocolSelection')
                    if ($data -isnot [System.Collections.IDictionary] -or @($data.Keys | Where-Object { $_ -notin $allowed }).Count -or
                        @($allowed | Where-Object { -not $data.Contains($_) }).Count) { throw 'Private path proof schema mismatch.' }
                    if ($data.status -isnot [string] -or $data.operation -isnot [string] -or $data.parentVmId -isnot [string] -or
                        $data.status -cne 'pass' -or $data.operation -cne $Operation -or $data.parentVmId -cne $Parent.vmId -or
                        $data.tlsProtocolSelection -cne $(if ($TlsMode -eq 'Tls12') { 'tls12' } else { 'runtime-default' }) -or
                        $data.tlsVerified -isnot [bool] -or -not $data.tlsVerified -or $data.privateAddresses -isnot [array] -or
                        -not $data.privateAddresses.Count -or @($data.privateAddresses | Where-Object { $_ -isnot [string] }).Count -or
                        @($data.privateAddresses | Sort-Object -Unique).Count -ne $data.privateAddresses.Count -or
                        @(Compare-Object @($data.privateAddresses | Sort-Object -Unique) @($PrivateAddresses | Sort-Object -Unique)).Count) {
                        throw 'Private path proof identity/address/TLS mismatch.'
                    }
                    $checked = [datetimeoffset]$data.checkedAtUtc
                    if ($checked -lt $submitted.AddSeconds(-5) -or $checked -gt [datetimeoffset]::UtcNow.AddSeconds(30)) { throw 'Private path proof freshness mismatch.' }
                    $receipt.result = $data
                    $receipt.status = 'pass'
                    break
                }
                $data = Get-DemoPrivateWriterProof -Output $output -Operation $Operation -VaultName $VaultName `
                    -PrivateAddresses $PrivateAddresses -NotBeforeUtc $submitted.AddSeconds(-5) -ExpiresAtUtc $ExpiresAtUtc
                if ($Operation -eq 'VerifyMarker' -and $data.secretVersionUri -cne $MarkerVersionUri) { throw 'Existing marker proof returned a different version.' }
                $receipt.result = $data
                $receipt.status = 'pass'
                break
            }
            if ([datetime]::UtcNow -ge $deadline) { throw 'Protected writer state unknown/running at deadline; retain its lane, never resubmit or cancel.' }
            Start-Sleep -Seconds 5
        } while ($true)
    } catch {
        $receipt.status = if ($terminal) { 'fail' } else { 'unknown' }
        if ($_.Exception.Data.Contains('ArcPrivateProofReason')) { $receipt.completionProofFailure = [string]$_.Exception.Data['ArcPrivateProofReason'] }
        if ($receipt.failure) {
            $failures.Add("Protected writer terminal failure at $($receipt.failure.stage), category=$($receipt.failure.category), HTTP $($receipt.failure.httpStatus), evidence=$($receipt.failure.evidence), reason=$($receipt.failure.reason), errorType=$($receipt.failure.errorType); inspect receipt, no automatic regrant/retry.")
        } else {
            $failures.Add("Protected writer failed/unknown at $stage (HTTP $(Get-DemoHttpFailureStatus -Record $_)); inspect its nonsecret receipt, never retry/cancel an unknown operation.")
        }
    } finally {
        $body = $null; $SecretValue = $null
        $evidenceSaved = $false
        try {
            $receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $EvidencePath -Encoding utf8 -ErrorAction Stop
            $evidenceSaved = $true
        }
        catch { $failures.Add('Nonsecret protected-command evidence could not be saved.') }
        if ($terminal -and $evidenceSaved) {
            try {
                Invoke-AzRest -Method DELETE -Url "https://management.azure.com${commandId}?api-version=2025-11-01" | Out-Null
                if (Get-DemoArmResource -ResourceId $commandId -ApiVersion '2025-11-01' -AllowNotFound) { throw 'Command still exists.' }
                $receipt.deleted = $true
                $receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
            } catch {
                $receipt.status = 'fail'
                $failures.Add('Terminal protected-command cleanup/evidence not verified; retain this command ID for explicit recovery.')
            }
        } elseif ($terminal) {
            $receipt.status = 'fail'
            $failures.Add("Terminal protected command $commandId retained because its diagnostic receipt was not saved; no automatic deletion/replay.")
        }
        if ($failures.Count) {
            if ($terminal) { $receipt.status = 'fail' }
            $receipt.errors = @($failures)
            try { $receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $EvidencePath -Encoding utf8 }
            catch { $failures.Add('Final nonsecret command error evidence could not be saved.') }
        }
    }
    if ($failures.Count) { throw ($failures -join ' ') }
    [pscustomobject]$receipt
}

Export-ModuleMember -Function Get-DemoArmResource, Get-DemoPrivatePlan, Invoke-DemoGraph, Get-DemoRoleAssignmentName, Get-DemoPrivateFailureProof, Get-DemoPrivateWriterProof, Invoke-DemoProtectedVaultCommand
