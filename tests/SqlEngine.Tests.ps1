BeforeAll {
    $repo = Split-Path $PSScriptRoot
    $guestPath = Join-Path $repo 'samples\sql-engine\SqlEngineDemo.ps1'
    $wrapper = Join-Path $repo 'scripts\Invoke-SqlEngineOnArc.ps1'
    $source = Get-Content $guestPath -Raw
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($guestPath, [ref]$tokens, [ref]$errors)
    if ($errors) { throw 'SQL guest source does not parse.' }
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    function New-TestTable {
        param([hashtable]$Values)
        $table = [Data.DataTable]::new()
        foreach ($key in $Values.Keys) { $table.Columns.Add($key, [object]) | Out-Null }
        $row = $table.NewRow()
        foreach ($key in $Values.Keys) { $row[$key] = $Values[$key] }
        $table.Rows.Add($row)
        return ,$table
    }
    function New-TestIncidentConnection {
        param([string]$Role, [switch]$CleanupTimeout)
        $wait = [pscustomobject]@{ Completes = -not $CleanupTimeout }
        $wait | Add-Member ScriptMethod WaitOne { param($milliseconds) return $this.Completes }
        $command = [pscustomobject]@{
            Role = $Role; CommandText = ''; CommandTimeout = 0; Disposed = $false
            Async = [pscustomobject]@{ IsCompleted = $true; AsyncWaitHandle = $wait }
        }
        $command | Add-Member ScriptMethod BeginExecuteNonQuery { return $this.Async }
        $command | Add-Member ScriptMethod EndExecuteNonQuery {
            param($async)
            if ($this.Role -eq 'Victim') { throw [InvalidOperationException]::new('Fixture SQL exception; not a real database result.') }
            return 0
        }
        $command | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        $connection = [pscustomobject]@{ Role = $Role; Command = $command; Disposed = $false }
        $connection | Add-Member ScriptMethod CreateCommand { return $this.Command }
        $connection | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        return $connection
    }
    foreach ($name in @('Get-CimInstance', 'Get-Service', 'Get-DiskImage', 'Mount-DiskImage', 'Dismount-DiskImage', 'Get-Volume', 'Get-ScheduledTask', 'Get-AuthenticodeSignature', 'Write-EventLog')) {
        if ($name -eq 'Get-Volume' -or -not (Get-Command $name -ErrorAction Ignore)) {
            Set-Item "function:$name" -Value {
                [CmdletBinding()]
                param([Parameter(ValueFromPipeline)]$InputObject, $ClassName, $Filter, $OperationTimeoutSec, $ImagePath, $FilePath, $Access, $TaskPath, $TaskName, $Name, $LogName, $Source, $EventId, $EntryType, $Message, [switch]$PassThru)
                throw 'Unmocked Windows API in offline SQL tests.'
            }
        }
    }
}

