#Requires -Version 5.1
<#
.SYNOPSIS
    SQL-shaped workload simulator for the Arc demo.

.DESCRIPTION
    Emits Windows Application events that look like common SQL workload symptoms
    without claiming SQL Server enabled by Azure Arc. The simulator is used to
    create a DBA-relevant Arc + Monitor + SRE diagnostic beat in the Azure-only lab.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\ProgramData\ArcSqlWorkloadDemo\appsettings.json',

    [string]$LogPath = 'C:\ProgramData\ArcSqlWorkloadDemo\logs\sql-workload.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-SqlWorkloadLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $directory = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $line = '{0:o} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Output $line
}

function Get-SqlWorkloadConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if (-not $config.PSObject.Properties['FaultMode']) {
        $config | Add-Member -NotePropertyName FaultMode -NotePropertyValue 'Healthy'
    }
    if (-not $config.PSObject.Properties['LoopSeconds']) {
        $config | Add-Member -NotePropertyName LoopSeconds -NotePropertyValue 15
    }
    if (-not $config.PSObject.Properties['HeartbeatEveryCycles']) {
        $config | Add-Member -NotePropertyName HeartbeatEveryCycles -NotePropertyValue 4
    }
    if (-not $config.PSObject.Properties['EventSource']) {
        $config | Add-Member -NotePropertyName EventSource -NotePropertyValue 'ArcSqlWorkloadDemo'
    }
    if (-not $config.PSObject.Properties['WorkloadName']) {
        $config | Add-Member -NotePropertyName WorkloadName -NotePropertyValue 'Orders SQL Workload'
    }

    return $config
}

function Ensure-EventSource {
    param([Parameter(Mandatory = $true)][string]$Source)

    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
            New-EventLog -LogName Application -Source $Source
        }
    }
    catch {
        Write-SqlWorkloadLog -Level 'WARN' -Message "Unable to create event source '$Source': $($_.Exception.Message)"
    }
}

function Write-SqlWorkloadEvent {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [int]$EventId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$EntryType,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    try {
        Write-EventLog -LogName Application -Source $Config.EventSource -EventId $EventId -EntryType $EntryType -Message $Message
    }
    catch {
        Write-SqlWorkloadLog -Level 'WARN' -Message "Unable to write Application event ${EventId}: $($_.Exception.Message)"
    }
}

function Get-WorkloadContext {
    param([Parameter(Mandatory = $true)][psobject]$Config)

    $incidentId = if ($Config.PSObject.Properties['IncidentId']) { $Config.IncidentId } else { 'none' }
    return "workload=$($Config.WorkloadName) faultMode=$($Config.FaultMode) incidentId=$incidentId"
}

$pidPath = Join-Path (Split-Path -Parent $ConfigPath) 'sql-workload.pid'
$PID | Set-Content -LiteralPath $pidPath -Encoding ASCII

$initialConfig = Get-SqlWorkloadConfig
Ensure-EventSource -Source $initialConfig.EventSource
Write-SqlWorkloadLog -Message "SQL workload simulator starting. $(Get-WorkloadContext -Config $initialConfig)"
Write-SqlWorkloadEvent -Config $initialConfig -EventId 5000 -EntryType Information -Message "SQL workload simulator started. $(Get-WorkloadContext -Config $initialConfig)"

$cycle = 0
while ($true) {
    $config = Get-SqlWorkloadConfig
    $cycle++
    $context = Get-WorkloadContext -Config $config

    switch ($config.FaultMode) {
        'Healthy' {
            if (($cycle % [int]$config.HeartbeatEveryCycles) -eq 0) {
                $message = "SQL workload heartbeat: orders database responsive. cycle=$cycle $context"
                Write-SqlWorkloadLog -Message $message
                Write-SqlWorkloadEvent -Config $config -EventId 5000 -EntryType Information -Message $message
            }
        }
        'Blocking' {
            $message = "SQL workload degradation: blocking chain detected on Orders.SubmitOrder. cycle=$cycle $context"
            Write-SqlWorkloadLog -Level 'WARN' -Message $message
            Write-SqlWorkloadEvent -Config $config -EventId 5200 -EntryType Warning -Message $message
        }
        'ConnectionTimeout' {
            $message = "SQL workload failure: application connection timeout to orders database. cycle=$cycle $context"
            Write-SqlWorkloadLog -Level 'ERROR' -Message $message
            Write-SqlWorkloadEvent -Config $config -EventId 5100 -EntryType Error -Message $message
            exit 51
        }
        default {
            $message = "Unsupported FaultMode '$($config.FaultMode)' in $ConfigPath. $context"
            Write-SqlWorkloadLog -Level 'ERROR' -Message $message
            Write-SqlWorkloadEvent -Config $config -EventId 5101 -EntryType Error -Message $message
            exit 52
        }
    }

    Start-Sleep -Seconds ([int]$config.LoopSeconds)
}
