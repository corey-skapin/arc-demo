<#
.SYNOPSIS
    Verifies your machine and Azure context are ready to deploy the Arc demo.

.DESCRIPTION
    Runs all the pre-flight checks the deploy script would run, without
    deploying anything. Safe to run any time.

.PARAMETER SubscriptionId
    The Azure subscription where the demo will live.

.PARAMETER TenantId
    The Entra tenant ID for the subscription.

.EXAMPLE
    .\Test-Prerequisites.ps1 -SubscriptionId 6ff7d039-... -TenantId 4a2e6a7b-...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force

$null = Test-Prerequisites -SubscriptionId $SubscriptionId -TenantId $TenantId
Write-Host ''
Write-Ok 'All prerequisites satisfied. You can now run Deploy-ArcDemo.ps1.'