Describe 'Real SQL guest safeguards and query evidence' {
    BeforeEach {
        $root = Join-Path $TestDrive ('owned-' + [guid]::NewGuid().ToString())
        $manifestPath = Join-Path $root 'manifest.json'
        $installedScript = Join-Path $root 'SqlEngineDemo.ps1'
        $instance = 'ARCDEMO'
        $database = 'ArcDemoOrders'
        $taskName = 'ArcSqlEngineDemo'
        $eventSource = 'ArcSqlEngineDemo'
        $serviceName = 'MSSQL$ARCDEMO'
        $sourcePath = $guestPath
        $hash = 'A' * 64
        Mock Get-Process { $null }
        Mock Test-DemoRebootPending { $false }
        Mock Assert-DemoSqlExtensionBlocked {}
        Mock Get-FileHash { @{ Hash = $hash } }
        Mock Start-Process { throw 'No installer may run in unit tests.' }
    }

    It 'requires user-owned licence acceptance and approved media before any installation' {
        { Install-DemoEngine } | Should -Throw '*licence*' -Because 'Install cannot imply licence acceptance'
        Should -Invoke Start-Process -Times 0
    }

    It 'does not bypass pending reboot/rename state' {
        Mock Test-DemoRebootPending { $true }
        { Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed } | Should -Throw '*pending rename*'
        Should -Invoke Start-Process -Times 0
    }

    It 'requires separate confirmation that Arc SQL automatic connection has been effectively opted out' {
        { Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms } | Should -Throw '*effective Arc SQL*'
        Should -Invoke Start-Process -Times 0
        Should -Invoke Get-Process -Times 0
    }

    It 'does not replay while an installer is active' {
        Mock Get-Process { [pscustomobject]@{ Id = 123; ProcessName = 'setup' } }
        { Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed } | Should -Throw '*installer may be active*'
        Should -Invoke Start-Process -Times 0
    }

    It 'rejects a foreign manifest' {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        @{ schemaVersion = 1; instance = 'FOREIGN'; database = $database } | ConvertTo-Json | Set-Content $manifestPath
        { Get-DemoManifest } | Should -Throw '*exact owned*'
    }

    It 'does not replay a partial or reboot-pending installation' -ForEach @('installing', 'initializing', 'pending-reboot', 'setup-failed') {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        @{ schemaVersion = 1; instance = $instance; database = $database; phase = $_; scriptSha256 = $hash; mediaSha256 = $hash } | ConvertTo-Json | Set-Content $manifestPath
        { Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed } | Should -Throw '*diagnose rather than replay*'
        Should -Invoke Start-Process -Times 0
    }

    It 'leaves a correctly owned installation unchanged on rerun' {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        @{ schemaVersion = 1; instance = $instance; database = $database; phase = 'ready'; scriptSha256 = $hash; mediaSha256 = $hash } |
            ConvertTo-Json | Set-Content $manifestPath
        Mock Get-FileHash { @{ Hash = $hash } }
        Mock Get-DemoSqlStatus { @{ status = 'pass'; orderCount = 4 } }
        Mock Test-DemoRebootPending { $true }
        (Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed).orderCount | Should -Be 4
        Should -Invoke Start-Process -Times 0
        Should -Invoke Test-DemoRebootPending -Times 0
    }

    It 'requires SQL 2022 Developer rather than silently accepting a paid/evaluation/other engine' -ForEach @(
        @{ Edition = 'Enterprise Edition'; Version = '16.0.1000.6' }
        @{ Edition = 'Enterprise Evaluation Edition'; Version = '16.0.1000.6' }
        @{ Edition = 'Developer Edition (64-bit)'; Version = '15.0.1000.6' }
    ) {
        Mock Invoke-DemoSql { New-TestTable @{ Edition = $Edition; Version = $Version } }
        { Assert-DemoEngine } | Should -Throw '*Expected SQL Server 2022 Developer*'
    }

    It 'does not adopt an unmarked database' {
        Mock Invoke-DemoSql { New-TestTable @{ Owner = 'someone-else' } }
        { Assert-DemoDatabase } | Should -Throw '*foreign*'
    }

    It 'requires the owned worker command and SYSTEM principal' -ForEach @(
        @{ UserId = 'S-1-5-18'; Accepted = $true }
        @{ UserId = 'another-user'; Accepted = $false }
    ) {
        Mock Get-ScheduledTask {
            [pscustomobject]@{
                Actions = @(@{ Execute = 'powershell.exe'; Arguments = "-NoProfile -File `"$installedScript`" -Action Workload" })
                Principal = @{ UserId = $UserId; RunLevel = 'Highest' }
            }
        }
        if ($Accepted) { (Assert-DemoTask).Principal.UserId | Should -Be $UserId }
        else { { Assert-DemoTask } | Should -Throw '*owned SQL worker*' }
    }

    It 'verifies actual instance/auth/transport/memory settings from SQL itself' {
        Mock Invoke-DemoSql {
            New-TestTable @{ Edition = 'Developer Edition (64-bit)'; Version = '16.0.1000.6'; InstanceName = 'ARCDEMO'; WindowsOnly = 1; Transport = 'Shared memory'; MemoryLimitMB = 512; MaxDop = 1 }
        }
        (Assert-DemoEngine).MemoryLimitMB | Should -Be 512
        Should -Invoke Invoke-DemoSql -Times 1 -ParameterFilter { $Sql -match "SERVERPROPERTY\('InstanceName'\)" -and $Sql -match 'sys.configurations' -and $Sql -match "CONNECTIONPROPERTY\('net_transport'\)" }
    }

    It 'uses a real bounded commit/read transaction, not fabricated SQL-shaped data' {
        Mock Invoke-DemoSql { New-TestTable @{ OrderCount = 7; LastCommitUtc = [datetime]::UtcNow } }
        $result = Invoke-DemoOrder
        $result.Rows[0].OrderCount | Should -Be 7
        Should -Invoke Invoke-DemoSql -Times 1 -ParameterFilter {
            $Database -eq 'ArcDemoOrders' -and $Sql -match 'INSERT dbo\.Orders' -and
            $Sql -match '@id-1000' -and $Sql -match 'COMMIT TRANSACTION' -and $Sql -match 'COUNT_BIG'
        }
    }

    It 'returns actual engine/query rows and never mutates the database during Status' {
        Mock Get-DemoManifest { @{ phase = 'ready'; scriptSha256 = $hash } }
        Mock Assert-DemoEngine { @{ Edition = 'Developer Edition (64-bit)'; Version = '16.0.1000.6'; InstanceName = 'ARCDEMO'; MemoryLimitMB = 512; MaxDop = 1 } }
        Mock Assert-DemoDatabase {}
        Mock Assert-DemoTask { @{ State = 'Running'; Settings = @{ Enabled = $true } } }
        Mock Invoke-DemoSql { New-TestTable @{ DatabaseName = 'ArcDemoOrders'; OrderCount = [long]7; LastCommitUtc = [datetime]::UtcNow } }
        $result = Get-DemoSqlStatus
        $result.status | Should -Be 'pass'
        $result.orderCount | Should -Be 7
        $result.database | Should -Be 'ArcDemoOrders'
        $result.instance | Should -Be 'ARCDEMO'
        $result.memoryLimitMB | Should -Be 512
        $result.maxDop | Should -Be 1
        Should -Invoke Invoke-DemoSql -Times 1 -ParameterFilter { $Sql -notmatch 'INSERT|UPDATE|DELETE|CREATE|ALTER' -and $Database -eq 'ArcDemoOrders' }
    }

    It 'keeps stale query data pending rather than calling a stopped worker healthy' {
        Mock Get-DemoManifest { @{ phase = 'ready'; scriptSha256 = $hash } }
        Mock Assert-DemoEngine { @{ Edition = 'Developer Edition (64-bit)'; Version = '16.0.1000.6' } }
        Mock Assert-DemoDatabase {}
        Mock Assert-DemoTask { @{ State = 'Ready'; Settings = @{ Enabled = $true } } }
        Mock Invoke-DemoSql { New-TestTable @{ DatabaseName = 'ArcDemoOrders'; OrderCount = [long]7; LastCommitUtc = [datetime]::UtcNow.AddHours(-1) } }
        (Get-DemoSqlStatus).status | Should -Be 'pending'
    }

    It 'keeps setup local, bounded, authenticated and non-disruptive' {
        $source | Should -Match '/TCPENABLED=0'
        $source | Should -Match '/NPENABLED=0'
        $source | Should -Match '/SQLMAXMEMORY=512'
        $source | Should -Match 'WaitForExit\(1200000\)'
        $source | Should -Not -Match 'Restart-Computer|Restart-Service|Stop-Process|LicenseType|SAPWD|SECURITYMODE=SQL|Invoke-WebRequest'
        $source | Should -Match 'MAXSIZE=128MB'
        $source | Should -Match 'MAXSIZE=64MB'
    }

    It 'resumes only initialization after a recorded successful setup, without another installer' {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        @{ schemaVersion = 1; instance = $instance; database = $database; phase = 'initializing'; setupExitCode = 0; scriptSha256 = $hash; mediaSha256 = $hash } |
            ConvertTo-Json | Set-Content $manifestPath
        Mock Complete-DemoWorkload { @{ status = 'pending' } }
        (Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed).status | Should -Be 'pending'
        Should -Invoke Start-Process -Times 0
        Should -Invoke Complete-DemoWorkload -Times 1
    }

    It 'resumes recorded 3010 only after a later boot, without repeating setup' -ForEach @(
        @{ HoursSinceBoot = 2; Resumable = $false }
        @{ HoursSinceBoot = 0; Resumable = $true }
    ) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        @{ schemaVersion = 1; instance = $instance; database = $database; phase = 'pending-reboot'; setupExitCode = 3010; scriptSha256 = $hash; mediaSha256 = $hash; startedAtUtc = [datetime]::UtcNow.AddHours(-1).ToString('o') } |
            ConvertTo-Json | Set-Content $manifestPath
        Mock Get-CimInstance { @{ LastBootUpTime = [datetime]::UtcNow.AddHours(-$HoursSinceBoot) } }
        Mock Complete-DemoWorkload { @{ status = 'pending' } }
        if ($Resumable) {
            (Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed).status | Should -Be 'pending'
            Should -Invoke Complete-DemoWorkload -Times 1
        } else {
            { Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed } | Should -Throw '*no later boot*'
            Should -Invoke Complete-DemoWorkload -Times 0
        }
        Should -Invoke Start-Process -Times 0
    }
}

Describe 'SQL worker cold-start readiness and terminal evidence' {
    BeforeEach {
        $instance = 'ARCDEMO'
        $database = 'ArcDemoOrders'
        $eventSource = 'ArcSqlEngineDemo'
        $sourcePath = $guestPath
        $script:coldStartClock = [datetime]'2026-01-01T00:00:00Z'
        $script:coldStartOrigin = $script:coldStartClock
        $script:orderCalls = 0
        Mock Get-Date { $script:coldStartClock }
        Mock Start-Sleep { $script:coldStartClock = $script:coldStartClock.AddSeconds($Seconds) }
        Mock Get-Service { @{ Status = 'Running' } }
        Mock Invoke-DemoSql { New-TestTable @{ DatabaseState = 0 } }
        Mock Get-DemoManifest { @{ phase = 'ready'; scriptSha256 = 'A' * 64 } }
        Mock Get-FileHash { @{ Hash = 'A' * 64 } }
        Mock Assert-DemoTask {}
        Mock Assert-DemoEngine {}
        Mock Assert-DemoDatabase {}
        Mock Write-EventLog {}
        Mock Invoke-DemoOrder { throw 'Fixture transaction stop.' }
    }

    It 'waits through the observed cold-start delay and database recovery before real work' {
        Mock Get-Service {
            @{ Status = if (($script:coldStartClock - $script:coldStartOrigin).TotalSeconds -lt 150) { 'StartPending' } else { 'Running' } }
        }
        Mock Invoke-DemoSql {
            New-TestTable @{ DatabaseState = if (($script:coldStartClock - $script:coldStartOrigin).TotalSeconds -lt 155) { 2 } else { 0 } }
        }
        Mock Invoke-DemoOrder {
            $script:orderCalls++
            if ($script:orderCalls -gt 1) { throw 'Fixture transaction stop.' }
            New-TestTable @{ DatabaseName = 'ArcDemoOrders'; OrderCount = 8; LastCommitUtc = $script:coldStartClock }
        }
        { Invoke-DemoWorkload } | Should -Throw '*Fixture transaction stop*'
        Should -Invoke Assert-DemoEngine -Times 1
        Should -Invoke Assert-DemoDatabase -Times 1
        Should -Invoke Invoke-DemoSql -Times 2 -ParameterFilter { $TimeoutSeconds -eq 3 -and $Sql -match 'sys.databases' }
        Should -Invoke Write-EventLog -Times 1 -ParameterFilter { $EventId -eq 6000 -and $Message -match 'rows=8' }
        Should -Invoke Write-EventLog -Times 1 -ParameterFilter { $EventId -eq 6200 -and $Message -match 'phase=transaction' }
        ($script:coldStartClock - $script:coldStartOrigin).TotalSeconds | Should -Be 170
    }

    It 'does not delay already-ready SQL or alter the fifteen-second transaction interval' {
        Mock Invoke-DemoOrder {
            $script:orderCalls++
            if ($script:orderCalls -gt 1) { throw 'Fixture transaction stop.' }
            New-TestTable @{ DatabaseName = 'ArcDemoOrders'; OrderCount = 1; LastCommitUtc = $script:coldStartClock }
        }
        { Invoke-DemoWorkload } | Should -Throw '*Fixture transaction stop*'
        Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -eq 15 }
        Should -Invoke Write-EventLog -Times 1 -ParameterFilter { $EventId -eq 6000 }
    }

    It 'bounds stopped-engine startup and emits one actionable terminal error without transactions' {
        Mock Get-Service { @{ Status = 'Stopped' } }
        { Invoke-DemoWorkload } | Should -Throw '*600-second budget*service=Stopped*'
        ($script:coldStartClock - $script:coldStartOrigin).TotalSeconds | Should -Be 600
        Should -Invoke Invoke-DemoSql -Times 0
        Should -Invoke Invoke-DemoOrder -Times 0
        Should -Invoke Write-EventLog -Times 1 -ParameterFilter {
            $EventId -eq 6200 -and $EntryType -eq 'Error' -and $Message -match 'phase=startup' -and $Message -match 'no service restart'
        }
        Should -Invoke Write-EventLog -Times 0 -ParameterFilter { $EventId -eq 6000 }
    }

    It 'bounds database recovery and never treats other database states as transient' -ForEach @(
        @{ DatabaseState = 2; WaitExpected = $true }
        @{ DatabaseState = 1; WaitExpected = $false }
        @{ DatabaseState = 3; WaitExpected = $false }
        @{ DatabaseState = 4; WaitExpected = $false }
        @{ DatabaseState = 6; WaitExpected = $false }
    ) {
        Mock Invoke-DemoSql { New-TestTable @{ DatabaseState = $DatabaseState } }
        if ($WaitExpected) {
            { Wait-DemoSqlReady -TimeoutSeconds 10 } | Should -Throw '*10-second budget*Recovering*'
            Should -Invoke Invoke-DemoSql -Times 1
        } else {
            { Wait-DemoSqlReady -TimeoutSeconds 10 } | Should -Throw '*diagnose rather than retry*'
            Should -Invoke Start-Sleep -Times 0
        }
    }

    It 'retries only known SQL connection-startup exceptions' -ForEach @(-2, 2, 53, 233) {
        $script:startupNumber = $_
        $script:probeCalls = 0
        Mock Invoke-DemoSql {
            $script:probeCalls++
            if ($script:probeCalls -eq 1) { throw 'Fixture wrapped SQL startup exception.' }
            New-TestTable @{ DatabaseState = 0 }
        }
        Mock Get-DemoSqlExceptionNumber { $script:startupNumber }
        Wait-DemoSqlReady
        Should -Invoke Invoke-DemoSql -Times 2
        Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -eq 5 }
    }

    It 'does not retry unknown, authentication, permission or paused-server SQL errors' -ForEach @($null, 18456, 229, 17142) {
        $script:startupNumber = $_
        Mock Invoke-DemoSql { throw 'Fixture non-startup error.' }
        Mock Get-DemoSqlExceptionNumber { $script:startupNumber }
        { Invoke-DemoWorkload } | Should -Throw '*Fixture non-startup error*'
        Should -Invoke Start-Sleep -Times 0
        Should -Invoke Invoke-DemoOrder -Times 0
        Should -Invoke Write-EventLog -Times 1 -ParameterFilter { $EventId -eq 6200 -and $Message -match 'phase=startup' }
    }

    It 'does not wait on a missing database or an invalid result shape' {
        Mock Invoke-DemoSql { ,([Data.DataTable]::new()) }
        { Invoke-DemoWorkload } | Should -Throw '*absent or startup query shape*'
        Should -Invoke Start-Sleep -Times 0
        Should -Invoke Assert-DemoDatabase -Times 0
    }

    It 'rejects a ready result arriving after the startup deadline' {
        Mock Invoke-DemoSql {
            $script:coldStartClock = $script:coldStartClock.AddSeconds(601)
            New-TestTable @{ DatabaseState = 0 }
        }
        { Invoke-DemoWorkload } | Should -Throw '*600-second budget*'
        Should -Invoke Invoke-DemoOrder -Times 0
        Should -Invoke Assert-DemoEngine -Times 0
        Should -Invoke Write-EventLog -Times 1 -ParameterFilter { $EventId -eq 6200 -and $Message -match 'phase=startup' }
    }

    It 'fails ownership and hash drift before polling or transactions' -ForEach @('manifest', 'hash', 'task') {
        if ($_ -eq 'manifest') { Mock Get-DemoManifest { throw 'Fixture foreign manifest.' } }
        elseif ($_ -eq 'hash') { Mock Get-FileHash { @{ Hash = 'B' * 64 } } }
        else { Mock Assert-DemoTask { throw 'Fixture foreign task.' } }
        { Invoke-DemoWorkload } | Should -Throw
        Should -Invoke Get-Service -Times 0
        Should -Invoke Invoke-DemoSql -Times 0
        Should -Invoke Invoke-DemoOrder -Times 0
        Should -Invoke Write-EventLog -Times 1 -ParameterFilter { $EventId -eq 6200 -and $Message -match 'phase=ownership' }
    }

    It 'does not retry incompatible engine or database ownership after connections are ready' -ForEach @('engine', 'database') {
        if ($_ -eq 'engine') { Mock Assert-DemoEngine { throw 'Fixture incompatible engine.' } }
        else { Mock Assert-DemoDatabase { throw 'Fixture foreign database.' } }
        { Invoke-DemoWorkload } | Should -Throw
        Should -Invoke Invoke-DemoSql -Times 1
        Should -Invoke Start-Sleep -Times 0
        Should -Invoke Invoke-DemoOrder -Times 0
        Should -Invoke Write-EventLog -Times 1 -ParameterFilter { $EventId -eq 6200 -and $Message -match 'phase=validation' }
    }

    It 'fails unexpected service states or denied service reads without waiting' -ForEach @('Paused', 'denied') {
        if ($_ -eq 'denied') { Mock Get-Service { throw 'Fixture service read denied.' } }
        else { Mock Get-Service { @{ Status = 'Paused' } } }
        { Invoke-DemoWorkload } | Should -Throw
        Should -Invoke Start-Sleep -Times 0
        Should -Invoke Invoke-DemoOrder -Times 0
        Should -Invoke Write-EventLog -Times 1 -ParameterFilter { $EventId -eq 6200 -and $Message -match 'phase=startup' }
    }
}

Describe 'SQL setup outcomes with mocked Windows APIs' {
    BeforeEach {
        $root = Join-Path $TestDrive ('new-engine-' + [guid]::NewGuid().ToString())
        $manifestPath = Join-Path $root 'manifest.json'
        $installedScript = Join-Path $root 'SqlEngineDemo.ps1'
        $sourcePath = $guestPath
        $instance = 'ARCDEMO'
        $database = 'ArcDemoOrders'
        $taskName = 'ArcSqlEngineDemo'
        $serviceName = 'MSSQL$ARCDEMO'
        $hash = 'A' * 64
        $framework = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
        $frameworkKey = [pscustomobject]@{}
        $frameworkKey | Add-Member ScriptMethod GetValue { param($name, $defaultValue) return 528040 }
        Mock Get-Process { $null }
        Mock Test-DemoRebootPending { $false }
        Mock Assert-DemoSqlExtensionBlocked {}
        Mock Get-FileHash { @{ Hash = $hash } }
        Mock Get-CimInstance {
            if ($ClassName -eq 'Win32_OperatingSystem') {
                @{ Version = '10.0.20348'; ProductType = 3; BuildNumber = '20348'; TotalVisibleMemorySize = 8MB; FreePhysicalMemory = 4MB }
            } elseif ($ClassName -eq 'Win32_LogicalDisk') { @{ FreeSpace = 20GB } }
        }
        Mock Get-ScheduledTask { @() }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $framework }
        Mock Get-Item { $frameworkKey } -ParameterFilter { $LiteralPath -eq $framework }
        Mock Get-Item { @{ VersionInfo = @{ ProductMajorPart = 16 } } } -ParameterFilter { $LiteralPath -eq 'Z:\setup.exe' }
        Mock Get-DiskImage { @{ Attached = $false } }
        Mock Mount-DiskImage { @{ Attached = $true } }
        Mock Get-Volume { @{ DriveLetter = 'Z' } }
        Mock Dismount-DiskImage {}
        Mock Get-AuthenticodeSignature { @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Microsoft, O=Microsoft Corporation' } } }
        Mock Complete-DemoWorkload { @{ status = 'pending' } }
    }

    It 'records actual setup exit and never retries/reboots on failure or 3010' -ForEach @(
        @{ Code = 0; Phase = 'initializing' }
        @{ Code = 3010; Phase = 'pending-reboot' }
        @{ Code = 1603; Phase = 'setup-failed' }
    ) {
        $fakeProcess = [pscustomobject]@{ ExitCode = $Code; HasExited = $true }
        $fakeProcess | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $this.HasExited }
        Mock Start-Process { $fakeProcess }
        if ($Code -eq 0) {
            (Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed).status | Should -Be 'pending'
            Should -Invoke Complete-DemoWorkload -Times 1
        } else {
            { Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed } | Should -Throw "*SQL setup exit $Code*"
            Should -Invoke Complete-DemoWorkload -Times 0
        }
        $record = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $record.phase | Should -Be $Phase
        $record.setupExitCode | Should -Be $Code
        Should -Invoke Start-Process -Times 1
        Should -Invoke Dismount-DiskImage -Times 1
    }

    It 'retains media and unknown in-flight state when the bounded wait expires' {
        $fakeProcess = [pscustomobject]@{ ExitCode = $null; HasExited = $false }
        $fakeProcess | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $false }
        Mock Start-Process { $fakeProcess }
        { Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed } | Should -Throw '*still active*'
        (Get-Content $manifestPath -Raw | ConvertFrom-Json).phase | Should -Be 'installing'
        Should -Invoke Dismount-DiskImage -Times 0
        Should -Invoke Start-Process -Times 1
        Should -Invoke Complete-DemoWorkload -Times 0
    }

    It 'rejects untrusted media before creating an owned manifest or installer process' {
        Mock Get-AuthenticodeSignature { @{ Status = 'NotSigned'; SignerCertificate = $null } }
        Mock Start-Process { throw 'Untrusted installer must not run.' }
        { Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed } | Should -Throw '*signed Microsoft SQL Server 2022*'
        Test-Path $manifestPath | Should -BeFalse
        Should -Invoke Start-Process -Times 0
        Should -Invoke Dismount-DiskImage -Times 1
    }

    It 'measures insufficient available memory before mounting or installing' {
        Mock Get-CimInstance {
            if ($ClassName -eq 'Win32_OperatingSystem') {
                @{ Version = '10.0.20348'; ProductType = 3; BuildNumber = '20348'; TotalVisibleMemorySize = 8MB; FreePhysicalMemory = 1MB }
            } elseif ($ClassName -eq 'Win32_LogicalDisk') { @{ FreeSpace = 20GB } }
        }
        Mock Start-Process { throw 'Insufficient host must not install.' }
        { Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed } | Should -Throw '*2GiB available*'
        Should -Invoke Start-Process -Times 0
        Should -Invoke Mount-DiskImage -Times 0
    }

    It 'refuses existing SQL services so setup cannot change another instance or shared Browser' {
        Mock Get-CimInstance { @{ Name = 'MSSQL$FOREIGN' } } -ParameterFilter { $ClassName -eq 'Win32_Service' }
        Mock Start-Process { throw 'Foreign SQL must remain unchanged.' }
        { Install-DemoEngine -MediaIsoPath 'C:\fixture.iso' -MediaSha256 $hash -AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed } | Should -Throw '*shared Browser*'
        Should -Invoke Start-Process -Times 0
        Should -Invoke Mount-DiskImage -Times 0
    }
}

Describe 'Real SQL incident with mocked sessions' {
    BeforeEach {
        $instance = 'ARCDEMO'
        $database = 'ArcDemoOrders'
        $eventSource = 'ArcSqlEngineDemo'
        $blockerFixture = New-TestIncidentConnection Blocker
        $victimFixture = New-TestIncidentConnection Victim
        Mock New-DemoIncidentConnection { if ($Role -eq 'Blocker') { $blockerFixture } else { $victimFixture } }
        Mock Get-DemoIncidentSessionId { if ($Connection.Role -eq 'Blocker') { 61 } else { 62 } }
        Mock Get-DemoSqlStatus { @{ status = 'pass' } }
        Mock Get-DemoSqlExceptionNumber { 1222 }
        Mock Write-EventLog {}
        Mock Invoke-DemoSql {
            if ($Sql -match 'sys.dm_tran_locks') { New-TestTable @{ LockCount = 1 } }
            elseif ($Sql -match 'sys.dm_exec_requests') { New-TestTable @{ VictimSessionId = 62; BlockerSessionId = 61; WaitType = 'LCK_M_X'; WaitResource = 'KEY: fixture' } }
            elseif ($Sql -match 'sys.dm_exec_sessions') { New-TestTable @{ Remaining = 0 } }
            else { New-TestTable @{ ProbeValue = 0 } }
        }
    }

    It 'records actual lock/1222 evidence before recovery and preserves the orders worker' {
        $result = Invoke-DemoSqlIncident
        $result.status | Should -Be 'recovered'
        $result.sqlErrorNumber | Should -Be 1222
        $result.ordersWorkerHealthy | Should -BeTrue
        $result.ownedSessionsRemaining | Should -Be 0
        $blockerFixture.Disposed | Should -BeTrue
        $victimFixture.Disposed | Should -BeTrue
        $blockerFixture.Command.CommandText | Should -Match "WAITFOR DELAY '00:00:12'"
        $blockerFixture.Command.CommandText | Should -Match 'sp_getapplock'
        $blockerFixture.Command.CommandText | Should -Not -Match 'COMMIT|dbo.Orders|KILL'
        $victimFixture.Command.CommandText | Should -Match 'SET LOCK_TIMEOUT 5000'
        $victimFixture.Command.CommandText | Should -Match 'ROLLBACK TRANSACTION'
        Should -Invoke Write-EventLog -Times 1 -ParameterFilter {
            $EventId -eq 6201 -and $Source -eq 'ArcSqlEngineDemo' -and $EntryType -eq 'Error' -and
            ($Message | ConvertFrom-Json).sqlErrorNumber -eq 1222 -and ($Message | ConvertFrom-Json).state -eq 'detected'
        }
        Should -Invoke Write-EventLog -Times 1 -ParameterFilter { $EventId -eq 6001 -and $EntryType -eq 'Information' -and ($Message | ConvertFrom-Json).state -eq 'recovered' }
        Should -Invoke Get-DemoSqlStatus -Times 2
    }

    It 'refuses a stale/unhealthy baseline without opening incident sessions' {
        Mock Get-DemoSqlStatus { @{ status = 'pending' } }
        { Invoke-DemoSqlIncident } | Should -Throw '*must be healthy*'
        Should -Invoke New-DemoIncidentConnection -Times 0
        Should -Invoke Write-EventLog -Times 0
    }

    It 'does not invent a lock incident without DMV wait evidence and still disposes its sessions' {
        Mock Invoke-DemoSql { [Data.DataTable]::new() } -ParameterFilter { $Sql -match 'sys.dm_exec_requests' }
        { Invoke-DemoSqlIncident } | Should -Throw '*No actual victim/blocker*'
        $blockerFixture.Disposed | Should -BeTrue
        $victimFixture.Disposed | Should -BeTrue
        Should -Invoke Write-EventLog -Times 0
    }

    It 'propagates unexpected SQL errors without claiming 1222 or recovery' {
        Mock Get-DemoSqlExceptionNumber { 1205 }
        { Invoke-DemoSqlIncident } | Should -Throw '*Fixture SQL exception*'
        $blockerFixture.Disposed | Should -BeTrue
        $victimFixture.Disposed | Should -BeTrue
        Should -Invoke Write-EventLog -Times 0
    }

    It 'reports unknown blocker cleanup rather than emitting recovery or retrying' {
        $blockerFixture = New-TestIncidentConnection Blocker -CleanupTimeout
        { Invoke-DemoSqlIncident } | Should -Throw '*cleanup failed/unknown*'
        $blockerFixture.Disposed | Should -BeTrue
        Should -Invoke Write-EventLog -Times 1 -ParameterFilter { $EventId -eq 6201 }
        Should -Invoke Write-EventLog -Times 0 -ParameterFilter { $EventId -eq 6001 }
    }

    It 'requires verification of zero remaining owned sessions before recovery' {
        Mock Invoke-DemoSql { New-TestTable @{ Remaining = 1 } } -ParameterFilter { $Sql -match 'sys.dm_exec_sessions' }
        { Invoke-DemoSqlIncident } | Should -Throw '*cleanup is not verified*'
        Should -Invoke Write-EventLog -Times 0 -ParameterFilter { $EventId -eq 6001 }
    }

    It 'does not claim recovery when the normal orders worker is no longer healthy' {
        $script:statusReadCount = 0
        Mock Get-DemoSqlStatus {
            $script:statusReadCount++
            @{ status = if ($script:statusReadCount -eq 1) { 'pass' } else { 'pending' } }
        }
        { Invoke-DemoSqlIncident } | Should -Throw '*Orders worker is no longer*'
        Should -Invoke Write-EventLog -Times 0 -ParameterFilter { $EventId -eq 6001 }
    }
}

Describe 'SQL-only Arc extension protection' {
    BeforeEach {
        $instance = 'ARCDEMO'
        $database = 'ArcDemoOrders'
        $script:blocks = @('Contoso/RetainedExtension')
        $script:allow = @('Microsoft.Azure.Monitor/AzureMonitorWindowsAgent')
        Mock Invoke-DemoArcConfig {
            $operation = $Arguments -join ' '
            switch ($operation) {
                'get config.mode' { 'full' }
                'get extensions.allowlist' { '[' + ($script:allow -join ' ') + ']' }
                'get extensions.blocklist' { '[' + ($script:blocks -join ' ') + ']' }
                'set extensions.blocklist Microsoft.AzureData/WindowsAgent.SqlServer --add' { $script:blocks += 'Microsoft.AzureData/WindowsAgent.SqlServer' }
                default { throw "Unexpected agent operation: $operation" }
            }
        }
        Mock Get-CimInstance {
            @('himds', 'ExtensionService', 'GCArcService') | ForEach-Object { [pscustomobject]@{ Name = $_; State = 'Running'; StartMode = 'Auto' } }
        }
        Mock Get-Process { [pscustomobject]@{ ProcessName = 'MonAgentCore'; Id = 123 } }
    }

    It 'appends only the exact SQL publisher/type and preserves other policy and service state' {
        $result = Set-DemoSqlExtensionBlock
        $result.status | Should -Be 'protected'
        $result.monitoringUnchanged | Should -BeTrue
        $result.policy.blocklist.Count | Should -Be 2
        $result.policy.allowlist | Should -Contain 'Microsoft.Azure.Monitor/AzureMonitorWindowsAgent'
        Should -Invoke Invoke-DemoArcConfig -Times 1 -ParameterFilter { $Arguments[0] -eq 'set' -and ($Arguments -join ' ') -eq 'set extensions.blocklist Microsoft.AzureData/WindowsAgent.SqlServer --add' }
    }

    It 'does not rewrite an already blocked SQL extension' {
        $script:blocks += 'Microsoft.AzureData/WindowsAgent.SqlServer'
        (Set-DemoSqlExtensionBlock).changed | Should -BeFalse
        Should -Invoke Invoke-DemoArcConfig -Times 0 -ParameterFilter { $Arguments[0] -eq 'set' }
    }

    It 'accepts empty lists without treating a Windows PowerShell JSON array as an entry' {
        $script:blocks = @()
        $script:allow = @()
        $result = Set-DemoSqlExtensionBlock
        $result.policy.allowlist.Count | Should -Be 0
        $result.policy.blocklist.Count | Should -Be 1
        $result.policy.blocklist[0] | Should -Be 'Microsoft.AzureData/WindowsAgent.SqlServer'
    }

    It 'refuses a conflicting SQL allowlist without overriding it' {
        $script:allow += 'Microsoft.AzureData/WindowsAgent.SqlServer'
        { Set-DemoSqlExtensionBlock } | Should -Throw '*policy conflict*'
        Should -Invoke Invoke-DemoArcConfig -Times 0 -ParameterFilter { $Arguments[0] -eq 'set' }
    }

    It 'does not change agent mode or accept an unknown/malformed list' {
        Mock Invoke-DemoArcConfig { 'monitor' } -ParameterFilter { ($Arguments -join ' ') -eq 'get config.mode' }
        { Set-DemoSqlExtensionBlock } | Should -Throw '*no mode change*'
        Should -Invoke Invoke-DemoArcConfig -Times 0 -ParameterFilter { $Arguments[0] -eq 'set' }
    }

    It 'blocks installation when actual local SQL protection is missing' {
        { Assert-DemoSqlExtensionBlocked } | Should -Throw '*not locally blocked*'
        Should -Invoke Invoke-DemoArcConfig -Times 0 -ParameterFilter { $Arguments[0] -eq 'set' }
    }
}

Describe 'SQL operation offline export and legacy path restriction' {
    It 'exports an explicitly selected target operation without Azure execution' {
        $path = Join-Path $TestDrive 'guest.ps1'
        $result = & $wrapper -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -MachineName 'sql-fixture' -GuestScriptOutputPath $path
        $result.executed | Should -BeFalse
        Test-Path $path | Should -BeTrue
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'does not write or execute an exported WhatIf' {
        $path = Join-Path $TestDrive 'preview.ps1'
        & $wrapper -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -MachineName 'sql-fixture' -GuestScriptOutputPath $path -WhatIf
        Test-Path $path | Should -BeFalse
    }

    It 'rejects installing without licence/media inputs before Azure access' {
        { & $wrapper -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -MachineName 'sql-fixture' -Action Install } | Should -Throw '*licence*'
    }

    It 'rejects unconfirmed Arc SQL opt-out before Azure access even with licence/media inputs' {
        { & $wrapper -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -MachineName 'sql-fixture' -Action Install -MediaIsoPath 'C:\fixture.iso' -MediaSha256 ('A' * 64) -AcceptDeveloperLicenseTerms } |
            Should -Throw '*effective Arc SQL*'
    }

    It 'retires the mixed deployment installer without Arc SQL extension or shared credentials' {
        $deploy = Get-Content (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -Raw
        $deploy | Should -Match 'if \(\$InstallSql\) \{ throw'
        $deploy | Should -Not -Match 'WindowsAgent\.SqlServer|SAPWD|Microsoft\.AzureArcData'
    }

    It 'rejects enabling the retired mixed path before preflight or cloud calls' -ForEach @(
        @{ Flag = @{ InstallSql = $true } }
        @{ Flag = @{ SkipSqlInstall = $false } }
    ) {
        $deploy = Join-Path $repo 'scripts\Deploy-ArcDemo.ps1'
        { & $deploy -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' @Flag -WhatIf } | Should -Throw '*mixed InstallSql/Arc SQL path is retired*'
    }
}
