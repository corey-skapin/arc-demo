# Arc Demo — Act-1 Arc/Monitor runsheet

> Story-first walkthrough for a standalone Azure Arc + Azure Monitor demo. No Azure SRE Agent dependency. The later `sre-agent` repo is optional and can consume the alerts produced here.
>
> Total time: **12-15 min** for the default Arc/Monitor path, or **20-30 min** with optional workload beats. SQL Server/Arc SQL/BPA is an optional advanced branch and is skipped by default.

## 0. Lab shape and workload toggles

Use a clean/new subscription in the **same tenant** you plan to use for any later optional SRE Agent lab. Keep tenant/subscription IDs as runtime inputs; do not hard-code private subscription details.

Default resource naming uses `-NamePrefix arc-demo`:

- Arc/observability RG: `rg-arc-demo`
- Backing lab/optional workload RG: `rg-arc-demo-infra`
- Workbook: **Arc Demo — Estate Overview**

These defaults come from `config\demo-skin.json`. To retarget for another customer, update the skin file and run scripts with `-SkinPath`; see [`reskin-guide.md`](reskin-guide.md).

| Goal | Deploy switches |
|---|---|
| Core Act-1 Arc/Monitor estate | *(defaults: `-DeployArcOnPrem $true`; all optional workloads false)* |
| Arc estate + Azure-native VM comparison | `-DeployAzureVMs $true` |
| Arc estate + Container App fault alert | `-DeployContainerApps $true` |
| Arc estate + AKS crash-loop alert | `-DeployAks $true` |
| Everything live-validated today | `-DeployAzureVMs $true -DeployContainerApps $true -DeployAks $true` |
| Azure-native scenarios only | `-DeployArcOnPrem $false -DeployAzureVMs $true -DeployContainerApps $true` |
| Optional SQL workload beat | Future option: SQL Server on an Azure VM can simulate workload signals, but do not claim SQL Server enabled by Azure Arc in this Azure-only lab; see [`sql-arc-spike.md`](sql-arc-spike.md). |

Example deploy:

```powershell
az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>

.\scripts\Test-Prerequisites.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID>

.\scripts\Deploy-ArcDemo.ps1 `
  -SubscriptionId <SUBSCRIPTION_ID> `
  -TenantId <TENANT_ID> `
  -SkinPath .\config\demo-skin.json `
  -DeployAzureVMs $true `
  -DeployContainerApps $true
