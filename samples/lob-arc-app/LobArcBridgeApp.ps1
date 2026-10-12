#Requires -Version 5.1
<#
.SYNOPSIS
    Tiny line-of-business worker used by the T11 Arc bridge scenario.

.DESCRIPTION
    The worker simulates an on-prem line-of-business app running on a Windows
    Arc-enabled server. It emits Application log events and a text log, then
    reads an appsettings.json fault flag so operators can induce a crash or a
    degraded state without changing the deployed source.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\ProgramData\ArcSreLobApp\appsettings.json',

    [string]$LogPath = 'C:\ProgramData\ArcSreLobApp\logs\lob-arc-app.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-AppLog {
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

function Get-AppConfig {
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
        $config | Add-Member -NotePropertyName EventSource -NotePropertyValue 'ArcLobBridgeApp'
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
        Write-AppLog -Level 'WARN' -Message "Unable to create event source '$Source': $($_.Exception.Message)"
    }
}

function Write-AppEvent {
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
        Write-AppLog -Level 'WARN' -Message "Unable to write Application event ${EventId}: $($_.Exception.Message)"
    }
}

function Get-RepositoryContext {
    param([Parameter(Mandatory = $true)][psobject]$Config)

    $repository = if ($Config.PSObject.Properties['SourceRepositoryUrl']) { $Config.SourceRepositoryUrl } else { '<not set>' }
    $commit = if ($Config.PSObject.Properties['SourceCommit']) { $Config.SourceCommit } else { '<not set>' }
    $path = if ($Config.PSObject.Properties['SourcePath']) { $Config.SourcePath } else { 'LobArcBridgeApp.ps1' }

    return "repo=$repository commit=$commit path=$path"
}

$pidPath = Join-Path (Split-Path -Parent $ConfigPath) 'lob-arc-app.pid'
$PID | Set-Content -LiteralPath $pidPath -Encoding ASCII

$initialConfig = Get-AppConfig
Ensure-EventSource -Source $initialConfig.EventSource
Write-AppLog -Message "LOB Arc bridge app starting. $(Get-RepositoryContext -Config $initialConfig)"
Write-AppEvent -Config $initialConfig -EventId 4000 -EntryType Information -Message "LOB Arc bridge app started. $(Get-RepositoryContext -Config $initialConfig)"

$cycle = 0
while ($true) {
    $config = Get-AppConfig
    $cycle++
    $context = Get-RepositoryContext -Config $config

    switch ($config.FaultMode) {
        'Healthy' {
            if (($cycle % [int]$config.HeartbeatEveryCycles) -eq 0) {
                $message = "Healthy business transaction heartbeat. cycle=$cycle $context"
                Write-AppLog -Message $message
                Write-AppEvent -Config $config -EventId 4000 -EntryType Information -Message $message
            }
        }
        'Degraded' {
            $message = "Degraded checkout dependency response detected. cycle=$cycle $context"
            Write-AppLog -Level 'WARN' -Message $message
            Write-AppEvent -Config $config -EventId 4200 -EntryType Warning -Message $message
        }
        'CrashOnProcessing' {
            $incidentId = if ($config.PSObject.Properties['IncidentId']) { $config.IncidentId } else { 'manual' }
            $message = "Fatal order-processing fault induced for T11. incidentId=$incidentId cycle=$cycle $context"
            Write-AppLog -Level 'ERROR' -Message $message
            Write-AppEvent -Config $config -EventId 4100 -EntryType Error -Message $message
            exit 42
        }
        default {
            $message = "Unsupported FaultMode '$($config.FaultMode)' in $ConfigPath. $context"
            Write-AppLog -Level 'ERROR' -Message $message
            Write-AppEvent -Config $config -EventId 4101 -EntryType Error -Message $message
            exit 43
        }
    }

    Start-Sleep -Seconds ([int]$config.LoopSeconds)
}
