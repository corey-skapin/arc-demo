BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'scripts\lib\Common.psm1')
}
BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1')
    $guestPath = Join-Path $repo 'scripts\guest\Save-DemoMedia.ps1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($guestPath, [ref]$null, [ref]$errors)
    if ($errors) { throw 'The media guest script does not parse.' }
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    # Windows storage API stand-in so the guest functions run offline on any OS.
    if (-not (Get-Command Get-Volume -ErrorAction Ignore)) {
        function Get-Volume { param($DriveLetter) throw 'Unmocked Get-Volume in offline media tests.' }
    }
    function Get-Sha256Of {
        param([byte[]]$Bytes)
        [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($Bytes)).Replace('-', '')
    }
    function New-ManifestFile {
        param([string]$Path, [hashtable]$Item = @{}, [string]$Id = 'sample-media')
        $entry = [ordered]@{
            displayName = 'Sample'; fileName = 'Sample.iso'; url = 'https://download.microsoft.com/download/sample/Sample.iso'
            bytes = 1024; sha256 = ('AB' * 32); licenseUrl = 'https://example.com/terms'; scope = 'Test only'
            acceptanceSwitch = 'AcceptSqlDeveloperTerms'
        }
        foreach ($key in $Item.Keys) { $entry[$key] = $Item[$key] }
        @{ schemaVersion = 1; media = @{ $Id = $entry } } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8
    }
}

Describe 'Tracked media manifest' {
    It 'pins both installers with sizes, hashes and licence URLs under the file names the build expects' {
        $items = @(Get-DemoMediaManifest)
        $items.Id | Should -Contain 'windows-server-2022-eval'
        $items.Id | Should -Contain 'sql-server-2022-developer'
        ($items | Where-Object Id -eq 'windows-server-2022-eval').FileName | Should -Be 'Windows_Server_2022_Evaluation.iso'
        ($items | Where-Object Id -eq 'sql-server-2022-developer').FileName | Should -Be 'SQLServer2022-x64-ENU-Dev.iso'
        foreach ($item in $items) {
            $item.Sha256 | Should -Match '^[A-F0-9]{64}$'
            $item.Bytes | Should -BeGreaterThan 1MB
            $item.LicenseUrl | Should -Match '^https://'
        }
    }
    It 'rejects an invalid <Case> instead of staging from it' -TestCases @(
        @{ Case = 'host'; Item = @{ url = 'https://example.com/Sample.iso' }; Message = '*url*' }
        @{ Case = 'plain-http url'; Item = @{ url = 'http://download.microsoft.com/Sample.iso' }; Message = '*url*' }
        @{ Case = 'hash'; Item = @{ sha256 = 'abc' }; Message = '*sha256*' }
        @{ Case = 'size'; Item = @{ bytes = 0 }; Message = '*bytes*' }
        @{ Case = 'file name'; Item = @{ fileName = '..\Sample.iso' }; Message = '*fileName*' }
        @{ Case = 'acceptance switch'; Item = @{ acceptanceSwitch = 'AcceptEverything' }; Message = '*acceptanceSwitch*' }
        @{ Case = 'licence URL'; Item = @{ licenseUrl = 'terms.txt' }; Message = '*licenseUrl*' }
    ) {
        param($Case, $Item, $Message)
        $path = Join-Path $TestDrive "bad-$($Case -replace ' ', '-').json"
        New-ManifestFile -Path $path -Item $Item
        { Get-DemoMediaManifest -Path $path } | Should -Throw $Message
    }
    It 'rejects a missing manifest and a wrong schema version' {
        { Get-DemoMediaManifest -Path (Join-Path $TestDrive 'missing.json') } | Should -Throw '*not found*'
        Set-Content -LiteralPath (Join-Path $TestDrive 'v2.json') -Value '{"schemaVersion":2,"media":{}}'
        { Get-DemoMediaManifest -Path (Join-Path $TestDrive 'v2.json') } | Should -Throw '*schemaVersion 1*'
    }
}