```

For custom legacy mixes, pass `-OnPremFleetPath <fleet.json>` using the schema in [`legacy-os-fleet.md`](legacy-os-fleet.md). The file must be a JSON array of fleet objects; use the `onPremFleet` entries in `bicep/params/mixed-legacy-fleet.bicepparam` as the validation reference for WS2012R2, WS2016, WS2019, WS2022, and represented WS2008R2.

## 1. OS-tier talk track

| Tier | What to show | What not to promise |
|---|---|---|
| **WS2016/WS2019/WS2022** | Full Azure Monitor path: AMA, core DCR, Heartbeat, performance/events, VM Insights map, Change Tracking, Defender, Update Manager/Machine Configuration surfaces, alerts/workbooks. | Nothing special; this is the supported Monitor path. |
| **Ubuntu 22.04** | AMA + core DCR + Change Tracking/syslog inventory in the shared workspace. | VM Insights dependency map is intentionally off until Dependency Agent support is validated for the chosen distro/kernel. |
| **WS2008/WS2012-era** | Arc-control-plane-only value: Azure Resource Graph inventory, tags (`osTier`, `monitorTier`, `esuEligible`), ESU conversation, Update Manager assessment where supported, Defender, Machine Configuration/TLS 1.2 policy posture, RBAC/audit. | Do **not** claim AMA, VM Insights, or Change Tracking. AMA is intentionally gated off for pre-2016 Windows. |
| **Represent-not-run legacy** | Use as a narrative placeholder when the Marketplace image is unavailable. | Do not claim a live deployed server exists. |

## 2. Before the meeting (T-30 min)

1. Select the lab subscription:
   ```powershell
   az account set --subscription <SUBSCRIPTION_ID>
   ```
2. If the environment is hibernated, activate it:
   ```powershell
   .\scripts\Activate-ArcDemo.ps1 -NamePrefix arc-demo
   ```
   The activation script waits for Arc Connected, then starts on-demand Update
   Manager patch assessments for the demo machines before the final Heartbeat
   check. The scan runs asynchronously, so allow several minutes before the
   Update Manager beat.
3. Open tabs:
   - **Arc Demo — Estate Overview** workbook.
   - **Azure Arc** > **Machines**, filtered to resource group `rg-arc-demo`.
     Fallback: open resource group `rg-arc-demo` and filter resource type to
     `Microsoft.HybridCompute/machines`.
   - **Resource Graph Explorer** for tag and inventory queries.
   - **Machine configuration** or **Azure Policy → Compliance**, filtered to the demo Arc machines if the tenant exposes those blades.
   - Open **Azure Update Manager**, then **Machines**, filtered to the demo RG.
   - Open **Defender for Cloud**, then **Recommendations** and **Regulatory compliance**.
   - Portal search: **SQL Server instances - Azure Arc** only if the optional advanced SQL path was enabled with `-InstallSql`.
   - Resource group `rg-arc-demo`, then **Alerts** and **Action group**.
   - If deployed: Container App, AKS cluster, and Azure-native VM in `rg-arc-demo-infra`.
4. Sanity-check Monitor-supported hosts are reporting:
   ```kql
   Heartbeat
   | where TimeGenerated > ago(30m)
   | summarize LastHeartbeat=max(TimeGenerated) by Computer, OSType
   | order by Computer asc
   ```
   In workbook and Logs pickers, use **`law-arc-demo` in `rg-arc-demo`**. Do not
   use the `McapsGovernance` / `mcaps...-la` workspace; that is a subscription
   governance workspace and is not part of this demo.

## 3. Live flow

### 3.1 Frame: the problem (1 min)

"This is for customers who already have a hybrid estate and need one operations plane: inventory, config, patch/security posture, logs, alerts, and a path to modern AI-assisted ops later. Today is Act 1: Arc + Monitor. It stands alone."

Presenter rule from Nic's runthrough: do not open the Arc server resource list
first. Lead with the workbook and operational outcomes, then let the customer ask
how the estate got there.

### 3.2 Estate overview workbook (2 min)

Open **Arc Demo — Estate Overview**.

- Show connected hosts and OS mix.
- Call out default WS2016/2019/2022 + Ubuntu fleet.
- If using a mixed legacy fleet, point to `monitorTier=full-monitor` versus `arc-control-plane-only`.
- If populated, use software/application inventory as the start of an application
  rationalisation conversation.
- Message: "This is what a head of platform wants to see on Monday morning:
  estate, health, drift, risk. Arc is how the on-prem estate enters Azure
  operations."

### 3.3 Inventory and Resource Graph (2 min)

Open **Azure Arc** > **Machines**, then filter to resource group `rg-arc-demo`.
If that navigation moves, open resource group `rg-arc-demo` and filter resource
type to `Microsoft.HybridCompute/machines`. This machine list is the reliable
portal inventory view; there is no separate **Inventory** blade in the current
Azure Arc portal experience. Use **Resource Graph Explorer** for the tag-based
inventory query below.

- Show tags: `osTier`, `monitorTier`, `esuEligible`, `inventory=arc`, `updateManager=assessment`, `defender=plan2`, `machineConfig=enabled`.
- For 2008/2012-era entries, explain: "No AMA. Still useful in the Azure control plane for inventory, governance, ESU planning, Defender/Update Manager/Machine Configuration surfaces where supported."

Useful Azure Resource Graph query:

```kql
resources
| where type =~ 'microsoft.hybridcompute/machines'
| project name, osTier=tostring(tags.osTier), monitorTier=tostring(tags.monitorTier), esuEligible=tostring(tags.esuEligible)
| order by name asc
```

### 3.4 Machine Configuration / TLS 1.2 beat (2 min)

Open **Machine configuration** if it is available in the portal, or use
**Azure Policy → Compliance** filtered to the demo assignments and Arc machines.
Use the compliance workbook if the tenant hides or delays the Machine
configuration blade.

Talk track:

- "Arc makes server configuration policy-addressable from Azure. TLS 1.2 is the easy customer-relevant example: audit first, then enforce/remediate through policy once agreed."
- "This repo surfaces the Machine Configuration beat and tags machines for it; use a live TLS policy assignment only if you have pre-staged one in the lab."

### 3.5 Update Manager and ESU beat (3 min)

Open **Azure Update Manager**, then **Machines**, filtered to `rg-arc-demo`.

- Periodic assessment should be enabled on all demo Arc machines. If the portal
  still says machines do not have periodic assessment enabled, refresh after a
  few minutes; `Deploy-ArcDemo.ps1` sets `assessment-mode=AutomaticByPlatform`
  on the Arc machine OS profile.
- Show patch assessment/compliance. `Activate-ArcDemo.ps1` starts an on-demand
  patch assessment during wake-up; if the blade is still empty, refresh or come
  back after the assessment finishes.
- In the current lab, Windows assessment data is the reliable live proof point.
  Linux rows can lag while the `LinuxOsUpdateExtension` is provisioning; do not
  pause the demo waiting for Linux rows.
- For WS2016+: tie patch posture to the full Monitor path.
- For WS2008/WS2012-era: pivot to ESU eligibility and lifecycle risk.
- Message: "Arc lets the platform team discuss patching and ESU from one Azure place, even before migration."

### 3.6 Defender for Cloud (3 min)

Open **Defender for Cloud**, then **Recommendations** and **Regulatory compliance**.

- Show Defender for Servers Plan 2 at subscription scope.
- Current demo has Defender for Servers Plan 2 enabled and MDE extensions on the
  Arc machines (`MDE.Windows` on Windows, `MDE.Linux` on Linux).
- Use live recommendations as the co-sell: the lab currently surfaces examples
  such as missing periodic update checks, Windows Defender Exploit Guard,
  Linux SSH key authentication, and secure protocol recommendations.
- Open a machine recommendation or vulnerability finding if populated. If
  vulnerability findings are available, show CVE/CVSS context and link it back
  to Defender for Servers Plan 2 coverage.
- Do not promise CVE/CVSS drill-down unless the Defender vulnerability blade is
  visibly populated at demo time. The reliable claim is posture, recommendations
  and MDE coverage.
- Show MCSB/NIST assignments; remind that policy/compliance can take hours to populate.
- Message: "Security sees the same governance plane for Azure and hybrid
  resources. This is the same conversation whether the server is Azure, VMware,
  or another connected environment."

### 3.7 Monitor deep dive: 2016+ full path (4 min)

Use a WS2016/2019/2022 host.

- **Logs**: Heartbeat, Perf, Event, ConfigurationChange.
- **VM Insights**: dependency map for supported Windows tiers.
- **Change Tracking**: software/service/file/registry drift.
- **Performance**: CPU and memory trends from Perf/InsightsMetrics.

Queries:

```kql
Perf
| where TimeGenerated > ago(30m)
| summarize AvgCpu=avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
```

```kql
ConfigurationChange
| where TimeGenerated > ago(7d)
| summarize Changes=count() by Computer, ConfigChangeType
```

Key line: "2016+ gets the full Monitor story; pre-2016 stays Arc-control-plane-only by design."

Optional customer-value line: "This is the evidence that stops a sizing or SQL
licensing conversation being driven by fear. If the actual peak is modest, the
answer may be right-size and govern, not automatically buy bigger."

### 3.8 SQL workload simulation (optional DBA beat, 2 min)

Skip this beat in the default Azure-only demo unless you have deployed the SQL
workload simulator. This is a SQL-shaped workload signal from an Arc-enabled
Windows server, not SQL Server enabled by Azure Arc. See
[`sql-workload-simulation.md`](sql-workload-simulation.md) and
[`sql-arc-spike.md`](sql-arc-spike.md).

- Show `win-sql-01`.
- Show `ArcSqlWorkloadDemo` Application events in Log Analytics.
- Position BPA, Defender for SQL, and SQL inventory as a future/customer-real SQL
  host follow-on, not as a claim in this Azure-only lab.

### 3.9 Alerts and action group (2 min)

Open resource group `rg-arc-demo`, then **Alerts**.

- Show `alert-arc-demo-host-missing-heartbeat`.
- Show Action Group email receiver.
- Explain that this Action Group is the seam a later optional `sre-agent` repo can consume; this repo itself stops at Azure Monitor alerting.
- ITSM line: "In a customer environment, this Action Group can also carry a
  webhook into ServiceNow, PagerDuty, or another HTTP endpoint. The demo keeps
  email as the simplest visible proof."

Optional force alert:

```powershell
az vm deallocate -g rg-arc-demo-infra -n win-app-01
# Reset after the demo:
az vm start -g rg-arc-demo-infra -n win-app-01
```

### 3.10 Only now open the Arc server resource (2 min)

After the customer has seen the workbook, security, operations, performance, and
alert story, open **Azure Arc** > **Machines** and drill into one machine.
Fallback: open `rg-arc-demo` and select any `Microsoft.HybridCompute/machines`
resource.

- Show the resource identity and tags.
- Show extensions, RBAC, Activity log, and the Azure-side management surface.
- Key line: "The machine owner still has control. Platform teams get inventory,
  policy, monitoring, and audit without starting from RDP or server-by-server
  tooling."

## 4. Optional workload beats

### 4.1 Azure-native VM comparison (`-DeployAzureVMs $true`)

Open the Azure-native VM in `rg-arc-demo-infra` (default `az-arcdemo-01`) and Azure Monitor.

- Show it is a native `Microsoft.Compute/virtualMachines` resource, not an Arc machine.
- Show AMA + DCR associations to the same Log Analytics workspace.
- Message: "Arc and native Azure VMs land in the same operations plane."

### 4.2 Container App fault (`-DeployContainerApps $true`)

Break:

```powershell
az containerapp update `
  --resource-group rg-arc-demo-infra `
  --name ca-arc-demo-fault `
  --set-env-vars SIMULATE_CRASH=true
```

