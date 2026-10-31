param([string]$SourceRoot = '')

BeforeAll {
    $repo = if ($SourceRoot) { [IO.Path]::GetFullPath($SourceRoot) } else { Split-Path $PSScriptRoot }
    Import-Module (Join-Path $repo 'scripts\lib\PrivateOnboarding.psm1') -Force
    function Invoke-PrivatePs5Fixture {
        param([string]$Actor, [string]$Case = 'DnsFailure', [string]$Json = '["10.50.1.10"]', [switch]$RawJson, [switch]$Tls, [switch]$Http, [string]$TlsMode = 'RuntimeDefault')
        $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $harness = Join-Path $repo 'tests\fixtures\PrivatePath.Ps5Harness.ps1'
        $source = Join-Path $repo $(if ($Actor -eq 'Inspector') { 'scripts\guest\Test-PrivateVaultPath.ps1' } else { 'scripts\guest\Set-PrivateVaultSecret.ps1' })
        $payload = if ($RawJson) { $Json } else { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Json)) }
        $encoding = if ($RawJson) { 'Json' } else { 'Base64' }
        $arguments = "-NoProfile -NonInteractive -File `"$harness`" -ActorPath `"$source`" -ActorKind $Actor -Case $Case -Encoding $encoding -Payload $payload"
        if ($Tls) {
            $harness = Join-Path $repo 'tests\fixtures\PrivateTls.Ps5Harness.ps1'
            $arguments = "-NoProfile -NonInteractive -File `"$harness`" -ActorPath `"$source`" -Case $Case -TlsMode $TlsMode"
        }
        if ($Http) {
            $harness = Join-Path $repo 'tests\fixtures\PrivateHttp.Ps5Harness.ps1'
            $arguments = "-NoProfile -NonInteractive -File `"$harness`" -ActorPath `"$source`" -Case $Case"
        }
        $start = [Diagnostics.ProcessStartInfo]::new($exe, $arguments)
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $start.EnvironmentVariables['PSModulePath'] = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules;$env:ProgramFiles\WindowsPowerShell\Modules"
        $process = [Diagnostics.Process]::Start($start)
        try {
            if (-not $process.WaitForExit(30000)) {
                Stop-Process -Id $process.Id
                throw 'Synthetic PS5 fixture exceeded its 30-second local bound.'
            }

            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            if ($process.ExitCode -ne 0) { throw "Synthetic PS5 fixture failed (exit $($process.ExitCode), stderr length $($stderr.Length)); no raw arguments or error output." }
            $stdout | ConvertFrom-Json -Depth 12
        } finally { $process.Dispose() }
    }
}

Describe 'Native Windows PowerShell 5.1 private path regression' -Skip:(-not [OperatingSystem]::IsWindows()) {
    It 'normalizes JSON and carries quote-free native parameters for <actor>' -ForEach @(
        @{ actor = 'Inspector' }
        @{ actor = 'Marker' }
    ) {
        $result = Invoke-PrivatePs5Fixture -Actor $actor
        $result.psVersion | Should -BeLike '5.1.*'
        $result.oldElementType | Should -Be 'System.Object[]'
        $result.normalizedElementType | Should -Be 'System.String'
        $result.oldMarkerRejectCount | Should -Be 1
        $result.normalizedMarkerRejectCount | Should -Be 0
        $result.failure.stage | Should -Be private-dns
        $result.failure.reason | Should -Be dns-request-failed
        $result.failure.details.addressEncoding | Should -Be base64
        $result.failure.details.addressElementKind | Should -Be string
        $result.dnsCalls | Should -Be 1
        $result | ConvertTo-Json -Depth 12 | Should -Not -Match SENSITIVE_SENTINEL
    }
    It 'supports multiple native endpoint addresses for <actor>' -ForEach @(
        @{ actor = 'Inspector' }
        @{ actor = 'Marker' }
    ) {
        $result = Invoke-PrivatePs5Fixture -Actor $actor -Json '["10.50.1.10","10.50.1.11"]'
        $result.failure.stage | Should -Be private-dns
        $result.failure.details.addressCount | Should -Be 2
        $result.dnsCalls | Should -Be 1
    }
    It 'identifies native unescaped JSON quote loss without mislabeling identity' {
        $result = Invoke-PrivatePs5Fixture -Actor Inspector -RawJson
        $result.failure.stage | Should -Be private-address-json
        $result.failure.reason | Should -Be address-json-invalid
        $result.failure.details.addressHasQuotes | Should -BeFalse
        $result.dnsCalls | Should -Be 0
    }
    It 'reports <case> with exact bounded nonsecret substage' -ForEach @(
        @{ case = 'NameMismatch'; stage = 'computer-name-validation'; reason = 'computer-name-mismatch' }
        @{ case = 'MetadataFailure'; stage = 'parent-metadata-request'; reason = 'metadata-request-failed' }
        @{ case = 'MetadataShape'; stage = 'parent-metadata-shape'; reason = 'metadata-vm-id-invalid' }
        @{ case = 'VmMismatch'; stage = 'parent-vm-id-validation'; reason = 'parent-vm-id-mismatch' }
    ) {
        $result = Invoke-PrivatePs5Fixture -Actor Inspector -Case $case
        $result.failure.stage | Should -Be $stage
        $result.failure.reason | Should -Be $reason
        $result.dnsCalls | Should -Be 0
        $result | ConvertTo-Json -Depth 12 | Should -Not -Match SENSITIVE_SENTINEL
        $proof = Get-DemoPrivateFailureProof -View @{ output = 'ARC_PRIVATE_VAULT_FAILURE:' + ($result.failure | ConvertTo-Json -Depth 6 -Compress) } -Operation InspectPath
        $proof.stage | Should -Be $stage
        $proof.reason | Should -Be $reason
        $proof.evidence | Should -Be structured
    }
}

