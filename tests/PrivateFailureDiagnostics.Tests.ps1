param([string]$SourceRoot = '')

BeforeAll {
    $repo = if ($SourceRoot) { [IO.Path]::GetFullPath($SourceRoot) } else { Split-Path $PSScriptRoot }
    Import-Module (Join-Path $repo 'scripts\lib\PrivateOnboarding.psm1') -Force
    if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
        function Resolve-DnsName { param($Name, $Type, [switch]$DnsOnly, [switch]$QuickTimeout) throw 'Synthetic DNS stub must be mocked.' }
    }
}

Describe 'Private failure proof projection' {
    BeforeEach {
        $data = @{
            status = 'fail'; operation = 'Marker'; stage = 'private-dns'; httpStatus = 0
            checkedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
        }
        $notBefore = [datetimeoffset]::UtcNow.AddMinutes(-1)
    }
    It 'distinguishes <stage> without inventing role propagation' -ForEach @(
        @{ stage = 'private-dns'; code = 0; category = 'dns' }
        @{ stage = 'private-tcp'; code = 0; category = 'tcp' }
        @{ stage = 'private-tls'; code = 0; category = 'tls' }
        @{ stage = 'parent-managed-identity'; code = 0; category = 'managed-identity' }
        @{ stage = 'private-secret-write'; code = 403; category = 'authorization-denied' }
        @{ stage = 'private-secret-readback'; code = 401; category = 'authorization-denied' }
    ) {
        $data.stage = $stage; $data.httpStatus = $code
        $proof = Get-DemoPrivateFailureProof -View @{
            output = 'ARC_PRIVATE_VAULT_FAILURE:' + ($data | ConvertTo-Json -Compress)
            error = 'SENSITIVE_SENTINEL'
        } -Operation Marker -NotBeforeUtc $notBefore
        $proof.stage | Should -Be $stage
        $proof.category | Should -Be $category
        $proof.evidence | Should -Be 'structured'
        $proof | ConvertTo-Json | Should -Not -Match 'SENSITIVE_SENTINEL|propagation'
    }
    It 'rejects <case> without masking terminal outcome or retaining supplied values' -ForEach @(
        @{ case = 'missing field'; change = { $data.Remove('stage') } }
        @{ case = 'null stage'; change = { $data.stage = $null } }
        @{ case = 'array stage'; change = { $data.stage = @('private-dns', 'SENSITIVE_SENTINEL') } }
        @{ case = 'noninteger HTTP'; change = { $data.httpStatus = '403' } }
        @{ case = 'out-of-range HTTP'; change = { $data.httpStatus = 999 } }
        @{ case = 'unknown stage'; change = { $data.stage = 'SENSITIVE_SENTINEL' } }
        @{ case = 'wrong operation'; change = { $data.operation = 'Initialize' } }
        @{ case = 'extra field'; change = { $data.secretValue = 'SENSITIVE_SENTINEL' } }
        @{ case = 'invalid time'; change = { $data.checkedAtUtc = 'SENSITIVE_SENTINEL' } }
        @{ case = 'stale time'; change = { $data.checkedAtUtc = $notBefore.AddMinutes(-1).ToString('o') } }
        @{ case = 'future time'; change = { $data.checkedAtUtc = [datetimeoffset]::UtcNow.AddMinutes(2).ToString('o') } }
    ) {
        & $change
        $proof = Get-DemoPrivateFailureProof -View @{
            error = 'ARC_PRIVATE_VAULT_FAILURE:' + ($data | ConvertTo-Json -Compress)
        } -Operation Marker -NotBeforeUtc $notBefore
        $proof.evidence | Should -Be 'malformed'
        $proof.stage | Should -Be 'unreported'
        $proof | ConvertTo-Json | Should -Not -Match 'SENSITIVE_SENTINEL'
    }
    It 'rejects duplicate markers rather than choosing an apparent cause' {
        $marker = 'ARC_PRIVATE_VAULT_FAILURE:' + ($data | ConvertTo-Json -Compress)
        $proof = Get-DemoPrivateFailureProof -View @{ output = "$marker`n$marker" } -Operation Marker
        $proof.evidence | Should -Be 'malformed'
    }
    It 'rejects unsafe extended <case> without copying supplied text' -ForEach @(
        @{ case = 'unknown reason'; change = { $data.reason = 'SENSITIVE_SENTINEL' } }
        @{ case = 'raw exception text'; change = { $data.errorType = 'SENSITIVE_SENTINEL' } }
        @{ case = 'extra metadata'; change = { $data.details.rawMetadata = 'SENSITIVE_SENTINEL' } }
        @{ case = 'invalid observed identity'; change = { $data.details.observedParentVmId = 'SENSITIVE_SENTINEL' } }
    ) {
        $data.reason = 'dns-request-failed'; $data.errorType = 'runtime'; $data.details = @{ addressEncoding = 'base64' }
        & $change
        $proof = Get-DemoPrivateFailureProof -View @{
            output = 'ARC_PRIVATE_VAULT_FAILURE:' + ($data | ConvertTo-Json -Depth 6 -Compress)
        } -Operation Marker
        $proof.evidence | Should -Be malformed
        $proof | ConvertTo-Json -Depth 6 | Should -Not -Match SENSITIVE_SENTINEL
    }
    It 'rejects malformed JSON without retaining arbitrary output' {
        $proof = Get-DemoPrivateFailureProof -View @{ output = 'ARC_PRIVATE_VAULT_FAILURE:{SENSITIVE_SENTINEL}' } -Operation Marker
        $proof.evidence | Should -Be 'malformed'
        $proof | ConvertTo-Json | Should -Not -Match 'SENSITIVE_SENTINEL'
    }
    It 'rejects unsafe TLS <case> evidence without copying its values' -ForEach @(
        @{ case = 'phase'; details = @{ tlsPhase = 'SENSITIVE_SENTINEL' } }
        @{ case = 'protocol type'; details = @{ tlsProtocolSelection = @('runtime-default') } }
        @{ case = 'task state'; details = @{ tlsTaskStatus = 'SENSITIVE_SENTINEL' } }
        @{ case = 'native error text'; details = @{ tlsNativeErrorCode = 'SENSITIVE_SENTINEL' } }
        @{ case = 'native error range'; details = @{ tlsNativeErrorCode = 4294967295L } }
        @{ case = 'arbitrary exception'; details = @{ tlsExceptionKinds = @('SENSITIVE_SENTINEL') } }
        @{ case = 'scalar exception'; details = @{ tlsExceptionKinds = 'authentication' } }
        @{ case = 'oversized chain'; details = @{ tlsExceptionKinds = @('other') * 7 } }
        @{ case = 'truncation type'; details = @{ tlsExceptionTruncated = 'SENSITIVE_SENTINEL' } }
    ) {
        $data.stage = 'private-tls'; $data.reason = 'tls-authentication-failed'
        $data.errorType = 'method-invocation'; $data.details = $details
        $proof = Get-DemoPrivateFailureProof -View @{ output = 'ARC_PRIVATE_VAULT_FAILURE:' + ($data | ConvertTo-Json -Depth 8 -Compress) } -Operation Marker
        $proof.evidence | Should -Be malformed
        $proof | ConvertTo-Json -Depth 8 | Should -Not -Match SENSITIVE_SENTINEL
    }
    It 'rejects oversized or nonstring service fields' -ForEach @(
        @{ value = ('SENSITIVE_SENTINEL' * 600) }
        @{ value = @('SENSITIVE_SENTINEL') }
    ) {
        $proof = Get-DemoPrivateFailureProof -View @{ output = $value } -Operation Marker
        $proof.evidence | Should -Be 'malformed'
        $proof | ConvertTo-Json | Should -Not -Match 'SENSITIVE_SENTINEL'
    }
    It 'recognizes the frozen writer legacy stage without claiming timestamped proof' {
        $proof = Get-DemoPrivateFailureProof -View @{
            error = 'Private writer failed during private-tcp-tls (HTTP 0). No fallback or retry; inspect sanitized stage evidence.'
        } -Operation Marker
        $proof.stage | Should -Be 'private-tcp-tls'
        $proof.category | Should -Be 'network-tls-unseparated'
        $proof.evidence | Should -Be 'legacy-sanitized-stage'
        $proof.checkedAtUtc | Should -BeNullOrEmpty
    }
    It 'recognizes a parser signature without copying source excerpts' {
        $proof = Get-DemoPrivateFailureProof -View @{ error = "SENSITIVE_SENTINEL`nFullyQualifiedErrorId : ParserError" } -Operation Marker
        $proof.stage | Should -Be 'script-parse'
        $proof | ConvertTo-Json | Should -Not -Match 'SENSITIVE_SENTINEL'
    }
    It 'does not fabricate a cause from missing or arbitrary output' -ForEach @(
        @{ view = @{} }
        @{ view = @{ output = 'SENSITIVE_SENTINEL'; error = 'SENSITIVE_SENTINEL' } }
    ) {
        $proof = Get-DemoPrivateFailureProof -View $view -Operation Marker
        $proof.stage | Should -Be 'unreported'
        $proof.evidence | Should -Be 'missing'
        $proof | ConvertTo-Json | Should -Not -Match 'SENSITIVE_SENTINEL'
    }
}

