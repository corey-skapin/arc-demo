#Requires -Version 5.1
<#
.SYNOPSIS
    Installs SQL Server Developer from approved parent media in the new Arc-connected guest.
.DESCRIPTION
    Verify the Azure machine's SQL suppression tag before invoking this step.
    Uses original demo Setup administrator selection and product service defaults.
    Does not install the SQL extension or make manual SQL privilege changes.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][pscredential]$GuestCredential,
    [Parameter(Mandatory)][string]$SqlIsoPath,
    [Parameter(Mandatory)][string]$ExpectedArcResourceId
)
$ErrorActionPreference = 'Stop'
$null = Get-Item -LiteralPath $SqlIsoPath
if (-not $PSCmdlet.ShouldProcess($VmName, 'Install SQL Server Developer using approved media and default service accounts')) { return }
if (-not (Get-VMDvdDrive -VMName $VmName)) {
    Add-VMDvdDrive -VMName $VmName -Path $SqlIsoPath
} else { Set-VMDvdDrive -VMName $VmName -Path $SqlIsoPath }
Invoke-Command -VMName $VmName -Credential $GuestCredential -ArgumentList $ExpectedArcResourceId -ScriptBlock {
    param($ArcId)
    $ErrorActionPreference = 'Stop'
    $agent = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
    $state = & $agent show --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $state.status -ne 'Connected' -or $state.resourceId -ne $ArcId) { throw 'Expected Arc connection missing' }
    if (-not @(Get-Service | Where-Object Name -EQ MSSQLSERVER).Count) {
        $block = & $agent config get extensions.blocklist --json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $block.Data -notmatch 'Microsoft\.AzureData/WindowsAgent\.SqlServer') { throw 'SQL block missing' }
        $media = Get-Volume | Where-Object { $_.FileSystem -in @('CDFS','UDF') -and $_.DriveLetter } | Select-Object -First 1
        $setup = "$($media.DriveLetter):\setup.exe"
        $processes=@(Get-Process | Where-Object ProcessName -EQ setup)
        if (@($processes | Where-Object { [string]::IsNullOrWhiteSpace($_.Path) }).Count) {
            throw 'An existing setup process has an unknown executable path; no SQL install attempted.'
        }
        if (@($processes | Where-Object {
            $_.Path -ieq $setup -or $_.Path -like "$env:ProgramFiles\Microsoft SQL Server\*"
        }).Count) { throw 'SQL Setup already running' }
        if ((Get-AuthenticodeSignature $setup).Status -ne 'Valid') { throw 'SQL Setup signature invalid' }
        $arguments = '/Q /ACTION=Install /FEATURES=SQLENGINE /INSTANCENAME=MSSQLSERVER /IACCEPTSQLSERVERLICENSETERMS /SQLSYSADMINACCOUNTS="BUILTIN\Administrators" /TCPENABLED=1 /NPENABLED=0 /SQLSVCSTARTUPTYPE=Automatic /UPDATEENABLED=False'
        $process = Start-Process $setup -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -notin @(0,3010)) {
            Get-Content "$env:ProgramFiles\Microsoft SQL Server\160\Setup Bootstrap\Log\Summary.txt" | Out-Host
            throw "SQL Setup failed: $($process.ExitCode)"
        }
    }
    $connection = [Data.SqlClient.SqlConnection]::new('Server=localhost;Database=master;Integrated Security=True;Connect Timeout=15')
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = "SELECT CONVERT(nvarchar(128),SERVERPROPERTY('Edition')) + ' / ' + CONVERT(nvarchar(128),SERVERPROPERTY('ProductVersion'))"
        [pscustomobject]@{ SqlVersion=$command.ExecuteScalar(); ServiceStatus=[string](Get-Service MSSQLSERVER).Status }
    } finally { $connection.Dispose() }
}
