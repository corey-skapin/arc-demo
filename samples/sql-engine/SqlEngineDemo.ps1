#Requires -Version 5.1
<#
.SYNOPSIS
    Runs an isolated, real SQL Server 2022 Developer demonstration on Windows.
.DESCRIPTION
    Guest-side helper. Installation requires approved Developer ISO media and
    explicit licence consent. No Arc SQL extension, SQL password or public listener.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Install', 'Status', 'Start', 'Stop', 'Incident', 'ProtectArcSql', 'Workload')]
    [string]$Action = 'Status',
    [string]$MediaIsoPath,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$MediaSha256,
    [switch]$AcceptDeveloperLicenseTerms,
    [switch]$ArcSqlAutoConnectOptOutConfirmed
)
$ErrorActionPreference = 'Stop'
$sourcePath = $PSCommandPath
$root = 'C:\ProgramData\ArcSqlEngineDemo'
$manifestPath = Join-Path $root 'manifest.json'
$installedScript = Join-Path $root 'SqlEngineDemo.ps1'
$instance = 'ARCDEMO'
$database = 'ArcDemoOrders'
$taskName = 'ArcSqlEngineDemo'
$eventSource = 'ArcSqlEngineDemo'

function Invoke-DemoSql {
    param([string]$Sql, [string]$Database = 'master', [switch]$NonQuery, [ValidateRange(1, 15)][int]$TimeoutSeconds = 15)
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = "Data Source=lpc:.\ARCDEMO;Initial Catalog=$Database;Integrated Security=True;Connect Timeout=5;Application Name=ArcSqlEngineDemo"
    $command = $null
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = $TimeoutSeconds
        $command.CommandText = $Sql
        if ($NonQuery) { $command.ExecuteNonQuery() | Out-Null; return }
        $table = New-Object System.Data.DataTable
        $reader = $command.ExecuteReader()
        try { $table.Load($reader) } finally { $reader.Dispose() }
        return ,$table
    } finally {
        if ($command) { $command.Dispose() }
        $connection.Dispose()
    }
}

function Test-DemoRebootPending {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($path in $paths) { if (Test-Path -LiteralPath $path) { return $true } }
    $session = Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    if ($session.GetValue('PendingFileRenameOperations')) { return $true }
    $updates = 'HKLM:\SOFTWARE\Microsoft\Updates'
    if ((Test-Path -LiteralPath $updates) -and (Get-Item -LiteralPath $updates).GetValue('UpdateExeVolatile', 0)) { return $true }
    return $false
}

function Get-DemoManifest {
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Owned SQL demo manifest is absent; do not adopt an existing instance.' }
    $record = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($record.schemaVersion -ne 1 -or $record.instance -ne $instance -or $record.database -ne $database) {
        throw 'SQL demo manifest does not identify this exact owned instance/database.'
    }
    return $record
}

function Assert-DemoEngine {
    $engine = Invoke-DemoSql @'
SELECT CONVERT(nvarchar(128),SERVERPROPERTY('Edition')) AS Edition,
       CONVERT(nvarchar(128),SERVERPROPERTY('ProductVersion')) AS Version,
       CONVERT(nvarchar(128),SERVERPROPERTY('InstanceName')) AS InstanceName,
       CONVERT(int,SERVERPROPERTY('IsIntegratedSecurityOnly')) AS WindowsOnly,
       CONVERT(nvarchar(128),CONNECTIONPROPERTY('net_transport')) AS Transport,
       (SELECT CONVERT(int,value_in_use) FROM sys.configurations WHERE name=N'max server memory (MB)') AS MemoryLimitMB,
       (SELECT CONVERT(int,value_in_use) FROM sys.configurations WHERE name=N'max degree of parallelism') AS MaxDop;
'@
    if ($engine.Rows.Count -ne 1 -or $engine.Rows[0].Edition -notmatch '^Developer Edition' -or $engine.Rows[0].Version -notmatch '^16\.' -or
        $engine.Rows[0].InstanceName -ne 'ARCDEMO' -or $engine.Rows[0].WindowsOnly -ne 1 -or $engine.Rows[0].Transport -ne 'Shared memory' -or
        $engine.Rows[0].MemoryLimitMB -ne 512 -or $engine.Rows[0].MaxDop -ne 1) {
        throw 'Expected SQL Server 2022 Developer instance ARCDEMO with Windows/shared-memory access and 512MB/MAXDOP1 limits; no adoption, reconfiguration or upgrade.'
    }
    return $engine.Rows[0]
}