Describe 'Private writer failure output' {
    It 'emits only a structured sanitized stage on pre-network identity failure' {
        $writer = Join-Path $repo 'scripts\guest\Set-PrivateVaultSecret.ps1'
        $script:writerFailure = $null
        $output = @(& {
            try {
                & $writer -ExpectedComputerName "$($env:COMPUTERNAME)-foreign" -VaultName kv-fixture `
                    -SecretName arc-onboarding-client-secret -PrivateAddressesJson '["10.50.1.10"]' `
                    -Operation Marker -SecretValue SENSITIVE_SENTINEL
            } catch { $script:writerFailure = $_ }
        })
        $script:writerFailure | Should -Not -BeNullOrEmpty
        $proof = Get-DemoPrivateFailureProof -View @{ output = $output -join "`n" } -Operation Marker
        $proof.stage | Should -Be 'computer-name-validation'
        $proof.evidence | Should -Be 'structured'
        $output -join "`n" | Should -Not -Match 'SENSITIVE_SENTINEL'
    }

    Describe 'Private path diagnostic boundary' {
        BeforeEach {
            $script:originalComputerName = $env:COMPUTERNAME
            if (-not $env:COMPUTERNAME) { $env:COMPUTERNAME = 'fixture-parent' }
            $actor = Join-Path $repo 'scripts\guest\Test-PrivateVaultPath.ps1'
            $call = @{
                ExpectedComputerName = $env:COMPUTERNAME; ExpectedParentVmId = '99999999-9999-9999-9999-999999999999'
                VaultName = 'kv-fixture'; PrivateAddressesJson = '["10.50.1.10"]'
            }
            Mock Invoke-RestMethod { @{ vmId = '99999999-9999-9999-9999-999999999999' } }
            Mock Resolve-DnsName { throw 'SENSITIVE_SENTINEL' }
            $script:pathFailure = $null
        }
        AfterEach { $env:COMPUTERNAME = $script:originalComputerName }
        It 'reports DNS failure without requesting a token or reading/writing a secret' {
            $output = @(& { try { & $actor @call } catch { $script:pathFailure = $_ } })
            $script:pathFailure | Should -Not -BeNullOrEmpty
            $proof = Get-DemoPrivateFailureProof -View @{ output = $output -join "`n" } -Operation InspectPath
            $proof.stage | Should -Be private-dns
            $proof.evidence | Should -Be structured
            $output -join "`n" | Should -Not -Match SENSITIVE_SENTINEL
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01' }
            Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Uri -match 'oauth2|/secrets/' }
        }
        It 'rejects a changed immutable parent before any DNS/TCP/TLS access' {
            Mock Invoke-RestMethod { @{ vmId = '88888888-8888-8888-8888-888888888888' } }
            $output = @(& { try { & $actor @call } catch { $script:pathFailure = $_ } })
            $proof = Get-DemoPrivateFailureProof -View @{ output = $output -join "`n" } -Operation InspectPath
            $proof.stage | Should -Be parent-vm-id-validation
            Should -Invoke Resolve-DnsName -Times 0
        }
        It 'rejects public, duplicate and malformed endpoint addresses before DNS' -ForEach @(
            @{ addresses = '["1.2.3.4"]' }
            @{ addresses = '["10.50.1.10","10.50.1.10"]' }
            @{ addresses = '["SENSITIVE_SENTINEL"]' }
        ) {
            $call.PrivateAddressesJson = $addresses
            $output = @(& { try { & $actor @call } catch { $script:pathFailure = $_ } })
            $proof = Get-DemoPrivateFailureProof -View @{ output = $output -join "`n" } -Operation InspectPath
            $proof.stage | Should -Be private-address-schema
            $output -join "`n" | Should -Not -Match SENSITIVE_SENTINEL
            Should -Invoke Resolve-DnsName -Times 0
        }
        It 'rejects foreign DNS answers before opening any socket' {
            Mock Resolve-DnsName { [pscustomobject]@{ Type = 'A'; IPAddress = '1.2.3.4' } }
            $output = @(& { try { & $actor @call } catch { $script:pathFailure = $_ } })
            $proof = Get-DemoPrivateFailureProof -View @{ output = $output -join "`n" } -Operation InspectPath
            $proof.stage | Should -Be private-dns-answers
            $script:pathFailure | Should -Not -BeNullOrEmpty
        }
    }
}
