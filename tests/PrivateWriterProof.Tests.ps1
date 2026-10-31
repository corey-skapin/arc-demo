param([string]$SourceRoot = '')

BeforeAll {
    $repo = if ($SourceRoot) { [IO.Path]::GetFullPath($SourceRoot) } else { Split-Path $PSScriptRoot }
    Import-Module (Join-Path $repo 'scripts\lib\PrivateOnboarding.psm1') -Force
    function Get-NativeWriterOutput {
        param([string]$Operation, [string]$MarkerCase = '')
        $fixture = Join-Path $repo 'tests\fixtures\PrivateWriterProof.Ps5Harness.ps1'
        $actor = Join-Path $repo 'scripts\guest\Set-PrivateVaultSecret.ps1'
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $start.Arguments = "-NoProfile -NonInteractive -File `"$fixture`" -ActorPath `"$actor`" -Operation $Operation"
        if ($MarkerCase) {
            $fixture = Join-Path $repo 'tests\fixtures\PrivateMarker.Ps5Harness.ps1'
            $start.Arguments = "-NoProfile -NonInteractive -File `"$fixture`" -ActorPath `"$actor`" -Case $MarkerCase"
        }
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $start.EnvironmentVariables['PSModulePath'] = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules;$env:ProgramFiles\WindowsPowerShell\Modules"
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Synthetic PS5 receipt fixture exceeded its deadline.' }
            if ($process.ExitCode -ne 0) { throw 'Synthetic PS5 writer receipt generation failed.' }
            return $stdout.Result.Trim()
        } finally { $process.Dispose() }
    }

}

Describe 'Native PS5 exact retained onboarding reader' -Skip:(-not [OperatingSystem]::IsWindows()) {
    It 'reads only the pinned version and returns a SecureString without writes or plaintext output' {
        $r = Get-NativeWriterOutput -MarkerCase ReaderSuccess | ConvertFrom-Json
        $r.failed | Should -BeFalse
        $r.secureResult | Should -BeTrue
        $r.versionBound | Should -BeTrue
        @($r.methods) | Should -Be @('GET')
        $r.proofLine | Should -BeNullOrEmpty
        $r | ConvertTo-Json | Should -Not -Match SENSITIVE_SENTINEL
    }
    It 'fails closed for <case> with no writes, latest fallback or plaintext output' -ForEach @(
        @{ case = 'ReaderDenied' }, @{ case = 'ReaderForeignVersion' }, @{ case = 'ReaderForeignKey' }
        @{ case = 'ReaderDisabled' }, @{ case = 'ReaderStringExpiry' }, @{ case = 'ReaderForeignPurpose' }
        @{ case = 'ReaderEmpty' }, @{ case = 'ReaderExpiring' }
    ) {
        $r = Get-NativeWriterOutput -MarkerCase $case | ConvertFrom-Json
        $r.failed | Should -BeTrue
        $r.safeError | Should -BeTrue
        $r.secureResult | Should -BeFalse
        @($r.methods | Where-Object { $_ -ne 'GET' }).Count | Should -Be 0
        @($r.methods).Count | Should -BeLessOrEqual 1
        $r | ConvertTo-Json | Should -Not -Match SENSITIVE_SENTINEL
    }
}

