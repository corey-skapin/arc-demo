<#
.SYNOPSIS
    Verifies your machine and Azure context are ready to deploy the Arc demo.

.DESCRIPTION
    Runs the pre-flight checks Deploy-ArcDemo.ps1 runs, without deploying anything.
    Read-only and safe any time: it never installs a CLI extension or registers a provider
    or subscription feature. Container Apps and AKS add their own provider (and, for Container
    Apps, the containerapp CLI extension) exactly as Deploy-ArcDemo.ps1 does, and a nested SQL
    parent (or any fleet entry with securityType Standard) adds the
    Microsoft.Compute/UseStandardSecurityType feature.

.PARAMETER SubscriptionId
    The Azure subscription where the demo will live.

.PARAMETER TenantId
    The Entra tenant ID for the subscription.

.PARAMETER DeployerPrincipalId
    Optional Entra object ID (your own) to use when Graph signed-in-user lookup is blocked. It replaces
    only that lookup; the RBAC check still runs. See docs/troubleshooting.md (continuous access evaluation).

.PARAMETER SkinPath
    Optional demo skin JSON. Defaults to config\demo-skin.json. Its workloads.deployContainerApps
    and workloads.deployAks choose the extra providers and CLI extension to check.

.PARAMETER DeployContainerApps
    Overrides the skin, as the same parameter on Deploy-ArcDemo.ps1 does.

.PARAMETER DeployAks
    Overrides the skin, as the same parameter on Deploy-ArcDemo.ps1 does.

.EXAMPLE
    .\Test-Prerequisites.ps1 -SubscriptionId <SUBSCRIPTION_ID> -TenantId <TENANT_ID>
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$DeployerPrincipalId = '',
    [string]$SkinPath = '',
    [bool]$DeployContainerApps = $false,
    [bool]$DeployAks = $false
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force

$skin = Get-DemoSkin -Path $SkinPath -RepoRoot (Split-Path -Parent $PSScriptRoot)
if (-not $PSBoundParameters.ContainsKey('DeployContainerApps')) { $DeployContainerApps = [bool](Get-DemoSkinValue -Skin $skin -Path 'workloads.deployContainerApps' -Default $DeployContainerApps) }
if (-not $PSBoundParameters.ContainsKey('DeployAks')) { $DeployAks = [bool](Get-DemoSkinValue -Skin $skin -Path 'workloads.deployAks' -Default $DeployAks) }
$standardSecurityType = [bool](Get-DemoSkinValue -Skin $skin -Path 'workloads.deployArcOnPrem' -Default $true) -and
    (Test-DemoStandardSecurityTypeRequired -Skin $skin -FleetPath (Get-DemoSkinValue -Skin $skin -Path 'workloads.onPremFleetPath' -Default '') -RepoRoot (Split-Path -Parent $PSScriptRoot))
$prerequisites = Get-DemoPrerequisiteSet -ContainerApps:$DeployContainerApps -Aks:$DeployAks -StandardSecurityType:$standardSecurityType

$null = Test-Prerequisites -SubscriptionId $SubscriptionId -TenantId $TenantId -DeployerPrincipalId $DeployerPrincipalId -Providers $prerequisites.Providers -RequiredExtensions $prerequisites.Extensions -Features $prerequisites.Features
Write-Host ''
Write-Ok 'All prerequisites satisfied. Next: run the plan (Invoke-ArcDemoBuild.ps1 with your build config).'