Show **RestartCount** metric and `alert-arc-demo-containerapp-restarts` routed to the same Action Group. Repair:

```powershell
az containerapp update `
  --resource-group rg-arc-demo-infra `
  --name ca-arc-demo-fault `
  --set-env-vars SIMULATE_CRASH=false
```

Full commands: [`container-app-fault.md`](container-app-fault.md).

### 4.3 AKS crash-loop (`-DeployAks $true`)

Break:

```powershell
az aks command invoke `
  --resource-group rg-arc-demo-infra `
  --name arc-demo-aks `
  --command "kubectl set env deployment/crashloop-demo -n arc-demo-aks CRASH_LOOP=true"
```

Show Container Insights data and `alert-arc-demo-aks-pod-restarts`. Repair:

```powershell
az aks command invoke `
  --resource-group rg-arc-demo-infra `
  --name arc-demo-aks `
  --command "kubectl set env deployment/crashloop-demo -n arc-demo-aks CRASH_LOOP=false && kubectl rollout status deployment/crashloop-demo -n arc-demo-aks --timeout=180s"
```

Full commands: [`aks-break-scenario.md`](aks-break-scenario.md).

## 5. Close (1 min)

"This repo is the reusable Arc + Monitor spine. It runs on its own. For a later Act 2, an optional SRE Agent repo can attach to these Azure Monitor alerts, but nothing here depends on that."

## 6. After the meeting

1. Reset any optional faults (`SIMULATE_CRASH=false`, `CRASH_LOOP=false`).
2. Hibernate if you do not need the lab running:
   ```powershell
   .\scripts\Hibernate-ArcDemo.ps1 -NamePrefix arc-demo
   ```
3. For permanent cleanup:
   ```powershell
   .\scripts\Remove-ArcDemo.ps1 -WhatIf
   .\scripts\Remove-ArcDemo.ps1
   ```