Describe 'Native PS5 pinned existing-marker verification, never replay/new version' -Skip:(-not [OperatingSystem]::IsWindows()) {
        It 'enables, reads the exact fixed nonsecret value and disables only the pinned existing version' {
            $r = Get-NativeWriterOutput -MarkerCase Success | ConvertFrom-Json
            $r.failed | Should -BeFalse
            $r.disabled | Should -BeTrue
            $r.versionBound | Should -BeTrue
            @($r.methods) | Should -Be @('PATCH-enable', 'GET', 'PATCH-disable')
            $proof = Get-DemoPrivateWriterProof -Output $r.proofLine -Operation VerifyMarker -VaultName kv-fixture `
                -PrivateAddresses @('10.50.1.10') -NotBeforeUtc ([datetimeoffset]::UtcNow.AddSeconds(-10))
            $proof.operation | Should -Be VerifyMarker
            $proof.enabled | Should -BeFalse
            $r | ConvertTo-Json | Should -Not -Match SENSITIVE_SENTINEL
        }
        It 'fails safely for <case>, always attempts one exact-version disable and never creates a version' -ForEach @(
            @{ case = 'EnableUnknown'; disabled = $true }
            @{ case = 'ReadDenied'; disabled = $true }
            @{ case = 'WrongValue'; disabled = $true }
            @{ case = 'DisableDenied'; disabled = $false }
        ) {
            $r = Get-NativeWriterOutput -MarkerCase $case | ConvertFrom-Json
            $r.failed | Should -BeTrue
            $r.safeError | Should -BeTrue
            $r.versionBound | Should -BeTrue
            $r.disabled | Should -Be $disabled
            @($r.methods | Where-Object { $_ -eq 'PATCH-disable' }).Count | Should -Be 1
            @($r.methods | Where-Object { $_ -eq 'PUT' }).Count | Should -Be 0
            $r.proofLine | Should -BeNullOrEmpty
            $r | ConvertTo-Json | Should -Not -Match SENSITIVE_SENTINEL
        }
    }

Describe 'Private writer exact producer/consumer completion contract' {
    BeforeEach {
        $data = @{
            status = 'pass'; operation = 'Marker'
            secretVersionUri = 'https://kv-fixture.vault.azure.net/secrets/arc-onboarding-client-secret/123456789012345678901234567890ab'
            privateAddresses = @('10.50.1.10'); tlsVerified = $true; valueVerified = $true; enabled = $false
            expiresAtUtc = ''; checkedAtUtc = [datetime]::UtcNow.ToString('o')
        }
        $call = @{
            Operation = 'Marker'; VaultName = 'kv-fixture'; PrivateAddresses = @('10.50.1.10')
            NotBeforeUtc = [datetimeoffset]::UtcNow.AddSeconds(-5)
        }
    }
    It 'accepts exact native PS5 <operation> output including DateTime.UTC Z and marker empty expiry' -ForEach @(
        @{ operation = 'Marker' }, @{ operation = 'Initialize' }
    ) -Skip:(-not [OperatingSystem]::IsWindows()) {
        $output = Get-NativeWriterOutput -Operation $operation
        $raw = $output.Substring('ARC_PRIVATE_VAULT_RESULT:'.Length)
        $decoded = $raw | ConvertFrom-Json -AsHashtable
        $decoded.checkedAtUtc | Should -BeOfType datetime
        $decoded.checkedAtUtc.Kind | Should -Be Utc
        $call.Operation = $operation
        if ($operation -eq 'Initialize') { $call.ExpiresAtUtc = ([datetimeoffset]$decoded.expiresAtUtc).ToString('o') }
        $result = Get-DemoPrivateWriterProof @call -Output $output
        ([datetimeoffset]$result.checkedAtUtc) | Should -Be ([datetimeoffset]$decoded.checkedAtUtc)
        $result.enabled | Should -Be ($operation -eq 'Initialize')
        $result.privateAddresses | Should -Be @('10.50.1.10')
    }
    It 'retains exact fractional UTC time without object-to-local-culture reparsing' {
        $instant = [datetime]::UtcNow
        $data.checkedAtUtc = $instant.ToString('o')
        $result = Get-DemoPrivateWriterProof @call -Output ('ARC_PRIVATE_VAULT_RESULT:' + ($data | ConvertTo-Json -Compress))
        ([datetimeoffset]$result.checkedAtUtc).UtcTicks | Should -Be $instant.Ticks
    }
    It 'rejects <case> with an allowlisted reason and no raw payload retention' -ForEach @(
        @{ case = 'missing field'; reason = 'writer-schema'; change = { $data.Remove('valueVerified') } }
        @{ case = 'boolean string'; reason = 'writer-schema'; change = { $data.tlsVerified = 'true' } }
        @{ case = 'address scalar'; reason = 'writer-schema'; change = { $data.privateAddresses = '10.50.1.10' } }
        @{ case = 'duplicate address'; reason = 'writer-schema'; change = { $data.privateAddresses = @('10.50.1.10', '10.50.1.10') } }
        @{ case = 'extra field'; reason = 'writer-schema'; change = { $data.secret = 'SENSITIVE_SENTINEL' } }
        @{ case = 'no timezone'; reason = 'writer-timestamp'; change = { $data.checkedAtUtc = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffff') } }
        @{ case = 'numeric time'; reason = 'writer-timestamp'; change = { $data.checkedAtUtc = 1 } }
        @{ case = 'stale'; reason = 'writer-freshness'; change = { $data.checkedAtUtc = [datetime]::UtcNow.AddHours(-1).ToString('o') } }
        @{ case = 'marker expiry'; reason = 'writer-expiry'; change = { $data.expiresAtUtc = [datetime]::UtcNow.AddDays(1).ToString('o') } }
    ) {
        & $change
        try {
            Get-DemoPrivateWriterProof @call -Output ('ARC_PRIVATE_VAULT_RESULT:' + ($data | ConvertTo-Json -Compress)) | Out-Null
            throw 'Fixture unexpectedly passed.'
        } catch {
            $_.Exception.Data['ArcPrivateProofReason'] | Should -Be $reason
            $_.Exception.Message | Should -Not -Match SENSITIVE_SENTINEL
        }
    }
    It 'rejects duplicate result lines rather than accepting one arbitrary proof' {
        $line = 'ARC_PRIVATE_VAULT_RESULT:' + ($data | ConvertTo-Json -Compress)
        { Get-DemoPrivateWriterProof @call -Output "$line`n$line" } | Should -Throw '*writer-envelope*'
    }
}
