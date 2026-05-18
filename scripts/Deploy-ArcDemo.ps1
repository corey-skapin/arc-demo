<#
.SYNOPSIS
    Deploys the Azure Arc + Azure Monitor demo end-to-end.

.DESCRIPTION
    Runs the following phases. Each phase is idempotent — re-running the script
    after a partial failure picks up where it left off.

      1. Pre-flight checks (PS, az, bicep, signed-in tenant, RBAC)
      2. Bicep main.bicep deployment (RGs, network, KV, LAW, DCRs, VMs,
         alerts, Defender, policies, budget)
      3. NAT Gateway (deployed separately so Hibernate can tear it down)
      4. Arc onboarding service principal
      5. Arc agent install on each VM (Windows via Arc ext path,
         Linux via Azure VM ext path — see AGENTS.md Gotcha 2)
      6. AMA install + DCR associations (DCRA against the Arc resource ID —
         see AGENTS.md Gotcha 3)
      7. Dependency Agent (Windows only — Ubuntu 22.04 kernel unsupported)
      8. Change Tracking extension
      9. (Optional) SQL Server 2022 Developer install on the 2 SQL hosts
     10. WindowsAgent.SqlServer extension to Arc-enable SQL
     11. Workbook upload
     12. Post-deploy validation (heartbeat, alert rule, workbook URL)

.PARAMETER SubscriptionId
    The Azure subscription to deploy into.

.PARAMETER TenantId
    The Entra tenant ID.

.PARAMETER AdminEmail
    Email address for budget + alert notifications.

.PARAMETER Location
    Azure region. Default: australiaeast.

.PARAMETER NamePrefix
    Used to derive resource group and resource names. Default: arc-demo.
    Two RGs will be created: rg-<prefix> and rg-<prefix>-infra.

.PARAMETER WindowsVmCount
    Number of Windows VMs. Default 5. The FIRST 2 become the SQL hosts (so set
    >= 2 if you want SQL).

.PARAMETER LinuxVmCount
    Number of Linux (Ubuntu 22.04) VMs. Default 3.

.PARAMETER VmSize
    VM SKU. Default Standard_B2as_v2 (2 vCPU / 8 GiB AMD burstable). Probe
    with `az vm create --validate` before changing — capacity restrictions
    on B-series are common in AU regions.

.PARAMETER AutoShutdownTime
    HHmm in AutoShutdownTimezone. Default 1900.

.PARAMETER AutoShutdownTimezone
    .NET timezone ID. Default 'Cen. Australia Standard Time'.

.PARAMETER BudgetAmount
    Monthly budget threshold in subscription currency. Default 200.

.PARAMETER SkipSqlInstall
    Skip the SQL Server install step (~20 min saved). Useful for iteration.

.PARAMETER WhatIf
    Show the Bicep what-if output and stop.

