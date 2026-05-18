# Azure Arc Demo — Build Runbook

> **Goal:** A replayable runbook for standing up the Arc + Azure Monitor demo modelled on Nic Seilaz's flow.
> Anyone can follow this end-to-end to rebuild the environment from scratch.

## Prerequisites
- Azure CLI ≥ 2.60 (`az version`)
- Permissions: **Owner** (or Contributor + User Access Administrator) on the target subscription
- A signed-in CLI session against the target tenant

```powershell
# Sign in to the MCAPS demo tenant
az login --tenant 4a2e6a7b-9d04-4e89-9d8b-01c75a2444c1
az account set --subscription 6ff7d039-8bfd-4cdb-8d74-f7a9f1eb9ff5
az account show --query "{name:name, id:id, tenantId:tenantId}" -o table
```

## Naming & tags (used everywhere)
| Item | Value |
|---|---|
| Resource group | `rg-arc-demo` |
| Region | `australiaeast` |
| Log Analytics | `law-arc-demo` |
| Tags | `owner=corey`, `purpose=arc-demo`, `costcenter=demo`, `env=demo` |

---

## Phase 1 — Foundations

### 1.1 Register required resource providers
Arc, Hybrid Compute, and Defender depend on these providers.

```powershell
foreach ($rp in @(
  'Microsoft.HybridCompute',
  'Microsoft.GuestConfiguration',
  'Microsoft.HybridConnectivity',
  'Microsoft.AzureArcData',
  'Microsoft.OperationalInsights',
  'Microsoft.OperationsManagement',
  'Microsoft.Insights',
  'Microsoft.Security',
  'Microsoft.PolicyInsights',
  'Microsoft.Compute',
  'Microsoft.Network',
  'Microsoft.Storage',
  'Microsoft.Logic'
)) {
  az provider register --namespace $rp --wait
}
```

### 1.2 Create resource group
```powershell
az group create `
  --name rg-arc-demo `
  --location australiaeast `
  --tags owner=corey purpose=arc-demo costcenter=demo env=demo
```

### 1.3 Create Log Analytics workspace
```powershell
az monitor log-analytics workspace create `
  --resource-group rg-arc-demo `
  --workspace-name law-arc-demo `
  --location australiaeast `
  --sku PerGB2018 `
  --retention-time 30 `
  --tags owner=corey purpose=arc-demo costcenter=demo env=demo
```

Capture the workspace resource ID for later phases:
```powershell
$lawId = az monitor log-analytics workspace show `
  --resource-group rg-arc-demo --workspace-name law-arc-demo `
  --query id -o tsv
```

### 1.4 Enable Defender for Servers Plan 2 on the subscription
```powershell
az security pricing create --name VirtualMachines --tier Standard --subplan P2
az security pricing show   --name VirtualMachines --query "{name:name,tier:pricingTier,subplan:subPlan}" -o table
```

### 1.5 Create the Cost Management budget alert (AUD 200/mo)
*Captured in Phase 7 — referenced here so cost telemetry exists from day one.*

### Validation
```powershell
az group show --name rg-arc-demo -o table
az monitor log-analytics workspace show -g rg-arc-demo -n law-arc-demo -o table
az security pricing show --name VirtualMachines -o table
```

Expected:
- RG exists in australiaeast with the four tags
- Workspace state = `Succeeded`
- Defender VirtualMachines tier = `Standard`, subPlan = `P2`

---

## Phase 2 — VM fleet & Arc onboarding

### 2.1 Sibling RG for the underlying Azure VMs
The Azure VMs live in `rg-arc-demo-infra` so they're cleanly separated from the **Arc machine** records (which land in `rg-arc-demo`).

```powershell
az group create -n rg-arc-demo-infra -l australiaeast `
  --tags owner=corey purpose=arc-demo costcenter=demo env=demo
```