Describe 'Native Windows PowerShell 5.1 bounded TLS diagnostics' -Skip:(-not [OperatingSystem]::IsWindows()) {
    It 'executes the protected writer TLS1.2 handshake block with hostname SNI and a bounded task' {
        $result = Invoke-PrivatePs5Fixture -Actor Marker -Case ActualHandshake -Tls -TlsMode Tls12
        $result.failure.operation | Should -Be Marker
        $result.failure.stage | Should -Be private-tls
        $result.clientHelloTls12 | Should -BeTrue
        $result.clientHelloContainsHostname | Should -BeTrue
    }
    It 'executes opt-in TLS1.2 with hostname SNI and no default-policy or validation change' {
        $before = [Net.ServicePointManager]::SecurityProtocol
        $result = Invoke-PrivatePs5Fixture -Actor Inspector -Case ActualHandshake -Tls -TlsMode Tls12
        $result.failure.details.tlsProtocolSelection | Should -Be tls12
        $result.failure.details.tlsPhase | Should -Be authenticate-wait
        $result.clientHelloTls12 | Should -BeTrue
        $result.clientHelloContainsHostname | Should -BeTrue
        [Net.ServicePointManager]::SecurityProtocol | Should -Be $before
    }

    Describe 'Native Windows PowerShell 5.1 per-request private TLS transport' -Skip:(-not [OperatingSystem]::IsWindows()) {
        It 'uses a real TLS1.2 handler with default certificate validation and no global-policy change' {
            $result = Invoke-PrivatePs5Fixture -Actor Marker -Case Success -Http
            $result.psVersion | Should -BeLike '5.1.*'
            $result.realProtocols | Should -Be 3072
            $result.realValidationDefault | Should -BeTrue
            $result.realRedirects | Should -BeFalse
            $result.globalProtocolUnchanged | Should -BeTrue
            $result.calls | Should -Be 1
            $result.routeCorrect | Should -BeTrue
            $result.policyCorrect | Should -BeTrue
            $result.headerCorrect | Should -BeTrue
            $result.valueVerified | Should -BeTrue
            $result | ConvertTo-Json | Should -Not -Match SENSITIVE_SENTINEL
        }
        It 'reports <case> without following redirects, retrying or disclosing response bodies' -ForEach @(
            @{ case = 'Denied'; status = 403; calls = 1 }
            @{ case = 'Redirect'; status = 302; calls = 1 }
            @{ case = 'ForeignRoute'; status = 0; calls = 0 }
        ) {
            $result = Invoke-PrivatePs5Fixture -Actor Marker -Case $case -Http
            $result.failed | Should -BeTrue
            $result.httpStatus | Should -Be $status
            $result.calls | Should -Be $calls
            $result.safeError | Should -BeTrue
            $result | ConvertTo-Json | Should -Not -Match SENSITIVE_SENTINEL
        }
    }
    It 'executes the real hostname TLS overload and task wait without a network connection' {
        $result = Invoke-PrivatePs5Fixture -Actor Inspector -Case ActualHandshake -Tls
        $result.psVersion | Should -BeLike '5.1.*'
        $result.failure.details.tlsPhase | Should -Be authenticate-wait
        $result.failure.details.tlsTaskStatus | Should -Be Faulted
        $result.failure.details.tlsExceptionKinds | Should -Contain aggregate
        $result.failure.details.tlsExceptionKinds | Should -Contain method-invocation
        $result.failure.details.tlsProtocolSelection | Should -Be runtime-default
    }
    It 'projects typed <case> failures through the actual PS5 Task.Wait wrapper' -ForEach @(
        @{ case = 'Authentication'; kind = 'authentication'; code = -2146893019 }
        @{ case = 'Socket'; kind = 'socket'; code = 10054 }
    ) {
        $result = Invoke-PrivatePs5Fixture -Actor Inspector -Case $case -Tls
        $result.failure.details.tlsExceptionKinds | Should -Contain $kind
        $result.failure.details.tlsNativeErrorCode | Should -Be $code
        $result.failure.details.tlsTaskStatus | Should -Be Faulted
        $result | ConvertTo-Json -Depth 10 | Should -Not -Match SENSITIVE_SENTINEL
        $proof = Get-DemoPrivateFailureProof -View @{ output = 'ARC_PRIVATE_VAULT_FAILURE:' + ($result.failure | ConvertTo-Json -Depth 8 -Compress) } -Operation InspectPath
        $proof.evidence | Should -Be structured
        $proof.details.tlsNativeErrorCode | Should -Be $code
    }
    It 'executes the actor ten-second task deadline and reports timeout separately' {
        $result = Invoke-PrivatePs5Fixture -Actor Inspector -Case Timeout -Tls
        $result.failure.reason | Should -Be tls-authentication-timeout
        $result.failure.details.tlsExceptionKinds | Should -Contain timeout
        $result.failure.details.tlsTaskStatus | Should -Be WaitingForActivation
        $result.elapsedMilliseconds | Should -BeGreaterOrEqual 9900
        $result.elapsedMilliseconds | Should -BeLessThan 20000
    }
    It 'bounds long and unknown exceptions without retaining their messages' -ForEach @(
        @{ case = 'LongChain'; count = 6; truncated = $true }
        @{ case = 'Unknown'; count = 1; truncated = $false }
    ) {
        $result = Invoke-PrivatePs5Fixture -Actor Inspector -Case $case -Tls
        @($result.failure.details.tlsExceptionKinds).Count | Should -Be $count
        $result.failure.details.tlsExceptionTruncated | Should -Be $truncated
        $result | ConvertTo-Json -Depth 10 | Should -Not -Match SENSITIVE_SENTINEL
    }
}
