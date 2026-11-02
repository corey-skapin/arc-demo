#Requires -Version 5.1
<#
.SYNOPSIS
    Guest side of Stage-DemoMedia.ps1: downloads pinned installer media with curl.exe
    (resumable), verifies size and SHA-256, then moves it into place.
.DESCRIPTION
    Runs inside a lab Windows VM as SYSTEM (Windows PowerShell 5.1) through Run Command.
    Settings arrive as base64 JSON; the script prints one ARC_GUEST_RESULT= line and
    ARC_DEMO_OK. A file that does not match its pin is never overwritten, and a
    download that does not match is discarded before it can take the final name.
#>
param(
    [Parameter(Mandatory)][ValidateSet('Save')][string]$Action,
    [Parameter(Mandatory)][string]$SettingsBase64
)
$ErrorActionPreference = 'Stop'

function Get-MediaHash {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Invoke-MediaDownload {
    param([string]$Url, [string]$Output)
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $curl)) { throw 'Windows curl.exe is unavailable; stop rather than use an unverified source.' }
    $arguments = @('--fail', '--location', '--silent', '--show-error', '--retry', '5', '--retry-connrefused',
        '--connect-timeout', '30', '--continue-at', '-', '--output', ('"' + $Output + '"'), ('"' + $Url + '"'))
    $process = Start-Process -FilePath $curl -ArgumentList $arguments -Wait -NoNewWindow -PassThru
    $process.ExitCode
}

function Save-MediaItem {
    param($Item, [string]$Root)
    $final = Join-Path $Root $Item.fileName
    $partial = $final + '.partial'
    $expectedBytes = [int64]$Item.bytes
    $expectedHash = ([string]$Item.sha256).ToUpperInvariant()
    if (Test-Path -LiteralPath $final) {
        $length = (Get-Item -LiteralPath $final).Length
        if ($length -ne $expectedBytes) { throw "Existing $($Item.fileName) is $length bytes, not the pinned $expectedBytes; refusing to overwrite it." }
        $hash = Get-MediaHash $final
        if ($hash -ne $expectedHash) { throw "Existing $($Item.fileName) has SHA-256 $hash, not the pinned $expectedHash; refusing to overwrite it." }
        return [pscustomobject]@{ id = [string]$Item.id; path = $final; bytes = $length; sha256 = $hash; state = 'present' }
    }
    $volume = Get-Volume -DriveLetter $Root.Substring(0, 1)
    $state = 'downloaded'
    if (Test-Path -LiteralPath $partial) {
        if (@(Get-Process -Name curl -ErrorAction SilentlyContinue).Count -gt 0) { throw 'A curl download is already running on this VM; wait for it instead of starting another.' }
        if ((Get-Item -LiteralPath $partial).Length -gt $expectedBytes) { throw "$partial is larger than the pinned size; delete it and run again." }
        $state = 'resumed'
    }
    $already = if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { 0 }
    if ($volume.SizeRemaining -lt ($expectedBytes - $already + 2GB)) { throw "Not enough free space on $($Root.Substring(0, 2)) for $($Item.fileName) plus a 2 GiB margin." }
    $exitCode = Invoke-MediaDownload -Url $Item.url -Output $partial
    if ($exitCode -eq 33 -and (Test-Path -LiteralPath $partial)) {
        # The server cannot resume: discard our own partial file and start once from zero.
        Remove-Item -LiteralPath $partial -Force
        $state = 'downloaded'
        $exitCode = Invoke-MediaDownload -Url $Item.url -Output $partial
    }
    if ($exitCode -ne 0) { throw "curl exited $exitCode while downloading $($Item.fileName); a partial file is kept so the next run resumes it." }
    $length = (Get-Item -LiteralPath $partial).Length
    if ($length -gt $expectedBytes) {
        Remove-Item -LiteralPath $partial -Force
        throw "Downloaded $length bytes for $($Item.fileName), more than the pinned $expectedBytes. Microsoft may have refreshed the file: confirm it, update config\demo-media.json and accept the terms again."
    }
    if ($length -lt $expectedBytes) { throw "Downloaded $length of $expectedBytes bytes for $($Item.fileName); the partial file is kept so the next run resumes it." }
    $hash = Get-MediaHash $partial
    if ($hash -ne $expectedHash) {
        Remove-Item -LiteralPath $partial -Force
        throw "Downloaded $($Item.fileName) has SHA-256 $hash, not the pinned $expectedHash. Microsoft may have refreshed the file: confirm it, update config\demo-media.json and accept the terms again. The mismatching download was discarded."
    }
    Move-Item -LiteralPath $partial -Destination $final
    [pscustomobject]@{ id = [string]$Item.id; path = $final; bytes = $length; sha256 = $hash; state = $state }
}

function Save-DemoMedia {
    param($Settings)
    $root = ([string]$Settings.root).TrimEnd('\')
    if ($root -notmatch '^[A-Za-z]:\\') { throw 'The destination must be an absolute path on a local drive.' }
    $volume = Get-Volume -DriveLetter $root.Substring(0, 1) -ErrorAction SilentlyContinue
    if (-not $volume -or [string]$volume.FileSystem -ne 'NTFS') { throw "Drive $($root.Substring(0, 2)) must be a local NTFS volume." }
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $results = @()
    foreach ($item in @($Settings.items)) { $results += Save-MediaItem -Item $item -Root $root }
    [pscustomobject]@{ items = @($results) }
}

$settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($SettingsBase64)) | ConvertFrom-Json
switch ($Action) {
    'Save' { $result = Save-DemoMedia -Settings $settings }
}
'ARC_GUEST_RESULT=' + ($result | ConvertTo-Json -Compress -Depth 5)
'ARC_DEMO_OK'
