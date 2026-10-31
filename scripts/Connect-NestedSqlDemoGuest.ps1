#Requires -Version 5.1
<#
.SYNOPSIS
    Installs and connects the new nested demo guest using the parent's private vault access.
.DESCRIPTION
    Run on the Hyper-V parent with the retained guest credential. Requires an
    OOBE-complete guest and an existing, approved private onboarding secret version.
    No identity creation, role assignment, secret rotation, or SQL installation.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The private HTTPS vault response is immediately converted in memory, never logged or exported.')]
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][pscredential]$GuestCredential,
    [Parameter(Mandatory)][string]$GuestAddress,
    [Parameter(Mandatory)][string]$Gateway,
    [Parameter(Mandatory)][string]$DnsServer,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$ArcName,
    [Parameter(Mandatory)][guid]$OnboardingApplicationId,
    [Parameter(Mandatory)][uri]$SecretVersionUri,
    [Parameter(Mandatory)][string]$VaultPrivateAddress
)
$ErrorActionPreference = 'Stop'
if ($SecretVersionUri.Scheme -ne 'https' -or
    $SecretVersionUri.Host -notlike '*.vault.azure.net' -or
    $SecretVersionUri.AbsolutePath -notmatch '\A/secrets/arc-onboarding-client-secret/[a-f0-9]{32}\z') {
    throw 'Supply the retained exact private onboarding secret version URI.'
}
if (-not $PSCmdlet.ShouldProcess($VmName, 'Configure NAT networking, install Arc, block SQL extension and connect with retained private onboarding')) { return }
$state = Invoke-Command -VMName $VmName -Credential $GuestCredential -ArgumentList $GuestAddress,$Gateway,$DnsServer -ScriptBlock {
    param($Address,$GatewayAddress,$DnsAddress)
    $ErrorActionPreference = 'Stop'
    $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
    if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState -ne 'IMAGE_STATE_COMPLETE' -or
        $setup.OOBEInProgress -ne 0 -or $setup.SystemSetupInProgress -ne 0) { throw 'Windows Setup incomplete' }
    $nic = Get-NetAdapter | Where-Object Status -EQ Up | Select-Object -First 1
    if (-not (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 | Where-Object IPAddress -EQ $Address)) {
        New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $Address -PrefixLength 24 -DefaultGateway $GatewayAddress | Out-Null
    }
    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $DnsAddress
    $networkDeadline=[datetime]::UtcNow.AddMinutes(3)
    $networkError='Static IPv4 address is not Preferred yet'
    do {
        $preferred=@(Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -eq $Address -and $_.AddressState -eq 'Preferred' }).Count -eq 1
        if ($preferred) {
            try {
                $resolved=@(Resolve-DnsName aka.ms -Type A -DnsOnly -QuickTimeout -ErrorAction Stop |
                    Where-Object Type -EQ A)
                if ($resolved.Count -gt 0) { break }
                $networkError='aka.ms returned no A records'
            } catch [ComponentModel.Win32Exception] {
                if ($_.Exception.NativeErrorCode -eq 5) { throw }
                $networkError=$_.Exception.Message
            }
        }
        if ([datetime]::UtcNow -ge $networkDeadline) { throw "Guest networking not ready: $networkError" }
        Start-Sleep 5
    } while ($true)
    if (-not (Get-NetFirewallRule -DisplayName 'Block Azure IMDS for nested Arc demo' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'Block Azure IMDS for nested Arc demo' -Direction Outbound -Action Block -RemoteAddress 169.254.169.254 | Out-Null
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $agent = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
    if (-not (Test-Path $agent)) {
        $msi = "$env:TEMP\AzureConnectedMachineAgent.msi"
        Invoke-WebRequest https://aka.ms/AzureConnectedMachineAgent -OutFile $msi -UseBasicParsing
        if ((Get-AuthenticodeSignature $msi).Status -ne 'Valid') { throw 'Agent installer signature invalid' }
        $process = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart /l*v `"$env:TEMP\arc-install.log`"" -Wait -PassThru
        if ($process.ExitCode -notin @(0,3010)) { throw "Arc MSI failed: $($process.ExitCode)" }
    }
    $current = & $agent show --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Arc state read failed' }
    if ($current.status -eq 'Connected') { return $current }
    $null = & $agent config set extensions.blocklist 'Microsoft.AzureData/WindowsAgent.SqlServer' --add --json
    if ($LASTEXITCODE -ne 0) { throw 'SQL extension block failed' }
    $block = & $agent config get extensions.blocklist --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $block.Data -notmatch 'Microsoft\.AzureData/WindowsAgent\.SqlServer') { throw 'SQL extension block not confirmed' }
    $result = & $agent show --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Arc state read failed' }
    $result
}
$expectedId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$ArcName"
if ($state.status -eq 'Connected') {
    if ($state.resourceId -ne $expectedId) { throw 'Guest connected to another Arc resource' }
    $state
    return
}
if ($state.status -ne 'Disconnected') { throw 'Arc state is not ready for enrollment' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$addresses = @(Resolve-DnsName $SecretVersionUri.Host -Type A | Where-Object Type -EQ A | Select-Object -ExpandProperty IPAddress -Unique)
if ($addresses.Count -ne 1 -or $addresses[0] -ne $VaultPrivateAddress) { throw 'Private vault DNS differs' }
$token = Invoke-RestMethod 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' -Headers @{Metadata='true'}
$headers = @{Authorization=('Bearer ' + $token.access_token)}
$onboarding = $null
try {
    $secret = Invoke-RestMethod ($SecretVersionUri.AbsoluteUri + '?api-version=7.4') -Headers $headers
    if ($secret.id -ne $SecretVersionUri.AbsoluteUri -or -not $secret.attributes.enabled -or
        $secret.tags.appId -ne "$OnboardingApplicationId" -or $secret.tags.state -ne 'initialized' -or
        $secret.attributes.exp -le [datetimeoffset]::UtcNow.ToUnixTimeSeconds()) { throw 'Retained secret metadata differs' }
    $onboarding = ConvertTo-SecureString $secret.value -AsPlainText -Force
} finally { $secret = $null; $headers.Clear(); $token = $null }
try {
    Invoke-Command -VMName $VmName -Credential $GuestCredential -ArgumentList $onboarding,"$SubscriptionId","$TenantId",$ResourceGroup,$Location,$ArcName,"$OnboardingApplicationId" -ScriptBlock {
        param([securestring]$OnboardingSecret,$Subscription,$Tenant,$Group,$Region,$Name,$Application)
        $ErrorActionPreference = 'Stop'
        $agent = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
        $directory = New-Item -ItemType Directory -Path "$env:ProgramData\NestedArcConnect" -Force
        & icacls.exe $directory.FullName /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Protected directory ACL failed' }
        $path = Join-Path $directory.FullName 'connect.json'
        try {
            $config = @{
                'subscription-id'=$Subscription; 'tenant-id'=$Tenant; 'resource-group'=$Group
                'resource-name'=$Name; location=$Region; 'service-principal-id'=$Application
                'service-principal-secret'=[pscredential]::new('onboarding',$OnboardingSecret).GetNetworkCredential().Password
                tags='ArcSQLServerExtensionDeployment=Disabled'
            } | ConvertTo-Json
            [IO.File]::WriteAllText($path,$config)
            $config = $null
            $process = Start-Process $agent -ArgumentList "connect --config `"$path`" --json" -Wait -PassThru `
                -RedirectStandardOutput "$env:TEMP\arc-connect.stdout.txt" -RedirectStandardError "$env:TEMP\arc-connect.stderr.txt"
            Get-Content "$env:TEMP\arc-connect.stdout.txt" | Out-Host
            Get-Content "$env:TEMP\arc-connect.stderr.txt" | Out-Host
            if ($process.ExitCode -ne 0) { throw "Arc connect failed: $($process.ExitCode)" }
        } finally { Remove-Item -LiteralPath $path -Force; $config=$null }
        $state = & $agent show --json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $state.status -ne 'Connected') { throw 'Arc connection not verified' }
        $state
    }
} finally { $onboarding.Dispose() }