Describe 'Guest media download is pinned, resumable and never overwrites' {
    BeforeAll {
        $script:payload = [Text.Encoding]::UTF8.GetBytes('installer media payload for tests')
        $script:pin = Get-Sha256Of $script:payload
    }
    BeforeEach {
        $script:root = Join-Path $TestDrive ('media-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root | Out-Null
        $script:item = [pscustomobject]@{ id = 'sample'; fileName = 'Sample.iso'; url = 'https://download.microsoft.com/download/sample/Sample.iso'; bytes = $script:payload.Length; sha256 = $script:pin }
        Mock Get-Volume { [pscustomobject]@{ FileSystem = 'NTFS'; SizeRemaining = 100GB } }
        Mock Get-Process {}
        Mock Invoke-MediaDownload { throw 'unexpected download' }
    }
    It 'keeps a matching file as-is without downloading' {
        [IO.File]::WriteAllBytes((Join-Path $script:root 'Sample.iso'), $script:payload)
        $result = Save-MediaItem -Item $script:item -Root $script:root
        $result.state | Should -Be 'present'
        $result.sha256 | Should -Be $script:pin
        Should -Invoke Invoke-MediaDownload -Times 0
    }
    It 'refuses to overwrite an existing file with the wrong size or hash' -TestCases @(
        @{ Case = 'size'; Bytes = [byte[]](1, 2, 3); Message = '*not the pinned*' }
        @{ Case = 'hash'; Bytes = [Text.Encoding]::UTF8.GetBytes('installer media payload for TESTS'); Message = '*SHA-256*' }
    ) {
        param($Case, $Bytes, $Message)
        $final = Join-Path $script:root 'Sample.iso'
        [IO.File]::WriteAllBytes($final, $Bytes)
        { Save-MediaItem -Item $script:item -Root $script:root } | Should -Throw $Message
        [IO.File]::ReadAllBytes($final) | Should -Be $Bytes
    }
    It 'downloads to a partial file and only then takes the final name' {
        Mock Invoke-MediaDownload { $Output | Should -BeLike '*.partial'; [IO.File]::WriteAllBytes($Output, $script:payload); 0 }
        $result = Save-MediaItem -Item $script:item -Root $script:root
        $result.state | Should -Be 'downloaded'
        Test-Path (Join-Path $script:root 'Sample.iso') | Should -BeTrue
        Test-Path (Join-Path $script:root 'Sample.iso.partial') | Should -BeFalse
    }
    It 'resumes an interrupted partial download' {
        $half = [byte[]]$script:payload[0..9]
        [IO.File]::WriteAllBytes((Join-Path $script:root 'Sample.iso.partial'), $half)
        Mock Invoke-MediaDownload { [IO.File]::WriteAllBytes($Output, $script:payload); 0 }
        (Save-MediaItem -Item $script:item -Root $script:root).state | Should -Be 'resumed'
    }
    It 'restarts once from zero when the server cannot resume' {
        [IO.File]::WriteAllBytes((Join-Path $script:root 'Sample.iso.partial'), [byte[]]$script:payload[0..9])
        $script:calls = 0
        Mock Invoke-MediaDownload {
            $script:calls++
            if ($script:calls -eq 1) { return 33 }
            [IO.File]::WriteAllBytes($Output, $script:payload)
            0
        }
        (Save-MediaItem -Item $script:item -Root $script:root).state | Should -Be 'downloaded'
        $script:calls | Should -Be 2
    }
    It 'keeps the partial file when curl fails or the transfer is short, so a rerun resumes' {
        Mock Invoke-MediaDownload { [IO.File]::WriteAllBytes($Output, [byte[]]$script:payload[0..9]); 18 }
        { Save-MediaItem -Item $script:item -Root $script:root } | Should -Throw '*curl exited 18*'
        Test-Path (Join-Path $script:root 'Sample.iso.partial') | Should -BeTrue
        Mock Invoke-MediaDownload { [IO.File]::WriteAllBytes($Output, [byte[]]$script:payload[0..9]); 0 }
        { Save-MediaItem -Item $script:item -Root $script:root } | Should -Throw '*Downloaded 10 of*'
        Test-Path (Join-Path $script:root 'Sample.iso.partial') | Should -BeTrue
    }
    It 'discards a download whose hash or size does not match its pin' -TestCases @(
        @{ Case = 'hash'; Bytes = [Text.Encoding]::UTF8.GetBytes('installer media payload for TESTS'); Message = '*not the pinned*' }
        @{ Case = 'size'; Bytes = [Text.Encoding]::UTF8.GetBytes('installer media payload for tests, refreshed'); Message = '*more than the pinned*' }
    ) {
        param($Case, $Bytes, $Message)
        $script:badBytes = $Bytes
        Mock Invoke-MediaDownload { [IO.File]::WriteAllBytes($Output, $script:badBytes); 0 }
        { Save-MediaItem -Item $script:item -Root $script:root } | Should -Throw $Message
        Test-Path (Join-Path $script:root 'Sample.iso') | Should -BeFalse
        Test-Path (Join-Path $script:root 'Sample.iso.partial') | Should -BeFalse
    }
    It 'refuses to start while another curl runs, on an oversized partial, or without free space' {
        [IO.File]::WriteAllBytes((Join-Path $script:root 'Sample.iso.partial'), [byte[]]$script:payload[0..9])
        Mock Get-Process { [pscustomobject]@{ Name = 'curl' } }
        { Save-MediaItem -Item $script:item -Root $script:root } | Should -Throw '*already running*'
        Mock Get-Process {}
        [IO.File]::WriteAllBytes((Join-Path $script:root 'Sample.iso.partial'), [byte[]]($script:payload + $script:payload))
        { Save-MediaItem -Item $script:item -Root $script:root } | Should -Throw '*larger than the pinned*'
        Remove-Item (Join-Path $script:root 'Sample.iso.partial')
        Mock Get-Volume { [pscustomobject]@{ FileSystem = 'NTFS'; SizeRemaining = 1MB } }
        { Save-MediaItem -Item $script:item -Root $script:root } | Should -Throw '*free space*'
        Should -Invoke Invoke-MediaDownload -Times 0
    }
    It 'refuses a non-NTFS or relative destination before touching anything' {
        Mock Get-Volume { [pscustomobject]@{ FileSystem = 'FAT32'; SizeRemaining = 100GB } }
        { Save-DemoMedia -Settings ([pscustomobject]@{ root = 'D:\Media'; items = @() }) } | Should -Throw '*NTFS*'
        { Save-DemoMedia -Settings ([pscustomobject]@{ root = 'Media'; items = @() }) } | Should -Throw '*absolute path*'
    }
}

Describe 'Guest scripts run on Windows PowerShell 5.1' -Skip:(-not $IsWindows) {
    It 'parses <Name> without PowerShell 7 syntax' -ForEach @(
        @{ Name = 'Save-DemoMedia.ps1' }
    ) {
        $path = Join-Path (Join-Path (Split-Path $PSScriptRoot) 'scripts\guest') $Name
        $command = "`$e = `$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$path', [ref]`$null, [ref]`$e); if (`$e) { `$e | Out-String; exit 1 }"
        $output = & powershell.exe -NoProfile -NonInteractive -Command $command 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
    }
}

Describe 'Guest action transport' {
    BeforeEach {
        $script:capturedWrapper = $null
        $script:runCommandJson = $null
        $script:machine = [pscustomobject]@{ Id = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'; Name = 'vm1'; OsType = 'Windows' }
    }
    It 'sends settings as base64, removes its temp file and returns the single result object' {
        InModuleScope Common -Parameters @{ Json = (@{ value = @(@{ code = 'ComponentStatus/StdOut/succeeded'; level = 'Info'; message = "ARC_GUEST_RESULT={`"ok`":true,`"n`":3}`nARC_DEMO_OK" }, @{ code = 'ComponentStatus/StdErr/succeeded'; level = 'Info'; message = '' }) } | ConvertTo-Json -Depth 6 -Compress) } {
            param($Json)
            $script:seenPath = $null
            Mock Start-DemoAzJob {
                param($Arguments)
                $script:seenPath = $Arguments[[Array]::IndexOf($Arguments, '--scripts') + 1].TrimStart('@')
                $script:seenText = [IO.File]::ReadAllText($script:seenPath)
                [pscustomobject]@{ Name = 'job' }
            }
            Mock Receive-DemoJobs { $Json }
            $machine = [pscustomobject]@{ Id = '/fixture/vm1'; Name = 'vm1'; OsType = 'Windows' }
            $script = Join-Path $TestDrive 'guest.ps1'
            Set-Content -LiteralPath $script -Value 'param($Action,$SettingsBase64)'
            $result = Invoke-DemoGuestAction -Machine $machine -ScriptPath $script -Action Save -Settings @{ url = 'https://download.microsoft.com/secret-marker' }
            $result.ok | Should -BeTrue
            $result.n | Should -Be 3
            $script:seenText | Should -Not -Match 'secret-marker'
            $script:seenText | Should -Match "-Action 'Save'"
            Test-Path -LiteralPath $script:seenPath | Should -BeFalse
        }
    }
    It 'surfaces a structured guest error and refuses output without the marker' {
        InModuleScope Common {
            $machine = [pscustomobject]@{ Id = '/fixture/vm1'; Name = 'vm1'; OsType = 'Windows' }
            $script = Join-Path $TestDrive 'guest.ps1'
            Set-Content -LiteralPath $script -Value 'param($Action,$SettingsBase64)'
            Mock Start-DemoAzJob { [pscustomobject]@{ Name = 'job' } }
            $errorJson = @{ value = @(@{ code = 'ComponentStatus/StdOut/succeeded'; level = 'Info'; message = 'ARC_GUEST_ERROR={"message":"Drive D: is already used"}' }) } | ConvertTo-Json -Depth 6 -Compress
            Mock Receive-DemoJobs { $errorJson }
            { Invoke-DemoGuestAction -Machine $machine -ScriptPath $script -Action Volume } | Should -Throw '*Drive D: is already used*'
            $noMarker = @{ value = @(@{ code = 'ComponentStatus/StdOut/succeeded'; level = 'Info'; message = 'ARC_GUEST_RESULT={"ok":true}' }) } | ConvertTo-Json -Depth 6 -Compress
            Mock Receive-DemoJobs { $noMarker }
            { Invoke-DemoGuestAction -Machine $machine -ScriptPath $script -Action Volume } | Should -Throw '*no verified result*'
            $failed = @{ value = @(@{ code = 'ProvisioningState/failed/-1'; level = 'Error'; message = 'x' }) } | ConvertTo-Json -Depth 6 -Compress
            Mock Receive-DemoJobs { $failed }
            { Invoke-DemoGuestAction -Machine $machine -ScriptPath $script -Action Volume } | Should -Throw '*no verified result*'
        }
    }
    It 'rejects a Linux target and an unsafe action name' {
        InModuleScope Common {
            $script = Join-Path $TestDrive 'guest.ps1'
            Set-Content -LiteralPath $script -Value 'x'
            { Invoke-DemoGuestAction -Machine ([pscustomobject]@{ Name = 'lnx'; OsType = 'Linux' }) -ScriptPath $script -Action Save } | Should -Throw '*Windows*'
            { Invoke-DemoGuestAction -Machine ([pscustomobject]@{ Name = 'w'; OsType = 'Windows' }) -ScriptPath $script -Action "Save'; calc" } | Should -Throw
        }
    }
}

Describe 'Stage-DemoMedia operator flow' {
    BeforeAll {
        $script:stage = Join-Path $repo 'scripts\Stage-DemoMedia.ps1'
        $script:manifestPath = Join-Path $TestDrive 'media.json'
        $script:payloadSha = ('CD' * 32)
        New-ManifestFile -Path $script:manifestPath -Item @{ bytes = 2048; sha256 = $script:payloadSha; fileName = 'Sample.iso' }
        $script:common = @{
            SubscriptionId = '11111111-1111-1111-1111-111111111111'; TenantId = '22222222-2222-2222-2222-222222222222'
            MachineName = 'win-sql-01'; Media = 'sample-media'; Destination = 'C:\DemoMedia'; ManifestPath = $script:manifestPath
        }
    }
    BeforeEach {
        # Mock bodies run in the caller's scope, so they use literals rather than script-scoped variables.
        $script:recordPath = Join-Path $TestDrive ('acceptance-' + [guid]::NewGuid().ToString('N') + '.json')
        Mock Import-Module {}
        Mock Initialize-DemoContext {}
        Mock Invoke-DemoAz { 'operator@example.com' }
        Mock Get-DemoGuestTarget {
            [pscustomobject]@{ Target = [pscustomobject]@{ Id = '/fixture/vm'; Name = 'win-sql-01'; OsType = 'Windows'
                Actual = [pscustomobject]@{ powerState = 'VM running'; provisioningState = 'Succeeded' } } }
        }
        Mock Invoke-DemoGuestAction {
            [pscustomobject]@{ items = @([pscustomobject]@{ id = 'sample-media'; path = 'C:\DemoMedia\Sample.iso'; bytes = 2048; sha256 = ('CD' * 32); state = 'downloaded' }) }
        }
    }
    It 'refuses without the explicit terms switch and names the terms to read' {
        { & $script:stage @script:common -AcceptanceRecordPath $script:recordPath } | Should -Throw '*https://example.com/terms*AcceptSqlDeveloperTerms*'
        Should -Invoke Invoke-DemoGuestAction -Times 0
        Test-Path $script:recordPath | Should -BeFalse
    }
    It 'previews without touching the VM or writing an acceptance record' {
        & $script:stage @script:common -AcceptanceRecordPath $script:recordPath -WhatIf
        Should -Invoke Invoke-DemoGuestAction -Times 0
        Test-Path $script:recordPath | Should -BeFalse
    }
    It 'stages, verifies the guest result against the pin and records acceptance once' {
        $result = & $script:stage @script:common -AcceptSqlDeveloperTerms -AcceptanceRecordPath $script:recordPath -Confirm:$false
        $result.items[0].path | Should -Be 'C:\DemoMedia\Sample.iso'
        $result.items[0].sha256 | Should -Be $script:payloadSha
        $record = Get-Content -LiteralPath $script:recordPath -Raw | ConvertFrom-Json
        $record.items.'sample-media'.licenseUrl | Should -Be 'https://example.com/terms'
        $record.items.'sample-media'.sha256 | Should -Be $script:payloadSha
        $record.items.'sample-media'.acceptedBy | Should -Be 'operator@example.com'
        $first = $record.items.'sample-media'.acceptedAtUtc
        Start-Sleep -Milliseconds 30
        & $script:stage @script:common -AcceptSqlDeveloperTerms -AcceptanceRecordPath $script:recordPath -Confirm:$false | Out-Null
        (Get-Content -LiteralPath $script:recordPath -Raw | ConvertFrom-Json).items.'sample-media'.acceptedAtUtc | Should -Be $first
        Should -Invoke Invoke-DemoGuestAction -Times 2 -Exactly -ParameterFilter { $Settings.root -eq 'C:\DemoMedia' -and $Settings.items[0].sha256 -eq ('CD' * 32) }
    }
    It 'rejects a guest result that does not match the pin' {
        Mock Invoke-DemoGuestAction { [pscustomobject]@{ items = @([pscustomobject]@{ id = 'sample-media'; path = 'C:\DemoMedia\Sample.iso'; bytes = 2048; sha256 = ('EF' * 32); state = 'downloaded' }) } }
        { & $script:stage @script:common -AcceptSqlDeveloperTerms -AcceptanceRecordPath $script:recordPath -Confirm:$false } | Should -Throw '*does not match its pin*'
    }
    It 'refuses a parked target and never starts a VM' {
        Mock Get-DemoGuestTarget {
            [pscustomobject]@{ Target = [pscustomobject]@{ Id = '/fixture/vm'; Name = 'win-sql-01'; OsType = 'Windows'
                Actual = [pscustomobject]@{ powerState = 'VM deallocated'; provisioningState = 'Succeeded' } } }
        }
        { & $script:stage @script:common -AcceptSqlDeveloperTerms -AcceptanceRecordPath $script:recordPath -Confirm:$false } | Should -Throw '*never starts a VM*'
        Should -Invoke Invoke-DemoGuestAction -Times 0
    }
    It 'rejects an unknown media id before any Azure call' {
        $unknown = $script:common.Clone()
        $unknown.Media = 'windows-11'
        { & $script:stage @unknown -AcceptSqlDeveloperTerms -AcceptanceRecordPath $script:recordPath -Confirm:$false } | Should -Throw '*Unknown media*'
        Should -Invoke Get-DemoGuestTarget -Times 0
        Should -Invoke Invoke-DemoGuestAction -Times 0
    }
}