### 2.2 Key Vault for VM admin credentials
```powershell
$kvName = "kv-arcdemo-" + -join ((48..57)+(97..122) | Get-Random -Count 6 | ForEach-Object {[char]$_})
az keyvault create -n $kvName -g rg-arc-demo-infra -l australiaeast `
  --enable-rbac-authorization true `
  --tags owner=corey purpose=arc-demo costcenter=demo env=demo

# Grant self KV admin
$me   = az ad signed-in-user show --query id -o tsv
$kvId = az keyvault show -n $kvName -g rg-arc-demo-infra --query id -o tsv
az role assignment create --assignee $me --role "Key Vault Administrator" --scope $kvId
Start-Sleep 30   # RBAC propagation

$pwd = -join (((48..57)+(65..90)+(97..122)+(33,35,36,37,38,42,64) | Get-Random -Count 24) | ForEach-Object {[char]$_})
az keyvault secret set --vault-name $kvName --name vm-admin-password --value $pwd
```

### 2.3 Network (no inbound — Arc agent is outbound-only)
```powershell
az network nsg  create -g rg-arc-demo-infra -n nsg-arc-demo  -l australiaeast
az network vnet create -g rg-arc-demo-infra -n vnet-arc-demo -l australiaeast `
  --address-prefix 10.50.0.0/16 `
  --subnet-name snet-vms --subnet-prefix 10.50.1.0/24 `
  --network-security-group nsg-arc-demo
```

### 2.4 Service principal for Arc onboarding
Creates an SPN with **Azure Connected Machine Onboarding** on the *target* RG (`rg-arc-demo`). The 8 VMs use this SPN to register themselves as Arc machines.

```powershell
$sub = az account show --query id -o tsv
az ad sp create-for-rbac --name "sp-arc-demo-onboard" `
  --role "Azure Connected Machine Onboarding" `
  --scopes "/subscriptions/$sub/resourceGroups/rg-arc-demo"