.EXAMPLE
    .\Deploy-ArcDemo.ps1 -SubscriptionId 6ff7d039-... -TenantId 4a2e6a7b-... `
        -AdminEmail corey@contoso.com
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$AdminEmail,
    [string]$Location = 'australiaeast',
    [string]$NamePrefix = 'arc-demo',
    [ValidateRange(1, 20)][int]$WindowsVmCount = 5,
    [ValidateRange(0, 20)][int]$LinuxVmCount = 3,
    [string]$VmSize = 'Standard_B2as_v2',
    [string]$AutoShutdownTime = '1900',
    [string]$AutoShutdownTimezone = 'Cen. Australia Standard Time',
    [int]$BudgetAmount = 200,
    [switch]$SkipSqlInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force

# Phase 1: pre-flight
$principalId = Test-Prerequisites -SubscriptionId $SubscriptionId -TenantId $TenantId

$arcRg   = "rg-$NamePrefix"
$infraRg = "rg-$NamePrefix-infra"
$kvName  = New-KeyVaultName -Prefix "kv-$($NamePrefix -replace '-','')"
$kvName  = $kvName.Substring(0, [Math]::Min(24, $kvName.Length))

# Phase 2: generate password, deploy Bicep
Write-Header 'Generating admin password + deploying Bicep'
$adminPwd = New-StrongPassword -Length 24

$paramFile = Join-Path $env:TEMP "arc-demo-params-$(Get-Random).json"
@{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
        location              = @{ value = $Location }
        arcResourceGroup      = @{ value = $arcRg }
        infraResourceGroup    = @{ value = $infraRg }
        tenantId              = @{ value = $TenantId }
        deployerPrincipalId   = @{ value = $principalId }
        keyVaultName          = @{ value = $kvName }
        adminUsername         = @{ value = 'azureuser' }
        adminPassword         = @{ value = $adminPwd }
        windowsVmCount        = @{ value = $WindowsVmCount }
        linuxVmCount          = @{ value = $LinuxVmCount }
        vmSize                = @{ value = $VmSize }
        autoShutdownTime      = @{ value = $AutoShutdownTime }
        autoShutdownTimezone  = @{ value = $AutoShutdownTimezone }
        adminEmail            = @{ value = $AdminEmail }
        budgetAmount          = @{ value = $BudgetAmount }
    }
} | ConvertTo-Json -Depth 12 | Set-Content -Path $paramFile -Encoding utf8

$deploymentName = "arc-demo-$(Get-Date -Format yyyyMMdd-HHmmss)"
$bicepFile = Join-Path $repoRoot 'bicep\main.bicep'

if ($WhatIfPreference) {
    Write-Step 'Running Bicep what-if...'
    az deployment sub what-if --name $deploymentName --location $Location `
        --template-file $bicepFile --parameters @$paramFile --only-show-errors
    Remove-Item $paramFile -Force
    return
}

Write-Step "Deploying main.bicep (deployment: $deploymentName)..."
$null = az deployment sub create --name $deploymentName --location $Location `
    --template-file $bicepFile --parameters @$paramFile --only-show-errors
$outputs = az deployment sub show --name $deploymentName --query properties.outputs -o json | ConvertFrom-Json
Remove-Item $paramFile -Force
Write-Ok 'Bicep deployment complete'

$workspaceId = $outputs.workspaceId.value
$workspaceCustomerId = $outputs.workspaceCustomerId.value
$vmNames     = $outputs.vmNames.value
$dcrCoreId   = $outputs.dcrCoreId.value
$dcrVmiId    = $outputs.dcrVmiId.value
$dcrCtId     = $outputs.dcrCtId.value
$winVms = $vmNames | Where-Object { $_ -like 'win-*' }
$lnxVms = $vmNames | Where-Object { $_ -like 'lnx-*' }
$sqlVms = $vmNames | Where-Object { $_ -like 'win-sql-*' }

# Phase 3: NAT Gateway (separate so Hibernate can delete it)
Write-Header 'Phase 3 — NAT Gateway'
$pipExists = az network public-ip show -g $infraRg -n pip-natgw --query id -o tsv 2>$null
if (-not $pipExists) {
    az network public-ip create -g $infraRg -n pip-natgw -l $Location `
        --sku Standard --allocation-method Static --only-show-errors -o none
    Write-Ok 'Public IP created'
} else { Write-Ok 'Public IP already exists' }

$natExists = az network nat gateway show -g $infraRg -n natgw-arc-demo --query id -o tsv 2>$null
if (-not $natExists) {
    az network nat gateway create -g $infraRg -n natgw-arc-demo -l $Location `
        --public-ip-addresses pip-natgw --idle-timeout 10 --only-show-errors -o none
    Write-Ok 'NAT Gateway created'
} else { Write-Ok 'NAT Gateway already exists' }

$attached = az network vnet subnet show -g $infraRg --vnet-name vnet-arc-demo -n snet-vms --query "natGateway.id" -o tsv 2>$null
if (-not $attached) {
    az network vnet subnet update -g $infraRg --vnet-name vnet-arc-demo -n snet-vms `
        --nat-gateway natgw-arc-demo --only-show-errors -o none
    Write-Ok 'NAT Gateway attached to subnet'
} else { Write-Ok 'Subnet already has NAT GW' }

