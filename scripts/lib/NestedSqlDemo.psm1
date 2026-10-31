#Requires -Version 5.1
Set-StrictMode -Version Latest

function New-NestedSqlAnswerXml {
    <#
    .SYNOPSIS
        Creates a sensitive answer document for a newly applied Server image.
    .DESCRIPTION
        Return this document only to restricted staging on a new guest image.
        Never log it, pass it on a command line, or apply it to a retained guest.
        DISM Apply-Unattend processes offlineServicing only; these specialize
        and oobeSystem settings must instead be available to first-boot Setup.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns XML in memory only; performs no state change.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('\A[A-Za-z][A-Za-z0-9-]{0,13}[A-Za-z0-9]\z', Options = [Text.RegularExpressions.RegexOptions]::None)]
        [string]$ComputerName,
        [Parameter(Mandatory)][securestring]$AdministratorPassword
    )
    $ErrorActionPreference = 'Stop'
    if ($AdministratorPassword.Length -lt 24 -or $AdministratorPassword.Length -gt 128) {
        throw 'A fresh protected Administrator credential of 24 to 128 characters is required.'
    }
    $pointer = [IntPtr]::Zero
    $plain = $null
    $escaped = $null
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdministratorPassword)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ($plain -cnotmatch '\A[\x21-\x7e]{24,128}\z' -or
            $plain -cnotmatch '[A-Z]' -or $plain -cnotmatch '[a-z]' -or
            $plain -notmatch '[0-9]' -or $plain -notmatch '[^A-Za-z0-9]') {
            throw 'The protected random credential must use printable ASCII and meet the approved complexity contract.'
        }
        $escaped = [Security.SecurityElement]::Escape($plain)
        @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$ComputerName</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>
      <UserAccounts><AdministratorPassword><Value>$escaped</Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts>
    </component>
  </settings>
</unattend>
"@
    } finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
        $plain = $null
        $escaped = $null
    }
}

Export-ModuleMember -Function New-NestedSqlAnswerXml