function Assert-DemoDatabase {
    $proof = Invoke-DemoSql "SELECT CONVERT(nvarchar(128),value) AS Owner FROM sys.extended_properties WHERE class=0 AND name=N'ArcDemoOwner';" $database
    if ($proof.Rows.Count -ne 1 -or $proof.Rows[0].Owner -ne 'ArcSqlEngineDemo-v1') { throw 'Database ownership marker is absent or foreign.' }
}

function Assert-DemoTask {
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
    if ($task.Actions.Count -ne 1 -or $task.Actions[0].Execute -ne 'powershell.exe' -or
        $task.Actions[0].Arguments -ne "-NoProfile -File `"$installedScript`" -Action Workload" -or
        $task.Principal.UserId -notin @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18') -or
        $task.Principal.RunLevel -ne 'Highest') {
        throw 'Scheduled task does not match the owned SQL worker; refusing to change it.'
    }
    return $task
}

function Get-DemoSqlStatus {
    $record = Get-DemoManifest
    if ($record.phase -ne 'ready') { throw "SQL preparation is '$($record.phase)'; inspect prior setup/reboot before retrying. Never replay a possibly active installer." }
    if ((Get-FileHash -LiteralPath $installedScript -Algorithm SHA256).Hash -ne $record.scriptSha256) { throw 'Installed SQL worker differs from the owned manifest; no execution or health claim.' }
    $engine = Assert-DemoEngine
    Assert-DemoDatabase
    $rows = Invoke-DemoSql @'
SELECT DB_NAME() AS DatabaseName, COUNT_BIG(*) AS OrderCount,
       MAX(CommittedAtUtc) AS LastCommitUtc, SUM(Amount) AS TotalAmount
FROM dbo.Orders;
'@ $database
    if ($rows.Rows.Count -ne 1 -or $rows.Rows[0].OrderCount -lt 0 -or $rows.Rows[0].OrderCount -gt 1000) { throw 'Unexpected SQL query shape/row bound; no healthy workload claim.' }
    $task = Assert-DemoTask
    $lastCommit = if ($rows.Rows[0].LastCommitUtc -is [DBNull]) { $null } else { [DateTime]::SpecifyKind([datetime]$rows.Rows[0].LastCommitUtc, [DateTimeKind]::Utc) }
    $fresh = $lastCommit -and ([DateTime]::UtcNow - $lastCommit).TotalSeconds -ge 0 -and ([DateTime]::UtcNow - $lastCommit).TotalSeconds -le 120
    [pscustomobject]@{
        status = if ($task.State -eq 'Running' -and $task.Settings.Enabled -and $fresh) { 'pass' } else { 'pending' }
        checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        instance = [string]$engine.InstanceName; edition = [string]$engine.Edition; version = [string]$engine.Version
        memoryLimitMB = [int]$engine.MemoryLimitMB; maxDop = [int]$engine.MaxDop
        database = [string]$rows.Rows[0].DatabaseName; orderCount = [long]$rows.Rows[0].OrderCount
        lastCommitUtc = if ($lastCommit) { $lastCommit.ToString('o') } else { $null }
        taskState = [string]$task.State; taskEnabled = [bool]$task.Settings.Enabled
    }
}

function Initialize-DemoDatabase {
    $existing = Invoke-DemoSql "SELECT name FROM sys.databases WHERE name=N'ArcDemoOrders';"
    if ($existing.Rows.Count) { Assert-DemoDatabase; return }
    Invoke-DemoSql "CREATE DATABASE [ArcDemoOrders];" -NonQuery | Out-Null
    Invoke-DemoSql @'
EXEC sys.sp_addextendedproperty @name=N'ArcDemoOwner', @value=N'ArcSqlEngineDemo-v1';
CREATE TABLE dbo.Orders (
    OrderId bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    CommittedAtUtc datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    Amount decimal(10,2) NOT NULL
);
CREATE TABLE dbo.IncidentProbe (
    ProbeId int NOT NULL PRIMARY KEY CHECK (ProbeId=1),
    ProbeValue int NOT NULL CHECK (ProbeValue BETWEEN 0 AND 1)
);
INSERT dbo.IncidentProbe(ProbeId, ProbeValue) VALUES (1, 0);
'@ $database -NonQuery | Out-Null
    Invoke-DemoSql @'
ALTER DATABASE [ArcDemoOrders] SET RECOVERY SIMPLE;
ALTER DATABASE [ArcDemoOrders] MODIFY FILE (NAME=N'ArcDemoOrders', MAXSIZE=128MB, FILEGROWTH=8MB);
ALTER DATABASE [ArcDemoOrders] MODIFY FILE (NAME=N'ArcDemoOrders_log', MAXSIZE=64MB, FILEGROWTH=8MB);
'@ -NonQuery | Out-Null
}

function Invoke-DemoOrder {
    Invoke-DemoSql @'
SET XACT_ABORT ON;
BEGIN TRANSACTION;
INSERT dbo.Orders(Amount) VALUES (19.95);
DECLARE @id bigint=CONVERT(bigint,SCOPE_IDENTITY());
DELETE dbo.Orders WHERE OrderId <= @id-1000;
COMMIT TRANSACTION;
SELECT @@SERVERNAME AS ServerName, DB_NAME() AS DatabaseName,
       COUNT_BIG(*) AS OrderCount, MAX(CommittedAtUtc) AS LastCommitUtc
FROM dbo.Orders;
'@ $database
}

function New-DemoIncidentConnection {
    param([ValidateSet('Blocker', 'Victim')][string]$Role)
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = "Data Source=lpc:.\ARCDEMO;Initial Catalog=ArcDemoOrders;Integrated Security=True;Connect Timeout=5;Pooling=False;Asynchronous Processing=True;Application Name=ArcSqlEngineDemo-Incident$Role"
    try { $connection.Open(); return $connection }
    catch { $connection.Dispose(); throw }
}

function Get-DemoIncidentSessionId {
    param($Connection)
    $command = $Connection.CreateCommand()
    try {
        $command.CommandTimeout = 3
        $command.CommandText = 'SELECT @@SPID;'
        $id = [int]$command.ExecuteScalar()
        if ($id -lt 1 -or $id -gt 32767) { throw 'SQL returned an invalid session ID.' }
        return $id
    } finally { $command.Dispose() }
}

function Get-DemoSqlExceptionNumber {
    param([Exception]$Exception)
    $current = $Exception
    for ($depth = 0; $current -and $depth -lt 8; $depth++) {
        if ($current -is [Data.SqlClient.SqlException]) { return $current.Number }
        $current = $current.InnerException
    }
    return $null
}

function Wait-DemoSqlReady {
    param([ValidateRange(10, 600)][int]$TimeoutSeconds = 600)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $observed = 'not checked'
    while ((Get-Date) -lt $deadline) {
        $service = Get-Service -Name 'MSSQL$ARCDEMO' -ErrorAction Stop
        if ($service.Status -ne 'Running' -or $observed -eq 'not checked') { $observed = "service=$($service.Status)" }
        if ($service.Status -notin @('Stopped', 'StartPending', 'Running')) {
            throw "Unexpected SQL startup state: service=$($service.Status). No service changes were made."
        }
        if ($service.Status -eq 'Running') {
            $remaining = ($deadline - (Get-Date)).TotalSeconds
            # The probe has a five-second connection and three-second command bound.
            if ($remaining -lt 8) { break }
            $state = $null
            try {
                $state = Invoke-DemoSql "SELECT state AS DatabaseState FROM sys.databases WHERE name=N'ArcDemoOrders';" -TimeoutSeconds 3
            } catch {
                $number = Get-DemoSqlExceptionNumber $_.Exception
                if ($number -notin @(-2, 2, 53, 233)) { throw }
                $observed = "SQL startup connection error=$number"
            }
            if ((Get-Date) -ge $deadline) { break }
            if ($null -ne $state) {
                if ($state.Rows.Count -ne 1 -or $state.Rows[0].DatabaseState -is [DBNull]) {
                    throw 'Owned SQL database is absent or startup query shape is invalid; no initialization or adoption.'
                }
                if ($state.Rows[0].DatabaseState -eq 0) { return }
                if ($state.Rows[0].DatabaseState -ne 2) {
                    throw "Owned SQL database is not Online or Recovering (state=$($state.Rows[0].DatabaseState)); diagnose rather than retry."
                }
                $observed = 'database=Recovering'
            }
        }
        $remaining = [int][Math]::Floor(($deadline - (Get-Date)).TotalSeconds)
        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([Math]::Min(5, $remaining))
    }
    throw "SQL startup did not become ready within the $TimeoutSeconds-second budget ($observed). Inspect MSSQL`$ARCDEMO and database recovery; no service restart, schema change or installer replay."
}

function Invoke-DemoWorkload {
    $phase = 'ownership'
    try {
        $record = Get-DemoManifest
        if ($record.phase -ne 'ready' -or (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne $record.scriptSha256) {
            throw 'Worker ownership/version is not ready.'
        }
        Assert-DemoTask | Out-Null
        $phase = 'startup'
        Wait-DemoSqlReady
        $phase = 'validation'
        Assert-DemoEngine | Out-Null
        Assert-DemoDatabase
        $phase = 'transaction'
        $cycle = 0
        while ($true) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $rows = Invoke-DemoOrder
            $clock.Stop()
            if ($cycle % 4 -eq 0) {
                $row = $rows.Rows[0]
                $committed = [DateTime]::SpecifyKind([datetime]$row.LastCommitUtc, [DateTimeKind]::Utc).ToString('o')
                $message = "Real SQL commit/read succeeded; instance=$instance database=$($row.DatabaseName) rows=$($row.OrderCount) lastCommitUtc=$committed elapsedMs=$($clock.ElapsedMilliseconds)."
                Write-EventLog -LogName Application -Source $eventSource -EventId 6000 -EntryType Information -Message $message
            }
            $cycle++
            Start-Sleep -Seconds 15
        }
    } catch {
        Write-EventLog -LogName Application -Source $eventSource -EventId 6200 -EntryType Error -Message "Real SQL worker failed; phase=$phase; instance=$instance database=$database; $($_.Exception.Message)"
        throw
    }
}

function Invoke-DemoArcConfig {
    param([string[]]$Arguments)
    $agent = 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe'
    $text = (& $agent config @Arguments --json 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Arc agent configuration command failed: $text" }
    $result = $text | ConvertFrom-Json
    if ($result.Status -ne 'success') { throw 'Arc agent returned a non-success configuration result.' }
    return [string]$result.Data
}

function ConvertFrom-DemoExtensionList {
    param([string]$Value)
    if ($Value -notmatch '^\[(?:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(?:[ ,]+[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)*)?\]$') {
        throw 'Unknown extension-list format; no policy write.'
    }
    $body = $Value.Substring(1, $Value.Length - 2)
    if ($body) { $body -split '[ ,]+' }
}

function Get-DemoArcExtensionPolicy {
    $mode = (Invoke-DemoArcConfig -Arguments @('get', 'config.mode')).Trim('"')
    $allow = @(ConvertFrom-DemoExtensionList (Invoke-DemoArcConfig -Arguments @('get', 'extensions.allowlist')))
    $block = @(ConvertFrom-DemoExtensionList (Invoke-DemoArcConfig -Arguments @('get', 'extensions.blocklist')))
    $services = @(Get-CimInstance Win32_Service -Filter "Name='himds' OR Name='ExtensionService' OR Name='GCArcService'" -OperationTimeoutSec 20 |
        Sort-Object Name | Select-Object Name, State, StartMode)
    $ama = @(Get-Process -ErrorAction Stop | Where-Object ProcessName -eq 'MonAgentCore' | Sort-Object Id | ForEach-Object Id)
    if ($mode -ne 'full' -or $services.Count -ne 3 -or @($services | Where-Object State -ne 'Running').Count -or -not $ama.Count) {
        throw 'Require full agent mode, running Arc services and AMA MonAgentCore process; no mode change, restart or policy bypass.'
    }
    [pscustomobject]@{ mode = $mode; allowlist = $allow; blocklist = $block; services = $services; amaProcessIds = $ama }
}

function Assert-DemoSqlExtensionBlocked {
    if ('Microsoft.AzureData/WindowsAgent.SqlServer' -notin (Get-DemoArcExtensionPolicy).blocklist) {
        throw 'The exact Arc SQL publisher/type is not locally blocked; prepare ProtectArcSql under separate approval before SQL installation.'
    }
}

function Set-DemoSqlExtensionBlock {
    $type = 'Microsoft.AzureData/WindowsAgent.SqlServer'
    $before = Get-DemoArcExtensionPolicy
    if ($type -in $before.allowlist) { throw 'SQL extension is explicitly allowlisted; resolve the policy conflict rather than overriding it.' }
    $changed = $type -notin $before.blocklist
    if ($changed) { Invoke-DemoArcConfig -Arguments @('set', 'extensions.blocklist', $type, '--add') | Out-Null }
    $after = Get-DemoArcExtensionPolicy
    $expected = @(@($before.blocklist) + @($type) | Sort-Object -Unique)
    if ($after.mode -ne $before.mode -or
        ($before.allowlist | ConvertTo-Json -Compress) -cne ($after.allowlist | ConvertTo-Json -Compress) -or
        ($expected | ConvertTo-Json -Compress) -cne (@($after.blocklist | Sort-Object -Unique) | ConvertTo-Json -Compress) -or
        ($before.services | ConvertTo-Json -Compress) -cne ($after.services | ConvertTo-Json -Compress) -or
        ($before.amaProcessIds | ConvertTo-Json -Compress) -cne ($after.amaProcessIds | ConvertTo-Json -Compress)) {
        throw 'Extension policy readback drift or monitoring state changed; do not retry/rollback automatically.'
    }
    [pscustomobject]@{
        status = 'protected'; instance = $instance; database = $database
        blockedType = $type; changed = $changed; monitoringUnchanged = $true; policy = $after
    }
}

function Invoke-DemoSqlIncident {
    if ((Get-DemoSqlStatus).status -ne 'pass') { throw 'The real SQL orders worker must be healthy before an incident.' }
    $probe = Invoke-DemoSql 'SELECT ProbeValue FROM dbo.IncidentProbe WHERE ProbeId=1;' $database -TimeoutSeconds 3
    if ($probe.Rows.Count -ne 1 -or $probe.Rows[0].ProbeValue -ne 0) { throw 'Incident probe is absent, changed or already in use; no fault submitted.' }
    $blocker = $null
    $victim = $null
    $blockCommand = $null
    $victimCommand = $null
    $blockAsync = $null
    $failure = $null
    $cleanupFailures = New-Object 'Collections.Generic.List[string]'
    $incident = [ordered]@{
        schemaVersion = 1; scenario = 'sql-lock-timeout'; incidentId = [guid]::NewGuid().ToString()
        state = 'detected'; instance = $instance; database = $database
        blockerSessionId = 0; victimSessionId = 0; waitType = ''; waitResource = ''
        sqlErrorNumber = 1222; lockTimeoutMs = 5000; maxBlockSeconds = 12; observedAtUtc = ''
    }
    try {
        $blocker = New-DemoIncidentConnection Blocker
        $victim = New-DemoIncidentConnection Victim
        $incident.blockerSessionId = Get-DemoIncidentSessionId $blocker
        $incident.victimSessionId = Get-DemoIncidentSessionId $victim
        if ($incident.blockerSessionId -eq $incident.victimSessionId) { throw 'Incident requires two distinct actual SQL sessions.' }
        $blockCommand = $blocker.CreateCommand()
        $blockCommand.CommandTimeout = 20
        $blockCommand.CommandText = @'
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 1000;
BEGIN TRY
    BEGIN TRANSACTION;
    DECLARE @result int;
    EXEC @result=sys.sp_getapplock @Resource=N'ArcDemoSqlIncident-v1',
        @LockMode=N'Exclusive', @LockOwner=N'Transaction', @LockTimeout=0;
    IF @result < 0 THROW 51000, 'Another SQL incident is active.', 1;
    UPDATE dbo.IncidentProbe WITH (ROWLOCK) SET ProbeValue=1 WHERE ProbeId=1;
    IF @@ROWCOUNT <> 1 THROW 51001, 'Owned incident probe is absent.', 1;
    WAITFOR DELAY '00:00:12';
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
'@
        $blockAsync = $blockCommand.BeginExecuteNonQuery()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        do {
            $locks = Invoke-DemoSql "SELECT COUNT(*) AS LockCount FROM sys.dm_tran_locks WHERE request_session_id=$($incident.blockerSessionId) AND resource_type='KEY' AND request_mode='X' AND request_status='GRANT' AND resource_associated_entity_id IN (SELECT hobt_id FROM sys.partitions WHERE object_id=OBJECT_ID(N'dbo.IncidentProbe'));" $database -TimeoutSeconds 2
            if ($locks.Rows.Count -eq 1 -and $locks.Rows[0].LockCount -gt 0) { break }
            if ($blockAsync.IsCompleted -or $clock.Elapsed.TotalSeconds -ge 2) { throw 'The owned blocking session did not acquire the probe lock; no incident claim.' }
            Start-Sleep -Milliseconds 100
        } while ($true)
        $victimCommand = $victim.CreateCommand()
        $victimCommand.CommandTimeout = 10
        $victimCommand.CommandText = @'
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 5000;
BEGIN TRY
    BEGIN TRANSACTION;
    UPDATE dbo.IncidentProbe SET ProbeValue=1 WHERE ProbeId=1;
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
'@
        $victimAsync = $victimCommand.BeginExecuteNonQuery()
        $clock.Restart()
        do {
            $waiting = Invoke-DemoSql "SELECT session_id AS VictimSessionId, blocking_session_id AS BlockerSessionId, wait_type AS WaitType, wait_resource AS WaitResource FROM sys.dm_exec_requests WHERE session_id=$($incident.victimSessionId) AND blocking_session_id=$($incident.blockerSessionId) AND database_id=DB_ID();" $database -TimeoutSeconds 2
            if ($waiting.Rows.Count -eq 1 -and $waiting.Rows[0].WaitType -match '^LCK_M_') { break }
            if ($victimAsync.IsCompleted -or $clock.Elapsed.TotalSeconds -ge 2) { throw 'No actual victim/blocker lock-wait evidence was captured; no incident claim.' }
            Start-Sleep -Milliseconds 100
        } while ($true)
        $incident.waitType = [string]$waiting.Rows[0].WaitType
        $incident.waitResource = [string]$waiting.Rows[0].WaitResource
        if (-not $victimAsync.AsyncWaitHandle.WaitOne(10000)) { throw 'Victim completion is unknown after its bounded wait; no expected-timeout claim.' }
        $timedOut = $false
        try { $victimCommand.EndExecuteNonQuery($victimAsync) | Out-Null }
        catch {
            if ((Get-DemoSqlExceptionNumber $_.Exception) -ne 1222) { throw }
            $timedOut = $true
        }
        if (-not $timedOut) { throw 'The victim did not return SQL error 1222; no incident event.' }
        $incident.observedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-EventLog -LogName Application -Source $eventSource -EventId 6201 -EntryType Error -Message ($incident | ConvertTo-Json -Compress)
    } catch { $failure = $_ }
    finally {
        try {
            if ($blockAsync) {
                if (-not $blockAsync.AsyncWaitHandle.WaitOne(15000)) { throw 'Blocker completion unknown after its server-side 12-second rollback and client wait.' }
                $blockCommand.EndExecuteNonQuery($blockAsync) | Out-Null
            }
        } catch { $cleanupFailures.Add($_.Exception.Message) }
        foreach ($item in @($victimCommand, $victim, $blockCommand, $blocker)) {
            if ($item) {
                try { $item.Dispose() }
                catch { $cleanupFailures.Add($_.Exception.Message) }
            }
        }
    }
    if ($cleanupFailures.Count) { throw "SQL incident cleanup failed/unknown: $($cleanupFailures -join '; '). Original failure: $failure. Do not retry or kill unrelated sessions." }
    if ($failure) { throw $failure }
    $probe = Invoke-DemoSql 'SELECT ProbeValue FROM dbo.IncidentProbe WHERE ProbeId=1;' $database -TimeoutSeconds 3
    $sessions = Invoke-DemoSql "SELECT COUNT(*) AS Remaining FROM sys.dm_exec_sessions WHERE session_id IN ($($incident.blockerSessionId),$($incident.victimSessionId)) AND program_name IN (N'ArcSqlEngineDemo-IncidentBlocker',N'ArcSqlEngineDemo-IncidentVictim');" $database -TimeoutSeconds 3
    if ($probe.Rows.Count -ne 1 -or $probe.Rows[0].ProbeValue -ne 0 -or $sessions.Rows.Count -ne 1 -or $sessions.Rows[0].Remaining -ne 0) {
        throw 'Rollback/probe/session cleanup is not verified; no recovery event or automatic replay.'
    }
    if ((Get-DemoSqlStatus).status -ne 'pass') { throw 'Orders worker is no longer proven healthy; no recovery event or automatic repair.' }
    $incident.state = 'recovered'
    $incident.sqlErrorNumber = 0
    $incident.observedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-EventLog -LogName Application -Source $eventSource -EventId 6001 -EntryType Information -Message ($incident | ConvertTo-Json -Compress)
    [pscustomobject]@{
        status = 'recovered'; instance = $instance; database = $database
        incidentId = $incident.incidentId; observedAtUtc = $incident.observedAtUtc
        blockerSessionId = $incident.blockerSessionId; victimSessionId = $incident.victimSessionId
        sqlErrorNumber = 1222; waitType = $incident.waitType; waitResource = $incident.waitResource
        dataRetained = $true; ownedSessionsRemaining = 0; ordersWorkerHealthy = $true
    }
}

function Complete-DemoWorkload {
    param($Record)
    Assert-DemoEngine | Out-Null
    Initialize-DemoDatabase
    if (-not [Diagnostics.EventLog]::SourceExists($eventSource)) { New-EventLog -LogName Application -Source $eventSource }
    if (Test-Path -LiteralPath $installedScript) {
        if ((Get-FileHash -LiteralPath $installedScript -Algorithm SHA256).Hash -ne $Record.scriptSha256) { throw 'Existing owned worker changed; no overwrite.' }
    } else { Copy-Item -LiteralPath $sourcePath -Destination $installedScript }
    $existing = @(Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq $taskName)
    if ($existing.Count) { Assert-DemoTask | Out-Null }
    else {
        $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -File `"$installedScript`" -Action Workload"
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $taskAction -Trigger $trigger -Settings $settings -User SYSTEM -RunLevel Highest | Out-Null
    }
    $Record.phase = 'ready'
    $Record | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    if (-not $existing.Count) { Start-ScheduledTask -TaskName $taskName -TaskPath '\' }
    Get-DemoSqlStatus
}

function Install-DemoEngine {
    param([string]$MediaIsoPath, [string]$MediaSha256, [switch]$AcceptDeveloperLicenseTerms, [switch]$ArcSqlAutoConnectOptOutConfirmed)
    $record = $null
    if (-not $AcceptDeveloperLicenseTerms -or -not $MediaIsoPath -or -not $MediaSha256) {
        throw 'Install requires user-accepted Developer licence terms and an explicitly approved local Developer ISO path/SHA256.'
    }
    if (-not $ArcSqlAutoConnectOptOutConfirmed) {
        throw 'Confirm a reviewed effective Arc SQL automatic-connection opt-out before installing; installation never changes tags/extension policy.'
    }
    Assert-DemoSqlExtensionBlocked
    if (Test-Path -LiteralPath $manifestPath) {
        $record = Get-DemoManifest
        if ($record.mediaSha256 -ne $MediaSha256 -or
            (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne $record.scriptSha256) { throw 'Owned worker source differs; no implicit upgrade/restart.' }
        if ($record.phase -eq 'ready') { return Get-DemoSqlStatus }
        if ($record.phase -notin @('initializing', 'pending-reboot') -or $record.setupExitCode -notin @(0, 3010)) {
            throw "Prior SQL installation is '$($record.phase)'; diagnose rather than replay."
        }
    }
    if (Get-Process | Where-Object { $_.ProcessName -in @('setup', 'ScenarioEngine', 'SqlSetupBootstrapper') -or $_.ProcessName -match '^SQL.*SSEI' }) { throw 'An installer may be active. Inspect it; do not replay SQL setup.' }
    if (Test-DemoRebootPending) { throw 'A reboot/pending rename is recorded. Resolve with the operator; no automatic reboot or bypass.' }
    if ($record) {
        if ($record.phase -eq 'pending-reboot') {
            $boot = (Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 20).LastBootUpTime.ToUniversalTime()
            if ($boot -le ([datetime]$record.startedAtUtc).ToUniversalTime()) { throw 'Setup requested a reboot and no later boot is observed; no automatic reboot or setup replay.' }
        }
        return Complete-DemoWorkload $record
    }
    if (Get-CimInstance Win32_Service -Filter "Name LIKE 'MSSQL%'" -OperationTimeoutSec 20) {
        throw 'Existing SQL services found; no adoption, side-by-side setup or shared Browser reconfiguration.'
    }
    if (Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq $taskName) { throw 'An unowned SQL demo task exists.' }
    if (Test-Path -LiteralPath $root) { throw 'Unowned SQL demo directory exists; inspect before preparation.' }
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 20
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -OperationTimeoutSec 20
    if ($os.Version -notmatch '^10\.' -or $os.ProductType -ne 3 -or [int]$os.BuildNumber -lt 14393 -or $os.TotalVisibleMemorySize * 1KB -lt 4GB -or $os.FreePhysicalMemory * 1KB -lt 2GB -or $disk.FreeSpace -lt 10GB) {
        throw 'Require Windows Server 2016+, at least 4GiB RAM/2GiB available and 10GiB free disk; no automatic resize or cleanup.'
    }
    $framework = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    if (-not [Environment]::Is64BitOperatingSystem -or -not (Test-Path -LiteralPath $framework) -or
        (Get-Item -LiteralPath $framework).GetValue('Release', 0) -lt 461808) { throw 'Require x64 Windows and .NET Framework 4.7.2+ before installation; no implicit framework upgrade.' }
    if ($MediaIsoPath -notmatch '^[A-Za-z]:\\[^"]+\.iso$' -or
        (Get-FileHash -LiteralPath $MediaIsoPath -Algorithm SHA256).Hash -ne $MediaSha256) { throw 'Approved ISO hash/type does not match.' }
    $image = Get-DiskImage -ImagePath $MediaIsoPath
    $mountedHere = -not $image.Attached
    $process = $null
    try {
        if ($mountedHere) { $image = Mount-DiskImage -ImagePath $MediaIsoPath -Access ReadOnly -PassThru }
        $volumes = @($image | Get-Volume)
        if ($volumes.Count -ne 1 -or -not $volumes[0].DriveLetter) { throw 'SQL media does not have one accessible volume.' }
        $setup = "$($volumes[0].DriveLetter):\setup.exe"
        $signature = Get-AuthenticodeSignature -FilePath $setup
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation' -or
            (Get-Item -LiteralPath $setup).VersionInfo.ProductMajorPart -ne 16) { throw 'Expected signed Microsoft SQL Server 2022 setup media.' }
        New-Item -ItemType Directory -Path $root | Out-Null
        $record = [ordered]@{
            schemaVersion = 1; instance = $instance; database = $database; phase = 'installing'
            mediaSha256 = $MediaSha256; scriptSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
            startedAtUtc = [DateTime]::UtcNow.ToString('o'); setupExitCode = $null
        }
        $record | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $arguments = @(
            '/Q', '/ACTION=Install', '/FEATURES=SQLENGINE', '/INSTANCENAME=ARCDEMO',
            '/SQLSYSADMINACCOUNTS="NT AUTHORITY\SYSTEM"', '/SQLSVCSTARTUPTYPE=Automatic',
            '/AGTSVCSTARTUPTYPE=Disabled',
            '/SQLMAXMEMORY=512', '/SQLMAXDOP=1', '/SQLTEMPDBFILECOUNT=1',
            '/TCPENABLED=0', '/NPENABLED=0', '/BROWSERSVCSTARTUPTYPE=Disabled',
            '/UPDATEENABLED=False', '/IACCEPTSQLSERVERLICENSETERMS'
        )
        $process = Start-Process -FilePath $setup -ArgumentList $arguments -PassThru
        if (-not $process.WaitForExit(1200000)) { throw 'SQL setup still active after 20 minutes; no kill, replay or reboot. Inspect setup and manifest.' }
        $record.setupExitCode = $process.ExitCode
        $record.phase = if ($process.ExitCode -eq 0) { 'initializing' } elseif ($process.ExitCode -eq 3010) { 'pending-reboot' } else { 'setup-failed' }
        $record | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        if ($process.ExitCode -ne 0) { throw "SQL setup exit $($process.ExitCode), phase=$($record.phase); inspect Summary.txt. No automatic reboot or replay." }
    } finally {
        if ($mountedHere -and -not ($process -and -not $process.HasExited)) { Dismount-DiskImage -ImagePath $MediaIsoPath | Out-Null }
    }
    Complete-DemoWorkload $record
}

if ($Action -ne 'Status' -and -not $PSCmdlet.ShouldProcess("local SQL instance $instance / $database", $Action)) { return }
if ($Action -eq 'Workload') {
    Invoke-DemoWorkload
}
$result = switch ($Action) {
    'Install' { Install-DemoEngine -MediaIsoPath $MediaIsoPath -MediaSha256 $MediaSha256 -AcceptDeveloperLicenseTerms:$AcceptDeveloperLicenseTerms -ArcSqlAutoConnectOptOutConfirmed:$ArcSqlAutoConnectOptOutConfirmed }
    'Status' { Get-DemoSqlStatus }
    'Incident' { Invoke-DemoSqlIncident }
    'ProtectArcSql' { Set-DemoSqlExtensionBlock }
    'Start' {
        Get-DemoSqlStatus | Out-Null
        Enable-ScheduledTask -TaskName $taskName -TaskPath '\' | Out-Null
        if ((Assert-DemoTask).State -ne 'Running') { Start-ScheduledTask -TaskName $taskName -TaskPath '\' }
        Get-DemoSqlStatus
    }
    'Stop' {
        Get-DemoManifest | Out-Null
        Assert-DemoTask | Out-Null
        Stop-ScheduledTask -TaskName $taskName -TaskPath '\'
        Disable-ScheduledTask -TaskName $taskName -TaskPath '\' | Out-Null
        [pscustomobject]@{ status = 'stopped'; instance = $instance; database = $database; dataRetained = $true }
    }
}
'ARC_SQL_RESULT=' + ($result | ConvertTo-Json -Compress)
'ARC_DEMO_OK'