# Phase 4: Arc onboarding SPN (idempotent)
Write-Header 'Phase 4 — Arc onboarding service principal'
$spnAppId = az ad sp list --display-name "sp-$NamePrefix-onboard" --query "[0].appId" -o tsv 2>$null
if ($spnAppId) {
    Write-Ok "SPN already exists ($spnAppId). Resetting credential to allow re-onboarding..."
    $spnSecret = az ad sp credential reset --id $spnAppId --query password -o tsv
} else {
    $spnJson = az ad sp create-for-rbac --name "sp-$NamePrefix-onboard" `
        --role "Azure Connected Machine Onboarding" `
        --scopes "/subscriptions/$SubscriptionId/resourceGroups/$arcRg" `
        --only-show-errors -o json | ConvertFrom-Json
    $spnAppId  = $spnJson.appId
    $spnSecret = $spnJson.password
    Write-Ok "SPN created ($spnAppId)"
}

# Helper script files
$libDir   = Join-Path $env:TEMP "arc-demo-onboard-$(Get-Random)"
New-Item -ItemType Directory -Path $libDir -Force | Out-Null
$winOnboard = @"
`$env:MSFT_ARC_TEST = 'true'
[Environment]::SetEnvironmentVariable('MSFT_ARC_TEST','true','Machine')
Invoke-WebRequest -Uri https://aka.ms/AzureConnectedMachineAgent -OutFile `$env:TEMP\acm.msi -UseBasicParsing
Start-Process msiexec.exe -Wait -ArgumentList "/i `$env:TEMP\acm.msi /qn"
& "`$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe" connect ``
  --service-principal-id $spnAppId --service-principal-secret '$spnSecret' ``
  --resource-group $arcRg --tenant-id $TenantId --location $Location ``
  --subscription-id $SubscriptionId ``
  --tags "owner=demo,purpose=arc-demo,costcenter=demo,env=demo"
"@
$lnxOnboard = @"
set -e
curl -sSL https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -o /tmp/pmp.deb
sudo dpkg -i /tmp/pmp.deb
sudo apt-get update -qq
sudo apt-get install -y azcmagent
sudo MSFT_ARC_TEST=true azcmagent connect \
  --service-principal-id $spnAppId --service-principal-secret '$spnSecret' \
  --resource-group $arcRg --tenant-id $TenantId --location $Location \
  --subscription-id $SubscriptionId \
  --tags "owner=demo,purpose=arc-demo,costcenter=demo,env=demo"
"@
$winFile = Join-Path $libDir 'arc-win.ps1'
$lnxFile = Join-Path $libDir 'arc-lnx.sh'
[System.IO.File]::WriteAllText($winFile, $winOnboard, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($lnxFile, $lnxOnboard, [System.Text.UTF8Encoding]::new($false))

# Phase 5: Arc onboarding (parallel, skips already-Connected machines)
Write-Header 'Phase 5 — Arc onboarding (parallel)'
$alreadyArc = (az connectedmachine list -g $arcRg --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ }
$toOnboard = $vmNames | Where-Object { $_ -notin $alreadyArc }
if (-not $toOnboard) {
    Write-Ok 'All VMs already Arc-onboarded — skipping'
} else {
    Write-Step "Onboarding $($toOnboard.Count) of $($vmNames.Count) VMs..."
    $jobs = @()
    foreach ($vm in $toOnboard) {
        $isWin = $vm -like 'win-*'
        $jobs += Start-Job -Name "onboard-$vm" -ScriptBlock {
            param($vm, $isWin, $infraRg, $f)
            $cmdId = if ($isWin) { 'RunPowerShellScript' } else { 'RunShellScript' }
            az vm run-command invoke -g $infraRg -n $vm --command-id $cmdId --scripts "@$f" --only-show-errors -o tsv 2>&1
        } -ArgumentList $vm, $isWin, $infraRg, ($(if ($isWin) { $winFile } else { $lnxFile }))
    }
    $jobs | Wait-Job -Timeout 1800 | Out-Null
    foreach ($j in $jobs) {
        $out = (Receive-Job $j 2>&1 | Out-String)
        if ($out -match 'Successfully Onboarded|ProvisioningState/succeeded|Connected') {
            Write-Ok $j.Name
        } else {
            Write-Warn "$($j.Name) — check Arc portal"
        }
        Remove-Job $j -Force
    }
}
Write-Step 'Waiting for all Arc machines to report Connected...'
$ok = Wait-Until -TimeoutSeconds 600 -IntervalSeconds 30 -Message 'Arc Connected' -Condition {
    $connected = (az connectedmachine list -g $arcRg --query "[?status=='Connected'].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ }
    return $connected.Count -ge $vmNames.Count
}
if (-not $ok) { throw 'Timed out waiting for all Arc machines to be Connected' }
Write-Ok 'All Arc machines Connected'

Remove-Item $libDir -Recurse -Force

# Phase 6: AMA (Windows via Arc, Linux via Azure VM) + DCR associations to Arc resource
Write-Header 'Phase 6 — Azure Monitor Agent + DCR associations'

$jobs = @()
foreach ($vm in $winVms) {
    $jobs += Start-Job -ScriptBlock {
        param($vm, $rg)
        az connectedmachine extension create -g $rg --machine-name $vm `
          -n AzureMonitorWindowsAgent --publisher Microsoft.Azure.Monitor `
          --type AzureMonitorWindowsAgent --enable-auto-upgrade true `
          --only-show-errors -o tsv 2>&1 | Out-Null
    } -ArgumentList $vm, $arcRg
}
foreach ($vm in $lnxVms) {
    $jobs += Start-Job -ScriptBlock {
        param($vm, $rg)
        az vm extension set -g $rg --vm-name $vm -n AzureMonitorLinuxAgent `
          --publisher Microsoft.Azure.Monitor --enable-auto-upgrade true `
          --only-show-errors -o tsv 2>&1 | Out-Null
    } -ArgumentList $vm, $infraRg
}
Write-Step "Installing AMA on $($vmNames.Count) machines (parallel)..."
$jobs | Wait-Job -Timeout 1800 | Out-Null
$jobs | ForEach-Object { Remove-Job $_ -Force }
Write-Ok 'AMA installs submitted'

Write-Step 'Associating DCRs (core + VMI + CT) with each Arc resource...'
foreach ($vm in $vmNames) {
    $resId = "/subscriptions/$SubscriptionId/resourceGroups/$arcRg/providers/Microsoft.HybridCompute/machines/$vm"
    foreach ($pair in @(
        @{ name = "dcra-core-$vm"; id = $dcrCoreId }
        @{ name = "dcra-vmi-$vm";  id = $dcrVmiId }
        @{ name = "dcra-ct-$vm";   id = $dcrCtId }
    )) {
        $body = @{ properties = @{ dataCollectionRuleId = $pair.id } }
        Invoke-AzRest -Method Put `
            -Url "https://management.azure.com$resId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($pair.name)?api-version=2022-06-01" `
            -Body $body | Out-Null
    }
}
Write-Ok "DCRAs created for $($vmNames.Count) machines × 3 rules"

# Phase 7: Dependency Agent (Windows only — Ubuntu kernel unsupported)
Write-Header 'Phase 7 — Dependency Agent (Windows only)'
$jobs = @()
foreach ($vm in $winVms) {
    $jobs += Start-Job -ScriptBlock {
        param($vm, $rg)
        az connectedmachine extension create -g $rg --machine-name $vm `
          -n DependencyAgentWindows --publisher Microsoft.Azure.Monitoring.DependencyAgent `
          --type DependencyAgentWindows --enable-auto-upgrade true `
          --only-show-errors -o tsv 2>&1 | Out-Null
    } -ArgumentList $vm, $arcRg
}
$jobs | Wait-Job -Timeout 1800 | Out-Null
$jobs | ForEach-Object { Remove-Job $_ -Force }
Write-Ok 'Dependency Agent installed on Windows VMs'

# Phase 8: Change Tracking extension (both OSes)
Write-Header 'Phase 8 — Change Tracking extension'
$jobs = @()
foreach ($vm in $winVms) {
    $jobs += Start-Job -ScriptBlock {
        param($vm, $rg)
        az connectedmachine extension create -g $rg --machine-name $vm `
          -n ChangeTracking-Windows --publisher Microsoft.Azure.ChangeTrackingAndInventory `
          --type ChangeTracking-Windows --enable-auto-upgrade true `
          --only-show-errors -o tsv 2>&1 | Out-Null
    } -ArgumentList $vm, $arcRg
}
foreach ($vm in $lnxVms) {
    $jobs += Start-Job -ScriptBlock {
        param($vm, $rg)
        az connectedmachine extension create -g $rg --machine-name $vm `
          -n ChangeTracking-Linux --publisher Microsoft.Azure.ChangeTrackingAndInventory `
          --type ChangeTracking-Linux --enable-auto-upgrade true `
          --only-show-errors -o tsv 2>&1 | Out-Null
    } -ArgumentList $vm, $arcRg
}
$jobs | Wait-Job -Timeout 1800 | Out-Null
$jobs | ForEach-Object { Remove-Job $_ -Force }
Write-Ok 'Change Tracking extension installed'

# Phase 9: SQL install
if ($SkipSqlInstall) {
    Write-Warn 'SkipSqlInstall set — skipping SQL Server install on win-sql-* hosts'
} elseif ($sqlVms) {
    Write-Header "Phase 9 — Installing SQL Server 2022 Developer on $($sqlVms.Count) hosts (~20 min)"
    $sqlScriptPath = Join-Path $env:TEMP "sql-install-$(Get-Random).ps1"
    $sqlScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$mediaDir = 'C:\SQL2022'
New-Item -ItemType Directory -Path $mediaDir -Force | Out-Null
Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2215158' `
    -OutFile "$mediaDir\SSEI.exe" -UseBasicParsing
& "$mediaDir\SSEI.exe" /ACTION=Download /MEDIAPATH=$mediaDir /MEDIATYPE=ISO /QUIET | Out-Null
Start-Sleep 60
$iso = Get-ChildItem $mediaDir -Filter '*.iso' | Select-Object -First 1
$mount = Mount-DiskImage -ImagePath $iso.FullName -PassThru
$drive = (Get-Volume -DiskImage $mount).DriveLetter
& "${drive}:\setup.exe" /Q /ACTION=Install /FEATURES=SQLENGINE /INSTANCENAME=MSSQLSERVER `
    /SQLSVCACCOUNT='NT AUTHORITY\NETWORK SERVICE' /SQLSYSADMINACCOUNTS='BUILTIN\Administrators' `
    /AGTSVCACCOUNT='NT AUTHORITY\NETWORK SERVICE' /TCPENABLED=1 /SECURITYMODE=SQL `
    /SAPWD='P@ssw0rd-DemoSQL-2026!' /IACCEPTSQLSERVERLICENSETERMS `
    /SUPPRESSPRIVACYSTATEMENTNOTICE /UPDATEENABLED=0 /SQLCOLLATION='SQL_Latin1_General_CP1_CI_AS'
Dismount-DiskImage -ImagePath $iso.FullName | Out-Null
Get-Service MSSQLSERVER | Format-List Name, Status
'@
    [System.IO.File]::WriteAllText($sqlScriptPath, $sqlScript, [System.Text.UTF8Encoding]::new($false))
    $jobs = @()
    foreach ($vm in $sqlVms) {
        $jobs += Start-Job -Name "sql-$vm" -ScriptBlock {
            param($vm, $rg, $f)
            az vm run-command invoke -g $rg -n $vm --command-id RunPowerShellScript --scripts "@$f" --only-show-errors --query "value[0].message" -o tsv 2>&1
        } -ArgumentList $vm, $infraRg, $sqlScriptPath
    }
    $jobs | Wait-Job -Timeout 3600 | Out-Null
    foreach ($j in $jobs) {
        $out = (Receive-Job $j 2>&1 | Out-String)
        if ($out -match 'MSSQLSERVER\s+Running|Status\s*:\s*Running') { Write-Ok $j.Name }
        else { Write-Warn $j.Name }
        Remove-Job $j -Force
    }
    Remove-Item $sqlScriptPath -Force

    Write-Header 'Phase 10 — Arc-enable SQL (BPA + Defender for SQL)'
    foreach ($vm in $sqlVms) {
        az connectedmachine extension create -g $arcRg --machine-name $vm `
          -n WindowsAgent.SqlServer --publisher Microsoft.AzureData --type WindowsAgent.SqlServer `
          --enable-auto-upgrade true `
          --settings '{\"SqlManagement\":{\"IsEnabled\":true}, \"LicenseType\":\"Paid\", \"AzureBestPracticesAssessment\":{\"IsEnabled\":true}}' `
          --only-show-errors -o tsv | Out-Null
    }
    Write-Ok 'WindowsAgent.SqlServer extension installed on SQL hosts'
}

# Phase 11: Workbook
Write-Header 'Phase 11 — Workbook'
$wbContent = Get-Content (Join-Path $repoRoot 'workbooks\arc-demo-overview.workbook.json') -Raw
$existingWb = az resource list -g $arcRg --resource-type Microsoft.Insights/workbooks `
    --query "[?tags.workbookTag=='arc-demo-overview'].id" -o tsv 2>$null
if ($existingWb) {
    Write-Ok 'Workbook already exists — skipping'
    $wbId = $existingWb
} else {
    $wbGuid = [guid]::NewGuid().ToString()
    $wbBody = @{
        location = $Location
        tags = @{ owner = 'demo'; purpose = 'arc-demo'; costcenter = 'demo'; env = 'demo'; workbookTag = 'arc-demo-overview' }
        kind = 'shared'
        properties = @{
            displayName    = 'Arc Demo — Estate Overview'
            serializedData = $wbContent
            version        = 'Notebook/1.0'
            category       = 'workbook'
            sourceId       = $workspaceId.ToLower()
        }
    }
    $r = Invoke-AzRest -Method Put `
        -Url "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$arcRg/providers/Microsoft.Insights/workbooks/${wbGuid}?api-version=2023-06-01" `
        -Body $wbBody
    $wbId = $r.id
    Write-Ok "Workbook created: $($r.properties.displayName)"
}

# Phase 12: validation
Write-Header 'Phase 12 — Validation'
Write-Step 'Waiting up to 10 min for first Heartbeats...'
$lawCustId = $workspaceCustomerId
$ok = Wait-Until -TimeoutSeconds 600 -IntervalSeconds 30 -Message 'Heartbeat' -Condition {
    $token = Get-LawQueryToken
    $hdr = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $body = @{ query = 'Heartbeat | where TimeGenerated > ago(10m) | summarize Hosts = dcount(Computer)' } | ConvertTo-Json
    try {
        $r = Invoke-RestMethod -Method Post -Headers $hdr -Body $body `
          -Uri "https://api.loganalytics.io/v1/workspaces/$lawCustId/query"
        $hosts = if ($r.tables[0].rows) { $r.tables[0].rows[0][0] } else { 0 }
        return $hosts -ge $vmNames.Count
    } catch { return $false }
}
if ($ok) { Write-Ok "Heartbeat received from all $($vmNames.Count) hosts" }
else { Write-Warn "Heartbeat not yet from all hosts — check portal, may need a few more minutes" }

Write-Header '🎉 Deploy complete'
$wbUrl = "https://portal.azure.com/#@$TenantId/resource$wbId"
Write-Host ''
Write-Host "  Workbook:  $wbUrl"
Write-Host "  Arc RG:    https://portal.azure.com/#@$TenantId/resource/subscriptions/$SubscriptionId/resourceGroups/$arcRg/overview"
Write-Host "  Infra RG:  https://portal.azure.com/#@$TenantId/resource/subscriptions/$SubscriptionId/resourceGroups/$infraRg/overview"
Write-Host ''
Write-Host "  Next steps:"
Write-Host "    - Wait ~12h for MCSB/NIST compliance scores to populate."
Write-Host "    - Wait ~30-60m for SQL Best Practice Assessment first run."
Write-Host "    - Use ./scripts/Hibernate-ArcDemo.ps1 between demos (~AUD 35/mo)."
Write-Host ''