# capture appId, password, tenant from output
```

### 2.5 VM SKU + region notes
- **Standard_B2s / B2ms unavailable** in this MCAPS subscription on 2026-05-14 (capacity-restricted in **both** australiaeast and australiasoutheast).
- Settled on **`Standard_B2as_v2`** for all 8 VMs (2 vCPU / 8 GiB / AMD burstable) in **australiaeast**.

Probe technique used to find a working SKU:
```powershell
foreach ($s in 'Standard_B2ms','Standard_B2as_v2','Standard_D2as_v5','Standard_D2s_v5') {
  az group create -n rg-skutest -l australiaeast --only-show-errors | Out-Null
  $err = az vm create -g rg-skutest -n probe -l australiaeast `
    --image MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest `
    --size $s --admin-username azureuser --admin-password $pwd `
    --authentication-type password --public-ip-address '""' --nsg '""' `
    --validate --only-show-errors 2>&1 | Out-String
  if ($err -match "SkuNotAvailable") { "❌ $s" } else { "✅ $s" }
}
az group delete -n rg-skutest --yes --no-wait
```

### 2.6 Deploy 8 VMs (in parallel via `--no-wait`)
| Name | Size | Image | Role |
|---|---|---|---|
| win-app-01..03 | Standard_B2as_v2 | WS 2022 Datacenter Azure Ed. | app |
| win-sql-01..02 | Standard_B2as_v2 | WS 2022 Datacenter Azure Ed. | sql (SQL installed in Phase 5) |
| lnx-app-01..03 | Standard_B2as_v2 | Ubuntu 22.04 LTS gen2 | app |

```powershell
foreach ($vm in $vms) {
  az vm create -g rg-arc-demo-infra -n $vm.n --image $vm.image --size Standard_B2as_v2 `
    -l australiaeast `
    --vnet-name vnet-arc-demo --subnet snet-vms `
    --public-ip-address '""' --nsg '""' `
    --admin-username azureuser --admin-password $pwd --authentication-type password `
    --tags owner=corey purpose=arc-demo costcenter=demo env=demo `
          "role=$($vm.role)" "ostype=$($vm.os)" `
    --no-wait
}
```

### 2.7 Onboard Azure VMs as Arc machines
Set `MSFT_ARC_TEST=true` so the Connected Machine agent permits installation on Azure VMs (per [Microsoft docs](https://aka.ms/azcmagent-testwarning) — for testing/demo only).

**Windows** (`@arc-onboard.ps1` invoked via `RunPowerShellScript`):
```powershell
$env:MSFT_ARC_TEST = 'true'
[Environment]::SetEnvironmentVariable('MSFT_ARC_TEST','true','Machine')
Invoke-WebRequest -Uri https://aka.ms/AzureConnectedMachineAgent `
  -OutFile $env:TEMP\AzureConnectedMachineAgent.msi -UseBasicParsing
Start-Process msiexec.exe -Wait -ArgumentList "/i $env:TEMP\AzureConnectedMachineAgent.msi /qn"
& "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe" connect `
  --service-principal-id <appId> --service-principal-secret <secret> `
  --resource-group rg-arc-demo --tenant-id <tenant> --location australiaeast `
  --subscription-id <sub> `
  --tags "owner=corey,purpose=arc-demo,costcenter=demo,env=demo"
```

**Linux** — the wrapper script `https://aka.ms/azcmagent` *refuses* to install on Azure VMs. **Use the apt repo directly:**
```bash
curl -sSL https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -o /tmp/pmp.deb
sudo dpkg -i /tmp/pmp.deb
sudo apt-get update -qq && sudo apt-get install -y azcmagent
sudo MSFT_ARC_TEST=true azcmagent connect \
  --service-principal-id <appId> --service-principal-secret '<secret>' \
  --resource-group rg-arc-demo --tenant-id <tenant> --location australiaeast \
  --subscription-id <sub> \
  --tags "owner=corey,purpose=arc-demo,costcenter=demo,env=demo"
```

Push to all VMs in parallel via Run Command + PowerShell `Start-Job`:
```powershell
$jobs = @()
foreach ($n in $winVms) { $jobs += Start-Job { az vm run-command invoke -g rg-arc-demo-infra -n $args[0] --command-id RunPowerShellScript --scripts "@$($args[1])" } -ArgumentList $n, $winFile }
foreach ($n in $lnxVms) { $jobs += Start-Job { az vm run-command invoke -g rg-arc-demo-infra -n $args[0] --command-id RunShellScript      --scripts "@$($args[1])" } -ArgumentList $n, $lnxFile }
$jobs | Wait-Job | ForEach-Object { Receive-Job $_; Remove-Job $_ }
```

### 2.8 Auto-shutdown 19:00 ACDT
Created via `Microsoft.DevTestLab/schedules` REST PUT (CLI `az vm auto-shutdown` exists but doesn't expose the timezone reliably).

```powershell
foreach ($vm in $vms) {
  $vmId = az vm show -g rg-arc-demo-infra -n $vm --query id -o tsv
  $body = @{
    location = "australiaeast"
    properties = @{
      status = "Enabled"; taskType = "ComputeVmShutdownTask"
      dailyRecurrence = @{ time = "1900" }
      timeZoneId = "Cen. Australia Standard Time"
      targetResourceId = $vmId
      notificationSettings = @{ status = "Disabled"; timeInMinutes = 30 }
    }
  } | ConvertTo-Json -Depth 6 -Compress
  $body | Out-File "$tmp\shutdown-$vm.json" -Encoding utf8
  az rest --method PUT `
    --url "https://management.azure.com/subscriptions/$sub/resourceGroups/rg-arc-demo-infra/providers/Microsoft.DevTestLab/schedules/shutdown-computevm-$vm`?api-version=2018-09-15" `
    --body "@$tmp\shutdown-$vm.json" `
    --headers "Content-Type=application/json"
}
```

### 2.9 Validation
```powershell
az vm list -g rg-arc-demo-infra --query "[].{name:name,state:provisioningState,size:hardwareProfile.vmSize}" -o table
az connectedmachine list -g rg-arc-demo --query "[].{name:name, status:status, os:osName}" -o table
az resource list -g rg-arc-demo-infra --resource-type Microsoft.DevTestLab/schedules --query "[].name" -o tsv
```

Expected: 8 Azure VMs `Succeeded`, 8 Arc machines `Connected`, 8 shutdown schedules.

---

## Phase 3 — Telemetry & policy

### 3.0 ⚠️ Two critical gotchas discovered (read first)

**Gotcha A — Default outbound is gone after deallocate/start.**
VMs created with `--public-ip-address "" --nsg ""` rely on Azure *default outbound*, which Azure is deprecating. The VMs onboard fine the first time but, **after the first auto-shutdown deallocates them**, they boot with no internet access — Arc agent goes `Disconnected`, all `gbl.his.arc.azure.com` endpoints fail. **Fix: attach a NAT Gateway to the subnet *before* the first auto-shutdown cycle.**

```powershell
az network public-ip create -g rg-arc-demo-infra -n pip-natgw -l australiaeast `
  --sku Standard --allocation-method Static
az network nat gateway create -g rg-arc-demo-infra -n natgw-arc-demo -l australiaeast `
  --public-ip-addresses pip-natgw --idle-timeout 10
az network vnet subnet update -g rg-arc-demo-infra --vnet-name vnet-arc-demo -n snet-vms `
  --nat-gateway natgw-arc-demo
```

**Gotcha B — Linux AMA uses Arc IMDS when Arc is also installed.**
On a Linux VM that's *both* an Azure VM and an Arc machine (our case), the AMA Linux agent detects the Arc agent and switches to the **Arc IMDS endpoint** (`http://localhost:40342/...`). It then expects to find its DCR association attached to the **Arc machine** resource, not the Azure VM resource. Symptoms: AMA is `active`, mdsd starts, but the LAW receives nothing.

**Fix: create the DCR association against the Arc resource ID for Linux** (Windows AMA in our setup uses the Arc identity from the start, so we only need Arc-side DCRA there; for Linux we left the Azure-VM extension because the Arc Linux GC extension stack was broken).

### 3.1 Install AMA on all 8 machines
**Windows** — installed via Arc extension (Arc IMDS auth works on Windows).
```powershell
foreach ($vm in $winVms) {
  az connectedmachine extension create -g rg-arc-demo --machine-name $vm `
    -n AzureMonitorWindowsAgent --publisher Microsoft.Azure.Monitor `
    --type AzureMonitorWindowsAgent --enable-auto-upgrade true
}
```

**Linux** — Arc extension stack on Ubuntu 22.04 + `MSFT_ARC_TEST` is broken (gcad/extd in restart loop). Install via the **Azure VM extension** path instead, and also enable system-assigned MI:
```powershell
foreach ($vm in $lnxVms) {
  az vm extension set -g rg-arc-demo-infra --vm-name $vm `
    -n AzureMonitorLinuxAgent --publisher Microsoft.Azure.Monitor `
    --enable-auto-upgrade true
  az vm identity assign -g rg-arc-demo-infra -n $vm
}
```

### 3.2 Create DCR (perf counters + Win events + Linux syslog)
CLI's `az monitor data-collection rule create --rule-file` rejects the standard ARM payload — use `az rest` instead:

```powershell
$body = @{ location = "australiaeast"; tags = @{...}; properties = @{
  dataSources = @{
    performanceCounters = @(@{
      name = "perfCounters"; streams = @("Microsoft-Perf")
      samplingFrequencyInSeconds = 60
      counterSpecifiers = @(
        "\Processor Information(_Total)\% Processor Time",
        "\Memory\% Committed Bytes In Use",
        "\LogicalDisk(_Total)\% Free Space",
        "\Network Interface(*)\Bytes Total/sec",
        # Linux equivalents
        "\Processor(*)\% Processor Time",
        "\Memory(*)\PercentUsedMemory",
        "\Logical Disk(*)\FreeSpacePercentage",
        "\Network(*)\TotalBytesTransmitted"
      )
    })
    windowsEventLogs = @(@{
      name = "winEvents"; streams = @("Microsoft-Event")
      xPathQueries = @(
        "Application!*[System[(Level=1 or Level=2 or Level=3)]]",
        "System!*[System[(Level=1 or Level=2 or Level=3)]]",
        "Security!*[System[(band(Keywords,4503599627370496))]]"
      )
    })
    syslog = @(@{
      name = "linuxSyslog"; streams = @("Microsoft-Syslog")
      facilityNames = @("auth","authpriv","cron","daemon","kern","syslog","user")
      logLevels = @("Info","Notice","Warning","Error","Critical","Alert","Emergency")
    })
  }
  destinations = @{ logAnalytics = @(@{ name = "law-arc-demo"; workspaceResourceId = $lawId }) }
  dataFlows = @(
    @{ streams=@("Microsoft-Perf");   destinations=@("law-arc-demo") },
    @{ streams=@("Microsoft-Event");  destinations=@("law-arc-demo") },
    @{ streams=@("Microsoft-Syslog"); destinations=@("law-arc-demo") }
  )
}} | ConvertTo-Json -Depth 12 -Compress

az rest --method PUT `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/rg-arc-demo/providers/Microsoft.Insights/dataCollectionRules/dcr-arc-demo?api-version=2023-03-11" `
  --body "@dcr.json" --headers "Content-Type=application/json"
```

### 3.3 Associate DCR with each machine
For **all 8** machines, create the association against the **Arc resource ID** (Microsoft.HybridCompute/machines) — that's the identity the AMA uses to fetch its config.

```powershell
$assoc = @{ properties = @{ dataCollectionRuleId = $dcrId } } | ConvertTo-Json -Compress
foreach ($vm in $allVms) {
  $resId = "/subscriptions/$sub/resourceGroups/rg-arc-demo/providers/Microsoft.HybridCompute/machines/$vm"
  az rest --method PUT `
    --url "https://management.azure.com$resId/providers/Microsoft.Insights/dataCollectionRuleAssociations/dcra-$vm`?api-version=2022-06-01" `
    --body "@assoc.json" --headers "Content-Type=application/json"
}
```

### 3.4 Assign policy initiatives (MCSB + NIST 800-53 r5)
CLI `az policy assignment create` 500s with this set definition — use `az rest`:

```powershell
function Assign-Initiative($name, $display, $setGuid) {
  $body = @{
    location = "australiaeast"
    identity = @{ type = "SystemAssigned" }
    properties = @{
      displayName = $display
      policyDefinitionId = "/providers/Microsoft.Authorization/policySetDefinitions/$setGuid"
      enforcementMode = "Default"
    }
  } | ConvertTo-Json -Depth 6 -Compress
  az rest --method PUT `
    --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Authorization/policyAssignments/$name`?api-version=2023-04-01" `
    --body "@$body" --headers "Content-Type=application/json"
}
Assign-Initiative "mcsb-arc-demo" "Microsoft cloud security benchmark (Arc Demo)" "1f3afdf9-d0c9-4c3d-847f-89da613e70a8"
Assign-Initiative "nist-arc-demo" "NIST SP 800-53 Rev. 5 (Arc Demo)"             "179d1daa-458f-4e47-8086-2a68d0d6c38f"
```

### 3.5 Validation
```kql
Heartbeat | where TimeGenerated > ago(15m)
| summarize Latest=max(TimeGenerated), Beats=count() by Computer, OSType
| order by Computer asc
```
Expected: 8 rows (5 Windows, 3 Linux), beats roughly equal across hosts.

If a row is missing:
1. Check VM is `running` and Arc machine is `Connected`.
2. SSH/RDP via `az vm run-command invoke` and `Restart-Service AzureMonitorAgent` / `sudo systemctl restart azuremonitoragent`.
3. Confirm DCRA exists on the **Arc** resource (HybridCompute), not the Azure VM resource.
4. Wait 4–5 min for first telemetry after restart.

---

## Phase 4 — Workbooks & insights

### 4.0 Two more gotchas

**Gotcha C — Azure CLI on Windows mangles URLs with `?` and `()`.**
PowerShell shells `az` through `cmd.exe`, which treats `?` as a wildcard and `()` as command-grouping. URLs like `Microsoft.OperationsManagement/solutions/VMInsights(law-arc-demo)?api-version=...` blow up before they ever reach the API. **Fix: use PowerShell's native `Invoke-RestMethod` with an `az account get-access-token` bearer token for any management-plane URL that contains `?` or `()`.**

**Gotcha D — Active subscription quietly drifts back to the corp tenant.**
When the CLI token expires and you have multiple tenants signed in, `az account show` silently falls back to the default. **Fix: always re-run `az account set --subscription <mcaps-sub>` at the start of every session and verify with `az account show`.**

### 4.1 Enable VMInsights + ChangeTracking solutions on the workspace
Required for tables `InsightsMetrics`, `ConfigurationChange`, `ConfigurationData` to exist.

```powershell
$token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$hdr = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
function Put-Solution($solName, $product) {
  $body = @{
    location = "australiaeast"
    properties = @{ workspaceResourceId = $lawId }
    plan = @{ name = $solName; publisher = "Microsoft"; product = $product; promotionCode = "" }
  } | ConvertTo-Json -Depth 8
  $url = "https://management.azure.com/subscriptions/$sub/resourceGroups/rg-arc-demo/providers/Microsoft.OperationsManagement/solutions/$([uri]::EscapeDataString($solName))?api-version=2015-11-01-preview"
  Invoke-RestMethod -Method Put -Uri $url -Headers $hdr -Body $body
}
Put-Solution "VMInsights(law-arc-demo)"    "OMSGallery/VMInsights"
Put-Solution "ChangeTracking(law-arc-demo)" "OMSGallery/ChangeTracking"
```

### 4.2 Install Dependency Agent (VM Map view)
- **Windows via Arc** — works fine.
- **Linux** — `DependencyAgentLinux` does NOT support Ubuntu 22.04 kernel ≥ 6.8 (current Azure ships 6.8.0-1052-azure). Skip on Linux; Map view will cover the 5 Windows VMs which is enough for the demo. Delete the failed extension via `az vm extension delete -n DependencyAgentLinux`.

### 4.3 Create VM Insights + Change Tracking DCRs
Two DCRs, both via REST PUT:
- `dcr-vminsights` — streams `Microsoft-InsightsMetrics` (perf counter `\VmInsights\DetailedMetrics`) + `Microsoft-ServiceMap` (DependencyAgent extension).
- `dcr-changetracking` — Windows + Linux variants of the CT extension in one DCR. Streams: `Microsoft-ConfigurationChange`, `Microsoft-ConfigurationChangeV2`, `Microsoft-ConfigurationData`. Toggles for files / software / registry (Win only) / services / inventory.

### 4.4 Associate both DCRs with all 8 Arc machines, install CT extension
DCRA target = Arc HybridCompute resource (consistent with Phase 3). CT extension publisher = `Microsoft.Azure.ChangeTrackingAndInventory`, type `ChangeTracking-Windows` or `ChangeTracking-Linux`.

### 4.5 Deploy the "Arc Demo — Estate Overview" workbook
Single custom workbook with 8 tiles modelled on Nic's story-first flow:
1. **Estate connectivity** (heartbeat bar, last 15m)
2. **Hosts beating over time** (24h timechart)
3. **Per-host CPU utilisation** (avg / max / p95, 24h)
4. **Configuration changes** (by host & type)
5. **Top 25 applications** across the estate
6. **Tagging hygiene** (Resource Graph: hasOwner + hasCostCenter)
7. **Critical & Error Windows events** (24h)
8. **Linux syslog errors** (24h)

Created via REST as `Microsoft.Insights/workbooks` (kind=shared), GUID name, `sourceId` set to the LAW resource ID so it opens in workspace context.

### 4.6 Validation
Wait 10–15 min after CT extension installs for first data. Then in Azure Portal: `rg-arc-demo` → Workbooks → "Arc Demo — Estate Overview". Tagging tile is instant via Resource Graph.

Built-in workbooks to pin alongside (no extra config):
- **Defender for Cloud → Regulatory compliance** (MCSB + NIST scorecards — ~12 h to first populate)
- **Defender for Cloud → Microsoft Defender Vulnerability Management** (CVSS-scored vulns from MDE)
- **Azure Arc → Inventory**
- **Azure Monitor → VM Insights** (Performance + Map tabs)

## Phase 5 — SQL on Arc

### 5.1 Install SQL Server 2022 Developer on the 2 SQL hosts
Headless ISO download + silent setup via `RunPowerShellScript`. ~15-20 min per host.

```powershell
$sqlInstall = @'
$mediaDir = "C:\SQL2022"
New-Item -ItemType Directory -Path $mediaDir -Force | Out-Null
Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2215158" `
  -OutFile "$mediaDir\SQL2022-SSEI-Dev.exe" -UseBasicParsing
& "$mediaDir\SQL2022-SSEI-Dev.exe" /ACTION=Download /MEDIAPATH=$mediaDir /MEDIATYPE=ISO /QUIET
Start-Sleep 60
$iso = Get-ChildItem $mediaDir -Filter *.iso | Select-Object -First 1
$mount = Mount-DiskImage -ImagePath $iso.FullName -PassThru
$drive = (Get-Volume -DiskImage $mount).DriveLetter
& "${drive}:\setup.exe" /Q /ACTION=Install /FEATURES=SQLENGINE /INSTANCENAME=MSSQLSERVER `
  /SQLSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE" `
  /SQLSYSADMINACCOUNTS="BUILTIN\Administrators" `
  /AGTSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE" `
  /TCPENABLED=1 /SECURITYMODE=SQL /SAPWD=$saPwd `
  /IACCEPTSQLSERVERLICENSETERMS /SUPPRESSPRIVACYSTATEMENTNOTICE `
  /UPDATEENABLED=0 /SQLCOLLATION="SQL_Latin1_General_CP1_CI_AS"
Dismount-DiskImage -ImagePath $iso.FullName
'@
foreach ($vm in @('win-sql-01','win-sql-02')) {
  Start-Job -Name "sql-$vm" -ScriptBlock {
    param($vm,$f)
    az vm run-command invoke -g rg-arc-demo-infra -n $vm `
      --command-id RunPowerShellScript --scripts "@$f"
  } -ArgumentList $vm, $f
}
```

### 5.2 Install WindowsAgent.SqlServer extension to Arc-enable SQL
Auto-discovers MSSQL instances and registers them as `Microsoft.AzureArcData/sqlServerInstances`. Enables Best Practice Assessment in the same call. Defender for SQL extension auto-deploys alongside because Defender for Servers Plan 2 is on.

```powershell
foreach ($vm in @('win-sql-01','win-sql-02')) {
  az connectedmachine extension create -g rg-arc-demo --machine-name $vm `
    -n WindowsAgent.SqlServer --publisher Microsoft.AzureData --type WindowsAgent.SqlServer `
    --enable-auto-upgrade true `
    --settings '{\"SqlManagement\":{\"IsEnabled\":true}, \"LicenseType\":\"Paid\", \"AzureBestPracticesAssessment\":{\"IsEnabled\":true}}'
}
```

### 5.3 Validation
- `Microsoft.AzureArcData/sqlServerInstances` should contain `win-sql-01` and `win-sql-02`.
- `azureDefenderStatus` should read `Protected` (Defender for SQL is included with Defender Plan 2).
- Best Practice Assessment first run takes 30-60 min after extension reports healthy.

Portal: **Azure Arc → SQL Server instances** then drill into each for BPA / Migration / Backup tiles.

---

## Phase 6 — Alerting (email via Action Group)

### Decision: email only for v1
Teams webhooks unavailable (MCAPS tenant has no Teams licence). Used **Action Group → email** to `coreyskapin@microsoft.com`.

> 📌 **Note for the demo:** When showing this tile, explicitly call out: *"In a real customer environment we'd add a second action on this Action Group — a webhook that POSTs the same payload to ServiceNow, PagerDuty, or any HTTP endpoint. It's a single `--action webhook <url>` switch. We just don't have a webhook target wired for this demo."*

### 6.1 Action Group
```powershell
az monitor action-group create -g rg-arc-demo -n ag-arc-demo `
  --short-name ArcDemo `
  --action email "corey-email" "coreyskapin@microsoft.com" usecommonalertschema
```

To add a webhook later (one-liner):
```powershell
az monitor action-group update -g rg-arc-demo -n ag-arc-demo `
  --add-action webhook "ticket-stub" "<https://your-webhook-or-ITSM-URL>" `
  usecommonalertschema
```

### 6.2 KQL alert rule — "Host missing heartbeat >10 min"
Scheduled query rule (`Microsoft.Insights/scheduledQueryRules`) created via REST. Evaluates every 5 min over a 15-min window:

```kql
Heartbeat
| summarize LastSeen = max(TimeGenerated) by Computer
| where LastSeen < ago(10m)
```

If any row returns, the rule fires Sev-2 and the Action Group emails. `autoMitigate=true` resolves the alert automatically once heartbeats resume.

### 6.3 Validation
The alert will naturally fire every weeknight ~19:05 ACDT when auto-shutdown deallocates the hosts. You can demonstrate this on demand:
```powershell
az vm deallocate -g rg-arc-demo-infra -n win-app-01
# Wait ~15 min for alert to fire, then start the VM again.
```

---

## Phase 7 — Polish, budget, tear-down

### 7.1 Cost Management budget (AUD 200/mo)
Subscription-scoped budget filtered to both demo RGs. Email alerts at 50/80/100% actual + 100% forecast → `coreyskapin@microsoft.com`.

### 7.2 Demo run-sheet
Saved as `Scratchpad\arc-demo-runsheet.md` — the persona-ordered click path for live demos.

### 7.3 Hibernate / Activate cycle
The demo is designed to be parked between customer engagements and woken up on demand.

| Script | What it does | Cost impact |
|---|---|---|
| **`arc-demo-hibernate.ps1`** | Deallocates all 8 VMs, deletes NAT GW + public IP. Keeps LAW, DCRs, alerts, Arc records, OS disks. | Drops from ~AUD 210/mo (active) to **~AUD 35/mo** hibernated |
| **`arc-demo-activate.ps1`** | Recreates NAT GW + PIP, starts all VMs, restarts Arc + AMA agents, polls until Connected + Heartbeat. `-SkipValidate` for quicker prep-the-night-before runs. | Restores ~AUD 210/mo run-rate |

Activate from cold:
```powershell
.\arc-demo-activate.ps1
# ~5-8 min end-to-end to demo-ready
```

Hibernate after a demo:
```powershell
.\arc-demo-hibernate.ps1
# ~2-3 min to fully torn down to cheap state
```

### 7.4 Tear-down script (full nuke)
Saved as `Scratchpad\arc-demo-teardown.ps1`. Deletes both RGs, both policy assignments, the budget, the onboarding SPN, and reverts Defender for Servers to Free. Supports `-WhatIf`.

### 7.5 Cost states summary
| State | Monthly cost (AUD) | Notes |
|---|---|---|
| **Active** (auto-shutdown 19:00 ACDT, ~10h running/day on weekdays) | ~210 | Defender P2 prorates because deallocated = not billed |
| **Hibernated** (`hibernate.ps1`) | ~35 | OS disks + minimal LAW retention; everything else free at rest |
| **Torn down** (`teardown.ps1`) | 0 | All resources deleted |

### 7.6 Final state inventory
| Component | Resource | Where |
|---|---|---|
| Resource groups | `rg-arc-demo`, `rg-arc-demo-infra` | australiaeast |
| Azure VMs | 5 × Win Server 2022, 3 × Ubuntu 22.04 (`Standard_B2as_v2`) | rg-arc-demo-infra |
| Arc machines | 8 × `Microsoft.HybridCompute/machines` | rg-arc-demo |
| Arc SQL instances | `win-sql-01`, `win-sql-02` | rg-arc-demo |
| Log Analytics | `law-arc-demo` | rg-arc-demo |
| DCRs | `dcr-arc-demo`, `dcr-vminsights`, `dcr-changetracking` | rg-arc-demo |
| Solutions | VMInsights, ChangeTracking | rg-arc-demo |
| Workbook | "Arc Demo — Estate Overview" | rg-arc-demo |
| Alert rule | `alert-host-missing-heartbeat` | rg-arc-demo |
| Action group | `ag-arc-demo` → email | rg-arc-demo |
| Policy initiatives | MCSB, NIST SP 800-53 Rev 5 | subscription scope |
| Defender for Servers | Plan 2 (P2) | subscription scope |
| Key Vault | `kv-arcdemo-<rand>` (admin password) | rg-arc-demo-infra |
| Network | vnet 10.50.0.0/16 + NAT gateway (in active state only) | rg-arc-demo-infra |
| Auto-shutdown | 19:00 ACDT, deallocates VMs | rg-arc-demo-infra |
| Budget | AUD 200/mo, 4 thresholds | subscription scope |

